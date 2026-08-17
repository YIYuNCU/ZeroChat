import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'pages/chat_list_page.dart';
import 'pages/contacts_page.dart';
import 'pages/discover_page.dart';
import 'pages/profile_page.dart';
import 'pages/create_group_page.dart';
import 'widgets/tab_bar.dart';
import 'services/storage_service.dart';
import 'services/secure_storage_service.dart';
import 'services/role_service.dart';
import 'services/memory_service.dart';
import 'services/media_cache_service.dart';
import 'services/task_service.dart';
import 'services/settings_service.dart';
import 'services/chat_list_service.dart';
import 'services/favorite_service.dart';
import 'services/moments_service.dart';
import 'services/image_service.dart';
import 'services/api_service.dart';
import 'services/notification_service.dart';
import 'services/background_runtime_service.dart';
import 'services/intent_service.dart';
import 'services/realtime_sync_service.dart';
import 'services/secure_websocket_client.dart';
import 'core/chat_controller.dart';
import 'core/moments_scheduler.dart';
import 'core/message_store.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaCacheService.configureImageCache();

  // ========== 最小初始化（仅本地存储，无网络请求） ==========
  await StorageService.init();
  await SecureStorageService.init();
  await SettingsService.init();

  // 设置状态栏样式
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
    ),
  );

  runApp(const ZeroChatApp());

  // ========== 权限请求（不阻塞启动） ==========
  unawaited(
    _requestPermissions().then((_) {
      debugPrint('✅ Permissions requested');
    }),
  );

  // ========== 后台初始化（不阻塞首帧渲染） ==========
  unawaited(_initServicesInBackground());
}

Future<void> _initServicesInBackground() async {
  // 让首帧先渲染
  await Future<void>.delayed(const Duration(milliseconds: 50));

  // 配置意图识别服务
  IntentService.configure(
    apiUrl: SettingsService.instance.intentApiUrl,
    apiKey: SettingsService.instance.intentApiKey,
    model: SettingsService.instance.intentModel,
    useAi: SettingsService.instance.intentEnabled,
  );

  // ===== 本地服务（无网络请求，并行执行） =====
  await Future.wait([
    RoleService.init(),
    ChatListService.init(),
    FavoriteService.init(),
    MomentsService.init(),
    ImageService.init(),
    NotificationService.instance.init(),
    ChatController.init(),
  ]);
  debugPrint('✅ Local services initialized');
  unawaited(MediaCacheService.trimDiskCaches());

  // ===== Memory/Task 本地部分（先加载缓存再发起网络同步） =====
  // _loadCoreMemory / _loadTasks 是本地 I/O，先完成让 UI 可用
  // 网络同步部分在后台静默执行
  await Future.wait([
    MemoryService.loadLocalOnly(),
    TaskService.loadLocalOnly(),
  ]);
  debugPrint('✅ Memory/task cache loaded');

  // ===== 后台服务 =====
  await BackgroundRuntimeService.init(
    enabled: SettingsService.instance.backgroundRuntimeEnabled,
  );
  final lifecycleState = WidgetsBinding.instance.lifecycleState;
  BackgroundRuntimeService.notifyAppLifecycle(
    inForeground: lifecycleState == AppLifecycleState.resumed,
  );
  RealtimeSyncService.init();
  await MomentsScheduler.instance.init();
  unawaited(
    SecureWebSocketClient.instance
        .ensureConnected()
        .then((_) {
          // 连接就绪后补齐上次会话遗留（弱网漏收/进程被杀）的异步聊天回复。
          return ChatController.instance.startPushRecovery();
        })
        .catchError((Object e) {
          debugPrint('⚠️ startPushRecovery failed: $e');
        }),
  );

  // ===== 网络同步（静默后台，不阻塞任何 UI） =====
  unawaited(_syncWithBackendInBackground());

  // ===== 网络服务同步（延迟执行，避免启动时集中请求） =====
  unawaited(_syncNetworkServices());
}

Future<void> _syncNetworkServices() async {
  // 延迟 2 秒，等核心 UI 和 WebSocket 就绪
  await Future<void>.delayed(const Duration(seconds: 2));
  bool anyFailed = false;
  try {
    await MemoryService.refreshCoreMemoryFromBackend();
    debugPrint('✅ MemoryService backend sync complete');
  } catch (e) {
    debugPrint('⚠️ MemoryService backend sync failed: $e');
    anyFailed = true;
  }
  try {
    await TaskService.fetchFromBackend();
    debugPrint('✅ TaskService backend sync complete');
  } catch (e) {
    debugPrint('⚠️ TaskService backend sync failed: $e');
    anyFailed = true;
  }
  if (anyFailed && backendSyncNotifier.value != BackendSyncStatus.fail) {
    backendSyncNotifier.value = BackendSyncStatus.fail;
  }
}

Future<void> _syncWithBackendInBackground() async {
  // Let first frame render first, then start network sync.
  await Future<void>.delayed(const Duration(milliseconds: 100));
  await _syncWithBackend();
}

/// 后端同步状态
enum BackendSyncStatus { initial, syncing, success, fail }

final ValueNotifier<BackendSyncStatus> backendSyncNotifier = ValueNotifier(
  BackendSyncStatus.initial,
);

bool _backendAvailable = false;
bool get isBackendAvailable => _backendAvailable;

/// 启动时同步后端数据
Future<void> _syncWithBackend() async {
  backendSyncNotifier.value = BackendSyncStatus.syncing;
  final backendUrl = SettingsService.instance.backendUrl;
  debugPrint('🔗 Backend URL: $backendUrl');

  final isAvailable = await ApiService.isBackendAvailable();
  _backendAvailable = isAvailable;

  if (!isAvailable) {
    debugPrint('⚠️ Backend unavailable at: $backendUrl');
    debugPrint('⚠️ 提示：请在 API 设置页面检查服务器地址是否正确');
    backendSyncNotifier.value = BackendSyncStatus.fail;
    return;
  }

  debugPrint('✅ Backend available, syncing data...');

  try {
    // 启动阶段仅同步公开设置，不默认拉取密钥
    await SettingsService.instance.syncPublicSettingsFromBackend();

    // 升级时先把旧客户端的本地主动消息配置迁移到服务端，再以下行为准。
    final proactiveMigrationComplete =
        await RoleService.migrateProactiveConfigsToBackendIfNeeded();
    if (!proactiveMigrationComplete) {
      throw StateError('主动消息配置迁移尚未完成');
    }

    // 同步角色数据
    await RoleService.syncIfHashMismatch();

    // 本地快照可立即展示，仅在 hash 变化时下载完整朋友圈列表。
    await MomentsService.instance.syncIfHashMismatch();

    // 同步任务数据
    await TaskService.fetchFromBackend();

    debugPrint('✅ Backend sync complete');
    backendSyncNotifier.value = BackendSyncStatus.success;
  } catch (e) {
    debugPrint('⚠️ Backend sync failed: $e');
    backendSyncNotifier.value = BackendSyncStatus.fail;
  }
}

/// 请求运行时权限
Future<void> _requestPermissions() async {
  // 请求通知权限
  if (await Permission.notification.isDenied) {
    await Permission.notification.request();
  }

  // 请求相机权限
  if (await Permission.camera.isDenied) {
    await Permission.camera.request();
  }

  // 请求存储权限（Android 13+ 使用 photos）
  if (await Permission.photos.isDenied) {
    await Permission.photos.request();
  }

  // 旧版存储权限
  if (await Permission.storage.isDenied) {
    await Permission.storage.request();
  }

  debugPrint('✅ Permissions requested');
}

class ZeroChatApp extends StatefulWidget {
  const ZeroChatApp({super.key});

  @override
  State<ZeroChatApp> createState() => _ZeroChatAppState();
}

class _ZeroChatAppState extends State<ZeroChatApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // App starts in foreground.
    SecureWebSocketClient.instance.setForeground(true);
    BackgroundRuntimeService.notifyAppLifecycle(inForeground: true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      SecureWebSocketClient.instance.setForeground(true);
      BackgroundRuntimeService.notifyAppLifecycle(inForeground: true);
      // 回到前台后确保连接并做一次全量对账，补齐后台期间可能漏收的消息。
      unawaited(() async {
        await SecureWebSocketClient.instance.ensureConnected();
        await RealtimeSyncService.resyncAll();
      }());
      return;
    }

    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      SecureWebSocketClient.instance.setForeground(false);
      BackgroundRuntimeService.notifyAppLifecycle(inForeground: false);
      // 进入后台前 flush 挂起的消息写入，避免防抖窗口内的数据丢失。
      unawaited(MessageStore.instance.flushPendingSaves());
      unawaited(SecureWebSocketClient.instance.ensureConnected());
    }
  }

  @override
  void didHaveMemoryPressure() {
    MediaCacheService.clearInMemoryImageCache();
    debugPrint('MediaCacheService: cleared decoded image cache on memory pressure');
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ZeroChat',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF07C160),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFEDEDED),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFEDEDED),
          foregroundColor: Color(0xFF000000),
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: true,
          titleTextStyle: TextStyle(
            color: Color(0xFF000000),
            fontSize: 17,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
      home: const MainPage(),
    );
  }
}

class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  int _currentIndex = 0;
  final GlobalKey<ContactsPageState> _contactsKey = GlobalKey();
  bool _bannerDismissed = false;

  List<Widget> get _pages => [
    const ChatListPage(),
    ContactsPage(key: _contactsKey),
    const DiscoverPage(),
    const ProfilePage(),
  ];

  final List<String> _titles = const ['ZeroChat', '通讯录', '发现', '我'];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_titles[_currentIndex]),
        actions: [
          IconButton(
            onPressed: () => _handleAddAction(context),
            icon: const Icon(Icons.add_circle_outline, size: 24),
          ),
        ],
      ),
      body: Column(
        children: [
          ValueListenableBuilder<BackendSyncStatus>(
            valueListenable: backendSyncNotifier,
            builder: (context, status, _) {
              if (status == BackendSyncStatus.fail && !_bannerDismissed) {
                return _buildSyncFailBanner();
              }
              return const SizedBox.shrink();
            },
          ),
          Expanded(
            child: IndexedStack(index: _currentIndex, children: _pages),
          ),
        ],
      ),
      bottomNavigationBar: AppBottomTabBar(
        currentIndex: _currentIndex,
        onTap: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
      ),
    );
  }

  Widget _buildSyncFailBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: const Color(0xFFFFF3E0),
      child: Row(
        children: [
          const Icon(Icons.wifi_off, size: 14, color: Color(0xFFE65100)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '网络不稳定，部分数据未同步',
              style: const TextStyle(fontSize: 12, color: Color(0xFFE65100)),
            ),
          ),
          GestureDetector(
            onTap: () {
              backendSyncNotifier.value = BackendSyncStatus.syncing;
              unawaited(_syncWithBackendInBackground());
            },
            child: const Text(
              '重试',
              style: TextStyle(fontSize: 12, color: Color(0xFF07C160)),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () => setState(() => _bannerDismissed = true),
            child: const Icon(Icons.close, size: 14, color: Color(0xFFAAAAAA)),
          ),
        ],
      ),
    );
  }

  void _handleAddAction(BuildContext context) {
    // 统一显示菜单，所有页面都一样
    _showAddMenu(context);
  }

  void _showAddRoleDialog(BuildContext context) async {
    final nameController = TextEditingController();
    final promptController = TextEditingController();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新建角色'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: '角色名称',
                hintText: '例如: 编程助手',
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: promptController,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: '角色设定',
                hintText: '例如: 你是一个专业的编程助手...',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('创建'),
          ),
        ],
      ),
    );

    if (confirmed == true && nameController.text.isNotEmpty) {
      await RoleService.createRole(
        name: nameController.text,
        systemPrompt: promptController.text.isNotEmpty
            ? promptController.text
            : '你是一个友好的AI助手。',
      );
      // 刷新列表
      ChatListService.instance.refresh();
      _contactsKey.currentState?.refresh();
      setState(() {});
    }
  }

  void _showAddMenu(BuildContext context) {
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        MediaQuery.of(context).size.width - 150,
        kToolbarHeight + MediaQuery.of(context).padding.top,
        10,
        0,
      ),
      color: const Color(0xFF4C4C4C),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      items: [
        _buildMenuItem(Icons.group_add, '发起群聊'),
        _buildMenuItem(Icons.person_add, '添加朋友'),
      ],
    ).then((value) {
      if (!context.mounted) {
        return;
      }
      if (value == '发起群聊') {
        _navigateToCreateGroup();
      } else if (value == '添加朋友') {
        _showAddRoleDialog(context);
      }
    });
  }

  PopupMenuItem<String> _buildMenuItem(IconData icon, String text) {
    return PopupMenuItem<String>(
      value: text,
      child: Row(
        children: [
          Icon(icon, color: Colors.white, size: 20),
          const SizedBox(width: 12),
          Text(text, style: const TextStyle(color: Colors.white, fontSize: 16)),
        ],
      ),
    );
  }

  void _navigateToCreateGroup() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const CreateGroupPage()),
    ).then((_) {
      ChatListService.instance.refresh();
      setState(() {});
    });
  }
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'pages/chat_list_page.dart';
import 'pages/contacts_page.dart';
import 'pages/discover_page.dart';
import 'pages/profile_page.dart';
import 'pages/create_group_page.dart';
import 'widgets/tab_bar.dart';
import 'services/storage_service.dart';
import 'services/role_service.dart';
import 'services/memory_service.dart';
import 'services/task_service.dart';
import 'services/settings_service.dart';
import 'services/chat_list_service.dart';
import 'services/favorite_service.dart';
import 'services/moments_service.dart';
import 'services/image_service.dart';
import 'services/api_service.dart';
import 'services/notification_service.dart';
import 'services/intent_service.dart';
import 'core/chat_controller.dart';
import 'core/proactive_message_scheduler.dart';
import 'core/moments_scheduler.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ========== 请求权限 ==========
  await _requestPermissions();

  // ========== 初始化服务 ==========
  await StorageService.init();
  await SettingsService.init();

  // 配置意图识别服务
  IntentService.configure(
    apiUrl: SettingsService.instance.intentApiUrl,
    apiKey: SettingsService.instance.intentApiKey,
    model: SettingsService.instance.intentModel,
    useAi: SettingsService.instance.intentEnabled,
  );

  await RoleService.init();
  await MemoryService.init();
  await TaskService.init();
  await ChatListService.init();
  await FavoriteService.init();
  await MomentsService.init();
  await ImageService.init();
  await NotificationService.instance.init();
  await ChatController.init();
  await ProactiveMessageScheduler.instance.init();
  await MomentsScheduler.instance.init();

  // ========== 后端同步 ==========
  await _syncWithBackend();

  // 设置状态栏样式
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
    ),
  );

  runApp(const ZeroChatApp());
}

/// 后端同步状态
bool _backendAvailable = false;
bool get isBackendAvailable => _backendAvailable;

/// 启动时同步后端数据
Future<void> _syncWithBackend() async {
  final backendUrl = SettingsService.instance.backendUrl;
  debugPrint('🔗 Backend URL: $backendUrl');

  final isAvailable = await ApiService.isBackendAvailable();
  _backendAvailable = isAvailable;

  if (!isAvailable) {
    debugPrint('⚠️ Backend unavailable at: $backendUrl');
    debugPrint('⚠️ 提示：请在 API 设置页面检查服务器地址是否正确');
    return;
  }

  debugPrint('✅ Backend available, syncing data...');

  // 同步角色数据
  await RoleService.fetchFromBackend();

  // 同步朋友圈数据
  await MomentsService.instance.fetchFromBackend();

  // 同步任务数据
  await TaskService.fetchFromBackend();

  debugPrint('✅ Backend sync complete');
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

class ZeroChatApp extends StatelessWidget {
  const ZeroChatApp({super.key});

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
          // 只保留 + 按钮，去掉搜索
          IconButton(
            onPressed: () => _handleAddAction(context),
            icon: const Icon(Icons.add_circle_outline, size: 24),
          ),
        ],
      ),
      body: IndexedStack(index: _currentIndex, children: _pages),
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

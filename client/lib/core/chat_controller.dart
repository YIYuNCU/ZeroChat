import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import '../models/message.dart';
import '../models/role.dart';
import '../models/chat_context.dart';
import '../models/group_chat.dart';
import '../services/api_service.dart';
import '../services/role_service.dart';
import '../services/group_chat_service.dart';
import '../services/chat_list_service.dart';
import '../services/settings_service.dart';
import '../services/notification_service.dart';
import '../services/background_runtime_service.dart';
import 'message_store.dart';
import 'message_parts.dart';
import 'segment_sender.dart';
import 'group_scheduler.dart';
import 'memory_manager.dart';
import 'moments_scheduler.dart';
import '../services/intent_service.dart';
import '../services/memory_service.dart';
import '../services/sticker_service.dart';
import '../services/secure_websocket_client.dart';
import '../services/task_service.dart';
import '../services/emoji_service.dart';
import '../services/storage_service.dart';

/// 待发送聚合项：文本项（text 非空）或图片项（imagePath 非空）。
/// 同一等待窗口内的文本与图片会被合并成一次请求。
class _PendingChatItem {
  final String messageId;
  final String? text;
  final String? imagePath;

  const _PendingChatItem({
    required this.messageId,
    this.text,
    this.imagePath,
  });

  bool get isImage => imagePath != null;
}

/// The server can return tool side effects alongside the assistant text.
class _AiReply {
  final String content;
  final List<String> emojisCalled;

  const _AiReply(this.content, this.emojisCalled);
}

/// 聊天核心引擎
/// 整个项目中唯一负责消息流转、AI 调度、分段发送、群聊控制、记忆更新的权威组件
/// UI 层严禁直接调用 AI、处理记忆、拆分消息
class ChatController extends ChangeNotifier {
  static final ChatController _instance = ChatController._internal();
  factory ChatController() => _instance;
  ChatController._internal();

  static ChatController get instance => _instance;

  final Random _random = Random();

  /// 聊天上下文缓存
  final Map<String, ChatContext> _contexts = {};

  /// 正在处理的聊天 ID 集合
  final Set<String> _processingChats = {};

  /// 后台等待中的请求 ID（按 chatId）
  final Map<String, String> _activeRequestIds = {};

  /// "正在输入"状态回调（按 chatId）- 仅用于单聊
  final Map<String, void Function(bool)> _typingCallbacks = {};

  /// 异步聊天任务等待（按 task_id）—— 仅内存，用于当次请求的活跃 await 关联。
  final Map<String, Completer<Map<String, dynamic>>> _pendingChatTasks = {};

  /// 已渲染的任务 id 集合（内存镜像，落盘见 [_kRenderedTasksKey]）。
  /// 用于跨"实时推送 / 超时恢复 / 重启恢复"多路径去重，避免同一回复重复渲染。
  final Set<String> _renderedTaskIds = <String>{};
  bool _persistedStateLoaded = false;

  /// 持久化待处理任务的存储键：task_id -> 渲染所需的上下文快照。
  /// 使 pending 任务在 App 重启后仍可恢复（内存 completer 会丢失）。
  static const String _kPendingTasksKey = 'pending_chat_tasks_v1';

  /// 已渲染任务 id 的存储键（FIFO 截断，防止无限增长）。
  static const String _kRenderedTasksKey = 'rendered_chat_tasks_v1';
  static const int _kRenderedTasksMax = 800;

  /// 恢复去重：避免并发（重连 + 前台恢复 + 启动）触发多次恢复请求。
  bool _recoveringPersistedTasks = false;

  /// 异步聊天任务推送订阅
  StreamSubscription<Map<String, dynamic>>? _chatPushSubscription;

  /// 待发送消息队列（用于消息合并等待，文本与图片统一入此缓冲）
  final Map<String, List<_PendingChatItem>> _pendingMessages = {};

  /// 等待定时器（用于消息合并）
  final Map<String, Timer> _waitTimers = {};

  /// 初始化
  static Future<void> init() async {
    await MessageStore.init();
    debugPrint('ChatController initialized');
  }

  /// 启动异步聊天回复的恢复机制：注册推送监听器并做一次补偿恢复。
  /// 在 WebSocket 就绪后调用，用于补齐上次会话遗留（弱网漏收/进程被杀）的回复。
  Future<void> startPushRecovery() async {
    _ensureChatPushListener();
    await _ensurePersistedStateLoaded();
    await recoverPendingChatTasks();
  }

  // ========== 公开接口 ==========

  /// 初始化聊天上下文（确保消息已加载）
  Future<ChatContext> initChat(
    String chatId, {
    bool isGroup = false,
    List<String>? memberIds,
  }) async {
    // 确保消息已加载
    await MessageStore.instance.ensureLoaded(chatId);

    if (!_contexts.containsKey(chatId)) {
      _contexts[chatId] = ChatContext(
        chatId: chatId,
        isGroup: isGroup,
        memberIds: memberIds,
        messageCount: MessageStore.instance.getMessageCount(chatId),
      );
    } else {
      // 更新消息数量
      final ctx = _contexts[chatId]!;
      _contexts[chatId] = ctx.copyWith(
        messageCount: MessageStore.instance.getMessageCount(chatId),
      );
    }

    // 强制刷新 Stream 确保 UI 收到历史消息
    MessageStore.instance.refreshStream(chatId);

    return _contexts[chatId]!;
  }

  /// 获取聊天上下文
  ChatContext? getContext(String chatId) => _contexts[chatId];

  /// 获取聊天记录数量（从 MessageStore 读取，确保准确）
  int getMessageCount(String chatId) {
    return MessageStore.instance.getMessageCount(chatId);
  }

  /// 创建消息（统一入口）
  Message createMessage({
    required String senderId,
    required String receiverId,
    required String content,
    Message? quotedMessage,
  }) {
    if (quotedMessage != null) {
      return Message.withQuote(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        senderId: senderId,
        receiverId: receiverId,
        content: content,
        quotedMessage: quotedMessage,
      );
    }
    return Message(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      senderId: senderId,
      receiverId: receiverId,
      content: content,
      timestamp: DateTime.now(),
    );
  }

  Future<bool> _ensureConnectionBeforeSend(String chatId) async {
    try {
      if (SecureWebSocketClient.instance.isConnected) {
        return true;
      }

      await SecureWebSocketClient.instance.ensureConnected();
      return SecureWebSocketClient.instance.isConnected;
    } catch (e) {
      debugPrint(
        'ChatController: pre-send websocket check failed for $chatId, retrying: $e',
      );
      try {
        // Prefer in-place reconnect to avoid unnecessary active disconnects.
        await SecureWebSocketClient.instance.ensureConnected();
        return SecureWebSocketClient.instance.isConnected;
      } catch (e2) {
        debugPrint(
          'ChatController: in-place websocket retry failed for $chatId, forcing reconnect: $e2',
        );
        try {
          await SecureWebSocketClient.instance.recoverConnectionWithoutClose(
            reason: 'chat_pre_send',
          );
          return SecureWebSocketClient.instance.isConnected;
        } catch (e3) {
          debugPrint(
            'ChatController: forced websocket reconnect failed before send for $chatId: $e3',
          );
          return false;
        }
      }
    }
  }

  /// 发送用户消息（唯一入口）
  /// 支持消息等待合并功能
  Future<void> sendUserMessage(
    String chatId,
    String content, {
    Message? quotedMessage,
  }) async {
    if (content.trim().isEmpty) return;

    debugPrint('ChatController: sendUserMessage to $chatId');

    // 归档角色不可对话（单聊场景，chatId 即 roleId）
    final targetRole = RoleService.getRoleById(chatId);
    if (targetRole?.archived == true) {
      debugPrint('ChatController: role $chatId archived, blocking send');
      final errorMsg = Message(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        senderId: 'ai',
        receiverId: 'me',
        content: '该角色已归档，无法聊天。可在角色设置中恢复。',
        type: MessageType.text,
        timestamp: DateTime.now(),
      );
      await MessageStore.instance.addMessage(chatId, errorMsg);
      notifyListeners();
      return;
    }

    // 创建用户消息并立即显示
    final userMessage = createMessage(
      senderId: 'me',
      receiverId: 'ai',
      content: content,
      quotedMessage: quotedMessage,
    );
    await MessageStore.instance.addMessage(chatId, userMessage);
    notifyListeners();

    // 获取等待时间配置
    final waitSeconds = SettingsService.instance.messageWaitSeconds;

    // 添加到待发送队列
    _pendingMessages.putIfAbsent(chatId, () => []);
    _pendingMessages[chatId]!.add(
      _PendingChatItem(messageId: userMessage.id, text: content),
    );

    // 重置定时器（无论是否已有定时器，统一重置）
    _waitTimers[chatId]?.cancel();
    _waitTimers[chatId] = Timer(
      waitSeconds > 0 ? Duration(seconds: waitSeconds) : Duration.zero,
      () => _sendBatchedMessages(chatId),
    );
  }

  /// 输入框内容变化时调用：只要还有待发送消息，就重置等待定时器。
  /// 这样用户在发送后继续打字时，请求会持续等待，直到停止输入满 X 秒。
  void notifyInputActivity(String chatId) {
    final waitSeconds = SettingsService.instance.messageWaitSeconds;
    // 立即发送模式，或当前没有待发送消息时，不做任何等待处理
    if (waitSeconds == 0) return;
    final pending = _pendingMessages[chatId];
    if (pending == null || pending.isEmpty) return;

    _waitTimers[chatId]?.cancel();
    _waitTimers[chatId] = Timer(
      Duration(seconds: waitSeconds),
      () => _sendBatchedMessages(chatId),
    );
  }

  /// 发送合并后的消息
  Future<void> _sendBatchedMessages(String chatId) async {
    // 取出待发送消息
    final pendingMessages = _pendingMessages.remove(chatId) ?? [];
    _waitTimers.remove(chatId);

    if (pendingMessages.isEmpty) return;
    if (_processingChats.contains(chatId)) {
      debugPrint('ChatController: Already processing $chatId, queueing');
      // 处理期间可能已有新消息入队（notifyInputActivity 追加到同一 chatId）。
      // 直接赋值会丢弃这些新项，因此把已取出的旧批次插回队首，保持时间顺序。
      final queued = _pendingMessages.putIfAbsent(chatId, () => []);
      queued.insertAll(0, pendingMessages);
      return;
    }

    // 拆分文本项与图片项：文本按换行合并，图片保留有序路径列表（支持多图）
    final combinedContent = pendingMessages
        .where((m) => m.text != null)
        .map((m) => m.text!)
        .join('\n');
    final imagePaths = pendingMessages
        .where((m) => m.isImage)
        .map((m) => m.imagePath!)
        .toList();

    debugPrint(
      'ChatController: Sending batched messages (${pendingMessages.length} msgs, ${imagePaths.length} images) to $chatId',
    );

    final ready = await _ensureConnectionBeforeSend(chatId);
    if (!ready) {
      for (final pending in pendingMessages) {
        await MessageStore.instance.updateMessageSendStatus(
          chatId,
          pending.messageId,
          MessageSendStatus.failed,
        );
      }
      notifyListeners();
      return;
    }

    // 初始化上下文
    final context = await initChat(chatId);

    // 更新上下文消息数量
    _contexts[chatId] = context.copyWith(
      messageCount: MessageStore.instance.getMessageCount(chatId),
      lastMessageTime: DateTime.now(),
    );

    // 标记正在处理
    _processingChats.add(chatId);
    _beginBackgroundTrackedRequest(chatId);
    notifyListeners();

    // 根据聊天类型处理（后台执行）
    _processMessageInBackground(
      chatId,
      combinedContent,
      context.isGroup,
      imagePaths: imagePaths,
    );
  }

  /// 发送用户图片消息
  ///
  /// tool 识图模式：图片进入与文本一致的聚合缓冲区，等待窗口后合并成一次
  /// ai_event 请求，由聊天模型自主决定是否调用 recognize_image（不立即识别）。
  /// 其余模式（standalone/pre_model）：保持原即时 chat_vision 路径。
  Future<void> sendUserImageMessage(String chatId, String imagePath) async {
    final aggregateViaTool = SettingsService.instance.visionMode == 'tool';

    // 非 tool 模式沿用旧的即时路径：处理中直接忽略
    if (!aggregateViaTool && _processingChats.contains(chatId)) {
      debugPrint('ChatController: Already processing $chatId, ignoring image');
      return;
    }

    debugPrint(
      'ChatController: sendUserImageMessage to $chatId, path=$imagePath, aggregate=$aggregateViaTool',
    );

    // 1. 创建图片消息（使用 image 类型）
    final imageMessage = Message(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      senderId: 'me',
      receiverId: 'ai',
      content: imagePath, // 保存图片路径
      type: MessageType.image,
      timestamp: DateTime.now(),
    );

    // 2. 写入 MessageStore
    await MessageStore.instance.addMessage(chatId, imageMessage);

    final ready = await _ensureConnectionBeforeSend(chatId);
    if (!ready) {
      await MessageStore.instance.updateMessageSendStatus(
        chatId,
        imageMessage.id,
        MessageSendStatus.failed,
      );
      notifyListeners();
      return;
    }

    // 图片消息做一次立即入库同步兜底，避免异步同步失败导致后端缺失该条对话
    await _syncMessageToBackendNow(chatId, imageMessage);

    // 初始化上下文
    final context = await initChat(chatId);

    // 更新上下文消息数量
    _contexts[chatId] = context.copyWith(
      messageCount: MessageStore.instance.getMessageCount(chatId),
      lastMessageTime: DateTime.now(),
    );

    // tool 模式：图片进入聚合缓冲区，与文本共用等待定时器
    if (aggregateViaTool) {
      final waitSeconds = SettingsService.instance.messageWaitSeconds;
      _pendingMessages.putIfAbsent(chatId, () => []);
      _pendingMessages[chatId]!.add(
        _PendingChatItem(messageId: imageMessage.id, imagePath: imagePath),
      );
      _waitTimers[chatId]?.cancel();
      _waitTimers[chatId] = Timer(
        waitSeconds > 0 ? Duration(seconds: waitSeconds) : Duration.zero,
        () => _sendBatchedMessages(chatId),
      );
      return;
    }

    // 非 tool 模式：标记正在处理，走即时 vision 路径
    _processingChats.add(chatId);
    _beginBackgroundTrackedRequest(chatId);
    notifyListeners();

    // 3. 后台处理图片消息（调用 vision API）
    _processImageMessageInBackground(chatId, imagePath, context.isGroup);
  }

  Future<void> _syncMessageToBackendNow(String chatId, Message message) async {
    try {
      await SecureWebSocketClient.instance.request('save_chat_message', {
        'role_id': chatId,
        'message': {
          'id': message.id,
          'content': message.content,
          'sender_id': message.senderId,
          'timestamp': message.timestamp.toIso8601String(),
          'type': message.type.toString().split('.').last,
          'quote_id': message.quotedMessageId,
          'quote_content': message.quotedPreviewText,
        },
      });
    } catch (e) {
      debugPrint('ChatController: immediate backend sync failed: $e');
    }
  }

  /// 发送用户表情（支持用户表情标签注入给 AI）
  Future<void> sendUserStickerMessage({
    required String chatId,
    required String stickerUrl,
    required String category,
    required String tag,
    String emojiId = '',
    bool fromUserLibrary = true,
  }) async {
    if (!fromUserLibrary) {
      debugPrint(
        'ChatController: AI sticker sending is disabled for user actions',
      );
      return;
    }

    if (_processingChats.contains(chatId)) {
      debugPrint(
        'ChatController: Already processing $chatId, ignoring sticker',
      );
      return;
    }

    final stickerContent = fromUserLibrary
        ? StickerService.createUserStickerMessageContent(
            category: category,
            tag: tag,
            emojiId: emojiId,
            imagePath: stickerUrl,
          )
        : StickerService.createStickerMessageContent(category, stickerUrl);

    final userStickerMessage = Message(
      id: '${DateTime.now().millisecondsSinceEpoch}_user_sticker',
      senderId: 'me',
      receiverId: 'ai',
      content: stickerContent,
      type: MessageType.sticker,
      timestamp: DateTime.now(),
    );

    await MessageStore.instance.addMessage(chatId, userStickerMessage);

    final ready = await _ensureConnectionBeforeSend(chatId);
    if (!ready) {
      await MessageStore.instance.updateMessageSendStatus(
        chatId,
        userStickerMessage.id,
        MessageSendStatus.failed,
      );
      notifyListeners();
      return;
    }

    final context = await initChat(chatId);

    _contexts[chatId] = context.copyWith(
      messageCount: MessageStore.instance.getMessageCount(chatId),
      lastMessageTime: DateTime.now(),
    );

    _processingChats.add(chatId);
    _beginBackgroundTrackedRequest(chatId);
    notifyListeners();

    final aiPrompt = fromUserLibrary
        ? '用户发送了一个表情，标签是"$tag"。请根据这个标签和上下文自然回复。'
        : '用户发送了一个表情，分类是"$category"。请结合上下文自然回复。';

    _processMessageInBackground(chatId, aiPrompt, context.isGroup);
  }

  /// 后台处理图片消息
  Future<void> _processImageMessageInBackground(
    String chatId,
    String imagePath,
    bool isGroup,
  ) async {
    try {
      Role role;
      if (isGroup) {
        // 群聊：从群成员中随机选一个角色回复图片
        final context = _contexts[chatId];
        final memberIds = context?.memberIds ?? [];
        if (memberIds.isEmpty) {
          role = RoleService.getCurrentRole();
        } else {
          final randomId = memberIds[_random.nextInt(memberIds.length)];
          role =
              RoleService.getRoleById(randomId) ?? RoleService.getCurrentRole();
        }
      } else {
        role = RoleService.getRoleById(chatId) ?? RoleService.getCurrentRole();
      }

      // 显示 typing
      await _showTypingWithDelay(chatId, isGroup: isGroup);

      // 调用 vision API（包含 Base Prompt 以遵循全局规则）
      final systemPrompt =
          '${SettingsService.instance.basePrompt}\n\n${role.systemPrompt}';
      final aiReply = await ApiService.chatWithImage(
        imagePath: imagePath,
        userPrompt:
            '用户发送了一张图片，请以你扮演的角色身份自然地回应这张图片。不要描述图片内容，而是像朋友收到图片一样自然地回复，表达你的感受或想法。',
        rolePersona: systemPrompt,
        roleId: role.id,
      );

      // 发送 AI 回复
      await _sendSegmentsQueued(chatId, role.id, aiReply, isGroup: isGroup);

      // 更新聊天列表
      _updateChatList(chatId);
    } catch (e) {
      debugPrint('ChatController: Image message error: $e');
      // 添加错误消息
      final errorMsg = Message(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        senderId: 'ai',
        receiverId: 'me',
        content: '图片识别失败：$e',
        type: MessageType.text,
        timestamp: DateTime.now(),
      );
      await MessageStore.instance.addMessage(chatId, errorMsg);
    } finally {
      _hideTyping(chatId);
      _processingChats.remove(chatId);
      _completeBackgroundTrackedRequest(chatId);
      notifyListeners();
      _flushPendingIfNeeded(chatId);
    }
  }

  /// 发送带引用的用户消息
  Future<void> sendUserMessageWithQuote(
    String chatId,
    String content,
    String quotedMessageId,
    String quotedContent,
  ) async {
    if (content.trim().isEmpty) return;

    // 获取被引用的消息
    final messages = MessageStore.instance.getMessages(chatId);
    final quotedMessage = messages
        .where((m) => m.id == quotedMessageId)
        .firstOrNull;

    if (quotedMessage != null) {
      await sendUserMessage(chatId, content, quotedMessage: quotedMessage);
    } else {
      // 如果找不到原消息，创建一个临时的引用
      final tempQuotedMessage = Message(
        id: quotedMessageId,
        senderId: 'unknown',
        receiverId: 'me',
        content: quotedContent,
        timestamp: DateTime.now(),
      );
      await sendUserMessage(chatId, content, quotedMessage: tempQuotedMessage);
    }
  }

  Future<void> retryFailedMessage(String chatId, String messageId) async {
    if (_processingChats.contains(chatId)) {
      return;
    }

    final message = MessageStore.instance.getMessage(chatId, messageId);
    if (message == null || message.senderId != 'me') {
      return;
    }

    await MessageStore.instance.updateMessageSendStatus(
      chatId,
      messageId,
      MessageSendStatus.sent,
    );

    final ready = await _ensureConnectionBeforeSend(chatId);
    if (!ready) {
      await MessageStore.instance.updateMessageSendStatus(
        chatId,
        messageId,
        MessageSendStatus.failed,
      );
      notifyListeners();
      return;
    }

    final context = await initChat(chatId);

    _contexts[chatId] = context.copyWith(
      messageCount: MessageStore.instance.getMessageCount(chatId),
      lastMessageTime: DateTime.now(),
    );

    _processingChats.add(chatId);
    _beginBackgroundTrackedRequest(chatId);
    notifyListeners();

    if (message.type == MessageType.image) {
      _processImageMessageInBackground(
        chatId,
        message.content,
        context.isGroup,
      );
      return;
    }

    if (message.type == MessageType.sticker) {
      final (_, categoryOrEmotion, _) = StickerService.parseStickerMessage(
        message.content,
      );
      final emotionText = (categoryOrEmotion ?? '').trim();
      final aiPrompt = emotionText.isEmpty
          ? '用户发送了一个表情。请结合上下文自然回复。'
          : '用户发送了一个表情，标签是"$emotionText"。请根据这个标签和上下文自然回复。';
      _processMessageInBackground(chatId, aiPrompt, context.isGroup);
      return;
    }

    _processMessageInBackground(chatId, message.content, context.isGroup);
  }

  /// 后台处理消息
  void _processMessageInBackground(
    String chatId,
    String content,
    bool isGroup, {
    List<String> imagePaths = const [],
  }) {
    Future(() async {
      try {
        if (isGroup) {
          await _handleGroupChat(chatId, content, imagePaths: imagePaths);
        } else {
          await _handleSingleChat(chatId, content, imagePaths: imagePaths);
        }
      } catch (e) {
        debugPrint('ChatController: Error processing message: $e');
      } finally {
        _processingChats.remove(chatId);
        _completeBackgroundTrackedRequest(chatId);
        notifyListeners();
        _updateChatList(chatId);
        _flushPendingIfNeeded(chatId);
      }
    });
  }

  /// AI 处理完成后，若还有排队中的消息则立即触发发送。
  void _flushPendingIfNeeded(String chatId) {
    if (_pendingMessages[chatId]?.isNotEmpty == true) {
      _sendBatchedMessages(chatId);
    }
  }

  void _beginBackgroundTrackedRequest(String chatId) {
    final requestId = '${DateTime.now().microsecondsSinceEpoch}_$chatId';
    final baselineMessageId =
        MessageStore.instance.getLastMessage(chatId)?.id ?? '';
    _activeRequestIds[chatId] = requestId;
    BackgroundRuntimeService.registerPendingRequest(
      requestId: requestId,
      chatId: chatId,
      baselineMessageId: baselineMessageId,
    );
  }

  void _completeBackgroundTrackedRequest(String chatId) {
    final requestId = _activeRequestIds.remove(chatId);
    if (requestId == null || requestId.isEmpty) {
      return;
    }
    BackgroundRuntimeService.completePendingRequest(requestId);
  }

  /// 进入聊天页
  Future<void> onChatPageEnter(String chatId) async {
    await MessageStore.instance.ensureLoaded(chatId);
    MessageStore.instance.activateChatWindow(chatId);
    MessageStore.instance.clearUnread(chatId);
    ChatListService.instance.clearUnread(chatId);
    MessageStore.instance.refreshStream(chatId);
    debugPrint(
      'ChatController: Entered chat $chatId (${getMessageCount(chatId)} messages)',
    );

    // 从后端同步角色数据（异步，不阻塞UI）
    // 用 hash gate + TTL 节流：角色无变化时零往返、零本地重写。
    RoleService.syncIfHashMismatch()
        .then((_) {
          debugPrint('ChatController: Role data synced from backend');
        })
        .catchError((e) {
          debugPrint('ChatController: Role sync failed: $e');
        });
  }

  /// 退出聊天页
  void onChatPageExit(String chatId) {
    MessageStore.instance.releaseChatWindow(chatId);
    debugPrint('ChatController: Exited chat $chatId');
  }

  /// 手动标记未读
  void markChatUnread(String chatId) {
    MessageStore.instance.setUnread(chatId, 1);
    ChatListService.instance.markAsUnread(chatId);
  }

  /// 从聊天列表移除
  void deleteChatFromList(String chatId) {
    ChatListService.instance.removeFromList(chatId);
  }

  /// 删除消息
  Future<void> deleteMessage(String chatId, String messageId) async {
    await MessageStore.instance.deleteMessage(chatId, messageId);
  }

  /// 发送定时任务消息（由 TaskService 调用）
  /// 使用角色人格生成自然的提醒消息
  Future<void> sendScheduledTaskMessage({
    required String chatId,
    required String roleId,
    required String taskContent,
    String? customPrompt,
  }) async {
    final role = RoleService.getRoleById(roleId);
    if (role == null) {
      debugPrint('ChatController: Role not found for scheduled task');
      return;
    }

    debugPrint('ChatController: Sending scheduled task message for $roleId');

    // 构建提示词
    final prompt =
        customPrompt ??
        '你需要自然地提醒用户以下事项，不要说"这是提醒"或"定时任务"之类的话，用日常对话的方式。提醒内容：$taskContent';

    // 调用 AI 生成消息
    final response = await ApiService.callBackendAI(
      roleId: role.id,
      eventType: 'task',
      content: prompt,
      context: {'chat_id': chatId},
    );

    String contentToSend;
    if (response.success && response.content != null) {
      contentToSend = response.content!;
    } else if (response.ignored) {
      debugPrint('ChatController: AI chose not to send scheduled task message');
      return;
    } else {
      debugPrint(
        'ChatController: Backend task AI call failed: ${response.error}',
      );
      contentToSend = '嘿～$taskContent';
    }

    // 分段发送
    await _sendSegmentsQueued(chatId, roleId, contentToSend, isGroup: false);

    // 更新聊天列表
    _updateChatList(chatId);

    debugPrint('ChatController: Scheduled task message sent');
  }

  /// 创建群聊
  Future<String> createGroupChat(List<String> roleIds, {String? name}) async {
    final group = await GroupChatService.createGroup(
      memberIds: roleIds,
      name: name ?? '群聊',
    );
    await initChat(group.id, isGroup: true, memberIds: roleIds);
    ChatListService.instance.getOrCreateChat(
      id: group.id,
      name: group.name,
      isGroup: true,
      memberIds: roleIds,
    );
    return group.id;
  }

  /// 注册 typing 回调（仅单聊使用）
  void registerTypingCallback(String chatId, void Function(bool) callback) {
    _typingCallbacks[chatId] = callback;
  }

  void unregisterTypingCallback(String chatId) {
    _typingCallbacks.remove(chatId);
  }

  bool isProcessing(String chatId) => _processingChats.contains(chatId);

  // ========== 单聊处理 ==========

  Future<void> _handleSingleChat(
    String chatId,
    String userMessage, {
    List<String> imagePaths = const [],
  }) async {
    final role =
        RoleService.getRoleById(chatId) ?? RoleService.getCurrentRole();

    // 意图识别（纯图片批次无文本时跳过，避免空串误判）
    final intent = userMessage.trim().isEmpty
        ? null
        : await IntentService.detectIntent(userMessage);
    debugPrint('ChatController: Intent detected: ${intent?.type}');

    // 根据意图类型执行副作用（不直接回复，交给 AI 自然回复）
    if (intent != null) {
      switch (intent.type) {
      case IntentType.setMemory:
        // 保存到核心记忆
        await MemoryService.addToCoreMemory(
          intent.extractedContent ?? userMessage,
        );
        debugPrint(
          'ChatController: Memory saved, continuing to AI for natural reply',
        );
        break;

      case IntentType.clearMemory:
        // 清除记忆
        await MemoryService.clearCoreMemory();
        MemoryService.clearShortTermMemory(chatId);
        debugPrint(
          'ChatController: Memory cleared, continuing to AI for natural reply',
        );
        break;

      case IntentType.setReminder:
        if (intent.duration != null) {
          debugPrint(
            'ChatController: Reminder intent detected for ${intent.duration}',
          );
          final now = DateTime.now();
          final triggerTime = now.add(intent.duration!);
          final reminderContent = (intent.extractedContent ?? userMessage)
              .trim();

          try {
            await TaskService.addReminder(
              chatId: chatId,
              roleId: role.id,
              message: reminderContent.isEmpty ? userMessage : reminderContent,
              triggerTime: triggerTime,
              aiPrompt:
                  '你需要在约定时间自然地提醒用户：${reminderContent.isEmpty ? userMessage : reminderContent}。不要说“定时任务”或“系统提醒”。',
            );
            debugPrint(
              'ChatController: Reminder created at ${triggerTime.toIso8601String()}',
            );
          } catch (e) {
            debugPrint('ChatController: Failed to create reminder task: $e');
          }
        }
        break;

      case IntentType.setQuietTime:
        if (intent.startHour != null && intent.endHour != null) {
          await SettingsService.instance.setQuietHours(
            intent.startHour!,
            intent.endHour!,
          );
          debugPrint(
            'ChatController: Quiet hours set ${intent.startHour}-${intent.endHour}',
          );
        }
        break;

      case IntentType.normalChat:
        break;
      }
    }

    // 单聊显示"正在输入"
    await _showTypingWithDelay(chatId, isGroup: false);

    final rawReply = await _callAI(
      chatId: chatId,
      role: role,
      userMessage: userMessage,
      isGroup: false,
      imagePaths: imagePaths,
    );

    if (rawReply != null) {
      await _sendSegmentsQueued(
        chatId,
        role.id,
        rawReply.content,
        isGroup: false,
        toolEmotions: rawReply.emojisCalled,
      );
    }

    _hideTyping(chatId);
  }

  // ========== 群聊处理 ==========

  Future<void> _handleGroupChat(
    String chatId,
    String userMessage, {
    List<String> imagePaths = const [],
  }) async {
    final context = _contexts[chatId];
    if (context == null) return;

    // 图片只归属用户本轮消息，AI↔AI 后续轮次不再携带
    var pendingImagePaths = imagePaths;

    // 获取群聊设置
    final group = GroupChatService.getGroup(chatId);
    final aiProbability = group?.aiReplyProbability ?? 0.6;
    final allowAiToAi = group?.allowAiToAiInteraction ?? true;
    final maxConsecutive = group?.maxConsecutiveSpeaks ?? 2;

    // 最大互动轮数
    final maxRounds = allowAiToAi ? 3 : 1;
    var currentRound = 0;
    String lastMessage = userMessage;
    String? lastSpeakerId;

    while (currentRound < maxRounds) {
      currentRound++;

      final schedule = GroupScheduler.selectRespondingRoles(
        memberIds: context.memberIds,
        userMessage: lastMessage,
        lastSpeakerRoleId: lastSpeakerId ?? context.lastSpeakerRoleId,
        consecutiveCounts: context.consecutiveSpeakCount,
        replyProbability: aiProbability,
        maxConsecutiveSpeaks: maxConsecutive,
      );

      if (schedule.selectedRoles.isEmpty) break;

      debugPrint(
        'ChatController: Group round $currentRound, ${schedule.selectedRoles.length} roles',
      );

      for (var i = 0; i < schedule.selectedRoles.length; i++) {
        final role = schedule.selectedRoles[i];

        if (i > 0 || currentRound > 1) {
          await Future.delayed(
            Duration(milliseconds: GroupScheduler.getReplyDelay(i)),
          );
        }

        // 群聊不显示"正在输入"

        final rawReply = await _callAI(
          chatId: chatId,
          role: role,
          userMessage: lastMessage,
          isGroup: true,
          imagePaths: pendingImagePaths,
        );
        // 图片已随首个应答角色发出，后续角色/轮次不再重复携带
        pendingImagePaths = const [];

        if (rawReply != null) {
          // 群聊分段发送也不显示 typing
          await _sendSegmentsQueued(
            chatId,
            role.id,
            rawReply.content,
            isGroup: true,
            toolEmotions: rawReply.emojisCalled,
          );
          if (MessageParts.isNoReplyDirective(rawReply.content)) {
            continue;
          }
          context.incrementConsecutiveCount(role.id);
          lastSpeakerId = role.id;
          lastMessage = rawReply.content;
        }
      }

      // 决定是否继续 AI↔AI 互动
      if (!allowAiToAi) break;
      final continueProbability = 0.3 / currentRound;
      if (_random.nextDouble() > continueProbability) break;
    }
  }

  // ========== AI 调用 ==========

  /// 确保异步聊天推送监听器已注册（幂等）
  void _ensureChatPushListener() {
    if (_chatPushSubscription != null) return;

    _chatPushSubscription = SecureWebSocketClient.instance.serverPushStream
        .listen(
          (Map<String, dynamic> event) {
            final eventType = (event['event_type'] ?? event['type'] ?? '')
                .toString()
                .trim();
            if (eventType != 'chat_response') return;

            final dynamic rawPayload = event['payload'];
            if (rawPayload is! Map) return;

            final payload = Map<String, dynamic>.from(rawPayload);
            final taskId = (payload['task_id'] ?? '').toString();
            if (taskId.isEmpty) return;

            final completer = _pendingChatTasks.remove(taskId);
            if (completer != null && !completer.isCompleted) {
              // 活跃 await 命中：交回 _callAI 走正常渲染路径。
              completer.complete(payload);
              return;
            }

            // 无活跃 await（已超时移除，或 App 重启后 completer 丢失）：
            // 该推送若被丢弃则回复永久丢失，这里直接落地渲染。
            unawaited(_deliverRecoveredReply(taskId, payload));
          },
          onError: (Object error, StackTrace stackTrace) {
            debugPrint('ChatController: chat push stream error: $error');
          },
        );

    // 重连后主动向服务端补偿拉取错过的推送。
    SecureWebSocketClient.instance.onReconnected = () {
      unawaited(recoverPendingChatTasks());
    };

    debugPrint('ChatController: chat push listener initialized');
  }

  /// 恢复所有待处理的异步聊天任务。
  ///
  /// 在 App 启动、WebSocket 重连、前台恢复时调用。先加载持久化的 pending 任务，
  /// 再向服务端 `recover_chat_push` 查询缓存的 chat_response 推送；命中即渲染。
  /// 服务端缓存已持久化（跨重启，TTL 24h），因此弱网/重启期间生成成功却漏收的
  /// 回复可在此补齐。
  Future<void> recoverPendingChatTasks() async {
    if (_recoveringPersistedTasks) return;
    _recoveringPersistedTasks = true;
    try {
      await _ensurePersistedStateLoaded();
      await _resumeUncertainChatSubmissions();

      // 合并内存中活跃 await 与持久化 pending 的 task_id。
      final pendingMap = _loadPersistedPendingTasks();
      final taskIds = <String>{
        ..._pendingChatTasks.keys,
        ...pendingMap.keys,
      }.where((id) => id.isNotEmpty && !_renderedTaskIds.contains(id)).toList();

      if (taskIds.isEmpty) return;

      debugPrint(
        'ChatController: recovering ${taskIds.length} pending chat tasks',
      );

      final result = await SecureWebSocketClient.instance.request(
        'recover_chat_push',
        {'task_ids': taskIds},
        timeout: const Duration(seconds: 10),
      );

      final recovered = result['recovered'];
      if (recovered is! List) return;

      for (final item in recovered) {
        if (item is! Map) continue;
        final taskId = item['task_id']?.toString() ?? '';
        final pushPayload = item['payload'];
        if (taskId.isEmpty || pushPayload is! Map) continue;

        final payload = Map<String, dynamic>.from(pushPayload);
        final completer = _pendingChatTasks.remove(taskId);
        if (completer != null && !completer.isCompleted) {
          // 活跃 await 命中：走正常渲染路径。
          completer.complete(payload);
          continue;
        }
        // 无活跃 await：直接落地渲染（重启/超时场景）。
        await _deliverRecoveredReply(taskId, payload);
      }
    } catch (e) {
      debugPrint('ChatController: recover missed pushes failed: $e');
    } finally {
      _recoveringPersistedTasks = false;
    }
  }

  /// 将一条恢复到的回复直接渲染到会话（用于无活跃 await 的补偿路径）。
  /// 通过 [_renderedTaskIds] 去重，保证同一 task 只渲染一次。
  Future<void> _deliverRecoveredReply(
    String taskId,
    Map<String, dynamic> payload,
  ) async {
    if (taskId.isEmpty) return;
    await _ensurePersistedStateLoaded();
    if (_renderedTaskIds.contains(taskId)) return;
    // 先占位（同步，await 之前）防止并发补偿路径重复渲染。
    _renderedTaskIds.add(taskId);

    final record = _loadPersistedPendingTasks()[taskId];
    if (record == null) {
      // 没有渲染所需的上下文（如老版本遗留任务），无法落地，仅记为已处理。
      await _persistRenderedTaskIds();
      return;
    }

    final chatId = record['chat_id']?.toString() ?? '';
    final roleId = record['role_id']?.toString() ?? '';
    final isGroup = record['is_group'] == true;
    final userMessage = record['user_message']?.toString() ?? '';
    final attachedJson = record['attached_json']?.toString();

    try {
      final success = payload['success'] == true;
      final content = payload['content']?.toString();
      if (!success || content == null || chatId.isEmpty || roleId.isEmpty) {
        await _replaceRecoveryStatusWithFailure(
          taskId,
          payload['error']?.toString() ?? '服务器处理失败',
        );
        // 终态失败或上下文缺失：丢弃 pending，不渲染。
        await _removePersistedPendingTask(taskId);
        await _persistRenderedTaskIds();
        return;
      }

      final metadata = payload['metadata'] is Map
          ? Map<String, dynamic>.from(payload['metadata'])
          : null;
      final noReply = metadata?['no_reply'] == true ||
          MessageParts.isNoReplyDirective(content);
      final requestId = metadata?['request_id']?.toString().trim();

      await MemoryService.appendJsonMemoryPair(
        roleId: roleId,
        userContent: userMessage,
        assistantContent: noReply ? null : content,
        requestId: (requestId != null && requestId.isNotEmpty) ? requestId : null,
        jsonMemory: (attachedJson != null && attachedJson.isNotEmpty)
            ? attachedJson
            : null,
      );

      final role = RoleService.getRoleById(roleId);
      final showNoReply = role?.showNoReply ?? false;
      await _clearRecoveryStatusMessage(taskId);
      if (!(noReply && !showNoReply)) {
        await MessageStore.instance.ensureLoaded(chatId);
        await _sendSegmentsQueued(
          chatId,
          roleId,
          content,
          isGroup: isGroup,
          toolEmotions: _extractToolEmotions(metadata),
        );
        debugPrint('ChatController: recovered reply rendered for task $taskId');
      }

      await _removePersistedPendingTask(taskId);
      await _persistRenderedTaskIds();
    } catch (e) {
      // 渲染失败：撤销占位，保留 pending，留待下次恢复重试。
      _renderedTaskIds.remove(taskId);
      debugPrint('ChatController: deliver recovered reply failed ($taskId): $e');
    }
  }

  // ========== 待处理任务持久化 ==========

  Future<void> _ensurePersistedStateLoaded() async {
    if (_persistedStateLoaded) return;
    final rendered = StorageService.getStringList(_kRenderedTasksKey);
    if (rendered != null) {
      _renderedTaskIds.addAll(rendered);
    }
    _persistedStateLoaded = true;
  }

  Map<String, dynamic> _loadPersistedPendingTasks() {
    return StorageService.getJson(_kPendingTasksKey) ?? <String, dynamic>{};
  }

  Future<void> _savePersistedPendingTask(
    String taskId, {
    required String chatId,
    required String roleId,
    required bool isGroup,
    required String userMessage,
    String? attachedJson,
    String? clientSubmissionId,
    String? requestMessage,
    Map<String, dynamic>? requestContext,
    bool submissionUncertain = false,
  }) async {
    final map = _loadPersistedPendingTasks();
    map[taskId] = {
      'chat_id': chatId,
      'role_id': roleId,
      'is_group': isGroup,
      'user_message': userMessage,
      'attached_json': attachedJson,
      'client_submission_id': clientSubmissionId,
      'request_message': requestMessage,
      'request_context': requestContext,
      'submission_uncertain': submissionUncertain,
      'created_at': DateTime.now().toIso8601String(),
    };
    await StorageService.setJson(
      _kPendingTasksKey,
      Map<String, dynamic>.from(map),
    );
  }

  Future<void> _removePersistedPendingTask(String taskId) async {
    final map = _loadPersistedPendingTasks();
    if (map.remove(taskId) != null) {
      await StorageService.setJson(
        _kPendingTasksKey,
        Map<String, dynamic>.from(map),
      );
    }
  }

  Future<void> _markTaskRendered(String taskId) async {
    if (taskId.isEmpty) return;
    await _ensurePersistedStateLoaded();
    _renderedTaskIds.add(taskId);
    await _persistRenderedTaskIds();
    await _removePersistedPendingTask(taskId);
  }

  Future<void> _persistRenderedTaskIds() async {
    // FIFO 截断，避免无限增长。
    if (_renderedTaskIds.length > _kRenderedTasksMax) {
      final excess = _renderedTaskIds.length - _kRenderedTasksMax;
      final trimmed = _renderedTaskIds.skip(excess).toSet();
      _renderedTaskIds
        ..clear()
        ..addAll(trimmed);
    }
    await StorageService.setStringList(
      _kRenderedTasksKey,
      _renderedTaskIds.toList(),
    );
  }

  List<String> _extractToolEmotions(Map<String, dynamic>? metadata) {
    final rawEmotions = metadata?['emojis_called'];
    if (rawEmotions is! List) return const <String>[];
    return rawEmotions
        .map((value) => value.toString().trim())
        .where((value) => value.isNotEmpty)
        .toList();
  }

  Future<void> _updatePersistedPendingTask(
    String taskId,
    Map<String, dynamic> updates,
  ) async {
    final map = _loadPersistedPendingTasks();
    final rawRecord = map[taskId];
    if (rawRecord is! Map) return;
    final record = Map<String, dynamic>.from(rawRecord);
    record.addAll(updates);
    map[taskId] = record;
    await StorageService.setJson(
      _kPendingTasksKey,
      Map<String, dynamic>.from(map),
    );
  }

  Future<void> _movePersistedPendingTask(
    String fromTaskId,
    String toTaskId,
  ) async {
    if (fromTaskId == toTaskId) return;
    final map = _loadPersistedPendingTasks();
    final record = map.remove(fromTaskId);
    if (record == null) return;
    map[toTaskId] = record;
    await StorageService.setJson(
      _kPendingTasksKey,
      Map<String, dynamic>.from(map),
    );
  }

  Future<void> _ensureRecoveryStatusMessage(String taskId) async {
    final rawRecord = _loadPersistedPendingTasks()[taskId];
    if (rawRecord is! Map) return;
    final record = Map<String, dynamic>.from(rawRecord);
    final chatId = record['chat_id']?.toString() ?? '';
    if (chatId.isEmpty) return;
    await MessageStore.instance.ensureLoaded(chatId);

    final existingId = record['recovery_message_id']?.toString();
    if (existingId != null &&
        existingId.isNotEmpty &&
        MessageStore.instance.getMessage(chatId, existingId) != null) {
      return;
    }

    final statusMessage = createMessage(
      senderId: 'error',
      receiverId: 'me',
      content: '网络连接已中断，正在恢复与服务器的连接…',
    );
    await MessageStore.instance.addMessages(chatId, [statusMessage]);
    await _updatePersistedPendingTask(taskId, {
      'recovery_message_id': statusMessage.id,
    });
  }

  Future<void> _clearRecoveryStatusMessage(String taskId) async {
    final rawRecord = _loadPersistedPendingTasks()[taskId];
    if (rawRecord is! Map) return;
    final record = Map<String, dynamic>.from(rawRecord);
    final chatId = record['chat_id']?.toString() ?? '';
    final messageId = record['recovery_message_id']?.toString() ?? '';
    if (chatId.isNotEmpty && messageId.isNotEmpty) {
      await MessageStore.instance.deleteMessage(chatId, messageId);
    }
  }

  Future<void> _resumeUncertainChatSubmissions() async {
    final pendingMap = _loadPersistedPendingTasks();
    for (final entry in pendingMap.entries.toList()) {
      final taskId = entry.key;
      if (entry.value is! Map) continue;
      final record = Map<String, dynamic>.from(entry.value as Map);
      if (record['submission_uncertain'] != true) continue;

      final submissionId = record['client_submission_id']?.toString() ?? '';
      final roleId = record['role_id']?.toString() ?? '';
      final requestMessage = record['request_message']?.toString() ?? '';
      final rawContext = record['request_context'];
      if (submissionId.isEmpty || roleId.isEmpty || rawContext is! Map) {
        continue;
      }

      final response = await ApiService.submitChatTask(
        roleId: roleId,
        message: requestMessage,
        clientSubmissionId: submissionId,
        context: Map<String, dynamic>.from(rawContext),
      );

      if (response.status == 'queued' && response.taskId != null) {
        await _movePersistedPendingTask(taskId, response.taskId!);
        await _updatePersistedPendingTask(response.taskId!, {
          'submission_uncertain': false,
        });
        continue;
      }

      if (response.status == 'completed' && response.content != null) {
        await _deliverRecoveredReply(taskId, {
          'task_id': taskId,
          'success': true,
          'content': response.content,
          'metadata': response.metadata ?? <String, dynamic>{},
        });
      } else if (!response.isTransportError) {
        await _replaceRecoveryStatusWithFailure(
          taskId,
          response.error ?? '服务器处理失败',
        );
        await _removePersistedPendingTask(taskId);
      }
    }
  }

  Future<void> _replaceRecoveryStatusWithFailure(
    String taskId,
    String error,
  ) async {
    final rawRecord = _loadPersistedPendingTasks()[taskId];
    if (rawRecord is! Map) return;
    final record = Map<String, dynamic>.from(rawRecord);
    final chatId = record['chat_id']?.toString() ?? '';
    final messageId = record['recovery_message_id']?.toString() ?? '';
    if (chatId.isNotEmpty && messageId.isNotEmpty) {
      await MessageStore.instance.updateMessage(
        chatId,
        messageId,
        content: '消息发送失败：$error',
      );
    }
  }

  String _newClientSubmissionId() {
    final entropy = Random.secure().nextInt(0x7fffffff).toRadixString(36);
    return '${DateTime.now().microsecondsSinceEpoch}_$entropy';
  }

  String _taskIdForSubmission(String clientSubmissionId) {
    return 'chat_$clientSubmissionId';
  }

  Future<_AiReply?> _callAI({
    required String chatId,
    required Role role,
    required String userMessage,
    required bool isGroup,
    List<String> imagePaths = const [],
  }) async {
    String? asyncPushError;
    var terminalTaskFailure = false;
    final recentMessages = MessageStore.instance.getRecentRounds(
      chatId,
      role.maxContextRounds,
    );
    final historyMessages = recentMessages.isNotEmpty
        ? recentMessages.sublist(0, recentMessages.length - 1)
        : <Message>[];
    final history = MessageStore.toApiHistory(historyMessages);
    final coreMemory = MemoryManager.getCoreMemoryForRequest();

    // 获取朋友圈感知上下文（弱上下文，概率注入）
    final momentsContext = isGroup
        ? null
        : MomentsScheduler.instance.buildMomentsAwarenessContext();

    // 注入外挂 JSON 记录（后端优先使用自身配置，此处作为兜底透传）
    final attachedJson = role.attachedJsonContent;

    // 图片（tool 模式聚合）：逐张上传得到 upload_id，随 ai_event 一并提交，
    // 由服务端组装 vision_context 并把 recognize_image 工具交给聊天模型。
    final visionUploadIds = <String>[];
    for (final path in imagePaths) {
      try {
        final uploadId = await ApiService.uploadVisionImage(imagePath: path);
        if (uploadId.isNotEmpty) visionUploadIds.add(uploadId);
      } catch (e) {
        debugPrint('ChatController: vision upload failed ($path): $e');
      }
    }

    // 纯图片批次（无文本）给一个中性提示，避免空消息
    final baseMessage = userMessage.trim().isEmpty && visionUploadIds.isNotEmpty
        ? '用户发送了图片'
        : userMessage;

    // 如果有朋友圈上下文，附加到消息后面
    final finalMessage = momentsContext != null
        ? '$baseMessage\n\n$momentsContext'
        : baseMessage;

    // 优先尝试后端 API（异步任务机制）
    _ensureChatPushListener();

    final requestContext = <String, dynamic>{
      'chat_id': chatId,
      'is_group': isGroup,
      'history': history,
      'core_memory': coreMemory,
      'moments_context': momentsContext,
      'attached_json': attachedJson,
      if (visionUploadIds.isNotEmpty) 'vision_upload_ids': visionUploadIds,
    };
    final clientSubmissionId = _newClientSubmissionId();
    final expectedTaskId = _taskIdForSubmission(clientSubmissionId);
    await _ensurePersistedStateLoaded();
    await _savePersistedPendingTask(
      expectedTaskId,
      chatId: chatId,
      roleId: role.id,
      isGroup: isGroup,
      userMessage: userMessage,
      attachedJson: (attachedJson != null && attachedJson.isNotEmpty)
          ? attachedJson
          : null,
      clientSubmissionId: clientSubmissionId,
      requestMessage: finalMessage,
      requestContext: requestContext,
      submissionUncertain: true,
    );

    final submitResponse = await ApiService.submitChatTask(
      roleId: role.id,
      message: finalMessage,
      clientSubmissionId: clientSubmissionId,
      context: requestContext,
    );

    // Older servers can finish the request synchronously. Preserve tool
    // metadata in this compatibility path as well.
    if (submitResponse.status == 'completed' && submitResponse.content != null) {
      await _removePersistedPendingTask(expectedTaskId);
      return _AiReply(
        submitResponse.content!,
        _extractToolEmotions(submitResponse.metadata),
      );
    }

    // 异步任务：等待推送结果
    if (submitResponse.status == 'queued' && submitResponse.taskId != null) {
      final taskId = submitResponse.taskId!;
      final completer = Completer<Map<String, dynamic>>();
      _pendingChatTasks[taskId] = completer;

      // 持久化 pending 任务上下文：即使 App 在等待期间被杀死/重启，
      // 恢复路径仍可凭 task_id 从服务端缓存补齐并渲染这条回复。
      await _movePersistedPendingTask(expectedTaskId, taskId);
      await _updatePersistedPendingTask(taskId, {
        'submission_uncertain': false,
      });

      try {
        final pushPayload = await completer.future.timeout(
          const Duration(seconds: 120),
          onTimeout: () {
            _pendingChatTasks.remove(taskId);
            throw TimeoutException(
              'Async chat push timeout',
              const Duration(seconds: 120),
            );
          },
        );

        final success = pushPayload['success'] == true;
        final content = pushPayload['content']?.toString();
        final metadata = pushPayload['metadata'] is Map
            ? Map<String, dynamic>.from(pushPayload['metadata'])
            : null;

        if (success && content != null) {
          // 由本次 await 负责渲染：立刻标记已渲染，避免并发恢复路径重复落地。
          _renderedTaskIds.add(taskId);
          final noReply = metadata?['no_reply'] == true ||
              MessageParts.isNoReplyDirective(content);
          debugPrint('ChatController: AI response via backend (async push)');
          final requestId = metadata?['request_id']?.toString().trim();
          await MemoryService.appendJsonMemoryPair(
            roleId: role.id,
            userContent: userMessage,
            assistantContent: noReply ? null : content,
            requestId: (requestId != null && requestId.isNotEmpty)
                ? requestId
                : null,
            jsonMemory: (attachedJson != null && attachedJson.isNotEmpty)
                ? attachedJson
                : null,
          );
          if (metadata != null) {
            debugPrint('ChatController: Metadata from async push: $metadata');
          }
          await _markTaskRendered(taskId);
          if (noReply && !role.showNoReply) return null;
          return _AiReply(content, _extractToolEmotions(metadata));
        }

        // 服务端已明确返回终态失败，才向用户展示发送失败。
        terminalTaskFailure = true;
        await _removePersistedPendingTask(taskId);
        asyncPushError = pushPayload['error']?.toString();
        debugPrint('ChatController: Async chat failed: $asyncPushError');
      } catch (e) {
        _pendingChatTasks.remove(taskId);
        debugPrint('ChatController: Async chat error (taskId=$taskId): $e');

        // On timeout, try to recover the missed push from server cache
        if (e is TimeoutException) {
          try {
            final result = await SecureWebSocketClient.instance.request(
              'recover_chat_push',
              {
                'task_ids': [taskId],
              },
              timeout: const Duration(seconds: 10),
            );
            final recovered = result['recovered'];
            if (recovered is List && recovered.isNotEmpty) {
              final pushPayload = (recovered[0] is Map)
                  ? (recovered[0] as Map)['payload']
                  : null;
              if (pushPayload is Map) {
                final success = pushPayload['success'] == true;
                final content = pushPayload['content']?.toString();
                // 若期间到达的迟推送已由监听器落地渲染，则此处不再重复。
                if (success && content != null &&
                    !_renderedTaskIds.contains(taskId)) {
                  _renderedTaskIds.add(taskId);
                  debugPrint('ChatController: AI response via recovery push');
                  final metadata = pushPayload['metadata'] is Map
                      ? Map<String, dynamic>.from(pushPayload['metadata'])
                      : null;
                  final noReply = metadata?['no_reply'] == true ||
                      MessageParts.isNoReplyDirective(content);
                  final requestId = metadata?['request_id']?.toString().trim();
                  await MemoryService.appendJsonMemoryPair(
                    roleId: role.id,
                    userContent: userMessage,
                    assistantContent: noReply ? null : content,
                    requestId: (requestId != null && requestId.isNotEmpty)
                        ? requestId
                        : null,
                    jsonMemory:
                        (attachedJson != null && attachedJson.isNotEmpty)
                        ? attachedJson
                        : null,
                  );
                  await _markTaskRendered(taskId);
                  if (noReply && !role.showNoReply) return null;
                  return _AiReply(content, _extractToolEmotions(metadata));
                }
              }
            }
          } catch (recoveryError) {
            debugPrint('ChatController: push recovery failed: $recoveryError');
          }
        }
        // 超时且即时恢复未命中：保留持久化 pending，留待后续
        // 重连/前台恢复/重启时经 recoverPendingChatTasks 补齐渲染。
      }

      // 已收到 queued/task_id 代表服务端已接收任务。推送未到或即时恢复
      // 未命中时保留 pending 供后续恢复，不能误报为消息发送失败。
      if (!terminalTaskFailure) {
        debugPrint('ChatController: queued task $taskId is awaiting recovery');
        return null;
      }
    }

    // 仅通过 WebSocket 通信，无直连回退
    if (submitResponse.isTransportError) {
      await _ensureRecoveryStatusMessage(expectedTaskId);
      debugPrint(
        'ChatController: chat submission is awaiting reconnect: ${submitResponse.error}',
      );
      return null;
    }

    await _removePersistedPendingTask(expectedTaskId);
    debugPrint(
      'ChatController: WebSocket chat failed: ${submitResponse.error}',
    );
    // 避免连续重复的错误消息：如果最后一条消息已经是错误，不再重复添加
    final lastMsg = MessageStore.instance.getLastMessage(chatId);
    if (lastMsg != null && lastMsg.senderId == 'error') {
      debugPrint(
        'ChatController: skipping duplicate error message for $chatId',
      );
      return null;
    }
    final errorMessage = createMessage(
      senderId: 'error',
      receiverId: 'me',
      content: '消息发送失败：${asyncPushError ?? '网络连接中断，请检查后端服务是否运行'}',
    );
    await MessageStore.instance.addMessage(chatId, errorMessage);
    return null;
  }

  // ========== 分段发送 ==========

  Future<List<String>> _loadAvailableEmojiCategories(String roleId) async {
    try {
      final categories = await EmojiService.instance.getAiCategories(roleId);
      return StickerService.normalizeCategorySet(categories).toList();
    } catch (e) {
      debugPrint(
        'ChatController: load emoji categories failed for $roleId: $e',
      );
      return const <String>[];
    }
  }

  Future<void> _sendSegmentsQueued(
    String chatId,
    String roleId,
    String rawReply, {
    required bool isGroup,
    List<String> toolEmotions = const <String>[],
  }) async {
    final segments = SegmentSender.splitMessage(rawReply);
    final availableEmojiCategories = await _loadAvailableEmojiCategories(
      roleId,
    );
    final preferredDefaultEmojiCategory =
        StickerService.resolveAvailableEmotion(
          rawEmotion: 'neutral',
          availableCategories: availableEmojiCategories,
          defaultCategory: null,
        );
    final defaultEmojiCategory =
        preferredDefaultEmojiCategory ??
        (availableEmojiCategories.isNotEmpty
            ? availableEmojiCategories.first
            : null);
    debugPrint('ChatController: Split into ${segments.length} segments');

    final renderedTextEmotions = <String>[];
    for (var i = 0; i < segments.length; i++) {
      final segment = segments[i];
      final isLast = i == segments.length - 1;

      // 非第一条时延迟（单聊显示 typing，群聊不显示）
      if (i > 0) {
        if (!isGroup) {
          _setTyping(chatId, true);
        }
        final delay = 500 + _random.nextInt(1001); // 500-1500ms
        await Future.delayed(Duration(milliseconds: delay));
      }

      // 解析情绪标签
      final (
        cleanedText,
        emotion,
      ) = StickerService.parseEmotionTagWithAvailableCategories(
        segment,
        availableCategories: availableEmojiCategories,
        defaultCategory: defaultEmojiCategory,
      );
      final displayText = cleanedText.isNotEmpty ? cleanedText : segment;

      final aiMessage = Message(
        id: '${DateTime.now().millisecondsSinceEpoch}_${i}_${segment.hashCode}',
        senderId: roleId,
        receiverId: 'me',
        content: displayText,
        timestamp: DateTime.now(),
      );

      await MessageStore.instance.addMessage(chatId, aiMessage);

      // 更新未读并发送通知
      if (!_typingCallbacks.containsKey(chatId)) {
        MessageStore.instance.incrementUnread(chatId);
        ChatListService.instance.incrementUnread(chatId);

        // 发送本地通知（去除格式标记，仅展示 AI 实际说出的内容）
        final role = RoleService.getRoleById(roleId);
        final notificationParts = MessageParts.parse(
          displayText,
          allowFact: false,
        );
        final notifyDialogue = notificationParts.dialogue;
        NotificationService.instance.showMessageNotification(
          chatId: chatId,
          senderName: role?.name ?? 'AI',
          message: notifyDialogue.trim().isNotEmpty
              ? notifyDialogue
              : notificationParts.plainText,
        );

        // 更新角标
        final totalUnread = ChatListService.instance.totalUnreadCount;
        NotificationService.instance.setBadgeCount(totalUnread);
      }

      // 更新上下文
      final context = _contexts[chatId];
      if (context != null) {
        _contexts[chatId] = context.copyWith(
          messageCount: MessageStore.instance.getMessageCount(chatId),
          lastMessageTime: DateTime.now(),
        );
      }

      debugPrint('ChatController: Sent segment ${i + 1}/${segments.length}');

      // Keep legacy text tags working while tool-call metadata becomes the
      // authoritative signal for newer backend responses.
      if (emotion != null) {
        renderedTextEmotions.add(emotion);
        await _appendAiSticker(
          chatId: chatId,
          roleId: roleId,
          emotion: emotion,
          availableEmojiCategories: availableEmojiCategories,
          defaultEmojiCategory: defaultEmojiCategory,
        );
      }

      if (!isLast) {
        await Future.delayed(
          Duration(milliseconds: 100 + _random.nextInt(200)),
        );
      }
    }

    // A tool call is valid even when the final model text does not echo its
    // legacy [emotion] marker. Consume matching text markers first so old
    // model responses do not render the same tool call twice.
    final unmatchedTextEmotions = List<String>.from(renderedTextEmotions);
    for (final rawEmotion in toolEmotions) {
      final emotion = StickerService.resolveAvailableEmotion(
        rawEmotion: rawEmotion,
        availableCategories: availableEmojiCategories,
        defaultCategory: defaultEmojiCategory,
      );
      if (emotion == null) continue;
      final existingIndex = unmatchedTextEmotions.indexOf(emotion);
      if (existingIndex >= 0) {
        unmatchedTextEmotions.removeAt(existingIndex);
        continue;
      }
      await _appendAiSticker(
        chatId: chatId,
        roleId: roleId,
        emotion: emotion,
        availableEmojiCategories: availableEmojiCategories,
        defaultEmojiCategory: defaultEmojiCategory,
      );
    }

    if (!isGroup) {
      _hideTyping(chatId);
    }
  }

  Future<void> _appendAiSticker({
    required String chatId,
    required String roleId,
    required String emotion,
    required List<String> availableEmojiCategories,
    required String? defaultEmojiCategory,
  }) async {
    final placeholderStickerId =
        '${DateTime.now().microsecondsSinceEpoch}_sticker_${emotion.hashCode}';
    final placeholderContent = StickerService.createStickerMessageContent(
      emotion,
      'placeholder://$emotion',
    );
    await MessageStore.instance.addMessage(chatId, Message(
      id: placeholderStickerId,
      senderId: roleId,
      receiverId: 'me',
      content: placeholderContent,
      type: MessageType.sticker,
      timestamp: DateTime.now(),
    ));

    final candidates = <String>[emotion];
    if (defaultEmojiCategory != null && defaultEmojiCategory.isNotEmpty) {
      candidates.add(defaultEmojiCategory);
    }
    candidates.addAll(availableEmojiCategories);

    String? stickerUrl;
    for (final candidate in candidates.toSet()) {
      try {
        final data = await SecureWebSocketClient.instance
            .request('emoji_random', {'role_id': roleId, 'emotion': candidate})
            .timeout(const Duration(seconds: 5));
        if (data['found'] == true && data['url'] != null) {
          final value = data['url'].toString().trim();
          if (value.isNotEmpty) {
            stickerUrl = value;
            break;
          }
        }
      } catch (e) {
        debugPrint('ChatController: Sticker fetch error on $candidate: $e');
      }

    }

    if (stickerUrl != null) {
      await Future.delayed(Duration(milliseconds: 300 + _random.nextInt(500)));
      await MessageStore.instance.updateMessage(
        chatId,
        placeholderStickerId,
        content: StickerService.createStickerMessageContent(emotion, stickerUrl),
        type: MessageType.sticker,
      );
      return;
    }

    final fallbackEmotion = defaultEmojiCategory ?? emotion;
    await MessageStore.instance.updateMessage(
      chatId,
      placeholderStickerId,
      content: StickerService.createStickerMessageContent(
        fallbackEmotion,
        'placeholder://$fallbackEmotion',
      ),
      type: MessageType.sticker,
    );
  }

  // ========== 辅助方法 ==========

  Future<void> _showTypingWithDelay(
    String chatId, {
    required bool isGroup,
  }) async {
    if (isGroup) return; // 群聊不显示 typing
    final delay = 500 + _random.nextInt(1500);
    await Future.delayed(Duration(milliseconds: delay));
    _setTyping(chatId, true);
  }

  void _hideTyping(String chatId) {
    _setTyping(chatId, false);
  }

  void _setTyping(String chatId, bool isTyping) {
    _typingCallbacks[chatId]?.call(isTyping);
  }

  void _updateChatList(String chatId) {
    final lastMessage = MessageStore.instance.getLastMessage(chatId);
    if (lastMessage != null) {
      ChatListService.instance.updateChat(
        chatId: chatId,
        lastMessage: _getMessageDisplayText(lastMessage),
        lastMessageTime: lastMessage.timestamp,
      );
    }
  }

  /// 获取消息的显示文本（用于聊天列表预览）
  static String _getMessageDisplayText(Message message) {
    switch (message.type) {
      case MessageType.sticker:
        return '[图片]';
      case MessageType.image:
        return '[图片]';
      default:
        // 预览只展示对话，剥离动作/心理/数值等格式化片段。
        return MessageParts.previewText(
          message.content,
          isUserMessage: message.senderId == 'me',
        );
    }
  }
}

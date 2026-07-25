import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import '../models/message.dart';
import '../services/sticker_service.dart';
import '../services/storage_service.dart';
import '../services/secure_websocket_client.dart';
import '../services/chat_list_service.dart';

/// 消息存储层
/// 聊天记录的唯一真实来源（Single Source of Truth）
/// 支持 Stream 订阅和持久化
class MessageStore extends ChangeNotifier {
  static final MessageStore _instance = MessageStore._internal();
  factory MessageStore() => _instance;
  MessageStore._internal();

  static MessageStore get instance => _instance;

  /// 是否已初始化
  bool _initialized = false;

  /// 按 chatId 存储的消息列表
  final Map<String, List<Message>> _messages = {};

  /// 按 chatId 存储的未读计数
  final Map<String, int> _unreadCounts = {};

  /// 消息 Stream 控制器（按 chatId）
  final Map<String, StreamController<List<Message>>> _streamControllers = {};

  /// 占位表情修复状态，避免在频繁重建时重复触发
  final Set<String> _placeholderRepairInProgress = <String>{};
  final Map<String, DateTime> _placeholderRepairLastAttempt =
      <String, DateTime>{};
  static const Duration _placeholderRepairGraceWindow = Duration(seconds: 8);

  /// 持久化写入防抖：内存与 UI 立即更新，落盘按 chat 合并到一个短窗口，
  /// 避免频繁收发消息时每条都全量重写 SharedPreferences 造成卡顿。
  final Map<String, Timer> _saveDebounceTimers = <String, Timer>{};
  static const Duration _saveDebounceWindow = Duration(milliseconds: 500);

  /// 发件箱：用户消息后端同步的最大重试次数（首发之外）。
  static const int _syncMaxRetry = 4;

  /// 正在 drain 的标记，避免重连风暴时并发重复 drain。
  bool _draining = false;

  /// 初始化（确保只执行一次）
  static Future<void> init() async {
    if (_instance._initialized) {
      debugPrint('MessageStore: Already initialized');
      return;
    }
    await _instance._loadAllMessages();
    await _instance._syncAllChatsFromBackendIfNeeded();
    _instance._initialized = true;
    debugPrint(
      'MessageStore initialized with ${_instance._messages.length} chats',
    );
  }

  /// 确保指定 chatId 的消息已加载
  Future<void> ensureLoaded(String chatId) async {
    if (!_messages.containsKey(chatId)) {
      await _loadMessages(chatId);
      debugPrint('MessageStore: Loaded messages for $chatId');
    }
  }

  // ========== 消息订阅 ==========

  /// 订阅指定聊天的消息流
  /// UI 层使用此方法订阅消息更新
  /// 订阅时立即推送当前历史消息
  Stream<List<Message>> watchMessages(String chatId) {
    // 确保消息已加载
    ensureLoaded(chatId);

    if (!_streamControllers.containsKey(chatId)) {
      _streamControllers[chatId] = StreamController<List<Message>>.broadcast(
        onListen: () {
          // 新订阅者加入时，立即推送当前消息
          Future.microtask(() {
            if (_streamControllers[chatId]?.hasListener == true) {
              _streamControllers[chatId]!.add(getMessages(chatId));
            }
          });
        },
      );
    }

    // 立即发送当前消息（确保订阅者收到初始数据）
    Future.microtask(() {
      if (_streamControllers[chatId]?.hasListener == true) {
        _streamControllers[chatId]!.add(getMessages(chatId));
      }
    });

    return _streamControllers[chatId]!.stream;
  }

  /// 强制刷新指定聊天的消息流
  void refreshStream(String chatId) {
    _notifyMessageUpdate(chatId);
  }

  /// 通知订阅者消息已更新
  void _notifyMessageUpdate(String chatId) {
    if (_streamControllers.containsKey(chatId) &&
        _streamControllers[chatId]!.hasListener) {
      _streamControllers[chatId]!.add(getMessages(chatId));
    }
    notifyListeners();
  }

  // ========== 消息操作 ==========

  /// 添加消息（唯一写入入口）
  Future<void> addMessage(String chatId, Message message) async {
    _messages[chatId] ??= [];
    _messages[chatId]!.add(message);
    // 内存与 UI 立即更新；落盘走防抖，合并高频写入。
    _scheduleSaveMessages(chatId);
    _notifyMessageUpdate(chatId);
    debugPrint(
      'MessageStore: Added message to $chatId (total: ${_messages[chatId]!.length})',
    );

    // 异步同步到后端（不阻塞 UI）
    _syncMessageToBackend(chatId, message);
  }

  /// 批量添加消息
  Future<void> addMessages(String chatId, List<Message> messages) async {
    _messages[chatId] ??= [];
    _messages[chatId]!.addAll(messages);
    await _saveMessages(chatId);
    _notifyMessageUpdate(chatId);
  }

  /// 删除消息
  Future<void> deleteMessage(String chatId, String messageId) async {
    final messages = _messages[chatId];
    if (messages != null) {
      messages.removeWhere((m) => m.id == messageId);
      await _saveMessages(chatId);
      _notifyMessageUpdate(chatId);

      // 同步到后端（fire-and-forget）
      _syncDeleteMessageToBackend(chatId, messageId);
    }
  }

  /// 更新已存在消息（用于占位消息替换等场景）
  Future<bool> updateMessage(
    String chatId,
    String messageId, {
    String? content,
    MessageType? type,
    String? quotedPreviewText,
    MessageSendStatus? sendStatus,
  }) async {
    final messages = _messages[chatId];
    if (messages == null || messages.isEmpty) {
      return false;
    }

    final index = messages.indexWhere((m) => m.id == messageId);
    if (index < 0) {
      return false;
    }

    final current = messages[index];
    messages[index] = current.copyWith(
      content: content,
      type: type,
      quotedPreviewText: quotedPreviewText,
      sendStatus: sendStatus,
    );

    await _saveMessages(chatId);
    _notifyMessageUpdate(chatId);
    final shouldSyncBackend =
        content != null || type != null || quotedPreviewText != null;
    if (shouldSyncBackend) {
      _syncUpdateMessageToBackend(chatId, messages[index]);
    }
    return true;
  }

  Future<bool> updateMessageSendStatus(
    String chatId,
    String messageId,
    MessageSendStatus sendStatus,
  ) {
    return updateMessage(chatId, messageId, sendStatus: sendStatus);
  }

  Future<void> _syncUpdateMessageToBackend(
    String chatId,
    Message message,
  ) async {
    try {
      await SecureWebSocketClient.instance.request('update_chat_message', {
        'role_id': chatId,
        'message_id': message.id,
        'content': message.content,
        'type': message.type.name,
        'quote_content': message.quotedPreviewText,
      });
    } catch (e) {
      debugPrint('MessageStore: WebSocket update sync failed: $e');
    }
  }

  bool _isPlaceholderStickerContent(String content) {
    final (_, _, imagePath) = StickerService.parseStickerMessage(content);
    return (imagePath ?? '').toLowerCase().startsWith('placeholder://');
  }

  Future<void> repairVisiblePlaceholderStickers(
    String chatId,
    List<Message> visibleMessages,
  ) async {
    if (visibleMessages.isEmpty) {
      return;
    }

    for (final msg in List<Message>.from(visibleMessages)) {
      if (msg.type != MessageType.sticker) {
        continue;
      }
      if (!_isPlaceholderStickerContent(msg.content)) {
        continue;
      }

      final repairKey = '$chatId::${msg.id}';
      final now = DateTime.now();
      // Newly created placeholders are likely being resolved by ChatController.
      // Skip immediate repair attempts to avoid duplicate emoji fetch requests.
      if (now.difference(msg.timestamp) < _placeholderRepairGraceWindow) {
        continue;
      }
      final lastAttempt = _placeholderRepairLastAttempt[repairKey];
      if (_placeholderRepairInProgress.contains(repairKey)) {
        continue;
      }
      if (lastAttempt != null && now.difference(lastAttempt).inSeconds < 15) {
        continue;
      }

      _placeholderRepairInProgress.add(repairKey);
      _placeholderRepairLastAttempt[repairKey] = now;

      final (_, emotion, _) = StickerService.parseStickerMessage(msg.content);
      final safeEmotion = (emotion ?? '').trim().toLowerCase();
      if (safeEmotion.isEmpty) {
        _placeholderRepairInProgress.remove(repairKey);
        continue;
      }

      final roleId = (msg.senderId == 'me' || msg.senderId == 'unknown')
          ? chatId
          : msg.senderId;

      try {
        final data = await SecureWebSocketClient.instance
            .request('emoji_random', {
              'role_id': roleId,
              'emotion': safeEmotion,
            })
            .timeout(const Duration(seconds: 5));
        if (data['found'] != true || data['url'] == null) {
          continue;
        }

        final stickerUrl = data['url'].toString();
        final fixedContent = StickerService.createStickerMessageContent(
          safeEmotion,
          stickerUrl,
        );
        await updateMessage(
          chatId,
          msg.id,
          content: fixedContent,
          type: MessageType.sticker,
        );
      } catch (e) {
        debugPrint('MessageStore: placeholder repair failed for ${msg.id}: $e');
      } finally {
        _placeholderRepairInProgress.remove(repairKey);
      }
    }
  }

  /// 同步删除消息到后端
  Future<void> _syncDeleteMessageToBackend(
    String chatId,
    String messageId,
  ) async {
    try {
      await SecureWebSocketClient.instance.request('delete_chat_message', {
        'role_id': chatId,
        'message_id': messageId,
      });
      debugPrint('MessageStore: Message $messageId deleted via websocket');
    } catch (e) {
      debugPrint('MessageStore: WebSocket delete sync error: $e');
    }
  }

  /// 获取指定聊天的所有消息
  List<Message> getMessages(String chatId) {
    return List.unmodifiable(_messages[chatId] ?? []);
  }

  /// 获取指定消息
  Message? getMessage(String chatId, String messageId) {
    final messages = _messages[chatId];
    if (messages == null) return null;
    try {
      return messages.firstWhere((m) => m.id == messageId);
    } catch (_) {
      return null;
    }
  }

  /// 获取最近 N 条消息
  List<Message> getRecentMessages(String chatId, int count) {
    final messages = _messages[chatId] ?? [];
    final start = messages.length > count ? messages.length - count : 0;
    return messages.sublist(start);
  }

  /// 获取最近 N 轮对话（一轮 = 用户消息 + AI 回复）
  List<Message> getRecentRounds(String chatId, int rounds) {
    final messages = _messages[chatId] ?? [];
    final messageCount = rounds * 2;
    final start = messages.length > messageCount
        ? messages.length - messageCount
        : 0;
    return messages.sublist(start);
  }

  /// 获取消息数量
  int getMessageCount(String chatId) {
    return _messages[chatId]?.length ?? 0;
  }

  /// 获取最后一条消息
  Message? getLastMessage(String chatId) {
    final messages = _messages[chatId];
    return messages != null && messages.isNotEmpty ? messages.last : null;
  }

  /// 清空指定聊天的消息
  Future<void> clearMessages(String chatId) async {
    _messages[chatId]?.clear();
    await _saveMessages(chatId);
    _notifyMessageUpdate(chatId);
  }

  // ========== 未读计数管理 ==========

  int getUnreadCount(String chatId) => _unreadCounts[chatId] ?? 0;

  void incrementUnread(String chatId, {int count = 1}) {
    _unreadCounts[chatId] = (_unreadCounts[chatId] ?? 0) + count;
    notifyListeners();
  }

  void clearUnread(String chatId) {
    _unreadCounts[chatId] = 0;
    notifyListeners();
  }

  void setUnread(String chatId, int count) {
    _unreadCounts[chatId] = count;
    notifyListeners();
  }

  // ========== 持久化 ==========

  /// 加载所有消息
  Future<void> _loadAllMessages() async {
    final chatIds =
        StorageService.getStringList('message_store_chat_ids') ?? [];
    debugPrint('MessageStore: Loading ${chatIds.length} chats');
    for (final chatId in chatIds) {
      await _loadMessages(chatId);
    }
    _reclassifyInterruptedOutbox();
  }

  /// 启动时把上次运行遗留的在途（sending）用户消息重分类为 failed：
  /// 进程已重启，其同步循环不复存在，标记为 failed 以显示重发入口，
  /// 并可被 drainOutbox() 自动重发。
  void _reclassifyInterruptedOutbox() {
    var reclassified = 0;
    for (final list in _messages.values) {
      for (var i = 0; i < list.length; i++) {
        final m = list[i];
        if (m.senderId == 'me' && m.sendStatus == MessageSendStatus.sending) {
          list[i] = m.copyWith(sendStatus: MessageSendStatus.failed);
          reclassified += 1;
        }
      }
    }
    if (reclassified > 0) {
      debugPrint(
        'MessageStore: reclassified $reclassified interrupted sending→failed',
      );
    }
  }

  /// 加载指定聊天的消息
  Future<void> _loadMessages(String chatId) async {
    final key = 'messages_v2_$chatId';
    final jsonList = StorageService.getStringList(key);

    if (jsonList != null && jsonList.isNotEmpty) {
      try {
        _messages[chatId] = jsonList.map((str) {
          return Message.fromStorageString(str);
        }).toList();
        debugPrint(
          'MessageStore: Loaded ${_messages[chatId]!.length} messages for $chatId',
        );
      } catch (e) {
        debugPrint('MessageStore: Error loading messages for $chatId: $e');
        _messages[chatId] = [];
      }
    } else {
      // 尝试加载旧格式
      await _loadMessagesLegacy(chatId);
    }
  }

  /// 加载旧格式消息并迁移
  Future<void> _loadMessagesLegacy(String chatId) async {
    final key = 'messages_$chatId';
    final jsonList = StorageService.getStringList(key);
    if (jsonList != null && jsonList.isNotEmpty) {
      _messages[chatId] = jsonList.map((json) {
        final parts = json.split('|||');
        if (parts.length >= 4) {
          return Message(
            id: parts[0],
            senderId: parts[1],
            receiverId: parts[2],
            content: parts[3],
            timestamp:
                DateTime.tryParse(parts.length > 4 ? parts[4] : '') ??
                DateTime.now(),
          );
        }
        return Message(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          senderId: 'unknown',
          receiverId: 'unknown',
          content: json,
          timestamp: DateTime.now(),
        );
      }).toList();
      // 迁移到新格式
      await _saveMessages(chatId);
      debugPrint(
        'MessageStore: Migrated ${_messages[chatId]!.length} messages for $chatId',
      );
    }
  }

  /// 立即将指定聊天的消息落盘（全量重写该 chat 的 list）
  Future<void> _saveMessages(String chatId) async {
    // 已有挂起的防抖写入则取消，避免重复写。
    _saveDebounceTimers.remove(chatId)?.cancel();
    final key = 'messages_v2_$chatId';
    final messages = _messages[chatId] ?? [];
    final jsonList = messages.map((m) => m.toStorageString()).toList();
    await StorageService.setStringList(key, jsonList);

    // 保存聊天 ID 列表
    final chatIds =
        StorageService.getStringList('message_store_chat_ids') ?? [];
    if (!chatIds.contains(chatId)) {
      chatIds.add(chatId);
      await StorageService.setStringList('message_store_chat_ids', chatIds);
    }
  }

  /// 防抖落盘：内存已即时更新，这里把落盘合并到一个短窗口内一次完成。
  void _scheduleSaveMessages(String chatId) {
    _saveDebounceTimers[chatId]?.cancel();
    _saveDebounceTimers[chatId] = Timer(_saveDebounceWindow, () {
      _saveDebounceTimers.remove(chatId);
      // fire-and-forget：落盘失败仅记录日志，内存仍是权威来源。
      unawaited(
        _saveMessages(chatId).catchError((Object e) {
          debugPrint('MessageStore: debounced save failed for $chatId: $e');
        }),
      );
    });
  }

  /// 立即 flush 所有挂起的防抖写入（app 进入后台/退出时调用，避免丢数据）。
  Future<void> flushPendingSaves() async {
    final pendingChatIds = _saveDebounceTimers.keys.toList();
    if (pendingChatIds.isEmpty) return;
    for (final chatId in pendingChatIds) {
      _saveDebounceTimers.remove(chatId)?.cancel();
    }
    for (final chatId in pendingChatIds) {
      await _saveMessages(chatId);
    }
    debugPrint(
      'MessageStore: flushed ${pendingChatIds.length} pending message saves',
    );
  }

  Future<void> _syncAllChatsFromBackendIfNeeded() async {
    try {
      final localMd5 = _calculateLocalChatsMd5();
      final data = await SecureWebSocketClient.instance.request(
        'chat_snapshot',
        {'client_md5': localMd5},
      );
      final needSync = data['need_sync'] == true;
      if (!needSync) {
        debugPrint('MessageStore: Chat snapshot MD5 matched, skip full sync');
        return;
      }

      final chatsRaw = data['chats'];
      if (chatsRaw is! Map) {
        return;
      }

      var syncedChats = 0;
      for (final entry in chatsRaw.entries) {
        final chatId = entry.key.toString();
        final rawMessages = entry.value;
        if (rawMessages is! List) {
          continue;
        }

        final previousIds = (_messages[chatId] ?? const <Message>[])
            .map((message) => message.id)
            .toSet();
        final messages = <Message>[];
        for (final item in rawMessages) {
          if (item is! Map) {
            continue;
          }
          final map = Map<String, dynamic>.from(item);
          final typeName = (map['type'] ?? 'text').toString();
          final type = MessageType.values.firstWhere(
            (e) => e.name == typeName,
            orElse: () => MessageType.text,
          );

          final timestampStr = map['timestamp']?.toString() ?? '';
          final timestamp = DateTime.tryParse(timestampStr) ?? DateTime.now();

          messages.add(
            Message(
              id:
                  map['id']?.toString() ??
                  '${timestamp.millisecondsSinceEpoch}',
              senderId: map['sender_id']?.toString() ?? 'unknown',
              receiverId: map['receiver_id']?.toString() ?? 'me',
              content: map['content']?.toString() ?? '',
              type: type,
              timestamp: timestamp,
              quotedMessageId:
                  map['quoted_message_id']?.toString() ??
                  map['quote_id']?.toString(),
              quotedPreviewText:
                  map['quoted_preview_text']?.toString() ??
                  map['quote_content']?.toString(),
            ),
          );
        }

        // 合并而非整体替换：保留服务端列表中缺失、且仍未同步（sending/failed）
        // 的本地用户消息，避免快照覆盖丢失离线期间产生的消息。
        // 因 drainOutbox() 先于本方法执行，多数本地消息已在服务端并自然去重，
        // 合并只兜底真正未同步的那些。
        final serverIds = messages.map((m) => m.id).toSet();
        final localOnly = (_messages[chatId] ?? const <Message>[]).where(
          (m) =>
              m.senderId == 'me' &&
              (m.sendStatus == MessageSendStatus.sending ||
                  m.sendStatus == MessageSendStatus.failed) &&
              !serverIds.contains(m.id),
        );
        messages.addAll(localOnly);

        messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
        final newBackgroundMessages = messages.where(
          (message) =>
              message.senderId != 'me' &&
              !previousIds.contains(message.id) &&
              (message.id.contains('_proactive') ||
                  message.id.contains('_task_')),
        );
        final newUnreadCount = newBackgroundMessages.length;
        _messages[chatId] = messages;
        await _saveMessages(chatId);
        if (messages.isNotEmpty) {
          final lastMessage = messages.last;
          ChatListService.instance.updateChat(
            chatId: chatId,
            lastMessage: lastMessage.type == MessageType.text
                ? lastMessage.content
                : '[图片]',
            lastMessageTime: lastMessage.timestamp,
            unreadIncrement: newUnreadCount,
          );
        }
        if (newUnreadCount > 0) {
          incrementUnread(chatId, count: newUnreadCount);
        }
        _notifyMessageUpdate(chatId);
        syncedChats += 1;
      }

      debugPrint('MessageStore: Full chat sync completed, chats=$syncedChats');
    } catch (e) {
      debugPrint('MessageStore: WebSocket full sync skipped due to error: $e');
    }
  }

  Future<void> syncFromBackendSnapshot() async {
    await _syncAllChatsFromBackendIfNeeded();
  }

  String _calculateLocalChatsMd5() {
    final canonical = <String, List<Map<String, dynamic>>>{};

    final chatIds = _messages.keys.toList()..sort();
    for (final chatId in chatIds) {
      final list = _messages[chatId] ?? const <Message>[];
      final serialized =
          list
              // 排除尚未同步到后端的本地用户消息（sending/failed）：MD5 只代表
              // "服务端应有的内容"，纯本地未同步消息不再触发破坏性 need_sync。
              .where(
                (m) =>
                    !(m.senderId == 'me' &&
                        (m.sendStatus == MessageSendStatus.sending ||
                            m.sendStatus == MessageSendStatus.failed)),
              )
              .map(
                (m) => {
                  'id': m.id,
                  'content': m.content,
                  'sender_id': m.senderId,
                  'receiver_id': m.receiverId,
                  'timestamp': m.timestamp.toIso8601String(),
                  'type': m.type.name,
                  'quote_id': m.quotedMessageId,
                  'quote_content': m.quotedPreviewText,
                },
              )
              .toList()
            ..sort(
              (a, b) => (a['timestamp'] ?? '').toString().compareTo(
                (b['timestamp'] ?? '').toString(),
              ),
            );
      canonical[chatId] = serialized;
    }

    final jsonStr = jsonEncode(canonical);
    return md5.convert(utf8.encode(jsonStr)).toString();
  }

  /// 异步同步消息到后端（不阻塞 UI）。
  ///
  /// 对用户消息（senderId=='me'）作为发件箱处理：入队即置 sending，
  /// 有界退避重试，成功置 sent、最终失败置 failed（供 retryFailedMessage 手动重发）。
  /// 服务端 save_chat_message 已按 message.id 幂等，重发不会重复。
  /// AI/系统消息保持尽力而为，不跟踪发送状态。
  void _syncMessageToBackend(String chatId, Message message) {
    final tracked = message.senderId == 'me';
    if (tracked) {
      // 入队即标记在途，供 UI 显示"发送中"。
      unawaited(
        updateMessageSendStatus(chatId, message.id, MessageSendStatus.sending),
      );
    }

    unawaited(_runOutboxSync(chatId, message, tracked: tracked));
  }

  Future<void> _runOutboxSync(
    String chatId,
    Message message, {
    required bool tracked,
  }) async {
    Object? lastError;
    for (int attempt = 0; attempt <= _syncMaxRetry; attempt += 1) {
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

        debugPrint(
          'MessageStore: Synced message ${message.id} via websocket ✓',
        );
        if (tracked) {
          await updateMessageSendStatus(
            chatId,
            message.id,
            MessageSendStatus.sent,
          );
        }
        return;
      } catch (e) {
        lastError = e;
        if (attempt < _syncMaxRetry) {
          // 线性退避：400ms, 800ms, 1200ms ...；WS request() 已含 socket/timeout 层重试，
          // 这里覆盖更长时间的中断。
          await Future<void>.delayed(
            Duration(milliseconds: 400 * (attempt + 1)),
          );
        }
      }
    }

    debugPrint(
      'MessageStore: WebSocket sync failed for ${message.id} after retries: $lastError',
    );
    if (tracked) {
      await updateMessageSendStatus(
        chatId,
        message.id,
        MessageSendStatus.failed,
      );
    }
  }

  /// 发件箱排水：重发所有 senderId=='me' 且状态为 sending/failed 的用户消息。
  /// 由重连后的全量对账调用，且必须在快照对比之前执行。
  Future<void> drainOutbox() async {
    if (_draining) return;
    _draining = true;
    try {
      final pending = <MapEntry<String, Message>>[];
      for (final entry in _messages.entries) {
        for (final m in entry.value) {
          if (m.senderId == 'me' &&
              (m.sendStatus == MessageSendStatus.failed ||
                  m.sendStatus == MessageSendStatus.sending)) {
            pending.add(MapEntry(entry.key, m));
          }
        }
      }

      if (pending.isEmpty) return;
      debugPrint('MessageStore: draining outbox (${pending.length} messages)');
      for (final entry in pending) {
        await _runOutboxSync(entry.key, entry.value, tracked: true);
      }
    } finally {
      _draining = false;
    }
  }

  // ========== 工具方法 ==========

  /// 将消息列表转换为 API 历史格式
  static List<Map<String, String>> toApiHistory(List<Message> messages) {
    return messages
        .where(
          (m) =>
              !(m.senderId == 'me' && m.sendStatus == MessageSendStatus.failed),
        )
        .map((m) {
          final buffer = StringBuffer();
          // 添加引用内容
          if (m.hasQuote && m.quotedPreviewText != null) {
            buffer.writeln('[引用: ${m.quotedPreviewText}]');
          }
          buffer.write(m.content);
          return {
            'role': m.senderId == 'me' ? 'user' : 'assistant',
            'content': buffer.toString(),
          };
        })
        .toList();
  }

  /// 释放资源
  @override
  void dispose() {
    // 尽力 flush 挂起的写入，避免丢数据。
    unawaited(flushPendingSaves());
    for (final controller in _streamControllers.values) {
      controller.close();
    }
    _streamControllers.clear();
    super.dispose();
  }
}

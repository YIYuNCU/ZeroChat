import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import '../models/message.dart';
import 'message_parts.dart';
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
  // Resident windows only. Full histories are stored as JSONL archives on disk.
  final Map<String, List<Message>> _messages = {};
  final Map<String, Message> _lastMessages = {};
  final Map<String, int> _messageCounts = {};
  final Set<String> _knownChatIds = {};
  final Set<String> _activeChatWindows = {};
  final Map<String, Future<void>> _loadingFutures = {};
  String? _archiveDirectoryPath;

  static const int residentMessageLimit = 200;
  static const int historyPageSize = 50;
  static const String _archiveChatIdsKey = 'message_store_archive_chat_ids_v1';
  static const String _archiveCountsKey = 'message_store_archive_counts_v1';

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

  /// 发件箱：用户消息后端同步的最大重试次数（首发之外）。
  static const int _syncMaxRetry = 4;

  /// 正在 drain 的标记，避免重连风暴时并发重复 drain。
  bool _draining = false;

  /// 本地归档变更时递增，用于识别可能覆盖新消息的旧快照。
  int _localMessageRevision = 0;
  Future<void> _archiveMutationTail = Future<void>.value();
  bool _snapshotSyncRequested = false;
  Future<void>? _snapshotSyncFuture;

  /// 初始化（确保只执行一次）
  static Future<void> init() async {
    if (_instance._initialized) {
      debugPrint('MessageStore: Already initialized');
      return;
    }
    await _instance._loadArchiveIndex();
    await _instance._reclassifyInterruptedOutbox();
    await _instance._syncAllChatsFromBackendIfNeeded();
    _instance._initialized = true;
    debugPrint(
      'MessageStore initialized with ${_instance._knownChatIds.length} archived chats',
    );
  }

  /// 确保指定 chatId 的消息已加载
  Future<void> ensureLoaded(String chatId) async {
    if (!_messages.containsKey(chatId)) {
      final existing = _loadingFutures[chatId];
      if (existing != null) {
        await existing;
        return;
      }

      late final Future<void> loading;
      loading = _withArchiveMutation(() async {
        if (!_messages.containsKey(chatId)) {
          await _loadMessages(chatId);
        }
      });
      _loadingFutures[chatId] = loading;
      try {
        await loading;
      } finally {
        if (identical(_loadingFutures[chatId], loading)) {
          _loadingFutures.remove(chatId);
        }
      }
      debugPrint('MessageStore: Loaded messages for $chatId');
    }
  }

  Future<T> _withArchiveMutation<T>(Future<T> Function() operation) {
    final next = _archiveMutationTail.then((_) => operation());
    _archiveMutationTail = next.then<void>(
      (_) {},
      onError: (error, stackTrace) {},
    );
    return next;
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
    final messageToStore = prepareMessageForLocalInsert(message);
    await ensureLoaded(chatId);
    await _withArchiveMutation(() async {
      if (!_messages.containsKey(chatId)) {
        await _loadMessages(chatId);
      }
      _messages[chatId]!.add(messageToStore);
      _trimResidentMessages(chatId);
      _lastMessages[chatId] = messageToStore;
      _localMessageRevision += 1;
      await _appendMessagesToArchive(chatId, [messageToStore]);
      _notifyMessageUpdate(chatId);
      if (!_activeChatWindows.contains(chatId)) {
        _messages.remove(chatId);
      }
    });
    debugPrint(
      'MessageStore: Added message to $chatId (total: ${getMessageCount(chatId)})',
    );

    // 异步同步到后端（不阻塞 UI）
    _syncMessageToBackend(chatId, messageToStore);
  }

  @visibleForTesting
  static Message prepareMessageForLocalInsert(Message message) {
    return message.copyWith(sendStatus: MessageSendStatus.sending);
  }

  /// 批量添加消息
  Future<void> addMessages(String chatId, List<Message> messages) async {
    if (messages.isEmpty) return;
    final messagesToStore = messages
        .map(prepareMessageForLocalInsert)
        .toList(growable: false);
    await ensureLoaded(chatId);
    await _withArchiveMutation(() async {
      if (!_messages.containsKey(chatId)) {
        await _loadMessages(chatId);
      }
      _messages[chatId]!.addAll(messagesToStore);
      _trimResidentMessages(chatId);
      _lastMessages[chatId] = messagesToStore.last;
      _localMessageRevision += 1;
      await _appendMessagesToArchive(chatId, messagesToStore);
      _notifyMessageUpdate(chatId);
      if (!_activeChatWindows.contains(chatId)) {
        _messages.remove(chatId);
      }
    });
    for (final message in messagesToStore) {
      _syncMessageToBackend(chatId, message);
    }
  }

  /// 删除消息
  Future<void> deleteMessage(String chatId, String messageId) async {
    await ensureLoaded(chatId);
    final deleted = await _withArchiveMutation(() async {
      final messages = _messages[chatId];
      if (messages == null) return false;
      final existed = messages.any((message) => message.id == messageId);
      if (!existed) return false;
      messages.removeWhere((m) => m.id == messageId);
      if (messages.isEmpty) {
        _lastMessages.remove(chatId);
      } else {
        _lastMessages[chatId] = messages.last;
      }
      _localMessageRevision += 1;
      await _removeArchivedMessage(chatId, messageId);
      _notifyMessageUpdate(chatId);
      return true;
    });

    if (deleted) {
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
    await ensureLoaded(chatId);
    Message? updatedMessage;
    final updated = await _withArchiveMutation(() async {
      final messages = _messages[chatId];
      if (messages == null || messages.isEmpty) return false;
      final index = messages.indexWhere((m) => m.id == messageId);
      if (index < 0) return false;

      updatedMessage = messages[index].copyWith(
        content: content,
        type: type,
        quotedPreviewText: quotedPreviewText,
        sendStatus: sendStatus,
      );
      messages[index] = updatedMessage!;
      if (_lastMessages[chatId]?.id == messageId) {
        _lastMessages[chatId] = updatedMessage!;
      }
      _localMessageRevision += 1;
      await _replaceArchivedMessage(chatId, updatedMessage!);
      _notifyMessageUpdate(chatId);
      return true;
    });
    if (!updated) return false;

    final shouldSyncBackend =
        content != null || type != null || quotedPreviewText != null;
    if (shouldSyncBackend) {
      _syncUpdateMessageToBackend(chatId, updatedMessage!);
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
    return _messageCounts[chatId] ?? _messages[chatId]?.length ?? 0;
  }

  bool hasOlderMessages(String chatId) {
    return getMessageCount(chatId) > (_messages[chatId]?.length ?? 0);
  }

  Future<int> loadOlderMessages(
    String chatId, {
    int count = historyPageSize,
  }) async {
    await ensureLoaded(chatId);
    final resident = _messages[chatId]!;
    if (resident.isEmpty) return 0;

    final archive = await _readArchivedMessages(chatId);
    final firstResidentId = resident.first.id;
    final firstResidentIndex = archive.indexWhere(
      (m) => m.id == firstResidentId,
    );
    if (firstResidentIndex <= 0) return 0;

    final start = (firstResidentIndex - count)
        .clamp(0, firstResidentIndex)
        .toInt();
    final older = archive.sublist(start, firstResidentIndex);
    resident.insertAll(0, older);
    _notifyMessageUpdate(chatId);
    return older.length;
  }

  void releaseChatWindow(String chatId) {
    _activeChatWindows.remove(chatId);
    _messages.remove(chatId);
    final streamController = _streamControllers.remove(chatId);
    if (streamController != null) {
      unawaited(streamController.close());
    }
  }

  void activateChatWindow(String chatId) {
    _activeChatWindows.add(chatId);
  }

  /// 获取最后一条消息
  Message? getLastMessage(String chatId) {
    final messages = _messages[chatId];
    return messages != null && messages.isNotEmpty
        ? messages.last
        : _lastMessages[chatId];
  }

  /// 清空指定聊天的消息
  Future<void> clearMessages(String chatId) async {
    _messages[chatId]?.clear();
    _lastMessages.remove(chatId);
    _messageCounts[chatId] = 0;
    _knownChatIds.add(chatId);
    _localMessageRevision += 1;
    await _withArchiveMutation(
      () => _writeArchivedMessages(chatId, const <Message>[]),
    );
    _notifyMessageUpdate(chatId);
  }

  Future<void> removeChatData(String chatId) async {
    await _withArchiveMutation(() async {
      _saveDebounceTimers.remove(chatId)?.cancel();
      _messages.remove(chatId);
      _lastMessages.remove(chatId);
      _messageCounts.remove(chatId);
      _knownChatIds.remove(chatId);
      _unreadCounts.remove(chatId);
      _localMessageRevision += 1;
      _placeholderRepairInProgress.removeWhere(
        (key) => key.startsWith('$chatId::'),
      );
      _placeholderRepairLastAttempt.removeWhere(
        (key, _) => key.startsWith('$chatId::'),
      );
      final file = await _archiveFile(chatId);
      if (await file.exists()) {
        await file.delete();
      }
      await StorageService.remove('messages_v2_$chatId');
      await StorageService.remove('messages_$chatId');
      await _persistArchiveIndex();
    });
    final streamController = _streamControllers.remove(chatId);
    if (streamController != null) {
      await streamController.close();
    }
    notifyListeners();
  }

  /// Deletes all locally archived conversations without sending any deletion
  /// request to the backend. This is used by device storage management.
  Future<void> clearAllLocalChatData() async {
    await _withArchiveMutation(() async {
      for (final timer in _saveDebounceTimers.values) {
        timer.cancel();
      }
      _saveDebounceTimers.clear();
      _messages.clear();
      _lastMessages.clear();
      _messageCounts.clear();
      _knownChatIds.clear();
      _unreadCounts.clear();
      _localMessageRevision += 1;

      final cachedDirectoryPath = _archiveDirectoryPath;
      final directory = cachedDirectoryPath == null
          ? Directory(
              '${(await getApplicationDocumentsDirectory()).path}'
              '${Platform.pathSeparator}message_archives',
            )
          : Directory(cachedDirectoryPath);
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
      _archiveDirectoryPath = null;
      await StorageService.remove('message_store_chat_ids');
      await StorageService.setStringList(_archiveChatIdsKey, const []);
      await StorageService.setJson(_archiveCountsKey, const {});
      notifyListeners();
    });
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

  Future<void> _loadArchiveIndex() async {
    _knownChatIds
      ..clear()
      ..addAll(StorageService.getStringList(_archiveChatIdsKey) ?? const []);
    _knownChatIds.addAll(
      StorageService.getStringList('message_store_chat_ids') ?? const [],
    );

    final counts = StorageService.getJson(_archiveCountsKey) ?? const {};
    for (final entry in counts.entries) {
      final count = entry.value;
      if (count is int && count >= 0) {
        _messageCounts[entry.key] = count;
      }
    }
  }

  /// 启动时把上次运行遗留的在途（sending）用户消息重分类为 failed：
  /// 进程已重启，其同步循环不复存在，标记为 failed 以显示重发入口，
  /// 并可被 drainOutbox() 自动重发。
  Future<void> _reclassifyInterruptedOutbox() async {
    var reclassified = 0;
    for (final chatId in _knownChatIds.toList()) {
      final list = await _readArchivedMessages(chatId);
      var changed = false;
      for (var i = 0; i < list.length; i++) {
        final m = list[i];
        if (m.senderId == 'me' && m.sendStatus == MessageSendStatus.sending) {
          list[i] = m.copyWith(sendStatus: MessageSendStatus.failed);
          reclassified += 1;
          changed = true;
        }
      }
      if (changed) await _writeArchivedMessages(chatId, list);
    }
    if (reclassified > 0) {
      debugPrint(
        'MessageStore: reclassified $reclassified interrupted sending→failed',
      );
    }
  }

  /// 加载指定聊天的消息
  Future<void> _loadMessages(String chatId) async {
    final archive = await _readArchivedMessages(chatId);
    if (archive.isEmpty && !(await _archiveFile(chatId)).existsSync()) {
      final legacy = await _readLegacyMessages(chatId);
      if (legacy.isNotEmpty) {
        await _writeArchivedMessages(chatId, legacy);
        await StorageService.remove('messages_v2_$chatId');
        await StorageService.remove('messages_$chatId');
        archive.addAll(legacy);
      }
    }

    _knownChatIds.add(chatId);
    _messageCounts[chatId] = archive.length;
    _messages[chatId] = _residentTail(archive);
    if (archive.isNotEmpty) {
      _lastMessages[chatId] = archive.last;
    } else {
      _lastMessages.remove(chatId);
    }
    await _persistArchiveIndex();
    debugPrint(
      'MessageStore: Loaded ${_messages[chatId]!.length}/${archive.length} messages for $chatId',
    );
  }

  Future<List<Message>> _readLegacyMessages(String chatId) async {
    final v2 = StorageService.getStringList('messages_v2_$chatId');
    if (v2 != null && v2.isNotEmpty) {
      try {
        return v2.map(Message.fromStorageString).toList();
      } catch (e) {
        debugPrint(
          'MessageStore: Error reading legacy v2 messages for $chatId: $e',
        );
      }
    }

    final legacy = StorageService.getStringList('messages_$chatId');
    if (legacy == null || legacy.isEmpty) return <Message>[];
    return legacy.map((json) {
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
  }

  Future<Directory> _archiveDirectory() async {
    final cached = _archiveDirectoryPath;
    if (cached != null) return Directory(cached);
    final documents = await getApplicationDocumentsDirectory();
    final directory = Directory(
      '${documents.path}${Platform.pathSeparator}message_archives',
    );
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    _archiveDirectoryPath = directory.path;
    return directory;
  }

  Future<File> _archiveFile(String chatId) async {
    final directory = await _archiveDirectory();
    final fileName = base64UrlEncode(utf8.encode(chatId)).replaceAll('=', '');
    return File('${directory.path}${Platform.pathSeparator}$fileName.jsonl');
  }

  Future<List<Message>> _readArchivedMessages(String chatId) async {
    final file = await _archiveFile(chatId);
    if (!await file.exists()) return <Message>[];
    final messages = <Message>[];
    try {
      await for (final line
          in file
              .openRead()
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        if (line.trim().isEmpty) continue;
        try {
          messages.add(Message.fromStorageString(line));
        } catch (e) {
          debugPrint(
            'MessageStore: skipped invalid archive record for $chatId: $e',
          );
        }
      }
    } catch (e) {
      debugPrint('MessageStore: failed to read archive for $chatId: $e');
    }
    return messages;
  }

  Future<void> _writeArchivedMessages(
    String chatId,
    List<Message> messages,
  ) async {
    final file = await _archiveFile(chatId);
    final temp = File('${file.path}.tmp');
    final contents = messages
        .map((message) => message.toStorageString())
        .join('\n');
    await temp.writeAsString(
      contents.isEmpty ? '' : '$contents\n',
      flush: true,
    );
    try {
      await temp.rename(file.path);
    } on FileSystemException {
      // Windows cannot replace an existing file through rename(). The fallback
      // still keeps the old archive until the temporary file is complete.
      if (await file.exists()) {
        await file.delete();
      }
      await temp.rename(file.path);
    }
    _knownChatIds.add(chatId);
    _messageCounts[chatId] = messages.length;
    await _persistArchiveIndex();
  }

  Future<void> _appendMessagesToArchive(
    String chatId,
    List<Message> messages,
  ) async {
    final file = await _archiveFile(chatId);
    await file.writeAsString(
      '${messages.map((message) => message.toStorageString()).join('\n')}\n',
      mode: FileMode.append,
      flush: true,
    );
    _knownChatIds.add(chatId);
    _messageCounts[chatId] = (_messageCounts[chatId] ?? 0) + messages.length;
    await _persistArchiveIndex();
  }

  Future<void> _replaceArchivedMessage(
    String chatId,
    Message replacement,
  ) async {
    final archive = await _readArchivedMessages(chatId);
    final index = archive.indexWhere((message) => message.id == replacement.id);
    if (index < 0) return;
    archive[index] = replacement;
    await _writeArchivedMessages(chatId, archive);
  }

  Future<void> _removeArchivedMessage(String chatId, String messageId) async {
    final archive = await _readArchivedMessages(chatId);
    final initialLength = archive.length;
    archive.removeWhere((message) => message.id == messageId);
    if (archive.length != initialLength) {
      await _writeArchivedMessages(chatId, archive);
    }
  }

  List<Message> _residentTail(List<Message> archive) {
    final start = archive.length > residentMessageLimit
        ? archive.length - residentMessageLimit
        : 0;
    return List<Message>.from(archive.sublist(start));
  }

  void _trimResidentMessages(String chatId) {
    final resident = _messages[chatId];
    if (resident == null || resident.length <= residentMessageLimit) return;
    resident.removeRange(0, resident.length - residentMessageLimit);
  }

  Future<void> _persistArchiveIndex() async {
    await StorageService.setStringList(
      _archiveChatIdsKey,
      _knownChatIds.toList(),
    );
    await StorageService.setJson(_archiveCountsKey, _messageCounts);
  }

  /// 立即 flush 所有挂起的防抖写入（app 进入后台/退出时调用，避免丢数据）。
  Future<void> flushPendingSaves() async {
    final pendingChatIds = _saveDebounceTimers.keys.toList();
    for (final chatId in pendingChatIds) {
      _saveDebounceTimers.remove(chatId)?.cancel();
    }
    if (pendingChatIds.isNotEmpty) {
      debugPrint(
        'MessageStore: cancelled ${pendingChatIds.length} obsolete save timers',
      );
    }
  }

  Future<void> _syncAllChatsFromBackendIfNeeded() async {
    if (_snapshotSyncFuture != null) {
      _snapshotSyncRequested = true;
      return _snapshotSyncFuture!;
    }
    _snapshotSyncFuture = _runSnapshotSync();
    try {
      await _snapshotSyncFuture;
    } finally {
      _snapshotSyncFuture = null;
      if (_snapshotSyncRequested) {
        _snapshotSyncRequested = false;
        unawaited(_syncAllChatsFromBackendIfNeeded());
      }
    }
  }

  Future<void> _runSnapshotSync() async {
    try {
      final requestContext = await _withArchiveMutation(() async {
        return (
          revision: _localMessageRevision,
          localMd5: await _calculateLocalChatsMd5(),
        );
      });
      final data = await SecureWebSocketClient.instance.request(
        'chat_snapshot',
        {'client_md5': requestContext.localMd5},
      );
      await _withArchiveMutation(() async {
        if (!isSnapshotRevisionCurrent(
          requestContext.revision,
          _localMessageRevision,
        )) {
          debugPrint(
            'MessageStore: discarded stale chat snapshot after local message change',
          );
          unawaited(_syncAllChatsFromBackendIfNeeded());
          return;
        }
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

          final previousIds = (await _readArchivedMessages(
            chatId,
          )).map((message) => message.id).toSet();
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
          final localArchive = await _readArchivedMessages(chatId);
          final mergedMessages = mergeSnapshotWithLocalMessages(
            messages,
            localArchive,
          );
          messages
            ..clear()
            ..addAll(mergedMessages);
          final newBackgroundMessages = messages.where(
            (message) =>
                message.senderId != 'me' &&
                !previousIds.contains(message.id) &&
                (message.id.contains('_proactive') ||
                    message.id.contains('_task_')),
          );
          final newUnreadCount = newBackgroundMessages.length;
          await _writeArchivedMessages(chatId, messages);
          if (messages.isNotEmpty) {
            _lastMessages[chatId] = messages.last;
          } else {
            _lastMessages.remove(chatId);
          }
          if (_activeChatWindows.contains(chatId)) {
            _messages[chatId] = _residentTail(messages);
          } else {
            _messages.remove(chatId);
          }
          if (messages.isNotEmpty) {
            final lastMessage = messages.last;
            ChatListService.instance.updateChat(
              chatId: chatId,
              // 预览只保留对话，剥离动作等格式化片段。
              lastMessage: lastMessage.type == MessageType.text
                  ? MessageParts.previewText(
                      lastMessage.content,
                      isUserMessage: lastMessage.senderId == 'me',
                    )
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

        debugPrint(
          'MessageStore: Full chat sync completed, chats=$syncedChats',
        );
      });
    } catch (e) {
      debugPrint('MessageStore: WebSocket full sync skipped due to error: $e');
    }
  }

  Future<void> syncFromBackendSnapshot() async {
    await _syncAllChatsFromBackendIfNeeded();
  }

  Future<String> _calculateLocalChatsMd5() async {
    final canonical = <String, List<Map<String, dynamic>>>{};

    final chatIds = _knownChatIds.toList()..sort();
    for (final chatId in chatIds) {
      var list = await _readArchivedMessages(chatId);
      if (list.isEmpty) {
        final legacy = await _readLegacyMessages(chatId);
        if (legacy.isNotEmpty) {
          await _writeArchivedMessages(chatId, legacy);
          await StorageService.remove('messages_v2_$chatId');
          await StorageService.remove('messages_$chatId');
          list = legacy;
        }
      }
      final serialized =
          list
              // Exclude all unconfirmed local messages. They are retained
              // separately during snapshot merge and must not cause every
              // reconnect to request the same full snapshot.
              .where((m) => m.sendStatus == MessageSendStatus.sent)
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
    unawaited(_runOutboxSync(chatId, message, tracked: tracked));
  }

  @visibleForTesting
  static bool isSnapshotRevisionCurrent(int requested, int current) {
    return requested == current;
  }

  @visibleForTesting
  static List<Message> mergeSnapshotWithLocalMessages(
    List<Message> serverMessages,
    List<Message> localMessages,
  ) {
    final merged = <String, Message>{
      for (final message in serverMessages) message.id: message,
    };
    for (final message in localMessages) {
      if (message.sendStatus != MessageSendStatus.sent) {
        merged.putIfAbsent(message.id, () => message);
      }
    }
    final result = merged.values.toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return result;
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
        await updateMessageSendStatus(
          chatId,
          message.id,
          MessageSendStatus.sent,
        );
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
      for (final chatId in _knownChatIds.toList()) {
        await ensureLoaded(chatId);
      }
      final pending = <MapEntry<String, Message>>[];
      for (final entry in _messages.entries) {
        for (final m in entry.value) {
          if (m.sendStatus == MessageSendStatus.failed ||
              m.sendStatus == MessageSendStatus.sending) {
            pending.add(MapEntry(entry.key, m));
          }
        }
      }

      if (pending.isEmpty) return;
      debugPrint('MessageStore: draining outbox (${pending.length} messages)');
      for (final entry in pending) {
        await _runOutboxSync(
          entry.key,
          entry.value,
          tracked: entry.value.senderId == 'me',
        );
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
          // 图片消息的 content 是本地文件路径，喂给模型无意义，用占位符替代
          if (m.type == MessageType.image) {
            buffer.write('[图片]');
          } else {
            buffer.write(m.content);
          }
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

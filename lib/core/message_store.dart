import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/message.dart';
import '../services/storage_service.dart';
import '../services/settings_service.dart';

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

  /// 初始化（确保只执行一次）
  static Future<void> init() async {
    if (_instance._initialized) {
      debugPrint('MessageStore: Already initialized');
      return;
    }
    await _instance._loadAllMessages();
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
    await _saveMessages(chatId);
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

  /// 同步删除消息到后端
  Future<void> _syncDeleteMessageToBackend(
    String chatId,
    String messageId,
  ) async {
    try {
      final backendUrl = SettingsService.instance.backendUrl;
      final url = Uri.parse(
        '$backendUrl/api/roles/$chatId/chats/messages/$messageId',
      );
      final response = await http
          .delete(url)
          .timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        debugPrint('MessageStore: Message $messageId deleted from backend');
      } else {
        debugPrint(
          'MessageStore: Backend delete failed: ${response.statusCode}',
        );
      }
    } catch (e) {
      debugPrint('MessageStore: Backend delete sync error: $e');
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

  /// 保存指定聊天的消息
  Future<void> _saveMessages(String chatId) async {
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

  /// 异步同步消息到后端（不阻塞 UI）
  void _syncMessageToBackend(String chatId, Message message) {
    Future(() async {
      try {
        final backendUrl = SettingsService.instance.backendUrl;
        if (backendUrl.isEmpty) {
          debugPrint('MessageStore: Backend URL empty, skip sync');
          return;
        }

        debugPrint(
          'MessageStore: Syncing to $backendUrl/api/roles/$chatId/chats/messages',
        );

        final response = await http.post(
          Uri.parse('$backendUrl/api/roles/$chatId/chats/messages'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'id': message.id,
            'content': message.content,
            'sender_id': message.senderId,
            'timestamp': message.timestamp.toIso8601String(),
            'type': message.type.toString().split('.').last, // enum to string
            'quote_id': message.quotedMessageId,
            'quote_content': message.quotedPreviewText,
          }),
        );

        if (response.statusCode == 200) {
          debugPrint('MessageStore: Synced message ${message.id} to backend ✓');
        } else {
          debugPrint(
            'MessageStore: Failed to sync message: ${response.statusCode} ${response.body}',
          );
        }
      } catch (e) {
        debugPrint('MessageStore: Sync error: $e');
      }
    });
  }

  // ========== 工具方法 ==========

  /// 将消息列表转换为 API 历史格式
  static List<Map<String, String>> toApiHistory(List<Message> messages) {
    return messages.map((m) {
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
    }).toList();
  }

  /// 释放资源
  @override
  void dispose() {
    for (final controller in _streamControllers.values) {
      controller.close();
    }
    _streamControllers.clear();
    super.dispose();
  }
}

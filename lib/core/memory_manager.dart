import 'package:flutter/foundation.dart';
import '../models/message.dart';
import '../models/role.dart';
import '../services/api_service.dart';
import '../services/settings_service.dart';
import '../services/role_service.dart';
import 'message_store.dart';

/// 记忆管理器
/// 负责核心记忆的自动总结与更新
class MemoryManager {
  /// 触发总结的消息间隔（可配置）
  static int summarizeInterval = 40; // 默认 20 轮对话

  /// 总结的历史消息轮数
  static int summarizeRounds = 20;

  /// 设置总结轮数
  static void setSummarizeEveryNRounds(int rounds) {
    if (rounds > 0) {
      summarizeRounds = rounds;
      summarizeInterval = rounds * 2;
      debugPrint(
        'MemoryManager: Set summarize every $rounds rounds ($summarizeInterval messages)',
      );
    }
  }

  /// 检查是否需要自动总结核心记忆
  static bool shouldAutoSummarize(String chatId) {
    final messageCount = MessageStore.instance.getMessageCount(chatId);
    final shouldSummarize =
        messageCount > 0 && messageCount % summarizeInterval == 0;
    debugPrint(
      'MemoryManager: Check summarize for $chatId - count: $messageCount, interval: $summarizeInterval, trigger: $shouldSummarize',
    );
    return shouldSummarize;
  }

  /// 触发核心记忆总结（异步执行，不阻塞主流程）
  static Future<void> triggerSummarizeIfNeeded(String chatId) async {
    if (!shouldAutoSummarize(chatId)) return;

    debugPrint('MemoryManager: *** TRIGGERING AUTO-SUMMARIZE for $chatId ***');

    // 异步执行，不阻塞
    _performSummarize(chatId).catchError((e) {
      debugPrint('MemoryManager: Summarize failed: $e');
    });
  }

  /// 执行核心记忆总结
  static Future<void> _performSummarize(String chatId) async {
    // 获取最近对话
    final recentMessages = MessageStore.instance.getRecentRounds(
      chatId,
      summarizeRounds,
    );
    if (recentMessages.isEmpty) {
      debugPrint('MemoryManager: No messages to summarize');
      return;
    }

    debugPrint('MemoryManager: Summarizing ${recentMessages.length} messages');

    // 获取当前角色
    final role = RoleService.getRoleById(chatId);
    if (role == null) {
      debugPrint('MemoryManager: Role not found for $chatId');
      return;
    }

    // 构建对话文本
    final chatText = _buildChatText(recentMessages);
    if (chatText.isEmpty) return;

    // 获取全局 Memory Prompt
    final memoryPrompt = SettingsService.instance.getMemoryPrompt();
    debugPrint(
      'MemoryManager: Using memory prompt: ${memoryPrompt.substring(0, 50.clamp(0, memoryPrompt.length))}...',
    );

    // 构建总结请求
    final summaryRole = Role(
      id: 'memory_summarizer',
      name: '记忆总结器',
      systemPrompt: memoryPrompt,
      temperature: 0.3,
    );

    // 调用 AI 进行总结（静默执行，不发送聊天消息）
    final response = await ApiService.sendChatMessageWithRole(
      message: '请总结以下对话的关键信息，提取重要的用户偏好、事实和需要记住的内容：\n\n$chatText',
      role: summaryRole,
    );

    if (response.success && response.content != null) {
      debugPrint('MemoryManager: AI returned summary: ${response.content}');

      // 解析总结结果
      final memories = _parseSummary(response.content!);
      debugPrint('MemoryManager: Parsed ${memories.length} memory items');

      if (memories.isNotEmpty) {
        // 添加到角色的核心记忆
        final updatedRole = role.addCoreMemories(memories);
        await RoleService.updateRole(updatedRole);
        debugPrint(
          'MemoryManager: Updated role ${role.name} with ${memories.length} new core memories',
        );
      }
    } else {
      debugPrint('MemoryManager: AI summarization failed: ${response.error}');
    }
  }

  /// 构建对话文本用于总结
  static String _buildChatText(List<Message> messages) {
    final buffer = StringBuffer();
    for (final msg in messages) {
      final sender = msg.senderId == 'me' ? '用户' : 'AI';
      buffer.writeln('$sender: ${msg.content}');
    }
    return buffer.toString();
  }

  /// 解析总结结果为记忆列表
  static List<String> _parseSummary(String summary) {
    final memories = <String>[];
    final lines = summary.split('\n').where((line) => line.trim().isNotEmpty);

    for (final line in lines) {
      // 清理行首的标记符号
      var cleaned = line.replaceFirst(RegExp(r'^[-•*\d.、]+\s*'), '').trim();
      // 移除多余的空格
      cleaned = cleaned.replaceAll(RegExp(r'\s+'), ' ');

      if (cleaned.isNotEmpty && cleaned.length > 3) {
        memories.add(cleaned);
      }
    }

    return memories;
  }

  /// 手动触发核心记忆总结
  static Future<void> manualSummarize(String chatId) async {
    debugPrint('MemoryManager: Manual summarize triggered for $chatId');
    await _performSummarize(chatId);
  }

  /// 获取用于 AI 请求的核心记忆（从角色获取）
  static List<String> getCoreMemoryForRequest() {
    final role = RoleService.getCurrentRole();
    return role.coreMemory;
  }

  /// 获取指定角色的核心记忆
  static List<String> getRoleCoreMemory(String roleId) {
    final role = RoleService.getRoleById(roleId);
    return role?.coreMemory ?? [];
  }
}

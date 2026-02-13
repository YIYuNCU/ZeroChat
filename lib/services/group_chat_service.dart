import 'package:flutter/foundation.dart';
import '../models/group_chat.dart';
import 'storage_service.dart';

/// 群聊服务
/// 管理群聊创建、成员、防刷屏等
class GroupChatService {
  static final List<GroupChat> _groups = [];
  static final Map<String, DateTime> _lastReplyTime = {};
  static final Map<String, int> _replyCountPerMinute = {};

  /// 初始化
  static Future<void> init() async {
    await _loadGroups();
    debugPrint('GroupChatService initialized with ${_groups.length} groups');
  }

  /// 加载群聊列表
  static Future<void> _loadGroups() async {
    final jsonList = StorageService.getJsonList('group_chats');
    if (jsonList != null) {
      _groups.clear();
      for (final json in jsonList) {
        try {
          _groups.add(GroupChat.fromJson(json));
        } catch (e) {
          debugPrint('Error loading group: $e');
        }
      }
    }
  }

  /// 保存群聊列表
  static Future<void> _saveGroups() async {
    final jsonList = _groups.map((g) => g.toJson()).toList();
    await StorageService.setJsonList('group_chats', jsonList);
  }

  /// 创建群聊
  static Future<GroupChat> createGroup({
    required String name,
    required List<String> memberIds,
    int cooldownSeconds = 5,
    int maxRepliesPerMinute = 10,
  }) async {
    final group = GroupChat(
      id: 'group_${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      memberIds: memberIds,
      ownerId: 'user',
      cooldownSeconds: cooldownSeconds,
      maxRepliesPerMinute: maxRepliesPerMinute,
    );

    _groups.add(group);
    await _saveGroups();
    return group;
  }

  /// 获取群聊
  static GroupChat? getGroup(String groupId) {
    return _groups.where((g) => g.id == groupId).firstOrNull;
  }

  /// 获取所有群聊
  static List<GroupChat> getAllGroups() {
    return List.unmodifiable(_groups);
  }

  /// 更新群聊
  static Future<void> updateGroup(GroupChat group) async {
    final index = _groups.indexWhere((g) => g.id == group.id);
    if (index != -1) {
      _groups[index] = group;
      await _saveGroups();
    }
  }

  /// 删除群聊
  static Future<void> deleteGroup(String groupId) async {
    _groups.removeWhere((g) => g.id == groupId);
    await _saveGroups();
  }

  /// 添加成员
  static Future<void> addMember(String groupId, String memberId) async {
    final group = getGroup(groupId);
    if (group != null && !group.memberIds.contains(memberId)) {
      final updated = group.copyWith(memberIds: [...group.memberIds, memberId]);
      await updateGroup(updated);
    }
  }

  /// 移除成员
  static Future<void> removeMember(String groupId, String memberId) async {
    final group = getGroup(groupId);
    if (group != null) {
      final updated = group.copyWith(
        memberIds: group.memberIds.where((id) => id != memberId).toList(),
      );
      await updateGroup(updated);
    }
  }

  /// 修改群名
  static Future<void> renameGroup(String groupId, String newName) async {
    final group = getGroup(groupId);
    if (group != null) {
      final updated = group.copyWith(name: newName);
      await updateGroup(updated);
    }
  }

  // ========== 防刷屏机制 ==========

  /// 检查 AI 是否可以回复（防止无限循环）
  static bool canAIReply(String groupId, String roleId) {
    final group = getGroup(groupId);
    if (group == null) return false;

    final key = '${groupId}_$roleId';
    final now = DateTime.now();

    // 检查冷却时间
    final lastReply = _lastReplyTime[key];
    if (lastReply != null) {
      final elapsed = now.difference(lastReply).inSeconds;
      if (elapsed < group.cooldownSeconds) {
        debugPrint(
          'AI $roleId in cooldown: ${group.cooldownSeconds - elapsed}s remaining',
        );
        return false;
      }
    }

    // 检查每分钟回复数
    final minuteKey = '${key}_${now.minute}';
    final count = _replyCountPerMinute[minuteKey] ?? 0;
    if (count >= group.maxRepliesPerMinute) {
      debugPrint('AI $roleId exceeded max replies per minute');
      return false;
    }

    return true;
  }

  /// 记录 AI 回复
  static void recordAIReply(String groupId, String roleId) {
    final key = '${groupId}_$roleId';
    final now = DateTime.now();

    _lastReplyTime[key] = now;

    final minuteKey = '${key}_${now.minute}';
    _replyCountPerMinute[minuteKey] =
        (_replyCountPerMinute[minuteKey] ?? 0) + 1;

    // 清理旧的计数
    _replyCountPerMinute.removeWhere((k, _) => !k.contains('_${now.minute}'));
  }

  /// 选择下一个应该回复的 AI（避免同一个 AI 连续回复）
  static String? selectNextResponder(String groupId, String lastResponderId) {
    final group = getGroup(groupId);
    if (group == null) return null;

    // 过滤掉最后回复的 AI 和不能回复的 AI
    final candidates = group.memberIds
        .where((id) => id != lastResponderId && canAIReply(groupId, id))
        .toList();

    if (candidates.isEmpty) return null;

    // 随机选择一个
    candidates.shuffle();
    return candidates.first;
  }
}

import 'dart:math';
import 'package:flutter/foundation.dart';
import '../models/role.dart';
import '../services/role_service.dart';

/// 群聊发言调度规则结果
class ScheduleResult {
  final List<Role> selectedRoles;
  final List<String> speakOrder;
  const ScheduleResult({required this.selectedRoles, required this.speakOrder});
}

/// 群聊发言调度器
class GroupScheduler {
  static final Random _random = Random();

  /// 关键词触发规则
  static final Map<String, List<String>> _keywordTriggers = {
    '技术': ['程序员', '工程师', 'developer', 'coder'],
    '代码': ['程序员', '工程师', 'developer', 'coder'],
    '设计': ['设计师', 'designer', 'ui', 'ux'],
    '产品': ['产品经理', 'pm', 'product'],
    '文案': ['文案', '编辑', 'writer', 'copywriter'],
    '营销': ['营销', 'marketing', '运营'],
  };

  /// 选择参与回复的角色
  /// [replyProbability] 可配置的回复概率
  /// [maxConsecutiveSpeaks] 可配置的最大连续发言次数
  static ScheduleResult selectRespondingRoles({
    required List<String> memberIds,
    required String userMessage,
    String? lastSpeakerRoleId,
    Map<String, int>? consecutiveCounts,
    double replyProbability = 0.6,
    int maxConsecutiveSpeaks = 2,
  }) {
    final counts = consecutiveCounts ?? {};
    final candidates = <Role>[];

    for (final roleId in memberIds) {
      final role = RoleService.getRoleById(roleId);
      if (role == null) continue;

      // 检查连续发言限制
      if (lastSpeakerRoleId == roleId) {
        final count = counts[roleId] ?? 0;
        if (count >= maxConsecutiveSpeaks) {
          debugPrint(
            'GroupScheduler: $roleId exceeded max consecutive ($maxConsecutiveSpeaks)',
          );
          continue;
        }
      }

      // 计算回复概率
      double probability = replyProbability;

      // 关键词匹配提升概率
      final keywords = _extractKeywords(userMessage);
      final roleKeywords = _getRoleKeywords(role);
      if (_hasKeywordMatch(keywords, roleKeywords)) {
        probability += 0.3;
        debugPrint('GroupScheduler: $roleId keyword match');
      }

      // 随机决定
      if (_random.nextDouble() < probability) {
        candidates.add(role);
      }
    }

    // 没有选中则随机选一个
    if (candidates.isEmpty && memberIds.isNotEmpty) {
      final randomId = memberIds[_random.nextInt(memberIds.length)];
      final role = RoleService.getRoleById(randomId);
      if (role != null) candidates.add(role);
    }

    candidates.shuffle(_random);

    return ScheduleResult(
      selectedRoles: candidates,
      speakOrder: candidates.map((r) => r.id).toList(),
    );
  }

  static Set<String> _extractKeywords(String message) {
    final keywords = <String>{};
    final lowerMessage = message.toLowerCase();
    for (final trigger in _keywordTriggers.keys) {
      if (lowerMessage.contains(trigger.toLowerCase())) {
        keywords.add(trigger);
      }
    }
    return keywords;
  }

  static Set<String> _getRoleKeywords(Role role) {
    final keywords = <String>{};
    final roleName = role.name.toLowerCase();
    final roleDesc = role.description.toLowerCase();
    for (final entry in _keywordTriggers.entries) {
      for (final keyword in entry.value) {
        if (roleName.contains(keyword) || roleDesc.contains(keyword)) {
          keywords.add(entry.key);
        }
      }
    }
    return keywords;
  }

  static bool _hasKeywordMatch(
    Set<String> messageKeywords,
    Set<String> roleKeywords,
  ) {
    return messageKeywords.intersection(roleKeywords).isNotEmpty;
  }

  static int getReplyDelay(int roleIndex) {
    final baseDelay = 1000 + roleIndex * 500;
    final variance = 500 + roleIndex * 200;
    return baseDelay + _random.nextInt(variance);
  }
}

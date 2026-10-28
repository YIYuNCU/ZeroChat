import '../models/role.dart';

/// 文本里一处 @ 提及。
class MentionSpan {
  /// '@' 所在下标（含）。
  final int start;

  /// 提及结束下标（不含）。
  final int end;

  /// 被提及的角色 ID（同名角色会有多个）；@所有人 时为空。
  final List<String> roleIds;

  const MentionSpan({
    required this.start,
    required this.end,
    this.roleIds = const [],
  });

  bool get isAll => roleIds.isEmpty;
}

/// 群聊 @ 提及的解析结果。
class MentionResult {
  /// 被提及的角色 ID，按首次出现顺序、去重。
  final List<String> roleIds;

  /// 是否 @所有人。
  final bool mentionAll;

  const MentionResult({this.roleIds = const [], this.mentionAll = false});

  bool get isEmpty => roleIds.isEmpty && !mentionAll;
}

/// 群聊 @ 提及：解析（调度用）与定位（气泡高亮用）。
class GroupMentions {
  GroupMentions._();

  /// 「@所有人」的显示名。
  static const String allName = '所有人';

  static final RegExp _wordChar = RegExp(r'[A-Za-z0-9_]');

  /// 在 [text] 中查找所有 @ 提及。
  ///
  /// [members] 为 名称 -> 角色 ID 列表（同名角色会各自命中）。
  /// 名称按长度降序匹配，保证「@小明明」不会被「小明」截断。
  /// '@' 前一个字符是字母数字时不算提及，避免把邮箱误判。
  static List<MentionSpan> findSpans(
    String text,
    Map<String, List<String>> members, {
    bool allowAll = true,
  }) {
    if (!text.contains('@')) return const [];

    final names = <String>[
      ...members.keys.where((n) => n.isNotEmpty),
      if (allowAll) allName,
    ]..sort((a, b) => b.length.compareTo(a.length));
    if (names.isEmpty) return const [];

    final lower = text.toLowerCase();
    final spans = <MentionSpan>[];
    var i = 0;
    while (i < text.length) {
      if (text[i] != '@') {
        i++;
        continue;
      }
      if (i > 0 && _wordChar.hasMatch(text[i - 1])) {
        i++;
        continue;
      }
      var matched = false;
      for (final name in names) {
        final end = i + 1 + name.length;
        if (end > text.length) continue;
        if (lower.substring(i + 1, end) != name.toLowerCase()) continue;
        // 群里恰好有叫「所有人」的角色时，优先当作提及该角色。
        spans.add(
          MentionSpan(start: i, end: end, roleIds: members[name] ?? const []),
        );
        i = end;
        matched = true;
        break;
      }
      if (!matched) i++;
    }
    return spans;
  }

  /// 把群成员整理成 名称 -> ID 列表。
  static Map<String, List<String>> indexMembers(Iterable<Role> members) {
    final index = <String, List<String>>{};
    for (final role in members) {
      index.putIfAbsent(role.name, () => []).add(role.id);
    }
    return index;
  }

  /// 解析 [text] 中提及了哪些成员。
  /// [excludeRoleId] 用于排除发言者自己，AI 提到自己不应触发自己再次回复。
  static MentionResult resolve(
    String text,
    Iterable<Role> members, {
    String? excludeRoleId,
  }) {
    final index = indexMembers(members);
    final ids = <String>[];
    var mentionAll = false;
    for (final span in findSpans(text, index)) {
      if (span.isAll) {
        mentionAll = true;
        continue;
      }
      for (final id in span.roleIds) {
        if (id != excludeRoleId && !ids.contains(id)) ids.add(id);
      }
    }
    return MentionResult(roleIds: ids, mentionAll: mentionAll);
  }
}

/// 聊天消息中的格式化片段类型。
enum MessagePartType { dialogue, action, psychology, fact, stats, noReply }

/// 单个格式化片段。
///
/// [text] 用于对话、动作、心理和事实；[stats] 仅用于数值片段。
class MessagePart {
  final MessagePartType type;
  final String text;
  final Map<String, String>? stats;

  const MessagePart({required this.type, this.text = '', this.stats});
}

/// 按原文位置解析消息格式，绝不跨位置合并片段。
///
/// 支持：
/// - `<对话>...</对话>`
/// - `<动作>...</动作>`
/// - `<心理>...</心理>`
/// - `<事实>...</事实>`（仅用户侧允许特殊展示）
/// - `<数值>键:值;键:值;...</数值>`
/// - `<无回复/>`（仅 AI 可用，且必须独立出现）
///
/// 未被完整、合法标签包裹的文本按其原始位置作为对话处理。
class MessageParts {
  static const String noReplyDirective = '<无回复/>';

  final List<MessagePart> parts;

  const MessageParts({required this.parts});

  /// 生成聊天列表/通知的预览文本：只保留对话，剥离动作/心理/数值等格式化片段。
  ///
  /// [isUserMessage] 为 true 时（用户侧）允许解析事实块，且在无对话内容时回退到
  /// 纯文本正文；AI 侧无对话（如纯动作）时返回空串，避免泄露 `<动作>` 等原始标签。
  static String previewText(String content, {required bool isUserMessage}) {
    final parts = parse(content, allowFact: isUserMessage);
    final dialogue = parts.dialogue.trim();
    if (dialogue.isNotEmpty) return dialogue;
    if (isUserMessage) {
      final fallback = parts.plainText.trim();
      return fallback.isNotEmpty ? fallback : content;
    }
    return '';
  }

  /// 兼容通知和预览调用：只提取实际对话，并保持出现顺序。
  String get dialogue => _joinedText(MessagePartType.dialogue);

  String? get action => _nullableJoinedText(MessagePartType.action);
  String? get psychology => _nullableJoinedText(MessagePartType.psychology);
  String? get fact => _nullableJoinedText(MessagePartType.fact);
  bool get isNoReply =>
      parts.length == 1 && parts.single.type == MessagePartType.noReply;

  /// 兼容旧调用：合并所有数值片段；渲染逻辑应直接使用 [parts]。
  Map<String, String>? get stats {
    final result = <String, String>{};
    for (final part in parts) {
      if (part.type == MessagePartType.stats && part.stats != null) {
        result.addAll(part.stats!);
      }
    }
    return result.isEmpty ? null : result;
  }

  bool get hasAction => action != null;
  bool get hasPsychology => psychology != null;
  bool get hasFact => fact != null;
  bool get hasStats => stats != null;

  /// 返回全部可读文本，适合不支持富格式的预览场景。
  String get plainText {
    final values = <String>[];
    for (final part in parts) {
      if (part.type == MessagePartType.stats) {
        final statText = part.stats?.entries
            .map((entry) => '${entry.key}:${entry.value}')
            .join(';');
        if (statText != null && statText.isNotEmpty) values.add(statText);
      } else if (part.text.trim().isNotEmpty) {
        values.add(part.text.trim());
      }
    }
    return values.join('\n');
  }

  static final RegExp _partRe = RegExp(
    r'<(对话|动作|心理|事实|数值)>(.*?)</\1>',
    dotAll: true,
  );

  /// [allowFact] 为 false 时，意外出现在 AI 回复中的事实块会降级为普通对话。
  static MessageParts parse(
    String content, {
    bool allowFact = true,
    bool allowNoReply = true,
  }) {
    if (isNoReplyDirective(content)) {
      return MessageParts(
        parts: [
          MessagePart(
            type: allowNoReply
                ? MessagePartType.noReply
                : MessagePartType.dialogue,
            text: allowNoReply ? '无回复' : noReplyDirective,
          ),
        ],
      );
    }

    final result = <MessagePart>[];
    var cursor = 0;

    for (final match in _partRe.allMatches(content)) {
      _appendDialogue(result, content.substring(cursor, match.start));

      final tag = match.group(1) ?? '';
      final body = (match.group(2) ?? '').trim();
      if (body.isNotEmpty) {
        switch (tag) {
          case '动作':
            result.add(MessagePart(type: MessagePartType.action, text: body));
            break;
          case '心理':
            result.add(
              MessagePart(type: MessagePartType.psychology, text: body),
            );
            break;
          case '事实':
            result.add(
              MessagePart(
                type: allowFact
                    ? MessagePartType.fact
                    : MessagePartType.dialogue,
                text: body,
              ),
            );
            break;
          case '数值':
            final parsedStats = _parseStats(body);
            if (parsedStats.isEmpty) {
              _appendDialogue(result, body);
            } else {
              result.add(
                MessagePart(type: MessagePartType.stats, stats: parsedStats),
              );
            }
            break;
          case '对话':
          default:
            result.add(MessagePart(type: MessagePartType.dialogue, text: body));
            break;
        }
      }
      cursor = match.end;
    }

    _appendDialogue(result, content.substring(cursor));
    return MessageParts(parts: List.unmodifiable(result));
  }

  static bool isNoReplyDirective(String content) =>
      content.trim() == noReplyDirective;

  String _joinedText(MessagePartType type) => parts
      .where((part) => part.type == type && part.text.trim().isNotEmpty)
      .map((part) => part.text.trim())
      .join('\n');

  String? _nullableJoinedText(MessagePartType type) {
    final value = _joinedText(type);
    return value.isEmpty ? null : value;
  }

  static void _appendDialogue(List<MessagePart> parts, String value) {
    final text = value.trim();
    if (text.isNotEmpty) {
      parts.add(MessagePart(type: MessagePartType.dialogue, text: text));
    }
  }

  static Map<String, String> _parseStats(String body) {
    final result = <String, String>{};
    for (final pair in body.split(RegExp(r'[;\n]+'))) {
      final trimmed = pair.trim();
      if (trimmed.isEmpty) continue;
      final sepIndex = _firstSepIndex(trimmed);
      if (sepIndex <= 0) continue;
      final key = trimmed.substring(0, sepIndex).trim();
      final value = trimmed.substring(sepIndex + 1).trim();
      if (key.isNotEmpty && value.isNotEmpty) result[key] = value;
    }
    return result;
  }

  static int _firstSepIndex(String value) {
    final colon = value.indexOf(':');
    final full = value.indexOf('：');
    if (colon < 0) return full;
    if (full < 0) return colon;
    return colon < full ? colon : full;
  }
}

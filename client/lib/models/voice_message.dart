import 'dart:convert';

import 'message.dart';

/// 语音消息（角色 TTS 合成的一段话）。
///
/// 服务端在 AI 回复的 `metadata['voice_messages']` 中下发列表，每项为
/// `{text, ref, duration_ms, mime}`；客户端落地为 [MessageType.voice] 消息，
/// `Message.content` 存放 `{"kind":"voice","text","ref","duration_ms"}` 的 JSON。
/// 音频本体不随消息传输：[ref] 是 `ws-emoji://voice/<role_id>/<filename>` 引用，
/// 播放时由 EmojiTransferService 经加密 WebSocket 分块下载并缓存到本地。
class VoiceMessage {
  /// `Message.content` JSON 中 `kind` 字段的固定取值。
  static const String kind = 'voice';

  /// 聊天列表 / 通知 / 历史等纯文本预览里使用的占位文案。
  static const String previewLabel = '[语音]';

  /// 语音所说的文字内容（用于「转文字」展示与送入模型历史）。
  final String text;

  /// 音频传输引用：`ws-emoji://voice/<role_id>/<filename>`。
  final String ref;

  /// 音频时长（毫秒），服务端无法得知时为 null。
  final int? durationMs;

  /// 音频 MIME（如 `audio/mpeg`）。仅在服务端元数据中携带，不写入消息内容。
  final String mime;

  const VoiceMessage({
    required this.text,
    required this.ref,
    this.durationMs,
    this.mime = '',
  });

  /// 从服务端 `voice_messages` 的单个元素解析；非法元素（缺少 ref 等）返回 null。
  static VoiceMessage? tryFromJson(dynamic raw) {
    if (raw is! Map) return null;
    final ref = (raw['ref'] ?? '').toString().trim();
    if (ref.isEmpty) return null;
    return VoiceMessage(
      text: (raw['text'] ?? '').toString(),
      ref: ref,
      durationMs: _readDurationMs(raw['duration_ms']),
      mime: (raw['mime'] ?? '').toString().trim(),
    );
  }

  /// 从 AI 回复元数据中提取全部合法语音；缺失或结构不对时返回空列表。
  static List<VoiceMessage> listFromMetadata(Map<String, dynamic>? metadata) {
    final raw = metadata?['voice_messages'];
    if (raw is! List) return const <VoiceMessage>[];
    final result = <VoiceMessage>[];
    for (final item in raw) {
      final voice = tryFromJson(item);
      if (voice != null) result.add(voice);
    }
    return result;
  }

  /// 序列化为 `Message.content`（JSON 字符串，不含 mime）。
  String toContent() {
    return jsonEncode({
      'kind': kind,
      'text': text,
      'ref': ref,
      'duration_ms': durationMs,
    });
  }

  /// 解析 `Message.content`；不是语音 JSON（或缺少 ref）时返回 null。
  static VoiceMessage? parseContent(String content) {
    final trimmed = content.trim();
    if (!trimmed.startsWith('{')) return null;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is! Map || decoded['kind'] != kind) return null;
      return tryFromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  /// 解析一条消息的语音内容；仅 [MessageType.voice] 消息有效。
  static VoiceMessage? fromMessage(Message message) {
    if (message.type != MessageType.voice) return null;
    return parseContent(message.content);
  }

  /// 消息的纯文本形式：语音消息返回所说文字（无法解析时为 [previewLabel]），
  /// 其他消息原样返回 `content`。用于复制、引用、提醒、模型历史等场景。
  static String plainText(Message message) {
    if (message.type != MessageType.voice) return message.content;
    final voice = parseContent(message.content);
    if (voice == null) return previewLabel;
    final text = voice.text.trim();
    return text.isEmpty ? previewLabel : text;
  }

  /// 时长；未知时为 null。
  Duration? get duration =>
      durationMs == null ? null : Duration(milliseconds: durationMs!);

  /// 气泡上展示的秒数标签，例如 `3"`；时长未知时返回空串。
  String get durationLabel {
    final ms = durationMs;
    if (ms == null || ms <= 0) return '';
    final seconds = (ms / 1000).ceil();
    return '$seconds"';
  }

  static int? _readDurationMs(dynamic value) {
    if (value is num) {
      final ms = value.round();
      return ms >= 0 ? ms : null;
    }
    if (value is String) {
      final ms = int.tryParse(value.trim());
      return ms != null && ms >= 0 ? ms : null;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is VoiceMessage &&
      other.text == text &&
      other.ref == ref &&
      other.durationMs == durationMs &&
      other.mime == mime;

  @override
  int get hashCode => Object.hash(text, ref, durationMs, mime);
}

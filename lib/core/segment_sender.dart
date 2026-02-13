import 'dart:math';

/// 分段发送控制器
/// 将 AI 回复按 $ 符号拆分为多段，逐条发送（模拟真人聊天）
class SegmentSender {
  static final Random _random = Random();

  /// 分隔符：使用 $ 作为唯一分隔符
  static const String _delimiter = '\$';

  /// 拆分消息为多段（按 $ 分隔）
  static List<String> splitMessage(String content) {
    if (content.trim().isEmpty) return [];

    // 按 $ 符号拆分
    final parts = content.split(_delimiter);

    // 清理并过滤空段落
    final segments = parts
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();

    // 如果没有 $ 分隔符，返回整个内容作为一条消息
    if (segments.isEmpty) {
      return [content.trim()];
    }

    return segments;
  }

  /// 生成随机发送延迟（300ms ~ 1200ms）
  static int getRandomDelay() {
    return 300 + _random.nextInt(900); // 300 + (0-899) = 300-1199
  }

  /// 分段发送消息
  static Future<void> sendInSegments({
    required String content,
    required Future<void> Function(String segment, bool isLast) onSegment,
    void Function(bool isTyping)? onTypingChange,
  }) async {
    final segments = splitMessage(content);

    for (var i = 0; i < segments.length; i++) {
      final isLast = i == segments.length - 1;
      final segment = segments[i];

      // 非第一条消息前显示"正在输入"并延迟
      if (i > 0) {
        onTypingChange?.call(true);
        await Future.delayed(Duration(milliseconds: getRandomDelay()));
      }

      await onSegment(segment, isLast);

      // 段与段之间的间隔
      if (!isLast) {
        await Future.delayed(Duration(milliseconds: getRandomDelay()));
      }
    }

    onTypingChange?.call(false);
  }
}

import 'dart:async';
import 'dart:math';

/// 消息分段发送服务
/// 将 AI 回复按分隔符拆分，模拟真人逐条发送
class MessageSplitterService {
  static final Random _random = Random();

  /// 分隔符列表（按优先级排序）
  static const List<String> _delimiters = [
    '\n\n', // 双换行
    '。', // 中文句号
    '！', // 中文感叹号
    '？', // 中文问号
    '.', // 英文句号
    '!', // 英文感叹号
    '?', // 英文问号
  ];

  /// 最小消息长度（太短的不拆分）
  static const int _minSegmentLength = 5;

  /// 最大消息长度（太长的强制拆分）
  static const int _maxSegmentLength = 200;

  /// 拆分消息
  /// [content] 原始消息内容
  /// 返回拆分后的消息片段列表
  static List<String> splitMessage(String content) {
    if (content.length <= _maxSegmentLength) {
      // 短消息不拆分
      return [content];
    }

    final segments = <String>[];
    var remaining = content.trim();

    while (remaining.isNotEmpty) {
      // 找最佳分割点
      int splitIndex = _findBestSplitPoint(remaining);

      if (splitIndex <= 0 || splitIndex >= remaining.length) {
        // 没有好的分割点，保留全部
        segments.add(remaining.trim());
        break;
      }

      final segment = remaining.substring(0, splitIndex + 1).trim();
      if (segment.length >= _minSegmentLength) {
        segments.add(segment);
      } else if (segments.isNotEmpty) {
        // 太短的追加到前一段
        segments[segments.length - 1] += ' $segment';
      } else {
        segments.add(segment);
      }

      remaining = remaining.substring(splitIndex + 1).trim();
    }

    return segments.isEmpty ? [content] : segments;
  }

  /// 找到最佳分割点
  static int _findBestSplitPoint(String text) {
    // 在合理范围内找分隔符
    final searchEnd = text.length > _maxSegmentLength
        ? _maxSegmentLength
        : text.length;

    for (final delimiter in _delimiters) {
      // 从后向前找，确保段落尽量长
      final index = text.lastIndexOf(delimiter, searchEnd);
      if (index > _minSegmentLength) {
        return index + delimiter.length - 1;
      }
    }

    // 没找到分隔符，在最大长度处找空格
    if (text.length > _maxSegmentLength) {
      final spaceIndex = text.lastIndexOf(' ', _maxSegmentLength);
      if (spaceIndex > _minSegmentLength) {
        return spaceIndex;
      }
      // 强制在最大长度处截断
      return _maxSegmentLength;
    }

    return -1; // 不分割
  }

  /// 生成随机发送延迟（毫秒）
  /// [baseDelay] 基础延迟
  /// [variance] 变化范围
  static int getRandomDelay({int baseDelay = 800, int variance = 600}) {
    return baseDelay + _random.nextInt(variance);
  }

  /// 分段发送消息
  /// [content] 原始消息内容
  /// [onSegment] 每段消息的回调，参数为 (segment, isLast)
  /// [onTyping] 显示"正在输入"的回调
  static Future<void> sendInSegments({
    required String content,
    required Future<void> Function(String segment, bool isLast) onSegment,
    void Function(bool isTyping)? onTyping,
  }) async {
    final segments = splitMessage(content);

    for (var i = 0; i < segments.length; i++) {
      final isLast = i == segments.length - 1;
      final segment = segments[i];

      // 发送前显示"正在输入"
      if (!isLast && onTyping != null) {
        onTyping(true);
        // 随机延迟模拟打字时间
        await Future.delayed(
          Duration(
            milliseconds: getRandomDelay(baseDelay: 500, variance: 1000),
          ),
        );
      }

      // 发送当前段
      await onSegment(segment, isLast);

      // 段与段之间的间隔
      if (!isLast) {
        await Future.delayed(
          Duration(milliseconds: getRandomDelay(baseDelay: 300, variance: 500)),
        );
      }
    }

    // 发送完毕，隐藏"正在输入"
    onTyping?.call(false);
  }
}

import 'package:intl/intl.dart';

/// 时间处理工具类
class DateTimeUtil {
  /// 格式化时间为聊天列表显示格式
  /// 今天显示时间，昨天显示"昨天"，其他显示日期
  static String formatChatListTime(DateTime dateTime) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final date = DateTime(dateTime.year, dateTime.month, dateTime.day);

    if (date == today) {
      return DateFormat('HH:mm').format(dateTime);
    } else if (date == yesterday) {
      return '昨天';
    } else if (now.difference(dateTime).inDays < 7) {
      return _getWeekday(dateTime.weekday);
    } else if (dateTime.year == now.year) {
      return DateFormat('M月d日').format(dateTime);
    } else {
      return DateFormat('yyyy年M月d日').format(dateTime);
    }
  }

  /// 格式化时间为消息显示格式
  static String formatMessageTime(DateTime dateTime) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final date = DateTime(dateTime.year, dateTime.month, dateTime.day);

    if (date == today) {
      return DateFormat('HH:mm').format(dateTime);
    } else if (dateTime.year == now.year) {
      return DateFormat('M月d日 HH:mm').format(dateTime);
    } else {
      return DateFormat('yyyy年M月d日 HH:mm').format(dateTime);
    }
  }

  /// 获取星期几的中文名称
  static String _getWeekday(int weekday) {
    const weekdays = ['', '周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return weekdays[weekday];
  }

  /// 计算时间差的友好显示
  static String getTimeAgo(DateTime dateTime) {
    final now = DateTime.now();
    final diff = now.difference(dateTime);

    if (diff.inSeconds < 60) {
      return '刚刚';
    } else if (diff.inMinutes < 60) {
      return '${diff.inMinutes}分钟前';
    } else if (diff.inHours < 24) {
      return '${diff.inHours}小时前';
    } else if (diff.inDays < 30) {
      return '${diff.inDays}天前';
    } else if (diff.inDays < 365) {
      return '${diff.inDays ~/ 30}个月前';
    } else {
      return '${diff.inDays ~/ 365}年前';
    }
  }
}

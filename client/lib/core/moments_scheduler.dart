import 'dart:math';
import 'package:flutter/foundation.dart';
import '../models/moment_post.dart';
import '../services/moments_service.dart';

/// AI 朋友圈调度器
///
/// 注意：AI 朋友圈的发布/点赞/评论/回复已**统一由服务端调度**
/// （server/services/scheduler_service.py），以保证「每角色最多一天一条、
/// 最少一周一条」的频率控制，并避免客户端与服务端重复发帖/竞态。
///
/// 客户端不再自主定时发帖或互动。本类现仅保留 [buildMomentsAwarenessContext]，
/// 为 1:1 聊天注入「用户最近发的朋友圈」弱上下文。
class MomentsScheduler {
  static final MomentsScheduler _instance = MomentsScheduler._internal();
  factory MomentsScheduler() => _instance;
  MomentsScheduler._internal();

  static MomentsScheduler get instance => _instance;

  final Random _random = Random();

  /// 初始化（客户端不再启动自主调度，保留以兼容启动流程）
  Future<void> init() async {
    debugPrint(
      'MomentsScheduler: Initialized (client scheduling disabled; '
      'moments are scheduled server-side)',
    );
  }

  /// 获取用户最近的朋友圈（供聊天感知使用）
  List<MomentPost> getUserRecentMoments({int limit = 3}) {
    return MomentsService.instance.posts
        .where((p) => p.authorId == 'me')
        .where((p) => DateTime.now().difference(p.createdAt).inHours < 24)
        .take(limit)
        .toList();
  }

  /// 构建朋友圈感知上下文（供 ChatController 使用）
  String? buildMomentsAwarenessContext() {
    final recentMoments = getUserRecentMoments(limit: 2);
    if (recentMoments.isEmpty) return null;

    // 25% 概率提及
    if (_random.nextDouble() > 0.25) return null;

    final moment = recentMoments[_random.nextInt(recentMoments.length)];
    final timeAgo = _formatTimeAgo(moment.createdAt);

    return '''[弱上下文提示 - 不强制使用，可忽略]
用户$timeAgo发了一条朋友圈：「${moment.content}」
如果聊天中自然想到，可以顺口提一嘴，但不要每次都提，也不要像监控用户。
提及时语气要自然，像是"对了，看到你发的那个..."''';
  }

  String _formatTimeAgo(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 60) {
      return '刚才';
    } else if (diff.inHours < 24) {
      return '${diff.inHours}小时前';
    } else {
      return '昨天';
    }
  }
}

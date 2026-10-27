import 'dart:async';

import 'package:flutter/foundation.dart';

import 'emoji_transfer_service.dart';
import 'voice_player.dart';
import 'voice_player_audioplayers.dart';

/// 把 `ws-emoji://voice/...` 引用解析为本地音频文件路径（失败返回 null）。
typedef VoicePathResolver = Future<String?> Function(String reference);

/// 某条语音消息当前的播放状态。
enum VoicePlaybackStatus { idle, loading, playing }

/// 语音消息播放服务（全局唯一，同一时间只播放一条）。
///
/// 音频经 [EmojiTransferService] 下载并缓存后再交给 [VoicePlayer] 播放；
/// 播放器与路径解析都可注入，测试不需要平台通道或网络。
class VoicePlaybackService extends ChangeNotifier {
  VoicePlaybackService({
    VoicePlayer Function()? playerFactory,
    VoicePathResolver? resolver,
  }) : _playerFactory = playerFactory ?? createDefaultVoicePlayer,
       _resolver = resolver ?? EmojiTransferService.resolveLocalPath;

  static VoicePlaybackService _instance = VoicePlaybackService();

  static VoicePlaybackService get instance => _instance;

  /// 测试里替换为注入了假播放器的实例。
  @visibleForTesting
  static set instance(VoicePlaybackService value) => _instance = value;

  final VoicePlayer Function() _playerFactory;
  final VoicePathResolver _resolver;

  VoicePlayer? _player;
  StreamSubscription<void>? _completeSubscription;

  String? _activeMessageId;
  VoicePlaybackStatus _status = VoicePlaybackStatus.idle;

  /// 每次切换/停止自增，用来丢弃已被取代的异步结果。
  int _token = 0;

  /// 当前正在加载或播放的消息 id（没有则为 null）。
  String? get activeMessageId => _activeMessageId;

  /// 指定消息的播放状态。
  VoicePlaybackStatus statusOf(String messageId) =>
      messageId == _activeMessageId ? _status : VoicePlaybackStatus.idle;

  /// 点击语音气泡：该条正在加载/播放则停止；否则停掉其他语音并播放该条。
  ///
  /// 返回 false 表示音频加载或播放失败（调用方可提示用户）。
  Future<bool> toggle({
    required String messageId,
    required String reference,
  }) async {
    if (_activeMessageId == messageId && _status != VoicePlaybackStatus.idle) {
      await stop();
      return true;
    }

    final token = ++_token;
    await _stopPlayer();
    if (token != _token) return true;
    _activeMessageId = messageId;
    _status = VoicePlaybackStatus.loading;
    notifyListeners();

    String? path;
    try {
      path = await _resolver(reference);
    } catch (e) {
      debugPrint('VoicePlaybackService: resolve failed: $e');
    }
    // 加载期间用户点了别的语音或停止，当前结果作废。
    if (token != _token) return true;
    if (path == null || path.isEmpty) {
      _reset();
      return false;
    }

    // 先切到播放态再启动播放器：极短的音频可能在 play 返回前就已播完，
    // 此时 onComplete 需要能把状态复位。
    _status = VoicePlaybackStatus.playing;
    notifyListeners();
    try {
      await _ensurePlayer().play(path);
    } catch (e) {
      debugPrint('VoicePlaybackService: play failed: $e');
      if (token == _token) _reset();
      return false;
    }
    return true;
  }

  /// 停止当前播放（没有播放时无副作用）。
  Future<void> stop() async {
    _token++;
    final wasActive = _activeMessageId != null;
    _reset(notify: wasActive);
    await _stopPlayer();
  }

  VoicePlayer _ensurePlayer() {
    final existing = _player;
    if (existing != null) return existing;
    final player = _playerFactory();
    _player = player;
    _completeSubscription = player.onComplete.listen((_) {
      if (_status == VoicePlaybackStatus.playing) _reset();
    });
    return player;
  }

  Future<void> _stopPlayer() async {
    final player = _player;
    if (player == null) return;
    try {
      await player.stop();
    } catch (e) {
      debugPrint('VoicePlaybackService: stop failed: $e');
    }
  }

  void _reset({bool notify = true}) {
    _activeMessageId = null;
    _status = VoicePlaybackStatus.idle;
    if (notify) notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_completeSubscription?.cancel());
    _completeSubscription = null;
    final player = _player;
    _player = null;
    if (player != null) unawaited(player.dispose());
    super.dispose();
  }
}

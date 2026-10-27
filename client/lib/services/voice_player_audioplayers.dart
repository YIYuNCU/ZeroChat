import 'package:audioplayers/audioplayers.dart';

import 'voice_player.dart';

/// 基于 audioplayers 的 [VoicePlayer] 实现。
///
/// 这是工程里唯一直接依赖 audioplayers 的文件，播放逻辑与状态机见
/// [VoicePlaybackService]。
class AudioplayersVoicePlayer implements VoicePlayer {
  final AudioPlayer _player = AudioPlayer();

  @override
  Stream<void> get onComplete => _player.onPlayerComplete;

  @override
  Future<void> play(String filePath) =>
      _player.play(DeviceFileSource(filePath));

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> dispose() => _player.dispose();
}

/// [VoicePlaybackService] 的默认播放器工厂。
VoicePlayer createDefaultVoicePlayer() => AudioplayersVoicePlayer();

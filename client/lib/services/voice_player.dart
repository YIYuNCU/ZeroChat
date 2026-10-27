/// 本地音频播放器抽象。
///
/// [VoicePlaybackService] 只依赖这个接口，真实实现见 `voice_player_audioplayers.dart`，
/// 测试里注入假实现即可，不需要平台通道。
abstract class VoicePlayer {
  /// 当前音频自然播放结束时触发（被 [stop] 打断不触发）。
  Stream<void> get onComplete;

  /// 播放本地音频文件；返回时音频已开始播放。
  Future<void> play(String filePath);

  /// 停止播放。
  Future<void> stop();

  /// 释放底层资源。
  Future<void> dispose();
}

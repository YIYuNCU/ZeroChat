import 'dart:io';

import 'package:flutter/services.dart';

class WakeLockService {
  WakeLockService._();

  static const MethodChannel _channel = MethodChannel('zerochat/wakelock');

  static Future<void> acquireShort({
    Duration duration = const Duration(seconds: 10),
    String reason = 'short_task',
  }) async {
    if (!Platform.isAndroid) {
      return;
    }

    final ms = duration.inMilliseconds.clamp(3000, 120000);
    try {
      await _channel.invokeMethod<void>('acquireFor', <String, dynamic>{
        'durationMs': ms,
        'reason': reason,
      });
    } catch (_) {
    }
  }

  static Future<void> release() async {
    if (!Platform.isAndroid) {
      return;
    }

    try {
      await _channel.invokeMethod<void>('release');
    } catch (_) {
    }
  }
}

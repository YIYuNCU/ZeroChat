import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:permission_handler/permission_handler.dart';

/// 后台运行服务
/// Android: 启动前台服务，保证应用切到后台后仍保持运行。
class BackgroundRuntimeService {
  BackgroundRuntimeService._();

  static final FlutterBackgroundService _service = FlutterBackgroundService();
  static bool _initialized = false;

  static Future<void> init({required bool enabled}) async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      _initialized = true;
      return;
    }

    if (!_initialized) {
      await _service.configure(
        androidConfiguration: AndroidConfiguration(
          onStart: _onStart,
          autoStart: false,
          isForegroundMode: true,
          autoStartOnBoot: true,
          foregroundServiceTypes: const [AndroidForegroundType.dataSync],
          foregroundServiceNotificationId: 8899,
          initialNotificationTitle: 'ZeroChat 正在后台运行',
          initialNotificationContent: '保持任务调度与消息能力',
        ),
        iosConfiguration: IosConfiguration(),
      );
      _initialized = true;
    }

    await applyEnabled(enabled);
    debugPrint('BackgroundRuntimeService: Initialized, enabled=$enabled');
  }

  static Future<void> applyEnabled(bool enabled) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;

    try {
      final isRunning = await _service.isRunning();
      if (enabled) {
        final notificationStatus = await Permission.notification.status;
        final canShowForegroundNotification =
            !notificationStatus.isDenied &&
            !notificationStatus.isPermanentlyDenied &&
            !notificationStatus.isRestricted;

        if (!canShowForegroundNotification) {
          debugPrint(
            'BackgroundRuntimeService: Skip start, notification permission not granted',
          );
          return;
        }

        if (!isRunning) {
          await _service.startService();
        }
        return;
      }

      if (isRunning) {
        _service.invoke('stopService');
      }
    } catch (e, st) {
      debugPrint('BackgroundRuntimeService: applyEnabled failed: $e');
      debugPrint('$st');
    }
  }

  @pragma('vm:entry-point')
  static void _onStart(ServiceInstance service) {
    WidgetsFlutterBinding.ensureInitialized();

    if (service is AndroidServiceInstance) {
      service.setAsForegroundService();
    }

    service.on('stopService').listen((event) {
      service.stopSelf();
    });

    Timer.periodic(const Duration(minutes: 15), (timer) async {
      if (service is AndroidServiceInstance) {
        await service.setForegroundNotificationInfo(
          title: 'ZeroChat 正在后台运行',
          content:
              '最后保活时间: ${DateTime.now().hour.toString().padLeft(2, '0')}:${DateTime.now().minute.toString().padLeft(2, '0')}',
        );
      }
    });
  }
}

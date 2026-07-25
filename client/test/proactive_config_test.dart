import 'package:flutter_test/flutter_test.dart';
import 'package:zerochat/models/proactive_config.dart';

void main() {
  test('legacy hour fields migrate to canonical minutes', () {
    final config = ProactiveConfig.fromJson({
      'enabled': true,
      'min_countdown_hours': 0.5,
      'max_countdown_hours': 4,
    });

    expect(config.minIntervalMinutes, 30);
    expect(config.maxIntervalMinutes, 240);
    expect(config.toJson()['min_interval_minutes'], 30);
    expect(config.toJson().containsKey('min_countdown_hours'), isFalse);
  });

  test('backend payload uses minutes and excludes server-owned trigger time', () {
    final config = ProactiveConfig(
      enabled: true,
      minIntervalMinutes: 6,
      maxIntervalMinutes: 90,
      nextTriggerTime: DateTime(2026, 7, 25, 12),
    );

    final payload = config.toBackendJson();

    expect(payload['min_interval_minutes'], 6);
    expect(payload['max_interval_minutes'], 90);
    expect(payload.containsKey('next_trigger_time'), isFalse);
  });
}

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

  test(
    'backend payload uses minutes and excludes server-owned trigger time',
    () {
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
    },
  );

  test('quiet periods use minutes and read legacy hour fields', () {
    final legacy = ProactiveConfig.fromJson({
      'quiet_hours_start': 22,
      'quiet_hours_end': 7,
    });
    final config = legacy.copyWith(
      quietPeriods: const [
        QuietPeriod(startMinute: 12 * 60 + 30, endMinute: 13 * 60 + 45),
        QuietPeriod(startMinute: 22 * 60, endMinute: 7 * 60),
      ],
    );

    expect(legacy.quietPeriods.single.label, '22:00 - 07:00');
    expect(config.toBackendJson()['quiet_periods'], [
      {'start_minute': 750, 'end_minute': 825},
      {'start_minute': 1320, 'end_minute': 420},
    ]);
  });

  test('quiet periods reject empty, overlapping, and adjacent ranges', () {
    expect(
      validateQuietPeriods(const [QuietPeriod(startMinute: 60, endMinute: 60)]),
      isNotNull,
    );
    expect(
      validateQuietPeriods(const [
        QuietPeriod(startMinute: 60, endMinute: 120),
        QuietPeriod(startMinute: 119, endMinute: 180),
      ]),
      isNotNull,
    );
    expect(
      validateQuietPeriods(const [
        QuietPeriod(startMinute: 60, endMinute: 120),
        QuietPeriod(startMinute: 120, endMinute: 180),
      ]),
      isNotNull,
    );
    expect(
      validateQuietPeriods(const [
        QuietPeriod(startMinute: 60, endMinute: 120),
        QuietPeriod(startMinute: 180, endMinute: 240),
      ]),
      isNull,
    );
  });
}

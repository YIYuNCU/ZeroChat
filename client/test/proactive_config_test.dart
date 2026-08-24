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

  test('daily rules use minutes and read legacy hour fields', () {
    final legacy = ProactiveConfig.fromJson({
      'quiet_hours_start': 22,
      'quiet_hours_end': 7,
    });
    final config = legacy.copyWith(
      quietRules: const [
        QuietRule(startMinute: 12 * 60 + 30, endMinute: 13 * 60 + 45),
        QuietRule(startMinute: 22 * 60, endMinute: 7 * 60),
      ],
    );

    // 旧字段回退为单条每日规则（23:00-07:00 默认）
    final legacyRule = legacy.quietRules.single;
    expect(legacyRule.startMinute, 22 * 60);
    expect(legacyRule.endMinute, 7 * 60);
    expect(legacyRule.repeatType, QuietRule.repeatDaily);
    expect(config.toBackendJson()['quiet_periods'], [
      {
        'start_minute': 750,
        'end_minute': 825,
        'repeat_type': 'daily',
        'weekdays': <int>[],
      },
      {
        'start_minute': 1320,
        'end_minute': 420,
        'repeat_type': 'daily',
        'weekdays': <int>[],
      },
    ]);
  });

  test('rule labels format daily / weekly / once', () {
    const daily = QuietRule(startMinute: 22 * 60, endMinute: 7 * 60);
    expect(daily.label, '每天 22:00 - 07:00');

    const weekly = QuietRule(
      startMinute: 22 * 60,
      endMinute: 8 * 60,
      repeatType: QuietRule.repeatWeekly,
      weekdays: [1, 5],
    );
    expect(weekly.label, '每周周一、周五 22:00 - 08:00');

    const once = QuietRule(
      startMinute: 22 * 60,
      endMinute: 8 * 60,
      repeatType: QuietRule.repeatOnce,
      date: '2026-08-20',
    );
    expect(once.label, '08-20 22:00 - 08:00');
  });

  test('weekly/once rules round-trip json shape', () {
    const weekly = QuietRule(
      startMinute: 23 * 60,
      endMinute: 7 * 60,
      repeatType: QuietRule.repeatWeekly,
      weekdays: [1, 3, 5],
    );
    expect(weekly.toJson(), {
      'start_minute': 1380,
      'end_minute': 420,
      'repeat_type': 'weekly',
      'weekdays': [1, 3, 5],
    });
    expect(QuietRule.fromJson(weekly.toJson()).weekdays, [1, 3, 5]);

    const once = QuietRule(
      startMinute: 22 * 60,
      endMinute: 23 * 60,
      repeatType: QuietRule.repeatOnce,
      date: '2026-08-20',
    );
    final onceJson = once.toJson();
    expect(onceJson['repeat_type'], 'once');
    expect(onceJson['date'], '2026-08-20');
    expect(onceJson.containsKey('weekdays'), isTrue);
    expect(QuietRule.fromJson(onceJson).date, '2026-08-20');
  });

  test('quiet rules reject empty, overlapping, and adjacent ranges', () {
    expect(
      validateQuietRules(const [
        QuietRule(startMinute: 60, endMinute: 60),
      ]),
      isNotNull,
    );
    expect(
      validateQuietRules(const [
        QuietRule(startMinute: 60, endMinute: 120),
        QuietRule(startMinute: 119, endMinute: 180),
      ]),
      isNotNull,
    );
    expect(
      validateQuietRules(const [
        QuietRule(startMinute: 60, endMinute: 120),
        QuietRule(startMinute: 120, endMinute: 180),
      ]),
      isNotNull,
    );
    expect(
      validateQuietRules(const [
        QuietRule(startMinute: 60, endMinute: 120),
        QuietRule(startMinute: 180, endMinute: 240),
      ]),
      isNull,
    );
  });

  test('weekly rules require weekdays and once rules require a date', () {
    expect(
      validateQuietRules(const [
        QuietRule(
          startMinute: 60,
          endMinute: 120,
          repeatType: QuietRule.repeatWeekly,
          weekdays: [],
        ),
      ]),
      isNotNull,
    );
    expect(
      validateQuietRules(const [
        QuietRule(
          startMinute: 60,
          endMinute: 120,
          repeatType: QuietRule.repeatWeekly,
          weekdays: [1, 3],
        ),
      ]),
      isNull,
    );
    expect(
      validateQuietRules(const [
        QuietRule(
          startMinute: 60,
          endMinute: 120,
          repeatType: QuietRule.repeatOnce,
        ),
      ]),
      isNotNull,
    );
    expect(
      validateQuietRules(const [
        QuietRule(
          startMinute: 60,
          endMinute: 120,
          repeatType: QuietRule.repeatOnce,
          date: '2026-08-20',
        ),
      ]),
      isNull,
    );
  });

  test('overnight weekly rule overlap is caught per weekdays', () {
    // 周一 23:00-07:00 与 周二 06:00-08:00（同为周一晚跨夜段的次日部分重叠）
    expect(
      validateQuietRules(const [
        QuietRule(
          startMinute: 23 * 60,
          endMinute: 7 * 60,
          repeatType: QuietRule.repeatWeekly,
          weekdays: [1],
        ),
        QuietRule(
          startMinute: 6 * 60,
          endMinute: 8 * 60,
          repeatType: QuietRule.repeatWeekly,
          weekdays: [2],
        ),
      ]),
      isNotNull,
    );
  });
}
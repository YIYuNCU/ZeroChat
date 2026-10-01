import 'package:flutter_test/flutter_test.dart';
import 'package:zerochat/models/cn_holidays.dart';
import 'package:zerochat/models/proactive_config.dart';
import 'package:zerochat/models/provider_quiet_rule.dart';

void main() {
  group('lunar conversion', () {
    test('spring festival dates', () {
      expect(lunarToSolar(2000, 1, 1), DateTime(2000, 2, 5));
      expect(lunarToSolar(2017, 1, 1), DateTime(2017, 1, 28));
      expect(lunarToSolar(2025, 1, 1), DateTime(2025, 1, 29));
      expect(lunarToSolar(2026, 1, 1), DateTime(2026, 2, 17));
      expect(lunarToSolar(2030, 1, 1), DateTime(2030, 2, 3));
    });

    test('dragon boat and mid-autumn', () {
      expect(lunarToSolar(2025, 5, 5), DateTime(2025, 5, 31));
      expect(lunarToSolar(2026, 5, 5), DateTime(2026, 6, 19));
      expect(lunarToSolar(2025, 8, 15), DateTime(2025, 10, 6));
      expect(lunarToSolar(2026, 8, 15), DateTime(2026, 9, 25));
    });

    test('out of range throws', () {
      expect(() => lunarToSolar(1999, 1, 1), throwsRangeError);
      expect(() => lunarToSolar(2100, 1, 1), throwsRangeError);
    });
  });

  group('holiday rules', () {
    test('2026 holidays', () {
      expect(isCnHoliday(DateTime(2026, 1, 1)), isTrue);
      expect(isCnHoliday(DateTime(2026, 2, 16)), isTrue); // 除夕
      expect(isCnHoliday(DateTime(2026, 2, 23)), isTrue); // 正月初七
      expect(isCnHoliday(DateTime(2026, 2, 24)), isFalse);
      expect(isCnHoliday(DateTime(2026, 4, 5)), isTrue); // 清明
      expect(isCnHoliday(DateTime(2026, 10, 7)), isTrue);
      expect(isCnHoliday(DateTime(2026, 10, 8)), isFalse);
    });

    test('workday excludes weekends, holidays and make-up workdays', () {
      expect(isCnWorkday(DateTime(2026, 10, 9)), isTrue); // 周五
      expect(isCnWorkday(DateTime(2026, 10, 1)), isFalse); // 国庆
      expect(isCnWorkday(DateTime(2026, 10, 10)), isFalse); // 补班周六
    });

    test('years outside lunar data keep solar holidays only', () {
      expect(holidaysInYear(2150).length, 1 + 5 + 7);
    });
  });

  group('workday quiet rules', () {
    const workdayNight = QuietRule(
      startMinute: 23 * 60,
      endMinute: 7 * 60,
      repeatType: QuietRule.repeatWorkday,
    );

    test('overnight workday rule follows start day', () {
      expect(workdayNight.isQuietAt(DateTime(2026, 10, 9, 23, 30)), isTrue);
      expect(workdayNight.isQuietAt(DateTime(2026, 10, 10, 6, 0)), isTrue);
      expect(workdayNight.isQuietAt(DateTime(2026, 10, 10, 23, 30)), isFalse);
      expect(workdayNight.isQuietAt(DateTime(2026, 10, 2, 23, 30)), isFalse);
    });

    test('non-workday rule', () {
      const rule = QuietRule(
        startMinute: 0,
        endMinute: 10 * 60,
        repeatType: QuietRule.repeatNonWorkday,
      );
      expect(rule.isQuietAt(DateTime(2026, 10, 3, 8, 0)), isTrue);
      expect(rule.isQuietAt(DateTime(2026, 10, 9, 8, 0)), isFalse);
      expect(rule.label, '非工作日 00:00 - 10:00');
    });

    test('json round-trip keeps repeat type', () {
      final restored = QuietRule.fromJson(workdayNight.toJson());
      expect(restored.repeatType, QuietRule.repeatWorkday);
      expect(restored.weekdays, isEmpty);
    });

    test('provider rule gating uses workday calendar', () {
      final rule = ProviderQuietRule.fromRuleAndTarget(
        rule: workdayNight,
        apiUrl: 'https://api.deepseek.com',
        model: 'deepseek-v4-flash',
      );
      expect(rule.isQuietAt(DateTime(2026, 10, 9, 23, 30)), isTrue);
      expect(rule.isQuietAt(DateTime(2026, 10, 3, 23, 30)), isFalse);
    });

    test('validation across day kinds', () {
      // 同一时段分别配置工作日和非工作日：不冲突
      expect(
        validateQuietRules(const [
          workdayNight,
          QuietRule(
            startMinute: 23 * 60,
            endMinute: 7 * 60,
            repeatType: QuietRule.repeatNonWorkday,
          ),
        ]),
        isNull,
      );
      // 工作日跨夜段与次日非工作日早间段重叠
      expect(
        validateQuietRules(const [
          workdayNight,
          QuietRule(
            startMinute: 60,
            endMinute: 10 * 60,
            repeatType: QuietRule.repeatNonWorkday,
          ),
        ]),
        isNotNull,
      );
      // 每天规则与工作日规则重叠
      expect(
        validateQuietRules(const [
          QuietRule(startMinute: 12 * 60, endMinute: 13 * 60),
          QuietRule(
            startMinute: 12 * 60 + 30,
            endMinute: 14 * 60,
            repeatType: QuietRule.repeatWorkday,
          ),
        ]),
        isNotNull,
      );
      // 周末每周规则与工作日规则互不影响
      expect(
        validateQuietRules(const [
          QuietRule(
            startMinute: 12 * 60,
            endMinute: 13 * 60,
            repeatType: QuietRule.repeatWeekly,
            weekdays: [6, 7],
          ),
          QuietRule(
            startMinute: 12 * 60,
            endMinute: 13 * 60,
            repeatType: QuietRule.repeatWorkday,
          ),
        ]),
        isNull,
      );
    });
  });
}

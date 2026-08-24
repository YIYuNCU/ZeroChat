import 'package:flutter_test/flutter_test.dart';
import 'package:zerochat/models/provider_quiet_rule.dart';
import 'package:zerochat/models/proactive_config.dart';

void main() {
  ProviderQuietRule rule({
    String apiUrl = 'https://api.deepseek.com',
    String model = 'deepseek-v4-flash',
    bool enabled = true,
    int startMinute = 22 * 60,
    int endMinute = 7 * 60,
    String repeatType = QuietRule.repeatDaily,
    List<int> weekdays = const [],
    String? date,
  }) {
    return ProviderQuietRule(
      enabled: enabled,
      apiUrl: apiUrl,
      model: model,
      startMinute: startMinute,
      endMinute: endMinute,
      repeatType: repeatType,
      weekdays: weekdays,
      date: date,
    );
  }

  test('target matching is case-insensitive and rejects trailing slash', () {
    final target = rule(apiUrl: 'https://API.DEEPSEEK.COM', model: 'DEEPSEEK');
    expect(ProviderQuietRule.matches(target, 'https://api.deepseek.com', 'deepseek'), isTrue);
    expect(ProviderQuietRule.matches(target, 'https://api.deepseek.com/', 'deepseek'), isFalse);
    expect(ProviderQuietRule.matches(target, 'https://api.other.com', 'deepseek'), isFalse);
  });

  test('daily overnight rule covers start day and next-day end segment', () {
    final quiet = rule();
    // 周一 23:30（起始日）
    expect(quiet.isQuietAt(DateTime(2026, 8, 17, 23, 30)), isTrue);
    // 周二 06:00（结束日）
    expect(quiet.isQuietAt(DateTime(2026, 8, 18, 6, 0)), isTrue);
    // 白天
    expect(quiet.isQuietAt(DateTime(2026, 8, 18, 10, 0)), isFalse);
  });

  test('weekly rule applies only on selected weekdays', () {
    final quiet = rule(repeatType: QuietRule.repeatWeekly, weekdays: [5, 6, 7]);
    // 2026-08-21 周五
    expect(quiet.isQuietAt(DateTime(2026, 8, 21, 23, 30)), isTrue);
    // 2026-08-18 周二
    expect(quiet.isQuietAt(DateTime(2026, 8, 18, 23, 30)), isFalse);
  });

  test('once rule applies only on its date', () {
    final quiet = rule(
      repeatType: QuietRule.repeatOnce,
      startMinute: 22 * 60,
      endMinute: 23 * 60,
      date: '2026-08-20',
    );
    expect(quiet.isQuietAt(DateTime(2026, 8, 20, 22, 30)), isTrue);
    expect(quiet.isQuietAt(DateTime(2026, 8, 21, 22, 30)), isFalse);
  });

  test('disabled rules never gate', () {
    final quiet = rule(enabled: false);
    expect(quiet.isQuietAt(DateTime(2026, 8, 17, 23, 30)), isFalse);
  });

  test('isProviderQuietNow uses role config with global fallback', () {
    final rules = [rule()];
    // 角色级匹配
    expect(
      ProviderQuietRule.isProviderQuietNow(
        rules: rules,
        roleApiUrl: 'https://api.deepseek.com',
        roleModel: 'deepseek-v4-flash',
        globalApiUrl: '',
        globalModel: '',
        at: DateTime(2026, 8, 17, 23, 30),
      ),
      isTrue,
    );
    // 角色级未配置 -> 回退全局
    expect(
      ProviderQuietRule.isProviderQuietNow(
        rules: rules,
        roleApiUrl: null,
        roleModel: null,
        globalApiUrl: 'https://api.deepseek.com',
        globalModel: 'deepseek-v4-flash',
        at: DateTime(2026, 8, 18, 6, 0),
      ),
      isTrue,
    );
    // 不匹配
    expect(
      ProviderQuietRule.isProviderQuietNow(
        rules: rules,
        roleApiUrl: 'https://api.other.com',
        roleModel: 'x',
        globalApiUrl: '',
        globalModel: '',
        at: DateTime(2026, 8, 17, 23, 30),
      ),
      isFalse,
    );
    // 空规则
    expect(
      ProviderQuietRule.isProviderQuietNow(
        rules: const [],
        roleApiUrl: 'https://api.deepseek.com',
        roleModel: 'deepseek-v4-flash',
        globalApiUrl: '',
        globalModel: '',
        at: DateTime(2026, 8, 17, 23, 30),
      ),
      isFalse,
    );
    // 禁用规则跳过
    expect(
      ProviderQuietRule.isProviderQuietNow(
        rules: [rule(enabled: false)],
        roleApiUrl: 'https://api.deepseek.com',
        roleModel: 'deepseek-v4-flash',
        globalApiUrl: '',
        globalModel: '',
        at: DateTime(2026, 8, 17, 23, 30),
      ),
      isFalse,
    );
  });

  test('json round-trip preserves provider target and rule fields', () {
    final quiet = rule(
      repeatType: QuietRule.repeatWeekly,
      weekdays: [1, 3],
    );
    final restored = ProviderQuietRule.fromJson(quiet.toJson());
    expect(restored.apiUrl, quiet.apiUrl);
    expect(restored.model, quiet.model);
    expect(restored.weekdays, [1, 3]);
    expect(restored.enabled, isTrue);
  });
}
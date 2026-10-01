import 'proactive_config.dart';

/// 供应商+模型级安静规则。
/// 扁平 JSON 与服务端 `settings.json` 的 `quiet_rules` 条目一致：
/// { enabled, api_url, model, start_minute, end_minute, repeat_type, weekdays, date }
/// repeat_type 取值见 [QuietRule.repeatTypes]（含 workday / non_workday）。
class ProviderQuietRule {
  final bool enabled;
  final String apiUrl;
  final String model;
  final int startMinute;
  final int endMinute;
  final String repeatType;
  final List<int> weekdays;
  final String? date;

  const ProviderQuietRule({
    this.enabled = true,
    required this.apiUrl,
    required this.model,
    required this.startMinute,
    required this.endMinute,
    this.repeatType = QuietRule.repeatDaily,
    this.weekdays = const [],
    this.date,
  });

  factory ProviderQuietRule.fromJson(Map<String, dynamic> json) {
    final rule = QuietRule.fromJson(json);
    return ProviderQuietRule(
      enabled: json['enabled'] is bool ? json['enabled'] as bool : true,
      apiUrl: json['api_url']?.toString().trim() ?? '',
      model: json['model']?.toString().trim() ?? '',
      startMinute: rule.startMinute,
      endMinute: rule.endMinute,
      repeatType: rule.repeatType,
      weekdays: rule.weekdays,
      date: rule.date,
    );
  }

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'api_url': apiUrl,
    'model': model,
    'start_minute': startMinute,
    'end_minute': endMinute,
    'repeat_type': repeatType,
    'weekdays': repeatType == QuietRule.repeatWeekly
        ? weekdays
        : const <int>[],
    if (repeatType == QuietRule.repeatOnce) 'date': date,
  };

  /// 转为角色级规则（供共享编辑器使用）。
  QuietRule toRule() => QuietRule(
    startMinute: startMinute,
    endMinute: endMinute,
    repeatType: repeatType,
    weekdays: weekdays,
    date: date,
  );

  /// 由规则 + 目标组合构造。
  factory ProviderQuietRule.fromRuleAndTarget({
    required QuietRule rule,
    required String apiUrl,
    required String model,
    bool enabled = true,
  }) {
    return ProviderQuietRule(
      enabled: enabled,
      apiUrl: apiUrl,
      model: model,
      startMinute: rule.startMinute,
      endMinute: rule.endMinute,
      repeatType: rule.repeatType,
      weekdays: rule.weekdays,
      date: rule.date,
    );
  }

  ProviderQuietRule copyWith({
    bool? enabled,
    String? apiUrl,
    String? model,
    QuietRule? rule,
  }) {
    final next = rule ?? toRule();
    return ProviderQuietRule(
      enabled: enabled ?? this.enabled,
      apiUrl: apiUrl ?? this.apiUrl,
      model: model ?? this.model,
      startMinute: next.startMinute,
      endMinute: next.endMinute,
      repeatType: next.repeatType,
      weekdays: next.weekdays,
      date: next.date,
    );
  }

  /// 展示用标签（如“每天 23:00 - 07:00”）。
  String get label => toRule().label;

  /// 结构校验（时间范围 / repeat 专属字段）。
  String? get validationMessage => validateQuietRules([toRule()]);

  /// 是否命中指定目标（大小写不敏感、去空白）。
  static bool matches(ProviderQuietRule rule, String apiUrl, String model) {
    return rule.apiUrl.trim().toLowerCase() == apiUrl.trim().toLowerCase() &&
        rule.model.trim().toLowerCase() == model.trim().toLowerCase();
  }

  /// 当前时刻是否处于该规则的静默区间（跨夜规则含次日结束段）。
  bool isQuietAt(DateTime at) => enabled && toRule().isQuietAt(at);

  /// 从一组规则判断当前是否静默（供群聊 AI↔AI 等客户端自主行为 gating）。
  /// [roleApiUrl]/[roleModel] 为角色级 AI 配置；缺省回退到全局配置。
  static bool isProviderQuietNow({
    required List<ProviderQuietRule> rules,
    required String? roleApiUrl,
    required String? roleModel,
    required String globalApiUrl,
    required String globalModel,
    DateTime? at,
  }) {
    if (rules.isEmpty) return false;
    final apiUrl = (roleApiUrl != null && roleApiUrl.trim().isNotEmpty)
        ? roleApiUrl.trim()
        : globalApiUrl.trim();
    final model = (roleModel != null && roleModel.trim().isNotEmpty)
        ? roleModel.trim()
        : globalModel.trim();
    if (apiUrl.isEmpty || model.isEmpty) return false;
    final now = at ?? DateTime.now();
    for (final rule in rules) {
      if (!rule.enabled) continue;
      if (!matches(rule, apiUrl, model)) continue;
      if (rule.isQuietAt(now)) return true;
    }
    return false;
  }
}
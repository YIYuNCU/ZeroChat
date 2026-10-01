/// 中国节假日规则（安静时间"工作日 / 非工作日"规则使用）。
///
/// 判定口径与服务端 server/core/cn_holidays.py 保持一致：
/// - 工作日 = 周一至周五，且不在节假日放假区间内
/// - 非工作日 = 周六、周日，以及节假日放假区间内的日期
/// - 调休补班日（如周六上班）不视为工作日，仍按非工作日处理
///
/// 节假日按固定规则推算，不依赖每年的放假通知：
/// - 公历节日：每年公历日期固定（清明按节气推算，落在 4 月 4-6 日）
/// - 农历节日：每年农历日期固定，换算为当年的公历日期
///
/// 修改节日定义或农历数据时必须同步服务端（server/tests/test_cn_holidays.py 会校验）。
/// 农历数据覆盖 2000-2099 年；超出范围时只计算公历固定节日。
library;

/// 公历节日：(名称, 月, 日, 放假天数)
const List<(String, int, int, int)> kSolarHolidays = [
  ('元旦', 1, 1, 1),
  ('劳动节', 5, 1, 5),
  ('国庆节', 10, 1, 7),
];

/// 节气节日：(名称, 放假天数)。清明日期按节气推算。
const List<(String, int)> kSolarTermHolidays = [('清明节', 1)];

/// 农历节日：(名称, 农历月, 农历日, 起始偏移天数, 放假天数)
/// 春节以正月初一为基准、偏移 -1 天从除夕开始，放到正月初七。
const List<(String, int, int, int, int)> kLunarHolidays = [
  ('春节', 1, 1, -1, 8),
  ('端午节', 5, 5, 0, 1),
  ('中秋节', 8, 15, 0, 1),
];

/// 农历 2000-2099 年数据，每年一项：
/// bit 0-3：闰月月份（0 = 无闰月）；bit 4-15：正月..十二月大小（bit 15 = 正月，1 = 30 天）；
/// bit 16：闰月大小（1 = 30 天）。
/// 2057 年八、九月大小各数据源有分歧，不影响春节、端午、中秋的日期。
const int kLunarBaseYear = 2000;
const List<int> kLunarYearInfo = [
  0x0C960, 0x0D954, 0x0D4A0, 0x0DA50, 0x07552, 0x056A0, 0x0ABB7, 0x025D0, 0x092D0, 0x0CAB5, // 2000-2009
  0x0A950, 0x0B4A0, 0x0BAA4, 0x0AD50, 0x055D9, 0x04BA0, 0x0A5B0, 0x15176, 0x052B0, 0x0A930, // 2010-2019
  0x07954, 0x06AA0, 0x0AD50, 0x05B52, 0x04B60, 0x0A6E6, 0x0A4E0, 0x0D260, 0x0EA65, 0x0D530, // 2020-2029
  0x05AA0, 0x076A3, 0x096D0, 0x04AFB, 0x04AD0, 0x0A4D0, 0x1D0B6, 0x0D250, 0x0D520, 0x0DD45, // 2030-2039
  0x0B5A0, 0x056D0, 0x055B2, 0x049B0, 0x0A577, 0x0A4B0, 0x0AA50, 0x1B255, 0x06D20, 0x0ADA0, // 2040-2049
  0x14B63, 0x09370, 0x049F8, 0x04970, 0x064B0, 0x168A6, 0x0EA50, 0x06B20, 0x1A6C4, 0x0AAE0, // 2050-2059
  0x092E0, 0x0D2E3, 0x0C960, 0x0D557, 0x0D4A0, 0x0DA50, 0x05D55, 0x056A0, 0x0A6D0, 0x055D4, // 2060-2069
  0x052D0, 0x0A9B8, 0x0A950, 0x0B4A0, 0x0B6A6, 0x0AD50, 0x055A0, 0x0ABA4, 0x0A5B0, 0x052B0, // 2070-2079
  0x0B273, 0x06930, 0x07337, 0x06AA0, 0x0AD50, 0x14B55, 0x04B60, 0x0A570, 0x054E4, 0x0D160, // 2080-2089
  0x0E968, 0x0D520, 0x0DAA0, 0x16AA6, 0x056D0, 0x04AE0, 0x0A9D4, 0x0A2D0, 0x0D150, 0x0F252, // 2090-2099
];

/// 农历 2000 年正月初一的公历日期。
final DateTime _lunarBaseDate = DateTime(2000, 2, 5);

int get kLunarLastYear => kLunarBaseYear + kLunarYearInfo.length - 1;

// ========== 农历换算 ==========

int _leapMonth(int info) => info & 0xF;

int _leapMonthDays(int info) {
  if (_leapMonth(info) == 0) return 0;
  return (info & 0x10000) != 0 ? 30 : 29;
}

int _monthDays(int info, int month) => (info & (0x10000 >> month)) != 0 ? 30 : 29;

int _lunarYearDays(int info) {
  var total = _leapMonthDays(info);
  for (var month = 1; month <= 12; month++) {
    total += _monthDays(info, month);
  }
  return total;
}

/// 日历日加减（不用 Duration，避免夏令时等时长偏差）。
DateTime _addDays(DateTime day, int days) =>
    DateTime(day.year, day.month, day.day + days);

/// 农历（非闰月）年月日 -> 公历日期。超出数据范围抛 [RangeError]。
DateTime lunarToSolar(int year, int month, int day) {
  if (year < kLunarBaseYear || year > kLunarLastYear) {
    throw RangeError('lunar year $year out of range');
  }
  final info = kLunarYearInfo[year - kLunarBaseYear];
  if (month < 1 || month > 12 || day < 1 || day > _monthDays(info, month)) {
    throw RangeError('invalid lunar date $year-$month-$day');
  }
  var offset = 0;
  for (var y = kLunarBaseYear; y < year; y++) {
    offset += _lunarYearDays(kLunarYearInfo[y - kLunarBaseYear]);
  }
  for (var m = 1; m < month; m++) {
    offset += _monthDays(info, m);
  }
  final leap = _leapMonth(info);
  if (leap != 0 && leap < month) offset += _leapMonthDays(info);
  return _addDays(_lunarBaseDate, offset + day - 1);
}

// ========== 节日推算 ==========

/// 清明节在 4 月的日期（21 世纪节气通式，适用 2000-2099）。
int qingmingDay(int year) {
  final y = year % 100;
  return (y * 0.2422 + 4.81).floor() - y ~/ 4;
}

final Map<int, Set<String>> _yearCache = {};

/// 推算某公历年内的全部节假日放假日期（YYYY-MM-DD）。
Set<String> holidaysInYear(int year) {
  return _yearCache.putIfAbsent(year, () {
    final days = <String>{};
    void addSpan(DateTime start, int length) {
      for (var i = 0; i < length; i++) {
        final day = _addDays(start, i);
        if (day.year == year) days.add(_dateKey(day)); // 跨年部分由所在年份负责
      }
    }

    for (final (_, month, day, length) in kSolarHolidays) {
      addSpan(DateTime(year, month, day), length);
    }
    if (year >= kLunarBaseYear && year <= kLunarLastYear) {
      for (final (_, length) in kSolarTermHolidays) {
        addSpan(DateTime(year, 4, qingmingDay(year)), length);
      }
      for (final (_, month, day, offset, length) in kLunarHolidays) {
        addSpan(_addDays(lunarToSolar(year, month, day), offset), length);
      }
    }
    return days;
  });
}

String _dateKey(DateTime day) {
  final month = day.month.toString().padLeft(2, '0');
  final dayOfMonth = day.day.toString().padLeft(2, '0');
  return '${day.year.toString().padLeft(4, '0')}-$month-$dayOfMonth';
}

/// 是否为节假日放假日期。
bool isCnHoliday(DateTime day) => holidaysInYear(day.year).contains(_dateKey(day));

/// 是否为工作日：周一至周五且非节假日（调休补班日不算工作日）。
bool isCnWorkday(DateTime day) =>
    day.weekday <= DateTime.friday && !isCnHoliday(day);

"""
中国节假日规则（安静时间"工作日 / 非工作日"规则使用）

判定口径：
- 工作日 = 周一至周五，且不在节假日放假区间内
- 非工作日 = 周六、周日，以及节假日放假区间内的日期
- 调休补班日（如周六上班）不视为工作日，仍按非工作日处理

节假日按固定规则推算，不依赖每年的放假通知：
- 公历节日：每年公历日期固定（清明按节气推算，落在 4 月 4-6 日）
- 农历节日：每年农历日期固定，换算为当年的公历日期

客户端 client/lib/models/cn_holidays.dart 必须与本文件保持一致
（server/tests/test_cn_holidays.py 会校验两端的节日定义和农历数据）。
农历数据覆盖 2000-2099 年；超出范围时只计算公历固定节日。
"""
from datetime import date, datetime, timedelta
from functools import lru_cache
from typing import FrozenSet, Tuple, Union

# 公历节日：(名称, 月, 日, 放假天数)
SOLAR_HOLIDAYS: Tuple[Tuple[str, int, int, int], ...] = (
    ("元旦", 1, 1, 1),
    ("劳动节", 5, 1, 5),
    ("国庆节", 10, 1, 7),
)

# 节气节日：(名称, 放假天数)。清明日期按节气推算。
SOLAR_TERM_HOLIDAYS: Tuple[Tuple[str, int], ...] = (("清明节", 1),)

# 农历节日：(名称, 农历月, 农历日, 起始偏移天数, 放假天数)
# 春节以正月初一为基准、偏移 -1 天从除夕开始，放到正月初七。
LUNAR_HOLIDAYS: Tuple[Tuple[str, int, int, int, int], ...] = (
    ("春节", 1, 1, -1, 8),
    ("端午节", 5, 5, 0, 1),
    ("中秋节", 8, 15, 0, 1),
)

# 农历 2000-2099 年数据，每年一项：
# bit 0-3：闰月月份（0 = 无闰月）；bit 4-15：正月..十二月大小（bit 15 = 正月，1 = 30 天）；
# bit 16：闰月大小（1 = 30 天）。
# 已与 lunardate 0.2.2 逐月交叉校验；唯一差异是 2057 年八、九月大小互换（各数据源本就有分歧），
# 不影响春节、端午、中秋的日期。
LUNAR_BASE_YEAR = 2000
LUNAR_BASE_DATE = date(2000, 2, 5)  # 农历 2000 年正月初一
LUNAR_YEAR_INFO: Tuple[int, ...] = (
    0x0C960, 0x0D954, 0x0D4A0, 0x0DA50, 0x07552, 0x056A0, 0x0ABB7, 0x025D0, 0x092D0, 0x0CAB5,  # 2000-2009
    0x0A950, 0x0B4A0, 0x0BAA4, 0x0AD50, 0x055D9, 0x04BA0, 0x0A5B0, 0x15176, 0x052B0, 0x0A930,  # 2010-2019
    0x07954, 0x06AA0, 0x0AD50, 0x05B52, 0x04B60, 0x0A6E6, 0x0A4E0, 0x0D260, 0x0EA65, 0x0D530,  # 2020-2029
    0x05AA0, 0x076A3, 0x096D0, 0x04AFB, 0x04AD0, 0x0A4D0, 0x1D0B6, 0x0D250, 0x0D520, 0x0DD45,  # 2030-2039
    0x0B5A0, 0x056D0, 0x055B2, 0x049B0, 0x0A577, 0x0A4B0, 0x0AA50, 0x1B255, 0x06D20, 0x0ADA0,  # 2040-2049
    0x14B63, 0x09370, 0x049F8, 0x04970, 0x064B0, 0x168A6, 0x0EA50, 0x06B20, 0x1A6C4, 0x0AAE0,  # 2050-2059
    0x092E0, 0x0D2E3, 0x0C960, 0x0D557, 0x0D4A0, 0x0DA50, 0x05D55, 0x056A0, 0x0A6D0, 0x055D4,  # 2060-2069
    0x052D0, 0x0A9B8, 0x0A950, 0x0B4A0, 0x0B6A6, 0x0AD50, 0x055A0, 0x0ABA4, 0x0A5B0, 0x052B0,  # 2070-2079
    0x0B273, 0x06930, 0x07337, 0x06AA0, 0x0AD50, 0x14B55, 0x04B60, 0x0A570, 0x054E4, 0x0D160,  # 2080-2089
    0x0E968, 0x0D520, 0x0DAA0, 0x16AA6, 0x056D0, 0x04AE0, 0x0A9D4, 0x0A2D0, 0x0D150, 0x0F252,  # 2090-2099
)
LUNAR_LAST_YEAR = LUNAR_BASE_YEAR + len(LUNAR_YEAR_INFO) - 1


# ========== 农历换算 ==========

def _leap_month(info: int) -> int:
    return info & 0xF


def _leap_month_days(info: int) -> int:
    if not _leap_month(info):
        return 0
    return 30 if info & 0x10000 else 29


def _month_days(info: int, month: int) -> int:
    return 30 if info & (0x10000 >> month) else 29


def _lunar_year_days(info: int) -> int:
    return sum(_month_days(info, month) for month in range(1, 13)) + _leap_month_days(info)


def lunar_to_solar(year: int, month: int, day: int) -> date:
    """农历（非闰月）年月日 -> 公历日期。超出数据范围抛 ValueError。"""
    if not LUNAR_BASE_YEAR <= year <= LUNAR_LAST_YEAR:
        raise ValueError(f"lunar year {year} out of range")
    info = LUNAR_YEAR_INFO[year - LUNAR_BASE_YEAR]
    if not 1 <= month <= 12 or not 1 <= day <= _month_days(info, month):
        raise ValueError(f"invalid lunar date {year}-{month}-{day}")

    offset = sum(
        _lunar_year_days(LUNAR_YEAR_INFO[y - LUNAR_BASE_YEAR])
        for y in range(LUNAR_BASE_YEAR, year)
    )
    offset += sum(_month_days(info, m) for m in range(1, month))
    leap = _leap_month(info)
    if leap and leap < month:
        offset += _leap_month_days(info)
    return LUNAR_BASE_DATE + timedelta(days=offset + day - 1)


# ========== 节日推算 ==========

def qingming_day(year: int) -> int:
    """清明节在 4 月的日期（21 世纪节气通式，适用 2000-2099）。"""
    y = year % 100
    return int(y * 0.2422 + 4.81) - y // 4


def _add_span(days: set, start: date, length: int) -> None:
    for i in range(length):
        days.add(start + timedelta(days=i))


@lru_cache(maxsize=16)
def holidays_in_year(year: int) -> FrozenSet[date]:
    """推算某公历年内的全部节假日放假日期。"""
    days: set = set()
    for _, month, day, length in SOLAR_HOLIDAYS:
        _add_span(days, date(year, month, day), length)

    if LUNAR_BASE_YEAR <= year <= LUNAR_LAST_YEAR:
        for _, length in SOLAR_TERM_HOLIDAYS:
            _add_span(days, date(year, 4, qingming_day(year)), length)
        for _, month, day, offset, length in LUNAR_HOLIDAYS:
            start = lunar_to_solar(year, month, day) + timedelta(days=offset)
            _add_span(days, start, length)

    # 只保留落在本年的日期（跨年部分由所在年份负责）
    return frozenset(d for d in days if d.year == year)


def _as_date(value: Union[date, datetime]) -> date:
    return value.date() if isinstance(value, datetime) else value


def is_cn_holiday(value: Union[date, datetime]) -> bool:
    """是否为节假日放假日期。"""
    day = _as_date(value)
    return day in holidays_in_year(day.year)


def is_cn_workday(value: Union[date, datetime]) -> bool:
    """是否为工作日：周一至周五且非节假日（调休补班日不算工作日）。"""
    day = _as_date(value)
    return day.weekday() < 5 and not is_cn_holiday(day)

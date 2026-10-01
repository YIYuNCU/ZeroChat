import ast
import re
import unittest
from datetime import date, datetime
from pathlib import Path

from pydantic import ValidationError

from core import cn_holidays
from core.cn_holidays import (
    holidays_in_year,
    is_cn_holiday,
    is_cn_workday,
    lunar_to_solar,
    qingming_day,
)
from core.quiet_rules import QuietRule, normalize_quiet_rule_dict, validate_quiet_rules
from routers.roles import ProactiveConfig
from services import scheduler_service

DART_FILE = (
    Path(__file__).resolve().parents[2] / "client" / "lib" / "models" / "cn_holidays.dart"
)

# 公开的春节（正月初一）公历日期
SPRING_FESTIVALS = {
    2000: date(2000, 2, 5), 2001: date(2001, 1, 24), 2002: date(2002, 2, 12),
    2003: date(2003, 2, 1), 2004: date(2004, 1, 22), 2005: date(2005, 2, 9),
    2006: date(2006, 1, 29), 2007: date(2007, 2, 18), 2008: date(2008, 2, 7),
    2009: date(2009, 1, 26), 2010: date(2010, 2, 14), 2011: date(2011, 2, 3),
    2012: date(2012, 1, 23), 2013: date(2013, 2, 10), 2014: date(2014, 1, 31),
    2015: date(2015, 2, 19), 2016: date(2016, 2, 8), 2017: date(2017, 1, 28),
    2018: date(2018, 2, 16), 2019: date(2019, 2, 5), 2020: date(2020, 1, 25),
    2021: date(2021, 2, 12), 2022: date(2022, 2, 1), 2023: date(2023, 1, 22),
    2024: date(2024, 2, 10), 2025: date(2025, 1, 29), 2026: date(2026, 2, 17),
    2027: date(2027, 2, 6), 2028: date(2028, 1, 26), 2029: date(2029, 2, 13),
    2030: date(2030, 2, 3),
}


class LunarConversionTests(unittest.TestCase):
    def test_spring_festival_dates(self):
        for year, expected in SPRING_FESTIVALS.items():
            self.assertEqual(lunar_to_solar(year, 1, 1), expected, year)

    def test_dragon_boat_and_mid_autumn(self):
        self.assertEqual(lunar_to_solar(2024, 5, 5), date(2024, 6, 10))
        self.assertEqual(lunar_to_solar(2025, 5, 5), date(2025, 5, 31))
        self.assertEqual(lunar_to_solar(2026, 5, 5), date(2026, 6, 19))
        self.assertEqual(lunar_to_solar(2024, 8, 15), date(2024, 9, 17))
        self.assertEqual(lunar_to_solar(2025, 8, 15), date(2025, 10, 6))
        self.assertEqual(lunar_to_solar(2026, 8, 15), date(2026, 9, 25))

    def test_every_year_new_year_in_valid_window(self):
        # 正月初一必在 1 月 21 日至 2 月 20 日之间，可发现表项错位
        for year in range(cn_holidays.LUNAR_BASE_YEAR, cn_holidays.LUNAR_LAST_YEAR + 1):
            new_year = lunar_to_solar(year, 1, 1)
            self.assertTrue(date(year, 1, 21) <= new_year <= date(year, 2, 20), year)

    def test_out_of_range_raises(self):
        with self.assertRaises(ValueError):
            lunar_to_solar(1999, 1, 1)
        with self.assertRaises(ValueError):
            lunar_to_solar(2100, 1, 1)

    def test_qingming(self):
        self.assertEqual(qingming_day(2024), 4)
        self.assertEqual(qingming_day(2025), 4)
        self.assertEqual(qingming_day(2026), 5)


class HolidayRuleTests(unittest.TestCase):
    def test_2026_holidays(self):
        days = holidays_in_year(2026)
        self.assertIn(date(2026, 1, 1), days)  # 元旦
        self.assertIn(date(2026, 2, 16), days)  # 除夕
        self.assertIn(date(2026, 2, 23), days)  # 正月初七
        self.assertNotIn(date(2026, 2, 24), days)  # 正月初八
        self.assertIn(date(2026, 4, 5), days)  # 清明
        self.assertIn(date(2026, 5, 5), days)  # 劳动节最后一天
        self.assertIn(date(2026, 6, 19), days)  # 端午
        self.assertIn(date(2026, 9, 25), days)  # 中秋
        self.assertIn(date(2026, 10, 7), days)  # 国庆最后一天
        self.assertNotIn(date(2026, 10, 8), days)

    def test_spring_festival_starts_on_lunar_new_years_eve(self):
        # 2025 年腊月为小月，除夕是腊月二十九（1 月 28 日）
        self.assertIn(date(2025, 1, 28), holidays_in_year(2025))
        self.assertNotIn(date(2025, 1, 27), holidays_in_year(2025))

    def test_workday_rules(self):
        self.assertTrue(is_cn_workday(date(2026, 10, 9)))  # 周五
        self.assertFalse(is_cn_workday(date(2026, 10, 1)))  # 国庆（周四）
        self.assertFalse(is_cn_workday(date(2026, 10, 10)))  # 调休补班的周六也算非工作日
        self.assertFalse(is_cn_workday(datetime(2026, 2, 18, 9, 0)))  # 春节
        self.assertTrue(is_cn_holiday(date(2026, 6, 19)))

    def test_out_of_lunar_range_keeps_solar_holidays(self):
        days = holidays_in_year(2150)
        self.assertIn(date(2150, 1, 1), days)
        self.assertIn(date(2150, 10, 1), days)
        self.assertEqual(len(days), 1 + 5 + 7)


class DartParityTests(unittest.TestCase):
    """客户端 cn_holidays.dart 必须与服务端定义一致。"""

    @classmethod
    def setUpClass(cls):
        cls.source = DART_FILE.read_text(encoding="utf-8")

    def _const_list(self, name):
        match = re.search(rf"{name}\s*=\s*\[(.*?)\];", self.source, re.S)
        self.assertIsNotNone(match, name)
        body = re.sub(r"//[^\n]*", "", match.group(1))
        return ast.literal_eval(f"[{body}]")

    def test_lunar_table_matches(self):
        self.assertEqual(tuple(self._const_list("kLunarYearInfo")), cn_holidays.LUNAR_YEAR_INFO)
        self.assertIn(f"kLunarBaseYear = {cn_holidays.LUNAR_BASE_YEAR};", self.source)

    def test_holiday_definitions_match(self):
        self.assertEqual(tuple(self._const_list("kSolarHolidays")), cn_holidays.SOLAR_HOLIDAYS)
        self.assertEqual(
            tuple(self._const_list("kSolarTermHolidays")), cn_holidays.SOLAR_TERM_HOLIDAYS
        )
        self.assertEqual(tuple(self._const_list("kLunarHolidays")), cn_holidays.LUNAR_HOLIDAYS)


class WorkdayQuietRuleTests(unittest.TestCase):
    def _rule(self, repeat_type, start=23 * 60, end=7 * 60):
        return {
            "start_minute": start,
            "end_minute": end,
            "repeat_type": repeat_type,
            "weekdays": [],
            "date": None,
        }

    def test_workday_rule_applies_by_start_day(self):
        rules = [self._rule("workday")]
        # 2026-10-09 周五（工作日）23:30 -> 次日 07:00
        self.assertEqual(
            scheduler_service.next_allowed_time(datetime(2026, 10, 9, 23, 30), rules),
            datetime(2026, 10, 10, 7),
        )
        # 2026-10-10 补班周六算非工作日 -> 不延迟
        self.assertEqual(
            scheduler_service.next_allowed_time(datetime(2026, 10, 10, 23, 30), rules),
            datetime(2026, 10, 10, 23, 30),
        )
        # 国庆假期内不生效
        self.assertEqual(
            scheduler_service.next_allowed_time(datetime(2026, 10, 2, 23, 30), rules),
            datetime(2026, 10, 2, 23, 30),
        )

    def test_non_workday_rule(self):
        rules = [self._rule("non_workday", start=0, end=10 * 60)]
        self.assertEqual(
            scheduler_service.next_allowed_time(datetime(2026, 10, 3, 8, 0), rules),
            datetime(2026, 10, 3, 10),
        )
        self.assertEqual(
            scheduler_service.next_allowed_time(datetime(2026, 10, 9, 8, 0), rules),
            datetime(2026, 10, 9, 8, 0),
        )

    def test_normalize_keeps_workday_types(self):
        self.assertEqual(normalize_quiet_rule_dict(self._rule("workday"))["repeat_type"], "workday")
        self.assertEqual(
            normalize_quiet_rule_dict(self._rule("non_workday"))["repeat_type"], "non_workday"
        )

    def test_workday_and_non_workday_same_time_allowed(self):
        validate_quiet_rules(
            [QuietRule(**self._rule("workday")), QuietRule(**self._rule("non_workday"))]
        )
        ProactiveConfig(
            quiet_periods=[
                self._rule("workday", start=23 * 60, end=7 * 60),
                self._rule("non_workday", start=8 * 60, end=10 * 60),
            ]
        )

    def test_overlap_rejected(self):
        # 工作日跨夜段 [0, 7:00) 与次日非工作日 [1:00, 10:00) 在周六重叠
        with self.assertRaises(ValidationError):
            ProactiveConfig(
                quiet_periods=[
                    self._rule("workday", start=23 * 60, end=7 * 60),
                    self._rule("non_workday", start=60, end=10 * 60),
                ]
            )
        with self.assertRaises(ValidationError):
            ProactiveConfig(
                quiet_periods=[
                    self._rule("daily", start=12 * 60, end=13 * 60),
                    self._rule("workday", start=12 * 60 + 30, end=14 * 60),
                ]
            )
        with self.assertRaises(ValidationError):
            ProactiveConfig(
                quiet_periods=[
                    {**self._rule("weekly", start=12 * 60, end=13 * 60), "weekdays": [6]},
                    self._rule("non_workday", start=12 * 60 + 30, end=14 * 60),
                ]
            )

    def test_weekly_weekend_and_workday_do_not_conflict(self):
        ProactiveConfig(
            quiet_periods=[
                {**self._rule("weekly", start=12 * 60, end=13 * 60), "weekdays": [6, 7]},
                self._rule("workday", start=12 * 60, end=13 * 60),
            ]
        )


if __name__ == "__main__":
    unittest.main()

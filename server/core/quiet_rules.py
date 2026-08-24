"""
安静时间规则（共享模块）

安静时间从"每天重复的时间段"升级为带循环类型的规则：
- repeat_type: "daily"（每天）| "weekly"（每周自选星期）| "once"（指定日期一次）
- weekdays: ISO 星期 1=周一 .. 7=周日（weekly 专属）
- date: YYYY-MM-DD（once 专属）

本模块同时提供：
1. pydantic 校验模型（角色级 QuietRule / 供应商级 ProviderQuietRule）
2. 宽容解析（调度器读取磁盘/设置时使用，坏条目直接丢弃）
3. 纯时间逻辑（包含判定 / 区间结束 / 下个可用时间），供调度器复用
"""
import logging
from datetime import date as date_cls, datetime, timedelta
from typing import Any, Dict, List, Optional

from pydantic import BaseModel, Field, model_validator

logger = logging.getLogger(__name__)

VALID_REPEAT_TYPES = {"daily", "weekly", "once"}
ISO_WEEKDAYS = list(range(1, 8))  # 1=周一 .. 7=周日


# ========== 结构校验（pydantic） ==========

class QuietRule(BaseModel):
    """一条安静时间规则（角色级，存于 proactive_config.quiet_periods）。"""

    start_minute: int = Field(ge=0, lt=24 * 60)
    end_minute: int = Field(ge=0, lt=24 * 60)
    repeat_type: str = "daily"
    weekdays: Optional[List[int]] = None
    date: Optional[str] = None

    @model_validator(mode="after")
    def validate_rule(self):
        if self.start_minute == self.end_minute:
            raise ValueError("quiet rule start and end must differ")
        if self.repeat_type not in VALID_REPEAT_TYPES:
            raise ValueError(f"repeat_type must be one of {sorted(VALID_REPEAT_TYPES)}")

        if self.repeat_type == "weekly":
            days = self.weekdays
            if not days:
                raise ValueError("weekly quiet rule requires weekdays")
            if any(not isinstance(d, int) or d < 1 or d > 7 for d in days):
                raise ValueError("weekdays must be integers 1..7 (1=Mon..7=Sun)")
            if len(set(days)) != len(days):
                raise ValueError("weekdays must not contain duplicates")
        elif self.repeat_type == "once":
            if not self.date:
                raise ValueError("once quiet rule requires date")
            try:
                date_cls.fromisoformat(self.date)
            except ValueError:
                raise ValueError("date must be a valid YYYY-MM-DD date")
        return self


class ProviderQuietRule(QuietRule):
    """供应商+模型级安静规则（存于 settings.json 的 quiet_rules）。"""

    enabled: bool = True
    api_url: str = ""
    model: str = ""

    @model_validator(mode="after")
    def validate_provider_target(self):
        if not str(self.api_url or "").strip():
            raise ValueError("provider quiet rule requires api_url")
        if not str(self.model or "").strip():
            raise ValueError("provider quiet rule requires model")
        return self


def validate_quiet_rules(rules: List[QuietRule]) -> None:
    """校验规则列表：结构 + 同一星期几上的非 once 规则不得重叠/首尾相接。

    once 规则是"单次例外"，不参与跨规则重叠校验；结构校验已由模型负责。
    """
    buckets: Dict[int, List] = {day: [] for day in ISO_WEEKDAYS}
    for rule in rules:
        if rule.repeat_type == "once":
            continue
        days = ISO_WEEKDAYS if rule.repeat_type == "daily" else rule.weekdays
        for day in days:
            if rule.start_minute < rule.end_minute:
                buckets[day].append((rule.start_minute, rule.end_minute))
            else:
                buckets[day].append((rule.start_minute, 24 * 60))
                next_day = day % 7 + 1
                buckets[next_day].append((0, rule.end_minute))

    for day, spans in buckets.items():
        spans.sort()
        for (_, prev_end), (start, _) in zip(spans, spans[1:]):
            if start <= prev_end:
                raise ValueError(
                    f"quiet rules must not overlap or touch on weekday {day}"
                )


# ========== 宽容解析（调度器 / 设置读取） ==========

def normalize_quiet_rule_dict(item: Any) -> Optional[Dict]:
    """把磁盘/设置里的条目解析为规范化 dict；不合法则返回 None（不抛异常）。"""
    if not isinstance(item, dict):
        return None
    try:
        start = int(item.get("start_minute"))
        end = int(item.get("end_minute"))
    except (TypeError, ValueError):
        return None
    if not (0 <= start < 24 * 60 and 0 <= end < 24 * 60 and start != end):
        return None

    repeat_type = str(item.get("repeat_type") or "daily").strip().lower()
    if repeat_type not in VALID_REPEAT_TYPES:
        repeat_type = "daily"

    weekdays: List[int] = []
    if repeat_type == "weekly":
        raw_days = item.get("weekdays")
        if isinstance(raw_days, list):
            try:
                weekdays = sorted({int(d) for d in raw_days if int(d) in ISO_WEEKDAYS})
            except (TypeError, ValueError):
                weekdays = []
        if not weekdays:
            return None

    once_date: Optional[str] = None
    if repeat_type == "once":
        raw_date = str(item.get("date") or "").strip()
        try:
            date_cls.fromisoformat(raw_date)
        except ValueError:
            return None
        once_date = raw_date

    return {
        "start_minute": start,
        "end_minute": end,
        "repeat_type": repeat_type,
        "weekdays": weekdays,
        "date": once_date,
    }


def normalize_provider_rule_dict(item: Any) -> Optional[Dict]:
    """解析供应商级规则条目（在 normalize_quiet_rule_dict 基础上加目标校验）。"""
    rule = normalize_quiet_rule_dict(item)
    if rule is None:
        return None
    if item.get("enabled") is False:
        return None
    api_url = str(item.get("api_url") or "").strip()
    model = str(item.get("model") or "").strip()
    if not api_url or not model:
        return None
    rule["enabled"] = True
    rule["api_url"] = api_url
    rule["model"] = model
    return rule


def provider_rule_matches(rule: Dict, api_url: Any, model: Any) -> bool:
    """供应商规则是否命中角色的生效组合 (api_url, model)。大小写不敏感、去空白。"""
    return (
        str(rule.get("api_url") or "").strip().lower()
        == str(api_url or "").strip().lower()
        and str(rule.get("model") or "").strip().lower()
        == str(model or "").strip().lower()
    )


# ========== 纯时间逻辑（调度器复用） ==========

def rule_applies_on(rule: Dict, dt: datetime) -> bool:
    """规则在 dt 当天是否"生效日"（daily 恒生效；weekly 按 isoweekday；once 按日期）。"""
    repeat_type = str(rule.get("repeat_type") or "daily")
    if repeat_type == "weekly":
        return dt.isoweekday() in (rule.get("weekdays") or [])
    if repeat_type == "once":
        return dt.date().isoformat() == str(rule.get("date") or "")
    return True


def rule_contains(rule: Dict, dt: datetime) -> bool:
    """dt 是否落在规则区间内（含跨夜规则的次日结束段）。"""
    start = int(rule["start_minute"])
    end = int(rule["end_minute"])
    minute = dt.hour * 60 + dt.minute
    if start < end:
        return rule_applies_on(rule, dt) and start <= minute < end
    # 跨夜：起始日的 [start, 1440) 或 次日（结束日）的 [0, end)
    if minute >= start and rule_applies_on(rule, dt):
        return True
    if minute < end and rule_applies_on(rule, dt - timedelta(days=1)):
        return True
    return False


def quiet_period_end(dt: datetime, rules: List[Dict]) -> Optional[datetime]:
    """返回包含 dt 的安静区间结束时间（取最早结束）；不在任何区间内返回 None。"""
    minute = dt.hour * 60 + dt.minute
    best: Optional[datetime] = None
    for rule in rules:
        start = int(rule["start_minute"])
        end = int(rule["end_minute"])
        ends_at: Optional[datetime] = None
        if start < end:
            if rule_applies_on(rule, dt) and start <= minute < end:
                ends_at = dt.replace(
                    hour=end // 60, minute=end % 60, second=0, microsecond=0
                )
        else:
            if minute >= start and rule_applies_on(rule, dt):
                ends_at = (dt + timedelta(days=1)).replace(
                    hour=end // 60, minute=end % 60, second=0, microsecond=0
                )
            elif minute < end and rule_applies_on(rule, dt - timedelta(days=1)):
                ends_at = dt.replace(
                    hour=end // 60, minute=end % 60, second=0, microsecond=0
                )
        if ends_at is not None and (best is None or ends_at < best):
            best = ends_at
    return best


def next_allowed_time(candidate: datetime, rules: List[Dict]) -> datetime:
    """把候选时间推出所有安静区间；防御性防止无法推进时死循环。"""
    for _ in range(len(rules) + 1):
        quiet_end = quiet_period_end(candidate, rules)
        if quiet_end is None:
            return candidate
        if quiet_end <= candidate:
            break
        candidate = quiet_end
    return candidate
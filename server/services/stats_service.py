"""
数值系统服务
负责每角色数值状态的读取、初始化、从 AI 回复中解析数值块，并按上下限裁剪后持久化。
状态文件：data/roles/{role_id}/stats_state.json，结构为 {key: value}
"""
import json
import re
from pathlib import Path
from typing import Any, Dict, Optional

DATA_DIR = Path(__file__).parent.parent / "data"
ROLES_DIR = DATA_DIR / "roles"

# 数值块标签（需与客户端 message_parts.dart 保持一致）
STATS_BLOCK_RE = re.compile(r"<数值>(.*?)</数值>", re.DOTALL)


def _state_file(role_id: str) -> Path:
    return ROLES_DIR / role_id / "stats_state.json"


def _stats_config(role_data: Dict[str, Any]) -> Dict[str, Any]:
    cfg = role_data.get("stats_config") or {}
    return cfg if isinstance(cfg, dict) else {}


def is_enabled(role_data: Dict[str, Any]) -> bool:
    cfg = _stats_config(role_data)
    return bool(cfg.get("enabled")) and bool(cfg.get("stats"))


def _stat_defs(role_data: Dict[str, Any]) -> Dict[str, Dict[str, Any]]:
    """返回 {key: item} 映射，仅含有效的数值定义。"""
    defs: Dict[str, Dict[str, Any]] = {}
    for item in _stats_config(role_data).get("stats") or []:
        if not isinstance(item, dict):
            continue
        key = str(item.get("key") or "").strip()
        if key:
            defs[key] = item
    return defs


def _clamp(value: float, vmin: Any, vmax: Any) -> float:
    try:
        lo = float(vmin)
    except (TypeError, ValueError):
        lo = 0.0
    try:
        hi = float(vmax)
    except (TypeError, ValueError):
        hi = 100.0
    if lo > hi:
        lo, hi = hi, lo
    return max(lo, min(hi, value))


def load_state(role_id: str) -> Dict[str, float]:
    f = _state_file(role_id)
    if f.exists():
        try:
            with open(f, "r", encoding="utf-8") as fp:
                data = json.load(fp)
            if isinstance(data, dict):
                return {str(k): v for k, v in data.items()}
        except Exception:
            pass
    return {}


def save_state(role_id: str, state: Dict[str, float]) -> None:
    f = _state_file(role_id)
    try:
        f.parent.mkdir(parents=True, exist_ok=True)
        with open(f, "w", encoding="utf-8") as fp:
            json.dump(state, fp, ensure_ascii=False, indent=2)
    except Exception:
        pass


def get_current_values(role_id: str, role_data: Dict[str, Any]) -> Dict[str, float]:
    """获取角色当前数值（按定义补齐缺失项，缺省取 initial 或 min），并裁剪到区间内。"""
    if not is_enabled(role_data):
        return {}
    defs = _stat_defs(role_data)
    state = load_state(role_id)
    current: Dict[str, float] = {}
    for key, item in defs.items():
        if key in state:
            try:
                val = float(state[key])
            except (TypeError, ValueError):
                val = None
        else:
            val = None
        if val is None:
            initial = item.get("initial")
            val = float(initial) if initial is not None else float(item.get("min", 0) or 0)
        current[key] = _clamp(val, item.get("min", 0), item.get("max", 100))
    return current


def parse_stats_block(text: str) -> Dict[str, str]:
    """从 AI 回复中解析 <数值>...</数值> 块，返回 {key: raw_value_str}。"""
    parsed: Dict[str, str] = {}
    if not text:
        return parsed
    for block in STATS_BLOCK_RE.findall(text):
        # 支持 ; 或换行分隔的 key:value 对
        for pair in re.split(r"[;\n]+", block):
            pair = pair.strip()
            if not pair or ":" not in pair and "：" not in pair:
                continue
            sep = ":" if ":" in pair else "："
            k, _, v = pair.partition(sep)
            k = k.strip()
            v = v.strip()
            if k:
                parsed[k] = v
    return parsed


def update_from_reply(role_id: str, role_data: Dict[str, Any], reply_text: str) -> Optional[Dict[str, float]]:
    """从回复中解析数值块，按上下限裁剪后与现状合并保存。返回更新后的完整状态，未启用则返回 None。"""
    if not is_enabled(role_data):
        return None
    defs = _stat_defs(role_data)
    if not defs:
        return None
    current = get_current_values(role_id, role_data)
    parsed = parse_stats_block(reply_text)
    for key, raw in parsed.items():
        if key not in defs:
            continue
        try:
            val = float(raw)
        except (TypeError, ValueError):
            continue
        item = defs[key]
        current[key] = _clamp(val, item.get("min", 0), item.get("max", 100))
    save_state(role_id, current)
    return current

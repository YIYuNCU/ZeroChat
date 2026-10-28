"""角色 onebot_config 的读取、默认值与事务式写回。

运行态字段（disabled_conversations / blocked_users / proactive_config）与接口配置
存放在同一份 profile.json 里，写回必须在角色档案锁内重新读取最新内容再修改，
避免用旧快照覆盖用户刚在 App 里保存的设置。
"""
from __future__ import annotations

import json
import logging
from contextlib import contextmanager
from typing import Any, Dict, Iterator, Optional

from core.utils import atomic_write_json
from services.onebot.paths import profile_path

logger = logging.getLogger(__name__)

DEFAULT_WAIT_SECONDS = 15
MAX_WAIT_SECONDS = 30


class InvalidRoleId(ValueError):
    """role_id 未通过路径安全校验。"""


class ProfileUnreadable(Exception):
    """profile.json 存在但无法读取 / 解析。"""


def load_role_profile(role_id: str) -> Optional[Dict[str, Any]]:
    """读取角色 profile.json；角色不存在返回 None。

    Raises:
        InvalidRoleId: role_id 非法（含路径穿越）。
        ProfileUnreadable: 文件损坏或无法读取。
    """
    try:
        path = profile_path(role_id)
    except ValueError as exc:
        raise InvalidRoleId(str(exc)) from exc
    if not path.exists():
        return None
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError) as exc:
        raise ProfileUnreadable(str(exc)) from exc
    return data if isinstance(data, dict) else None


def load_config(role_id: str) -> Dict[str, Any]:
    """读取最新 onebot_config（不存在返回空 dict）。"""
    try:
        profile = load_role_profile(role_id)
    except (InvalidRoleId, ProfileUnreadable):
        return {}
    return dict((profile or {}).get("onebot_config") or {})


@contextmanager
def edit_config(role_id: str) -> Iterator[Dict[str, Any]]:
    """在角色档案锁内以最新内容修改 onebot_config，正常退出时原子写回。"""
    from services.chat_io_service import role_lock

    path = profile_path(role_id)
    with role_lock(role_id):
        with open(path, "r", encoding="utf-8") as f:
            profile = json.load(f)
        cfg = profile.get("onebot_config")
        if not isinstance(cfg, dict):
            cfg = {}
        profile["onebot_config"] = cfg
        before = json.dumps(cfg, sort_keys=True, ensure_ascii=False)
        yield cfg
        if json.dumps(cfg, sort_keys=True, ensure_ascii=False) == before:
            return  # 未改动则不写盘
        atomic_write_json(path, profile)
    try:
        from routers.ai_behavior import invalidate_role_cache

        invalidate_role_cache(role_id)
    except Exception:  # noqa: BLE001 - 缓存失效失败不影响写回
        logger.debug("invalidate_role_cache failed", exc_info=True)


def wait_seconds(config: Dict[str, Any]) -> float:
    """聚合窗口秒数：缺省 15，限制在 0–30。"""
    raw = config.get("wait_seconds", DEFAULT_WAIT_SECONDS)
    try:
        value = float(raw)
    except (TypeError, ValueError):
        return float(DEFAULT_WAIT_SECONDS)
    return max(0.0, min(float(MAX_WAIT_SECONDS), value))


def deliver_proactive_enabled(config: Dict[str, Any]) -> bool:
    return config.get("deliver_proactive") is True


def main_user_id(config: Dict[str, Any]) -> int:
    try:
        return int(config.get("main_user_id") or 0)
    except (TypeError, ValueError):
        return 0

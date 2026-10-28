"""入站放行策略：白名单、@ 检测、随机回复、会话关闭与屏蔽。

所有函数返回 ``None`` 表示放行，返回字符串表示拒绝原因（仅用于日志与 HTTP 响应）。
"""
from __future__ import annotations

import logging
import random
import time
from typing import Any, Dict, Optional

from services.onebot.config import edit_config
from services.onebot.models import Inbound

logger = logging.getLogger(__name__)


def default_scene() -> Dict[str, Any]:
    return {
        "enabled": False,
        "interval": 3.0,
        "last_time": 0,
        "remaining": 0,
        "rate": 0.05,
        "burst": 10,
    }


def get_scene_config(config: Dict[str, Any], conv_key: str) -> Dict[str, Any]:
    """获取指定场景的主动回复配置（不存在时创建默认值）。"""
    scenes = config.setdefault("proactive_config", {})
    if conv_key not in scenes:
        scenes[conv_key] = default_scene()
    return scenes[conv_key]


def check_whitelist(inbound: Inbound, config: Dict[str, Any]) -> Optional[str]:
    if inbound.is_private:
        allowed_users = config.get("allowed_users") or []
        if not allowed_users:
            return "allowed_users 为空，跳过私聊"
        if inbound.user_id not in allowed_users:
            return f"user_id {inbound.user_id} 不在白名单中"
    elif inbound.is_group:
        allowed_groups = config.get("allowed_groups") or []
        if not allowed_groups:
            return "allowed_groups 为空，跳过群聊"
        if inbound.group_id not in allowed_groups:
            return f"group_id {inbound.group_id} 不在白名单中"
    return None


def check_disabled_or_blocked(inbound: Inbound, config: Dict[str, Any]) -> Optional[str]:
    conv_key = inbound.conv_key
    if conv_key in (config.get("disabled_conversations") or []):
        return f"会话 {conv_key} 已关闭"
    blocked = config.get("blocked_users") or {}
    uid = str(inbound.user_id or "")
    if uid in blocked:
        scopes = blocked[uid]
        if not scopes or conv_key in scopes:
            return f"用户 {uid} 在会话 {conv_key} 中被屏蔽"
    return None


def should_random_reply(role_id: str, conv_key: str, now: Optional[float] = None) -> bool:
    """群聊无 @ 时是否触发主动回复。命中时在档案锁内更新计数并持久化。"""
    now = time.time() if now is None else now
    with edit_config(role_id) as cfg:
        scene = get_scene_config(cfg, conv_key)
        if not scene.get("enabled", False):
            return False

        remaining = int(scene.get("remaining", 0))
        if remaining > 0:  # 优先消耗 burst，使剩余次数集中释放
            scene["remaining"] = remaining - 1
            scene["last_time"] = now
            return True

        interval = float(scene.get("interval", 3)) * 3600
        if now - float(scene.get("last_time", 0)) < interval:
            return False

        rate = float(scene.get("rate", 0.05))
        burst = int(scene.get("burst", 10))
        if random.random() < rate:
            scene["remaining"] = burst - 1
            scene["last_time"] = now
            logger.info("主动回复触发: role=%s, conv=%s, rate=%s, burst=%s", role_id, conv_key, rate, burst)
            return True
    return False


def gate(inbound: Inbound, config: Dict[str, Any]) -> Optional[str]:
    """@ 检测 / 随机回复 / 白名单。主用户的 / 指令不受 @ 与白名单限制，否则无法管理。"""
    is_command = inbound.is_owner and inbound.content.startswith("/")

    if inbound.is_group and not is_command and not inbound.at_bot:
        # 不在白名单的群聊不检查自动回复
        if inbound.group_id not in (config.get("allowed_groups") or []):
            return "群聊不在白名单，跳过随机回复"
        from services import scheduler_service

        if scheduler_service.is_role_provider_quiet(inbound.role_id):
            return "供应商静默，跳过随机回复"
        if not should_random_reply(inbound.role_id, inbound.conv_key):
            return "未 @机器人"

    # 主用户不受白名单限制（否则无法在未授权群聊执行 /allow 等指令）
    if not inbound.is_owner:
        return check_whitelist(inbound, config)
    return None

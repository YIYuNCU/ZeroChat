"""主动消息 / 续写 / 提醒的投递平台选择与 QQ 投递。

生成只做一次（App 协议、记忆共享），这里只决定「发到哪」：

* 提醒（task）：发到创建它的平台（QQ 创建的任务记录里带 ``platform: "qq"``）。
* 主动消息 / 续写：发到主用户最近一次 1:1 互动的平台（App 单聊或 QQ 私聊，群聊不算）。
* 默认 App。QQ 需要 ``onebot_config.deliver_proactive`` 开启、角色已启用且配置了主 QQ、
  反向 WS 在线；任一不满足就回落到 App。
"""
from __future__ import annotations

import logging
from typing import Any, Dict, Optional

from services.onebot import config as cfg_mod
from services.onebot.mirror import mirror_item
from services.onebot.models import Target
from services.onebot.reply_plan import build_plan
from services.onebot.sender import deliver_plan

logger = logging.getLogger(__name__)

PLATFORM_APP = "app"
PLATFORM_QQ = "qq"
META_KEY = "last_owner_platform"

_last_platform: Dict[str, str] = {}


async def record_owner_platform(role_id: str, platform: str) -> None:
    """记录主用户最近一次 1:1 互动的平台（内存缓存 + memory_meta 持久化，仅变化时落库）。"""
    if platform not in (PLATFORM_APP, PLATFORM_QQ):
        return
    if _last_platform.get(role_id) == platform:
        return
    _last_platform[role_id] = platform
    try:
        from services.memory_service import _run_db, write_meta_value

        await _run_db(role_id, write_meta_value, role_id, META_KEY, platform)
    except Exception:  # noqa: BLE001 - 记录失败只影响下次投递选择
        logger.debug("记录最近互动平台失败", exc_info=True)


async def last_owner_platform(role_id: str) -> str:
    cached = _last_platform.get(role_id)
    if cached:
        return cached
    try:
        from services.memory_service import _run_db, read_meta_value

        value = await _run_db(role_id, read_meta_value, role_id, META_KEY, PLATFORM_APP)
    except Exception:  # noqa: BLE001
        value = PLATFORM_APP
    value = value if value in (PLATFORM_APP, PLATFORM_QQ) else PLATFORM_APP
    _last_platform[role_id] = value
    return value


def _qq_available(role_id: str, config: Dict[str, Any]) -> bool:
    from transport.onebot_ws import manager as ws_manager

    return bool(
        config.get("enabled", False)
        and cfg_mod.deliver_proactive_enabled(config)
        and cfg_mod.main_user_id(config)
        and ws_manager.is_connected(role_id)
    )


async def resolve_platform(role_id: str, event_type: str, context: Optional[Dict[str, Any]] = None) -> str:
    """返回 ``"app"`` 或 ``"qq"``；QQ 不可用时回落 App。"""
    ctx = context or {}
    if event_type == "task":
        desired = str(ctx.get("platform") or PLATFORM_APP)
    elif event_type in ("proactive", "followup"):
        desired = await last_owner_platform(role_id)
    else:
        desired = PLATFORM_APP
    if desired != PLATFORM_QQ:
        return PLATFORM_APP
    if str(ctx.get("chat_id") or role_id) != role_id:  # App 群聊里的任务不转 QQ
        return PLATFORM_APP
    return PLATFORM_QQ if _qq_available(role_id, cfg_mod.load_config(role_id)) else PLATFORM_APP


async def deliver_to_qq(role_id: str, content: str, metadata: Optional[Dict[str, Any]] = None) -> bool:
    """把一条 AI 主动内容发给主用户的 QQ 私聊，并同步进 App 历史。

    Returns:
        True 表示已处理（含「无回复」无需发送）；False 表示发送失败，调用方应回落到 App。
    """
    from transport.onebot_ws import manager as ws_manager

    config = cfg_mod.load_config(role_id)
    conn = ws_manager.get_connection(role_id)
    main_id = cfg_mod.main_user_id(config)
    if conn is None or not main_id:
        return False

    meta = metadata or {}
    plan = build_plan(content, meta)
    if plan.empty:
        return True

    async def _mirror(item, path):
        await mirror_item(role_id, item, path, meta)

    delivered = await deliver_plan(
        conn, role_id, Target(main_id), plan,
        server_url=str(config.get("server_url") or ""),
        on_delivered=_mirror,
    )
    return bool(delivered)

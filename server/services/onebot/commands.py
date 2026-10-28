"""主用户的 QQ 管理指令（WS 与 HTTP 共用同一份实现）。"""
from __future__ import annotations

import re
from typing import Any, Callable, Dict, Optional

from services.onebot.config import edit_config, load_config
from services.onebot.models import Inbound
from services.onebot.policy import get_scene_config

HELP_TEXT = (
    "可用指令：\n"
    "/clear - 清除当前会话记忆\n"
    "/on - 开启当前会话消息处理\n"
    "/off - 关闭当前会话消息处理\n"
    "/allow - 将当前群聊加入白名单（群聊中使用）\n"
    "/allow @用户 - 将用户加入白名单\n"
    "/disallow - 将当前群聊移出白名单（群聊中使用）\n"
    "/disallow @用户 - 将用户移出白名单\n"
    "/block @用户 - 屏蔽当前场景指定用户\n"
    "/unblock @用户 - 取消屏蔽\n"
    "/blocklist - 查看被屏蔽用户列表\n"
    "/random - 查看随机回复配置\n"
    "/random set <概率> <次数> - 设置随机回复概率和连续回复次数\n"
    "/proactive - 查看主动回复模式状态\n"
    "/proactive on/off - 开启/关闭主动回复模式（调试用）\n"
    "/proactive interval <小时> - 设置主动回复间隔时间（支持小数）\n"
    "/clear 只清除服务端记忆，不会删除 App 里已同步的聊天记录\n"
    "/help - 显示此帮助"
)

_Handler = Callable[[str, Inbound, str], str]


def _target_id(arg: str) -> str:
    m = re.search(r"@(\d+)", arg)
    if m:
        return m.group(1)
    return arg if arg.isdigit() else ""


def _help(role_id: str, ib: Inbound, arg: str) -> str:
    return HELP_TEXT


def _clear(role_id: str, ib: Inbound, arg: str) -> str:
    from services.memory_service import clear_short_term_by_conversation

    clear_short_term_by_conversation(role_id, ib.conv_key)
    return f"已清除 {ib.conv_key} 的记忆"


def _on(role_id: str, ib: Inbound, arg: str) -> str:
    with edit_config(role_id) as cfg:
        disabled = cfg.get("disabled_conversations") or []
        if ib.conv_key not in disabled:
            return f"{ib.conv_key} 未关闭，无需开启"
        disabled.remove(ib.conv_key)
        cfg["disabled_conversations"] = disabled
    return f"已开启 {ib.conv_key} 的消息处理"


def _off(role_id: str, ib: Inbound, arg: str) -> str:
    with edit_config(role_id) as cfg:
        disabled = cfg.get("disabled_conversations") or []
        if ib.conv_key in disabled:
            return f"{ib.conv_key} 已经关闭"
        disabled.append(ib.conv_key)
        cfg["disabled_conversations"] = disabled
    return f"已关闭 {ib.conv_key} 的消息处理"


def _block(role_id: str, ib: Inbound, arg: str) -> str:
    target = _target_id(arg)
    if not target:
        return "请指定要操作的用户，格式：/block @用户"
    conv = ib.conv_key
    with edit_config(role_id) as cfg:
        blocked = cfg.get("blocked_users") or {}
        scopes = blocked.get(target)
        if scopes is None:
            blocked[target] = [conv]
        elif not scopes:
            return f"用户 {target} 已被全局屏蔽"
        elif conv in scopes:
            return f"用户 {target} 已在 {conv} 被屏蔽"
        else:
            scopes.append(conv)
        cfg["blocked_users"] = blocked
    return f"已在 {conv} 屏蔽用户 {target}"


def _unblock(role_id: str, ib: Inbound, arg: str) -> str:
    target = _target_id(arg)
    if not target:
        return "请指定要操作的用户，格式：/unblock @用户"
    conv = ib.conv_key
    with edit_config(role_id) as cfg:
        blocked = cfg.get("blocked_users") or {}
        scopes = blocked.get(target)
        if scopes is None:
            return f"用户 {target} 未被屏蔽"
        if not scopes:
            del blocked[target]
            cfg["blocked_users"] = blocked
            return f"已取消对用户 {target} 的全局屏蔽"
        if conv not in scopes:
            return f"用户 {target} 未在 {conv} 被屏蔽"
        scopes.remove(conv)
        if scopes:
            blocked[target] = scopes
        else:
            del blocked[target]
        cfg["blocked_users"] = blocked
    return f"已在 {conv} 取消屏蔽用户 {target}"


def _blocklist(role_id: str, ib: Inbound, arg: str) -> str:
    return build_blocklist_text(load_config(role_id))


def build_blocklist_text(config: Dict[str, Any]) -> str:
    blocked = config.get("blocked_users") or {}
    if not blocked:
        return "暂无被屏蔽的用户"
    lines = ["被屏蔽用户列表："]
    for uid, scopes in blocked.items():
        lines.append(f"  {uid}（全局屏蔽）" if not scopes else f"  {uid}（{', '.join(scopes)}）")
    return "\n".join(lines)


def _allow_common(role_id: str, ib: Inbound, arg: str, *, add: bool) -> str:
    verb = "加入" if add else "移出"
    usage = "/allow" if add else "/disallow"
    if not arg and ib.is_group and ib.group_id:
        gid = ib.group_id
        with edit_config(role_id) as cfg:
            allowed = cfg.get("allowed_groups") or []
            if (gid in allowed) == add:
                return f"群 {gid} 已在白名单中" if add else f"群 {gid} 不在白名单中"
            allowed.append(gid) if add else allowed.remove(gid)
            cfg["allowed_groups"] = allowed
        return f"已将群 {gid} {verb}白名单"
    target = _target_id(arg)
    if not target:
        return f"请指定要操作的用户，格式：{usage} @用户（群聊中直接使用 {usage} 可将当前群{verb}白名单）"
    uid = int(target)
    with edit_config(role_id) as cfg:
        allowed = cfg.get("allowed_users") or []
        if (uid in allowed) == add:
            return f"用户 {uid} 已在白名单中" if add else f"用户 {uid} 不在白名单中"
        allowed.append(uid) if add else allowed.remove(uid)
        cfg["allowed_users"] = allowed
    return f"已将用户 {uid} {verb}白名单"


def _allow(role_id: str, ib: Inbound, arg: str) -> str:
    return _allow_common(role_id, ib, arg, add=True)


def _disallow(role_id: str, ib: Inbound, arg: str) -> str:
    return _allow_common(role_id, ib, arg, add=False)


def _random(role_id: str, ib: Inbound, arg: str) -> str:
    sub = arg.split()
    conv = ib.conv_key
    if sub and sub[0] == "set" and len(sub) >= 3:
        try:
            rate, burst = float(sub[1]), int(sub[2])
        except (ValueError, TypeError):
            return "格式错误，正确格式：/random set <概率> <次数>"
        if not 0 <= rate <= 1:
            return "随机概率必须在 0~1 之间"
        if burst < 1:
            return "连续回复次数必须 >= 1"
        with edit_config(role_id) as cfg:
            scene = get_scene_config(cfg, conv)
            scene["rate"], scene["burst"] = rate, burst
        return f"已设置 {conv} 随机回复概率={rate}，连续回复次数={burst}"
    with edit_config(role_id) as cfg:
        scene = dict(get_scene_config(cfg, conv))
    return (
        f"随机回复配置（{conv}）：\n"
        f"  触发概率：{scene['rate']}\n"
        f"  连续回复次数：{scene['burst']}\n"
        f"  剩余免费回复：{scene['remaining']}\n"
        f"  回复间隔：{scene['interval']}小时"
    )


def _proactive(role_id: str, ib: Inbound, arg: str) -> str:
    sub = arg.split()
    conv = ib.conv_key
    if sub and sub[0] == "interval" and len(sub) >= 2:
        try:
            interval = float(sub[1])
        except (ValueError, TypeError):
            return "格式错误，正确格式：/proactive interval <小时>"
        if interval < 0:
            return "间隔时间不能为负数"
        with edit_config(role_id) as cfg:
            get_scene_config(cfg, conv)["interval"] = interval
        return f"已设置 {conv} 主动回复间隔为 {interval} 小时"
    if sub and sub[0] in ("on", "off"):
        on = sub[0] == "on"
        with edit_config(role_id) as cfg:
            get_scene_config(cfg, conv)["enabled"] = on
        return f"已{'开启' if on else '关闭'} {conv} 的主动回复模式"
    with edit_config(role_id) as cfg:
        scene = dict(get_scene_config(cfg, conv))
    return (
        f"主动回复模式（{conv}）：{'已开启' if scene.get('enabled') else '已关闭'}\n"
        f"  回复间隔：{scene['interval']}小时\n"
        f"  提示：/proactive on 开启，/proactive off 关闭，"
        f"/proactive interval <小时> 设置间隔"
    )


COMMANDS: Dict[str, _Handler] = {
    "/help": _help,
    "/clear": _clear,
    "/on": _on,
    "/off": _off,
    "/block": _block,
    "/unblock": _unblock,
    "/blocklist": _blocklist,
    "/allow": _allow,
    "/disallow": _disallow,
    "/random": _random,
    "/proactive": _proactive,
}


def is_command_text(content: str) -> bool:
    return content.strip().startswith("/")


def run_command(role_id: str, inbound: Inbound) -> Optional[str]:
    """执行主用户指令，返回结果文本；非指令或未知指令返回 None（交给 AI 当普通消息）。"""
    if not inbound.is_owner:
        return None
    content = inbound.content.strip()
    if not content.startswith("/"):
        return None
    parts = content.split(maxsplit=1)
    handler = COMMANDS.get(parts[0].lower())
    if handler is None:
        return None
    return handler(role_id, inbound, parts[1].strip() if len(parts) > 1 else "")

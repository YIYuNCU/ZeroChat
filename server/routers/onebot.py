"""
OneBot V11 接口
支持两种传输方式：
1. HTTP POST: /api/onebot/{role_id}/event
2. 反向 WebSocket: /onebot/ws/{role_id}?access_token=xxx
"""
import asyncio
import base64
import hashlib
import hmac
import json
import logging
import random
import re
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import httpx
from fastapi import APIRouter, Header, HTTPException, Request, WebSocket, WebSocketDisconnect
from pydantic import BaseModel

from transport.onebot_ws import manager as ws_manager
from core.utils import is_safe_external_url

router = APIRouter()
logger = logging.getLogger(__name__)

DATA_DIR = Path(__file__).parent.parent / "data"
ROLES_DIR = DATA_DIR / "roles"

AGG_WINDOW = 15.0  # 消息聚合窗口（秒）
SERVER_URL_FALLBACK = "http://127.0.0.1:8000"


# ========== 消息聚合 ==========

class _AggBuffer:
    """单个发送者的消息聚合缓冲"""
    __slots__ = ("contents", "transformed", "message_id", "conn", "flush_task", "last_ts")

    def __init__(self, content: str, transformed: Dict[str, Any], message_id: Optional[int], conn):
        self.contents: List[str] = [content]
        self.transformed = transformed
        self.message_id = message_id
        self.conn = conn
        self.flush_task: Optional[asyncio.Task] = None
        self.last_ts: float = time.monotonic()


# key = (role_id, user_id, group_id_str)
_agg_buffers: Dict[Tuple[str, int, str], _AggBuffer] = {}


async def _schedule_flush(key: Tuple[str, int, str]):
    """延迟后刷写聚合缓冲"""
    await asyncio.sleep(AGG_WINDOW)
    buf = _agg_buffers.pop(key, None)
    if buf is None:
        return

    combined = "\n".join(buf.contents)
    transformed = buf.transformed
    transformed["content"] = combined

    role_id = key[0]
    try:
        reply_text, image_paths = await _process_and_reply(role_id, transformed, buf.message_id)
    except Exception as e:
        logger.error(f"OneBot AI 处理失败: role={role_id}, error={e}", exc_info=True)
        return

    if reply_text or image_paths:
        try:
            await _send_reply(buf.conn, transformed, reply_text, message_id=buf.message_id, image_paths=image_paths)
            logger.info(
                f"OneBot 回复发送: role={role_id}, "
                f"target={transformed['origin']}, "
                f"msgs={len(buf.contents)}, reply={reply_text[:50]}..."
            )
        except Exception as e:
            logger.error(f"OneBot 回复发送失败: {e}")


def _enqueue(transformed: Dict[str, Any], message_id: Optional[int], conn):
    """将消息加入聚合队列，重置定时器"""
    role_id = transformed.pop("_role_id", "")
    user_id = transformed["user_id"] or 0
    group_id = str(transformed["group_id"] or "")
    key = (role_id, user_id, group_id)

    existing = _agg_buffers.get(key)
    if existing:
        existing.contents.append(transformed["content"])
        existing.message_id = message_id  # 始终引用最新消息
        # 合并图片 URL
        new_urls = transformed.get("image_urls") or []
        if new_urls:
            existing.transformed.setdefault("image_urls", []).extend(new_urls)
        existing.last_ts = time.monotonic()
        # 重置定时器
        if existing.flush_task and not existing.flush_task.done():
            existing.flush_task.cancel()
        existing.flush_task = asyncio.ensure_future(_schedule_flush(key))
    else:
        buf = _AggBuffer(transformed["content"], transformed, message_id, conn)
        buf.flush_task = asyncio.ensure_future(_schedule_flush(key))
        _agg_buffers[key] = buf


# ========== 数据模型 ==========

class OneBotEvent(BaseModel):
    post_type: Optional[str] = None
    message_type: Optional[str] = None
    sub_type: Optional[str] = None
    message_id: Optional[int] = None
    user_id: Optional[int] = None
    group_id: Optional[int] = None
    message: Any = None
    raw_message: Optional[str] = None
    sender: Optional[Dict[str, Any]] = None
    time: Optional[int] = None
    self_id: Optional[int] = None
    font: Optional[int] = None


# ========== 消息转换 ==========

def _flatten_message(message: Any, self_id: Optional[int] = None) -> Tuple[str, List[str]]:
    """将 OneBot message 字段转换为纯文本和图片 URL 列表，自动去除开头的 @机器人"""
    if isinstance(message, str):
        return message, []
    if isinstance(message, list):
        parts: List[str] = []
        image_urls: List[str] = []
        skip_leading_at = True  # 仅跳过消息开头的 @机器人
        for seg in message:
            if not isinstance(seg, dict):
                continue
            seg_type = seg.get("type", "")
            data = seg.get("data", {})
            if seg_type == "at":
                qq = data.get("qq") or data.get("target") or data.get("uin") or "all"
                at_qq = int(qq) if str(qq).isdigit() else qq
                if skip_leading_at and self_id and at_qq == self_id:
                    continue  # 跳过开头的 @机器人
                parts.append(f"@{qq}")
                skip_leading_at = False
            elif seg_type == "text":
                text = str(data.get("text", ""))
                if skip_leading_at and text.lstrip():
                    skip_leading_at = False
                parts.append(text)
            else:
                skip_leading_at = False
                if seg_type == "face":
                    parts.append("[表情]")
                elif seg_type == "image":
                    parts.append("[图片]")
                    url = str(data.get("url", "")).strip()
                    if url:
                        image_urls.append(url)
                elif seg_type == "record":
                    parts.append("[语音]")
                elif seg_type == "video":
                    parts.append("[视频]")
                elif seg_type == "reply":
                    parts.append("[回复]")
                elif seg_type == "forward":
                    parts.append("[转发消息]")
                elif seg_type == "json":
                    parts.append("[JSON卡片]")
                elif seg_type == "xml":
                    parts.append("[XML消息]")
                else:
                    parts.append(f"[{seg_type}]")
        return "".join(parts).strip(), image_urls
    return str(message or ""), []


def _is_at_bot(message: Any, self_id: Optional[int]) -> bool:
    """检查消息是否 @了机器人"""
    if not self_id:
        logger.warning(f"_is_at_bot: self_id 为 None，跳过检查")
        return True
    if isinstance(message, str):
        return f"@{self_id}" in message
    if isinstance(message, list):
        for seg in message:
            if isinstance(seg, dict) and seg.get("type") == "at":
                data = seg.get("data", {})
                # 兼容 qq / target / uin 等不同字段名
                at_qq = data.get("qq") or data.get("target") or data.get("uin") or ""
                logger.debug(f"_is_at_bot: at segment data={data}, at_qq={at_qq}, self_id={self_id}")
                if str(at_qq) == str(self_id):
                    return True
    return False


def _extract_sender_name(event: OneBotEvent) -> str:
    """从 sender 中提取显示名称"""
    sender = event.sender or {}
    if event.message_type == "group":
        card = str(sender.get("card") or "").strip()
        if card:
            return card
    nickname = str(sender.get("nickname") or "").strip()
    if nickname:
        return nickname
    return str(event.user_id or "unknown")


def _transform_event(event: OneBotEvent, self_id: Optional[int] = None) -> Optional[Dict[str, Any]]:
    """将 OneBot 事件转换为处理参数"""
    if event.post_type != "message":
        return None
    if event.message_type not in ("private", "group"):
        return None

    content, image_urls = _flatten_message(event.message, self_id=self_id)
    if not content.strip() and not image_urls:
        return None

    sender_name = _extract_sender_name(event)
    sender_id = event.user_id or 0
    sender = f"{sender_id}(QQ名:{sender_name})"

    if event.message_type == "group":
        origin = "onebot_group"
        group_id = event.group_id or 0
    else:
        origin = "onebot_private"
        group_id = None

    return {
        "content": content,
        "origin": origin,
        "sender": sender,
        "image_urls": image_urls,
        "user_id": event.user_id,
        "group_id": group_id,
    }


# ========== 签名验证 ==========

def _verify_signature(raw_body: bytes, secret: str, signature_header: str) -> bool:
    """验证 OneBot V11 HMAC-SHA1 签名。空 secret 不放行（调用方应在更早处拒绝）。"""
    if not secret:
        return False
    if not signature_header or not signature_header.startswith("sha1="):
        return False
    expected = "sha1=" + hmac.new(
        secret.encode("utf-8"),
        raw_body,
        hashlib.sha1,
    ).hexdigest()
    return hmac.compare_digest(expected, signature_header)


# ========== 白名单过滤 ==========

def _check_whitelist(
    transformed: Dict[str, Any],
    event: OneBotEvent,
    onebot_config: Dict,
) -> Optional[str]:
    """检查白名单，返回 None 表示通过，返回字符串表示拒绝原因"""
    allowed_users = onebot_config.get("allowed_users") or []
    allowed_groups = onebot_config.get("allowed_groups") or []

    if transformed["origin"] == "onebot_private":
        if not allowed_users:
            return "allowed_users 为空，跳过私聊"
        if transformed["user_id"] not in allowed_users:
            logger.warning(f"OneBot 私聊消息过滤: user_id {transformed['user_id']} 不在 allowed_users{allowed_users} 中")
            return f"user_id {transformed['user_id']} 不在白名单中"
    
    if transformed["origin"] == "onebot_group":
        if not allowed_groups:
            return "allowed_groups 为空，跳过群聊"
        if transformed["group_id"] not in allowed_groups:
            return f"group_id {transformed['group_id']} 不在白名单中"
    return None


# ========== AI 处理 + 回复 ==========

async def _process_and_reply(
    role_id: str,
    transformed: Dict[str, Any],
    message_id: Optional[int],
) -> Tuple[str, List[Path]]:
    """调用 AI 处理消息，返回 (回复文本, 表情图片路径列表)"""
    from routers.ai_behavior import AIEvent, AIEventType, handle_ai_event

    # ===== 图片识别预处理 =====
    content = transformed["content"]
    image_urls = transformed.get("image_urls") or []
    if image_urls:
        descriptions = await _describe_onebot_images(image_urls)
        if descriptions:
            # 将 [图片] 占位符替换为识别结果，多余的描述追加到末尾
            pic_count = content.count("[图片]")
            used = 0
            for desc in descriptions[:pic_count]:
                content = content.replace("[图片]", f"[图片: {desc}]", 1)
                used += 1
            if used < len(descriptions):
                extra = " ".join(f"[图片识别: {d}]" for d in descriptions[used:])
                content = f"{content}\n{extra}" if content else extra

    ai_event = AIEvent(
        role_id=role_id,
        event_type=AIEventType.CHAT,
        content=content,
        context={
            "origin": transformed["origin"],
            "sender": transformed["sender"],
            "sender_id": str(transformed["user_id"] or ""),
            "request_id": f"onebot_{message_id or ''}_{transformed['user_id'] or ''}",
            "onebot_user_id": transformed["user_id"],
            "onebot_group_id": transformed["group_id"],
        },
    )

    result = await handle_ai_event(ai_event)
    if hasattr(result, "model_dump"):
        result_dict = result.model_dump()
    elif isinstance(result, dict):
        result_dict = result
    else:
        return "", []

    if result_dict.get("success"):
        reply_text = result_dict.get("content") or ""
        emojis_called = (result_dict.get("metadata") or {}).get("emojis_called") or []
        image_paths = _resolve_emojis(emojis_called, role_id)
        return reply_text, image_paths
    return "", []


def _strip_action_descriptions(text: str) -> str:
    """去除 AI 回复中残留的动作/心理/状态描写（兜底过滤）"""
    # 使用状态机处理 <>，正确处理内含 > 字符（如 (>_<)）或嵌套的情况
    result = []
    depth = 0
    for ch in text:
        if ch == '<':
            depth += 1
        elif ch == '>':
            if depth > 0:
                depth -= 1
        elif depth == 0:
            result.append(ch)
    text = ''.join(result)
    text = re.sub(r'【[^】]+】', '', text)      # 【小声说】
    text = re.sub(r'/[一-鿿][^/]*/', '', text)   # /揉了揉眼睛/（仅中文内容，避免误匹配URL）
    text = re.sub(r'\*\*[^*]+\*\*', '', text)  # **真的**（双星号强调，必须在单*之前）
    text = re.sub(r'\*[^*]+\*', '', text)      # *叹气*
    text = re.sub(r'\[[^\[\]]+\]', '', text)   # [小声嘀咕]（补充说明）
    text = re.sub(r'（[^）]+）', '', text)        # （停顿片刻）
    # 清理多余空白和残留标点
    text = re.sub(r'[，、，]+$', '', text.strip())
    return text.strip()


# ========== OneBot 图片识别 ==========

async def _describe_onebot_images(image_urls: List[str]) -> List[str]:
    """下载 OneBot 消息中的图片，通过 Vision API 识别内容，返回描述列表"""
    from services import vision_service

    vision_cfg = vision_service.resolve_vision_config()
    api_url = vision_cfg.get("api_url", "")
    api_key = vision_cfg.get("api_key", "")
    model = vision_cfg.get("model", "gpt-4o")
    api_format = vision_cfg.get("api_format", "auto")

    if not api_url or not api_key:
        logger.info("OneBot 图片识别跳过：未配置 Vision API")
        return []

    descriptions: List[str] = []
    max_images = 3  # 限制处理数量避免过长延迟

    async with httpx.AsyncClient(timeout=30.0) as client:
        for url in image_urls[:max_images]:
            # SSRF 防护：入站图片 URL 不可信，禁止指向内网/环回/元数据地址
            if not is_safe_external_url(url):
                logger.warning(f"OneBot 图片下载拒绝（URL 未通过 SSRF 校验）: {url[:80]}")
                continue
            try:
                # 从 QQ CDN 下载图片
                resp = await client.get(url, headers={
                    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
                    "Referer": "https://qq.com",
                })
                resp.raise_for_status()
                image_bytes = resp.content
                if not image_bytes:
                    continue

                mime = vision_service.guess_image_mime(image_bytes) or "image/jpeg"
                b64 = base64.b64encode(image_bytes).decode("utf-8")
                data_url = f"data:{mime};base64,{b64}"

                # 使用共享 vision_service 构建消息并调用 API
                messages = vision_service.build_vision_messages(
                    data_url, "请用一句话简洁描述这张图片的内容"
                )
                body = {
                    "model": model,
                    "messages": messages,
                    "max_tokens": 256,
                }
                api_result = await vision_service.call_vision_api(api_url, api_key, body, api_format=api_format)
                if api_result:
                    descriptions.append(api_result)
                    logger.info(f"OneBot 图片识别成功: {api_result[:50]}...")
            except httpx.TimeoutException:
                logger.warning(f"OneBot 图片下载超时: {url[:60]}...")
            except Exception as e:
                logger.warning(f"OneBot 图片处理失败: {e}")
                continue

    return descriptions


# ========== 表情图片查找 ==========

def _resolve_emojis(emotions: List[Any], role_id: str) -> List[Path]:
    """把 emojis_called 列表解析为表情图片路径。

    元素可为：
      - str 情绪名 —— 走本地情绪目录随机抽取（共享 ai_tools 逻辑）；
      - dict {"category": ..., "filename": ...} —— 精确定位某张缓存图片（如云端表情）。
    """
    from services.ai_tools import _pick_emoji_file
    from core.utils import ensure_path_within_root, ensure_simple_path_segment

    image_paths: List[Path] = []
    seen: set = set()
    for item in emotions:
        if isinstance(item, dict):
            category = str(item.get("category") or "").strip()
            filename = str(item.get("filename") or "").strip()
            key = f"{category}/{filename}"
            if not category or not filename or key in seen:
                continue
            seen.add(key)
            try:
                safe_cat = ensure_simple_path_segment(category, "category")
                safe_name = ensure_simple_path_segment(filename, "filename")
                root = ROLES_DIR / role_id / "emojis"
                path = ensure_path_within_root(root / safe_cat / safe_name, root)
            except ValueError:
                continue
            if path.exists() and path.is_file():
                image_paths.append(path)
            continue

        e = str(item).lower()
        if e in seen:
            continue
        seen.add(e)
        f = _pick_emoji_file(role_id, e)
        if f is not None:
            image_paths.append(f)
    return image_paths


# ========== 服务器 URL 解析 ==========

def _build_server_url(websocket=None) -> str:
    """从 WebSocket 连接或 CONFIG 构建服务器 URL（用于 HTTP 图片传输）"""
    from main import CONFIG

    if websocket is not None:
        scheme = "https" if websocket.url.scheme == "wss" else "http"
        return f"{scheme}://{websocket.url.hostname}:{websocket.url.port}"

    host = CONFIG.get("host", "0.0.0.0")
    port = CONFIG.get("port", 8000)
    if not host or host in ("0.0.0.0", "::"):
        host = "127.0.0.1"
    return f"http://{host}:{port}"


# ========== 构建 OneBot 消息数组 ==========

def _build_message_segments(
    reply_text: str,
    message_id: Optional[int],
    origin: str,
    user_id: int,
    image_paths: Optional[List[Path]] = None,
    server_url: str = SERVER_URL_FALLBACK,
) -> List[Dict[str, Any]]:
    """构建 OneBot 消息数组（reply + @ + text + image）"""
    segments: List[Dict[str, Any]] = []

    if message_id is not None:
        segments.append({"type": "reply", "data": {"id": message_id}})

    if origin == "onebot_group":
        segments.append({"type": "at", "data": {"qq": user_id}})

    if reply_text:
        segments.append({"type": "text", "data": {"text": f" {reply_text}"}})

    if image_paths:
        for img_path in image_paths:
            # img_path = .../data/roles/{role_id}/emojis/{emotion}/{filename}
            # ROLES_DIR = .../data/roles → relative = {role_id}/emojis/{emotion}/{filename}
            relative = img_path.relative_to(ROLES_DIR)
            parts = relative.parts  # (role_id, "emojis", emotion, filename)
            http_url = f"{server_url.rstrip('/')}/files/public/emojis/{parts[0]}/{parts[2]}/{parts[3]}"
            segments.append({"type": "image", "data": {"file": http_url}})

    return segments


async def _send_reply(
    conn,
    transformed: Dict[str, Any],
    reply_text: str,
    raw: bool = False,
    message_id: Optional[int] = None,
    image_paths: Optional[List[Path]] = None,
):
    """通过 WebSocket 连接发送回复到 QQ（消息数组格式：reply + @ + text + image）"""
    if not reply_text.strip():
        return

    if raw:
        clean_reply = reply_text.strip()
    else:
        clean_reply = _strip_action_descriptions(reply_text)

    paths = image_paths or []
    if not clean_reply and not paths:
        return

    server_url = transformed.get("_server_url", SERVER_URL_FALLBACK)
    segments = _build_message_segments(
        reply_text=clean_reply,
        message_id=message_id,
        origin=transformed["origin"],
        user_id=transformed["user_id"],
        image_paths=paths,
        server_url=server_url,
    )

    if transformed["origin"] == "onebot_group":
        await conn.send_action("send_group_msg", {
            "group_id": transformed["group_id"],
            "message": segments,
        })
    else:
        await conn.send_action("send_private_msg", {
            "user_id": transformed["user_id"],
            "message": segments,
        })


# ========== 系统指令 ==========

_HELP_TEXT = (
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
    "/help - 显示此帮助"
)


def _build_conversation_key(transformed: Dict[str, Any]) -> str:
    """根据消息构建会话 key"""
    if transformed["origin"] == "onebot_group":
        return f"group:{transformed['group_id']}"
    return f"private:{transformed['user_id']}"


def _persist_onebot_config(role_id: str, onebot_config: Dict):
    """将 onebot_config 变更写回 profile.json"""
    profile_file = ROLES_DIR / role_id / "profile.json"
    try:
        with open(profile_file, "r", encoding="utf-8") as f:
            role_data = json.load(f)
        role_data["onebot_config"] = onebot_config
        with open(profile_file, "w", encoding="utf-8") as f:
            json.dump(role_data, f, ensure_ascii=False, indent=2)
    except Exception as e:
        logger.error(f"持久化 onebot_config 失败: role={role_id}, error={e}")


def _check_disabled_or_blocked(
    transformed: Dict[str, Any],
    onebot_config: Dict,
) -> Optional[str]:
    """检查会话是否关闭或用户是否被屏蔽，返回 None 表示通过，返回字符串表示拒绝原因"""
    conv_key = _build_conversation_key(transformed)

    disabled = onebot_config.get("disabled_conversations") or []
    if conv_key in disabled:
        return f"会话 {conv_key} 已关闭"

    blocked = onebot_config.get("blocked_users") or {}
    user_id_str = str(transformed["user_id"] or "")
    if user_id_str in blocked:
        block_scopes = blocked[user_id_str]
        if not block_scopes or conv_key in block_scopes:
            return f"用户 {user_id_str} 在会话 {conv_key} 中被屏蔽"

    return None


def _get_scene_config(onebot_config: Dict, conv_key: str) -> Dict:
    """获取指定场景的主动回复配置（不存在时创建默认值）"""
    scenes = onebot_config.setdefault("proactive_config", {})
    if conv_key not in scenes:
        scenes[conv_key] = {
            "enabled": False,
            "interval": 3.0,
            "last_time": 0,
            "remaining": 0,
            "rate": 0.05,
            "burst": 10,
        }
    return scenes[conv_key]


def _check_random_reply(onebot_config: Dict, role_id: str, current_time: float, conv_key: str) -> bool:
    """检查是否应触发主动回复（群聊无 @ 时使用）。返回 True 表示本次应回复。"""
    cfg = _get_scene_config(onebot_config, conv_key)

    # 主动回复未开启时，不进行任何无 @ 回复
    if not cfg.get("enabled", False):
        return False

    remaining = int(cfg.get("remaining", 0))

    # 优先消耗 burst，使剩余次数在短时间内集中释放
    if remaining > 0:
        cfg["remaining"] = remaining - 1
        cfg["last_time"] = current_time
        _persist_onebot_config(role_id, onebot_config)
        return True

    interval = float(cfg.get("interval", 3)) * 3600
    last_time = float(cfg.get("last_time", 0))
    if current_time - last_time < interval:
        return False

    rate = float(cfg.get("rate", 0.05))
    burst = int(cfg.get("burst", 10))

    if random.random() < rate:
        cfg["remaining"] = burst - 1
        cfg["last_time"] = current_time
        _persist_onebot_config(role_id, onebot_config)
        logger.info(f"主动回复触发: role={role_id}, conv={conv_key}, rate={rate}, burst={burst}")
        return True

    return False


def _build_blocklist_text(onebot_config: Dict) -> str:
    """构建被屏蔽人列表文本"""
    blocked = onebot_config.get("blocked_users") or {}
    if not blocked:
        return "暂无被屏蔽的用户"
    lines = ["被屏蔽用户列表："]
    for uid, scopes in blocked.items():
        if not scopes:
            lines.append(f"  {uid}（全局屏蔽）")
        else:
            scopes_str = ", ".join(scopes)
            lines.append(f"  {uid}（{scopes_str}）")
    return "\n".join(lines)


async def _handle_command(
    conn,
    role_id: str,
    onebot_config: Dict,
    transformed: Dict[str, Any],
    message_id: Optional[int] = None,
) -> Optional[str]:
    """
    处理系统指令。返回指令执行结果文本（已发送给主用户），或 None 表示非指令。
    """
    content = transformed["content"].strip()
    if not content.startswith("/"):
        return None

    parts = content.split(maxsplit=1)
    cmd = parts[0].lower()
    arg = parts[1].strip() if len(parts) > 1 else ""

    conv_key = _build_conversation_key(transformed)
    reply = None

    if cmd == "/help":
        reply = _HELP_TEXT

    elif cmd == "/clear":
        from services.memory_service import clear_short_term_by_conversation
        clear_short_term_by_conversation(role_id, conv_key)
        reply = f"已清除 {conv_key} 的记忆"

    elif cmd == "/on":
        disabled = onebot_config.get("disabled_conversations") or []
        if conv_key in disabled:
            disabled.remove(conv_key)
            onebot_config["disabled_conversations"] = disabled
            _persist_onebot_config(role_id, onebot_config)
            reply = f"已开启 {conv_key} 的消息处理"
        else:
            reply = f"{conv_key} 未关闭，无需开启"

    elif cmd == "/off":
        disabled = onebot_config.get("disabled_conversations") or []
        if conv_key not in disabled:
            disabled.append(conv_key)
            onebot_config["disabled_conversations"] = disabled
            _persist_onebot_config(role_id, onebot_config)
            reply = f"已关闭 {conv_key} 的消息处理"
        else:
            reply = f"{conv_key} 已经关闭"

    elif cmd in ("/block", "/unblock"):
        # 解析 @用户 QQ号
        target_id = ""
        m = re.search(r'@(\d+)', arg)
        if m:
            target_id = m.group(1)
        elif arg.isdigit():
            target_id = arg
        if not target_id:
            reply = "请指定要操作的用户，格式：/block @用户"
        else:
            blocked = onebot_config.get("blocked_users") or {}
            if cmd == "/block":
                scopes = blocked.get(target_id)
                if scopes is None:
                    blocked[target_id] = [conv_key]
                    onebot_config["blocked_users"] = blocked
                    _persist_onebot_config(role_id, onebot_config)
                    reply = f"已在 {conv_key} 屏蔽用户 {target_id}"
                elif not scopes:
                    reply = f"用户 {target_id} 已被全局屏蔽"
                elif conv_key in scopes:
                    reply = f"用户 {target_id} 已在 {conv_key} 被屏蔽"
                else:
                    scopes.append(conv_key)
                    onebot_config["blocked_users"] = blocked
                    _persist_onebot_config(role_id, onebot_config)
                    reply = f"已在 {conv_key} 屏蔽用户 {target_id}"
            else:  # /unblock
                scopes = blocked.get(target_id)
                if scopes is None:
                    reply = f"用户 {target_id} 未被屏蔽"
                elif not scopes:
                    del blocked[target_id]
                    onebot_config["blocked_users"] = blocked
                    _persist_onebot_config(role_id, onebot_config)
                    reply = f"已取消对用户 {target_id} 的全局屏蔽"
                elif conv_key in scopes:
                    scopes.remove(conv_key)
                    if not scopes:
                        del blocked[target_id]
                    else:
                        blocked[target_id] = scopes
                    onebot_config["blocked_users"] = blocked
                    _persist_onebot_config(role_id, onebot_config)
                    reply = f"已在 {conv_key} 取消屏蔽用户 {target_id}"
                else:
                    reply = f"用户 {target_id} 未在 {conv_key} 被屏蔽"

    elif cmd == "/allow":
        if not arg and transformed.get("origin") == "onebot_group" and transformed.get("group_id"):
            allowed = onebot_config.get("allowed_groups") or []
            gid = transformed["group_id"]
            if gid not in allowed:
                allowed.append(gid)
                onebot_config["allowed_groups"] = allowed
                _persist_onebot_config(role_id, onebot_config)
                reply = f"已将群 {gid} 加入白名单"
            else:
                reply = f"群 {gid} 已在白名单中"
        else:
            target_id = ""
            m = re.search(r'@(\d+)', arg)
            if m:
                target_id = m.group(1)
            elif arg.isdigit():
                target_id = arg
            if not target_id:
                reply = "请指定要操作的用户，格式：/allow @用户（群聊中直接使用 /allow 可将当前群加入白名单）"
            else:
                uid = int(target_id)
                allowed = onebot_config.get("allowed_users") or []
                if uid not in allowed:
                    allowed.append(uid)
                    onebot_config["allowed_users"] = allowed
                    _persist_onebot_config(role_id, onebot_config)
                    reply = f"已将用户 {uid} 加入白名单"
                else:
                    reply = f"用户 {uid} 已在白名单中"

    elif cmd == "/disallow":
        if not arg and transformed.get("origin") == "onebot_group" and transformed.get("group_id"):
            allowed = onebot_config.get("allowed_groups") or []
            gid = transformed["group_id"]
            if gid in allowed:
                allowed.remove(gid)
                onebot_config["allowed_groups"] = allowed
                _persist_onebot_config(role_id, onebot_config)
                reply = f"已将群 {gid} 移出白名单"
            else:
                reply = f"群 {gid} 不在白名单中"
        else:
            target_id = ""
            m = re.search(r'@(\d+)', arg)
            if m:
                target_id = m.group(1)
            elif arg.isdigit():
                target_id = arg
            if not target_id:
                reply = "请指定要操作的用户，格式：/disallow @用户（群聊中直接使用 /disallow 可将当前群移出白名单）"
            else:
                uid = int(target_id)
                allowed = onebot_config.get("allowed_users") or []
                if uid in allowed:
                    allowed.remove(uid)
                    onebot_config["allowed_users"] = allowed
                    _persist_onebot_config(role_id, onebot_config)
                    reply = f"已将用户 {uid} 移出白名单"
                else:
                    reply = f"用户 {uid} 不在白名单中"

    elif cmd == "/random":
        sub = arg.split()
        if sub and sub[0] == "set" and len(sub) >= 3:
            try:
                new_rate = float(sub[1])
                new_burst = int(sub[2])
                if not (0 <= new_rate <= 1):
                    reply = "随机概率必须在 0~1 之间"
                elif new_burst < 1:
                    reply = "连续回复次数必须 >= 1"
                else:
                    cfg = _get_scene_config(onebot_config, conv_key)
                    cfg["rate"] = new_rate
                    cfg["burst"] = new_burst
                    _persist_onebot_config(role_id, onebot_config)
                    reply = f"已设置 {conv_key} 随机回复概率={new_rate}，连续回复次数={new_burst}"
            except (ValueError, TypeError):
                reply = "格式错误，正确格式：/random set <概率> <次数>"
        else:
            cfg = _get_scene_config(onebot_config, conv_key)
            reply = (
                f"随机回复配置（{conv_key}）：\n"
                f"  触发概率：{cfg['rate']}\n"
                f"  连续回复次数：{cfg['burst']}\n"
                f"  剩余免费回复：{cfg['remaining']}\n"
                f"  回复间隔：{cfg['interval']}小时"
            )

    elif cmd == "/proactive":
        sub = arg.split()
        if sub and sub[0] == "interval" and len(sub) >= 2:
            try:
                new_interval = float(sub[1])
                if new_interval < 0:
                    reply = "间隔时间不能为负数"
                else:
                    cfg = _get_scene_config(onebot_config, conv_key)
                    cfg["interval"] = new_interval
                    _persist_onebot_config(role_id, onebot_config)
                    reply = f"已设置 {conv_key} 主动回复间隔为 {new_interval} 小时"
            except (ValueError, TypeError):
                reply = "格式错误，正确格式：/proactive interval <小时>"
        elif sub and sub[0] in ("on", "off"):
            cfg = _get_scene_config(onebot_config, conv_key)
            cfg["enabled"] = (sub[0] == "on")
            _persist_onebot_config(role_id, onebot_config)
            reply = f"已{'开启' if sub[0] == 'on' else '关闭'} {conv_key} 的主动回复模式"
        else:
            cfg = _get_scene_config(onebot_config, conv_key)
            enabled = cfg.get("enabled", False)
            reply = (
                f"主动回复模式（{conv_key}）：{'已开启' if enabled else '已关闭'}\n"
                f"  回复间隔：{cfg['interval']}小时\n"
                f"  提示：/proactive on 开启，/proactive off 关闭，"
                f"/proactive interval <小时> 设置间隔"
            )

    if reply is not None:
        await _send_reply(conn, transformed, reply, raw=True, message_id=message_id, image_paths=[])
    return reply


async def _handle_command_http(
    role_id: str,
    onebot_config: Dict,
    transformed: Dict[str, Any],
) -> Optional[str]:
    """处理系统指令（HTTP POST 模式，不发送 WS 回复，仅返回结果）"""
    content = transformed["content"].strip()
    if not content.startswith("/"):
        return None

    parts = content.split(maxsplit=1)
    cmd = parts[0].lower()
    arg = parts[1].strip() if len(parts) > 1 else ""

    conv_key = _build_conversation_key(transformed)

    if cmd == "/help":
        return _HELP_TEXT

    if cmd == "/clear":
        from services.memory_service import clear_short_term_by_conversation
        clear_short_term_by_conversation(role_id, conv_key)
        return f"已清除 {conv_key} 的记忆"

    if cmd == "/on":
        disabled = onebot_config.get("disabled_conversations") or []
        if conv_key in disabled:
            disabled.remove(conv_key)
            onebot_config["disabled_conversations"] = disabled
            _persist_onebot_config(role_id, onebot_config)
            return f"已开启 {conv_key} 的消息处理"
        return f"{conv_key} 未关闭，无需开启"

    if cmd == "/off":
        disabled = onebot_config.get("disabled_conversations") or []
        if conv_key not in disabled:
            disabled.append(conv_key)
            onebot_config["disabled_conversations"] = disabled
            _persist_onebot_config(role_id, onebot_config)
            return f"已关闭 {conv_key} 的消息处理"
        return f"{conv_key} 已经关闭"

    if cmd in ("/block", "/unblock"):
        target_id = ""
        m = re.search(r'@(\d+)', arg)
        if m:
            target_id = m.group(1)
        elif arg.isdigit():
            target_id = arg
        if not target_id:
            return "请指定要操作的用户，格式：/block @用户"
        blocked = onebot_config.get("blocked_users") or {}
        if cmd == "/block":
            scopes = blocked.get(target_id)
            if scopes is None:
                blocked[target_id] = [conv_key]
                onebot_config["blocked_users"] = blocked
                _persist_onebot_config(role_id, onebot_config)
                return f"已在 {conv_key} 屏蔽用户 {target_id}"
            if not scopes:
                return f"用户 {target_id} 已被全局屏蔽"
            if conv_key in scopes:
                return f"用户 {target_id} 已在 {conv_key} 被屏蔽"
            scopes.append(conv_key)
            onebot_config["blocked_users"] = blocked
            _persist_onebot_config(role_id, onebot_config)
            return f"已在 {conv_key} 屏蔽用户 {target_id}"
        else:  # /unblock
            scopes = blocked.get(target_id)
            if scopes is None:
                return f"用户 {target_id} 未被屏蔽"
            if not scopes:
                del blocked[target_id]
                onebot_config["blocked_users"] = blocked
                _persist_onebot_config(role_id, onebot_config)
                return f"已取消对用户 {target_id} 的全局屏蔽"
            if conv_key in scopes:
                scopes.remove(conv_key)
                if not scopes:
                    del blocked[target_id]
                else:
                    blocked[target_id] = scopes
                onebot_config["blocked_users"] = blocked
                _persist_onebot_config(role_id, onebot_config)
                return f"已在 {conv_key} 取消屏蔽用户 {target_id}"
            return f"用户 {target_id} 未在 {conv_key} 被屏蔽"

    if cmd == "/allow":
        if not arg and transformed.get("origin") == "onebot_group" and transformed.get("group_id"):
            allowed = onebot_config.get("allowed_groups") or []
            gid = transformed["group_id"]
            if gid not in allowed:
                allowed.append(gid)
                onebot_config["allowed_groups"] = allowed
                _persist_onebot_config(role_id, onebot_config)
                return f"已将群 {gid} 加入白名单"
            return f"群 {gid} 已在白名单中"
        else:
            target_id = ""
            m = re.search(r'@(\d+)', arg)
            if m:
                target_id = m.group(1)
            elif arg.isdigit():
                target_id = arg
            if not target_id:
                return "请指定要操作的用户，格式：/allow @用户（群聊中直接使用 /allow 可将当前群加入白名单）"
            uid = int(target_id)
            allowed = onebot_config.get("allowed_users") or []
            if uid not in allowed:
                allowed.append(uid)
                onebot_config["allowed_users"] = allowed
                _persist_onebot_config(role_id, onebot_config)
                return f"已将用户 {uid} 加入白名单"
            return f"用户 {uid} 已在白名单中"

    if cmd == "/disallow":
        if not arg and transformed.get("origin") == "onebot_group" and transformed.get("group_id"):
            allowed = onebot_config.get("allowed_groups") or []
            gid = transformed["group_id"]
            if gid in allowed:
                allowed.remove(gid)
                onebot_config["allowed_groups"] = allowed
                _persist_onebot_config(role_id, onebot_config)
                return f"已将群 {gid} 移出白名单"
            return f"群 {gid} 不在白名单中"
        else:
            target_id = ""
            m = re.search(r'@(\d+)', arg)
            if m:
                target_id = m.group(1)
            elif arg.isdigit():
                target_id = arg
            if not target_id:
                return "请指定要操作的用户，格式：/disallow @用户（群聊中直接使用 /disallow 可将当前群移出白名单）"
            uid = int(target_id)
            allowed = onebot_config.get("allowed_users") or []
            if uid in allowed:
                allowed.remove(uid)
                onebot_config["allowed_users"] = allowed
                _persist_onebot_config(role_id, onebot_config)
                return f"已将用户 {uid} 移出白名单"
            return f"用户 {uid} 不在白名单中"

    if cmd == "/random":
        sub = arg.split()
        if sub and sub[0] == "set" and len(sub) >= 3:
            try:
                new_rate = float(sub[1])
                new_burst = int(sub[2])
                if not (0 <= new_rate <= 1):
                    return "随机概率必须在 0~1 之间"
                if new_burst < 1:
                    return "连续回复次数必须 >= 1"
                cfg = _get_scene_config(onebot_config, conv_key)
                cfg["rate"] = new_rate
                cfg["burst"] = new_burst
                _persist_onebot_config(role_id, onebot_config)
                return f"已设置 {conv_key} 随机回复概率={new_rate}，连续回复次数={new_burst}"
            except (ValueError, TypeError):
                return "格式错误，正确格式：/random set <概率> <次数>"
        cfg = _get_scene_config(onebot_config, conv_key)
        return (
            f"随机回复配置（{conv_key}）：\n"
            f"  触发概率：{cfg['rate']}\n"
            f"  连续回复次数：{cfg['burst']}\n"
            f"  剩余免费回复：{cfg['remaining']}\n"
            f"  回复间隔：{cfg['interval']}小时"
        )

    if cmd == "/proactive":
        sub = arg.split()
        if sub and sub[0] == "interval" and len(sub) >= 2:
            try:
                new_interval = float(sub[1])
                if new_interval < 0:
                    return "间隔时间不能为负数"
                cfg = _get_scene_config(onebot_config, conv_key)
                cfg["interval"] = new_interval
                _persist_onebot_config(role_id, onebot_config)
                return f"已设置 {conv_key} 主动回复间隔为 {new_interval} 小时"
            except (ValueError, TypeError):
                return "格式错误，正确格式：/proactive interval <小时>"
        if sub and sub[0] in ("on", "off"):
            cfg = _get_scene_config(onebot_config, conv_key)
            cfg["enabled"] = (sub[0] == "on")
            _persist_onebot_config(role_id, onebot_config)
            return f"已{'开启' if sub[0] == 'on' else '关闭'} {conv_key} 的主动回复模式"
        cfg = _get_scene_config(onebot_config, conv_key)
        enabled = cfg.get("enabled", False)
        return (
            f"主动回复模式（{conv_key}）：{'已开启' if enabled else '已关闭'}\n"
            f"  回复间隔：{cfg['interval']}小时\n"
            f"  提示：/proactive on 开启，/proactive off 关闭，"
            f"/proactive interval <小时> 设置间隔"
        )

    if cmd == "/blocklist":
        return _build_blocklist_text(onebot_config)

    return None


# ========== WebSocket 端点 ==========

async def onebot_ws_endpoint(websocket: WebSocket, role_id: str):
    """反向 WebSocket 端点：NapCat 连接到此"""
    from main import CONFIG

    # 检查全局开关
    if not CONFIG.get("onebot_enabled", True):
        logger.warning("OneBot WS 拒绝: 全局开关关闭")
        await websocket.accept()
        await websocket.close(code=1008, reason="OneBot interface disabled")
        return

    # 加载角色配置
    profile_file = ROLES_DIR / role_id / "profile.json"
    if not profile_file.exists():
        logger.warning(f"OneBot WS 拒绝: 角色 {role_id} 不存在")
        await websocket.accept()
        await websocket.close(code=1008, reason=f"角色 {role_id} 不存在")
        return

    try:
        with open(profile_file, "r", encoding="utf-8") as f:
            role_data = json.load(f)
    except Exception:
        await websocket.accept()
        await websocket.close(code=1011, reason="读取角色配置失败")
        return

    onebot_config = role_data.get("onebot_config") or {}
    if not onebot_config.get("enabled", False):
        logger.warning(f"OneBot WS 拒绝: 角色 {role_id} 未启用 OneBot (onebot_config={onebot_config})")
        await websocket.accept()
        await websocket.close(code=1008, reason=f"角色 {role_id} 未启用 OneBot 接口")
        return

    # 鉴权：支持 Authorization header、query param、首条消息 token
    # OneBot 通道豁免全局鉴权，安全完全依赖 per-role secret。启用但未配置 secret 视为
    # 配置错误，一律拒绝——绝不把空 secret 当作“关闭鉴权”。
    expected_secret = str(onebot_config.get("secret") or "").strip()
    first_data: Optional[Dict] = None

    if not expected_secret:
        logger.warning(f"OneBot WS 拒绝：角色 {role_id} 已启用 OneBot 但未配置 secret")
        await websocket.accept()
        await websocket.close(code=1008, reason="OneBot secret not configured")
        return

    auth_ok = False

    # 1. Authorization: Bearer <token>
    auth_header = websocket.headers.get("authorization", "")
    if auth_header.lower().startswith("bearer "):
        if hmac.compare_digest(auth_header[7:].strip(), expected_secret):
            auth_ok = True

    # 2. X-OneBot-Secret header
    if not auth_ok:
        x_secret = websocket.headers.get("x-onebot-secret", "")
        if hmac.compare_digest(x_secret, expected_secret):
            auth_ok = True

    # 3. Query param
    if not auth_ok:
        if hmac.compare_digest(websocket.query_params.get("access_token", ""), expected_secret):
            auth_ok = True

    # 4. 首条消息 token 字段
    if not auth_ok:
        try:
            first_text = await asyncio.wait_for(websocket.receive_text(), timeout=10.0)
            first_data = json.loads(first_text)
            body_token = str(
                first_data.get("token")
                or first_data.get("access_token")
                or first_data.get("secret")
                or ""
            ).strip()
            if hmac.compare_digest(body_token, expected_secret):
                auth_ok = True
        except (asyncio.TimeoutError, Exception):
            pass

    if not auth_ok:
        logger.warning(f"OneBot WS 鉴权失败: role={role_id}")
        await websocket.accept()
        await websocket.close(code=1008, reason="Invalid token")
        return

    # 接受连接
    await websocket.accept()
    try:
        effective_self_id = int(onebot_config.get("self_id") or onebot_config.get("selfId") or 0)
    except (TypeError, ValueError):
        effective_self_id = 0
    conn = await ws_manager.connect(websocket, role_id, self_id=effective_self_id)
    server_url = _build_server_url(websocket)
    logger.info(f"OneBot WS 连接建立: role={role_id}, self_id={effective_self_id}, server_url={server_url}")

    # 如果首条消息已读取（通过 body 鉴权时），先处理它
    if first_data is not None:
        try:
            await _handle_ws_frame(conn, role_id, onebot_config, first_data, server_url=server_url)
        except Exception as e:
            logger.error(f"OneBot WS 首条消息处理失败: {e}")

    # 消息循环
    try:
        while True:
            text = await websocket.receive_text()
            try:
                data = json.loads(text)
            except json.JSONDecodeError:
                continue

            # 处理 echo 响应（NapCat 对 API 调用的回复）
            if "echo" in data and "retcode" in data:
                conn.resolve_echo(data["echo"], data)
                continue

            # 每条消息重新加载配置（支持热更新）
            try:
                with open(profile_file, "r", encoding="utf-8") as f:
                    onebot_config = (json.load(f).get("onebot_config") or {})
            except Exception:
                pass

            # 处理事件
            await _handle_ws_frame(conn, role_id, onebot_config, data, server_url=server_url)

    except WebSocketDisconnect:
        pass
    except Exception as e:
        logger.error(f"OneBot WS 异常: role={role_id}, error={e}")
    finally:
        ws_manager.disconnect(role_id)


async def _handle_ws_frame(
    conn,
    role_id: str,
    onebot_config: Dict,
    data: Dict,
    server_url: str = SERVER_URL_FALLBACK,
):
    """处理单个 WebSocket 事件帧（聚合后统一处理）"""
    event = OneBotEvent(**data)
    try:
        effective_self_id = int(onebot_config.get("self_id") or onebot_config.get("selfId") or 0)
    except (TypeError, ValueError):
        effective_self_id = 0
    transformed = _transform_event(event, self_id=effective_self_id or event.self_id)

    if transformed is None:
        return

    # 传递服务器 URL（OneBot 发送表情图片时通过 HTTP 而非 file:///）
    transformed["_server_url"] = onebot_config.get("server_url") or server_url

    # 主QQ号判断：先识别发送者身份（需要在白名单过滤之前）
    try:
        main_user_id = int(onebot_config.get("main_user_id", 0) or 0)
    except (TypeError, ValueError):
        main_user_id = 0
    if main_user_id and transformed["user_id"] == main_user_id:
        transformed["sender"] = "user"

    # 群聊 @ 检测：所有用户（包括主用户）都需要 @机器人才会处理
    # 但主用户的 / 指令不需要 @（否则无法执行管理指令）
    if transformed["origin"] == "onebot_group":
        is_command = transformed["sender"] == "user" and transformed["content"].startswith("/")
        if not is_command:
            config_self_id = onebot_config.get("self_id") or onebot_config.get("selfId")
            effective_self_id = config_self_id or event.self_id
            if not _is_at_bot(event.message, effective_self_id):
                conv_key = _build_conversation_key(transformed)
                # 不在白名单的群聊不检查自动回复
                if transformed["origin"] == "onebot_group":
                    allowed_groups = onebot_config.get("allowed_groups") or []
                    if transformed["group_id"] not in allowed_groups:
                        logger.debug(f"OneBot 群聊不在白名单，跳过随机回复: group={transformed['group_id']}")
                        return
                if _check_random_reply(onebot_config, role_id, time.time(), conv_key):
                    logger.debug(f"OneBot 随机回复放行: role={role_id}, sender={transformed['sender']}")
                else:
                    logger.debug(f"OneBot 群消息未 @机器人: role={role_id}, sender={transformed['sender']}")
                    return

    # 白名单过滤（主用户不受白名单限制，否则无法在未授权群聊执行 /allow 等指令）
    if transformed["sender"] != "user":
        reject_reason = _check_whitelist(transformed, event, onebot_config)
        if reject_reason:
            logger.debug(f"OneBot 消息过滤: {reject_reason}")
            return

    # 系统指令拦截（仅主用户的识别命令跳过聚合，直接执行）
    if transformed["sender"] == "user" and transformed["content"].startswith("/"):
        cmd_result = await _handle_command(conn, role_id, onebot_config, transformed, message_id=event.message_id)
        if cmd_result is not None:
            return  # 指令已处理，不进入聚合

    # 会话关闭 / 用户屏蔽检查
    block_reason = _check_disabled_or_blocked(transformed, onebot_config)
    if block_reason:
        logger.debug(f"OneBot 消息拦截: {block_reason}")
        return

    # 加入聚合队列（15秒内同用户消息合并后统一处理）
    transformed["_role_id"] = role_id
    _enqueue(transformed, event.message_id, conn)


# ========== HTTP POST 端点（备用）==========

@router.post("/onebot/{role_id}/event")
async def handle_onebot_event(
    role_id: str,
    request: Request,
):
    """接收 OneBot V11 HTTP POST 事件（备用接口）"""
    from main import CONFIG

    if not CONFIG.get("onebot_enabled", True):
        raise HTTPException(status_code=403, detail="OneBot interface disabled")

    profile_file = ROLES_DIR / role_id / "profile.json"
    if not profile_file.exists():
        raise HTTPException(status_code=404, detail=f"角色 {role_id} 不存在")

    try:
        with open(profile_file, "r", encoding="utf-8") as f:
            role_data = json.load(f)
    except Exception:
        raise HTTPException(status_code=500, detail="读取角色配置失败")

    onebot_config = role_data.get("onebot_config") or {}
    if not onebot_config.get("enabled", False):
        raise HTTPException(status_code=403, detail=f"角色 {role_id} 未启用 OneBot 接口")

    try:
        raw_body = await request.body()
        body = json.loads(raw_body.decode("utf-8")) if raw_body else {}
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid JSON body")

    # 鉴权：OneBot 通道豁免全局 X-Auth-Token 与加密，安全完全依赖 per-role secret。
    # 因此启用 OneBot 但未设置 secret 视为配置错误，一律拒绝——绝不把空 secret 当作“关闭鉴权”。
    expected_secret = str(onebot_config.get("secret") or "").strip()
    if not expected_secret:
        logger.warning(f"OneBot HTTP 拒绝：角色 {role_id} 已启用 OneBot 但未配置 secret")
        raise HTTPException(status_code=401, detail="OneBot secret not configured")

    auth_ok = False
    x_signature = request.headers.get("x-signature", "")
    if x_signature:
        auth_ok = _verify_signature(raw_body, expected_secret, x_signature)
    if not auth_ok:
        for header_name in ("x-onebot-secret", "authorization", "x-auth-token"):
            val = request.headers.get(header_name, "").strip()
            if val:
                if header_name == "authorization" and val.lower().startswith("bearer "):
                    val = val[7:].strip()
                if hmac.compare_digest(val, expected_secret):
                    auth_ok = True
                break
    if not auth_ok:
        if hmac.compare_digest(request.query_params.get("access_token", ""), expected_secret):
            auth_ok = True
    if not auth_ok and isinstance(body, dict):
        body_token = str(
            body.get("token") or body.get("access_token") or body.get("secret") or ""
        ).strip()
        if hmac.compare_digest(body_token, expected_secret):
            auth_ok = True
    if not auth_ok:
        raise HTTPException(status_code=401, detail="Invalid OneBot secret")

    event = OneBotEvent(**body)
    try:
        effective_self_id = int(onebot_config.get("self_id") or onebot_config.get("selfId") or 0)
    except (TypeError, ValueError):
        effective_self_id = 0
    transformed = _transform_event(event, self_id=effective_self_id or event.self_id)

    if transformed is None:
        return {"status": "ignored", "reason": "not a message event or empty content"}

    # 传递服务器 URL（HTTP 传输图片时使用）
    transformed["_server_url"] = str(request.base_url).rstrip("/")

    # 主QQ号判断：先识别发送者身份（需要在白名单过滤之前）
    try:
        main_user_id = int(onebot_config.get("main_user_id", 0) or 0)
    except (TypeError, ValueError):
        main_user_id = 0
    if main_user_id and transformed["user_id"] == main_user_id:
        transformed["sender"] = "user"

    # 群聊 @ 检测：所有用户（包括主用户）都需要 @机器人才会处理
    if transformed["origin"] == "onebot_group":
        is_command = transformed["sender"] == "user" and transformed["content"].startswith("/")
        if not is_command:
            config_self_id = onebot_config.get("self_id") or onebot_config.get("selfId")
            effective_self_id = config_self_id or event.self_id
            if not _is_at_bot(event.message, effective_self_id):
                conv_key = _build_conversation_key(transformed)
                if _check_random_reply(onebot_config, role_id, time.time(), conv_key):
                    logger.debug(f"OneBot HTTP 随机回复放行: role={role_id}")
                else:
                    return {"status": "ignored", "reason": "not @bot"}

    # 白名单过滤（主用户不受白名单限制）
    if transformed["sender"] != "user":
        reject_reason = _check_whitelist(transformed, event, onebot_config)
        if reject_reason:
            return {"status": "ignored", "reason": reject_reason}

    # 系统指令拦截（仅主用户）
    if transformed["sender"] == "user" and transformed["content"].startswith("/"):
        conn = ws_manager.get_connection(role_id)
        if conn:
            cmd_result = await _handle_command(conn, role_id, onebot_config, transformed, message_id=event.message_id)
        else:
            cmd_result = await _handle_command_http(role_id, onebot_config, transformed)
        if cmd_result is not None:
            return {"status": "ok", "reply": cmd_result, "success": True, "is_command": True}

    # 会话关闭 / 用户屏蔽检查
    block_reason = _check_disabled_or_blocked(transformed, onebot_config)
    if block_reason:
        return {"status": "ignored", "reason": block_reason}

    logger.info(
        f"OneBot HTTP 消息接收: role={role_id}, type={event.message_type}, "
        f"user={event.user_id}, sender={transformed['sender']}, "
        f"origin={transformed['origin']}, content={transformed['content']}"
    )

    # AI 处理
    try:
        reply_text, image_paths = await _process_and_reply(role_id, transformed, event.message_id)
        reply_text = _strip_action_descriptions(reply_text)
    except Exception as e:
        logger.error(f"OneBot AI 处理失败: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail="内部处理错误")

    # 如果有 WS 连接，尝试通过 WS 发送回复
    conn = ws_manager.get_connection(role_id)
    if conn and (reply_text or image_paths):
        try:
            await _send_reply(conn, transformed, reply_text, message_id=event.message_id, image_paths=image_paths)
        except Exception as e:
            logger.error(f"OneBot WS 回复发送失败: {e}")

    return {
        "status": "ok",
        "reply": reply_text,
        "success": True,
    }

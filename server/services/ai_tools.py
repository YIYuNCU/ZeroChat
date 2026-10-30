"""
AI 工具定义与执行器
管理 AI 可调用的 function-calling 工具（定时任务、用户屏蔽等）
"""
import asyncio
import json
import logging
import random
import re
import uuid
from contextvars import ContextVar
from datetime import date as _date, datetime, time as _dtime, timedelta
from pathlib import Path
from typing import Dict, List, Optional

from core.utils import ensure_direct_child_path
from services import scheduler_service
from services.tool_registry import build_tool

logger = logging.getLogger(__name__)

DATA_DIR = Path(__file__).parent.parent / "data"
TASKS_FILE = DATA_DIR / "tasks" / "scheduled.json"
ROLES_DIR = DATA_DIR / "roles"

#: 本轮对话发生的平台（"app" / "qq"），由 generate_with_role 在入口设置。
#: 工具（如 schedule_task）据此记录提醒应送达的平台，避免把 origin 逐层传进工具执行器。
current_platform: ContextVar[str] = ContextVar("zerochat_chat_platform", default="app")


def _role_dir(role_id: str) -> Path:
    return ensure_direct_child_path(ROLES_DIR, role_id, "role_id")


def _emoji_root(role_id: str) -> Path:
    return ensure_direct_child_path(_role_dir(role_id), "emojis", "emoji root")


def _emoji_dir(role_id: str, emotion: str) -> Path:
    return ensure_direct_child_path(_emoji_root(role_id), emotion, "emotion")

# ========== 工具定义 ==========

"""
定时任务工具：允许 AI 在对话中主动创建定时提醒。
对所有场景开放。
"""
_SCHEDULE_TASK_TOOL = build_tool("schedule_task", {
    "message": {"type": "string"},
    "trigger_time": {"type": "string"},
    "repeat": {"type": "string", "enum": ["none", "daily", "weekly"]},
})

"""
系统闹钟/日历工具：允许 AI 请求在用户设备上设置系统闹钟或写入日历事件。
与 schedule_task 不同：schedule_task 是应用内的定时消息提醒；set_alarm 会
落到用户手机的系统闹钟 App 或系统日历，由客户端执行。仅对有设备的场景开放。
"""
_SET_ALARM_TOOL = build_tool("set_alarm", {
    "title": {"type": "string"},
    "trigger_time": {"type": "string"},
    "kind": {"type": "string", "enum": ["alarm", "calendar_event"]},
    "note": {"type": "string"},
})

"""
无回复续写工具：允许 AI 在说完话后设置一个「若用户在指定时长内没有回复就继续说」的计时器。
用户一旦回复，续写会自动取消。支持链式续写，但受角色配置的最大续写次数限制。
仅对有设备的场景开放。
"""
_CONTINUE_IF_NO_REPLY_TOOL = build_tool("continue_if_no_reply", {
    "delay_minutes": {"type": "integer"},
    "prompt": {"type": "string"},
})

"""
屏蔽用户工具：允许 AI 屏蔽第三方用户的骚扰消息。
仅对 OneBot 第三方用户消息场景开放。
"""
_BLOCK_USER_TOOL = build_tool("block_user", {
    "user_id": {"type": "string"},
    "reason": {"type": "string"},
})


# ========== 工具执行器 ==========

async def execute_schedule_task(role_data: Dict, message: str, trigger_time: str, repeat: str = "none") -> str:
    """创建定时任务，返回结果描述"""
    role_id = role_data.get("id", "")
    role_name = role_data.get("name", role_id)

    # 解析并验证时间
    try:
        run_time = datetime.fromisoformat(trigger_time)
        if run_time < datetime.now():
            return f"创建失败：触发时间 {trigger_time} 已过期，请选择未来的时间"
    except ValueError as e:
        return f"创建失败：时间格式无效（{e}），请使用 ISO 8601 格式"

    task_record = {
        "id": str(uuid.uuid4()),
        "chat_id": role_id,
        "role_id": role_id,
        "message": message,
        "ai_prompt": "",
        "trigger_time": run_time.isoformat(),
        "repeat": repeat if repeat != "none" else None,
        "enabled": True,
        "created_at": datetime.now().isoformat(),
    }
    if current_platform.get() == "qq":
        # 仅 QQ 来源记录该字段，App 创建的任务记录与旧版逐字段一致
        task_record["platform"] = "qq"

    try:
        TASKS_FILE.parent.mkdir(parents=True, exist_ok=True)
        tasks = []
        if TASKS_FILE.exists():
            with open(TASKS_FILE, "r", encoding="utf-8") as f:
                tasks = json.load(f)

        tasks.append(task_record)
        with open(TASKS_FILE, "w", encoding="utf-8") as f:
            json.dump(tasks, f, indent=2, ensure_ascii=False)

        scheduler_service.schedule_task(task_record)

        # 通知在线客户端立即刷新任务列表，使 AI 自建任务在设置页可见
        try:
            from transport.push_hub import publish_server_push
            await publish_server_push(
                "task_created",
                {
                    "role_id": role_id,
                    "chat_id": task_record["chat_id"],
                    "task_id": task_record["id"],
                },
            )
        except Exception as e:
            logger.debug(f"task_created 推送失败（不影响任务创建）: {e}")

        repeat_hint = "" if repeat == "none" else f"（重复：{repeat}）"
        logger.info(f"AI创建定时任务: role={role_name}({role_id}), time={trigger_time}, msg={message}{repeat_hint}")
        return f"定时任务已创建：在 {trigger_time} 提醒「{message}」{repeat_hint}"
    except Exception as e:
        return f"创建失败：{e}"


async def execute_set_alarm(
    role_data: Dict,
    title: str,
    trigger_time: str,
    kind: str = "alarm",
    note: str = "",
) -> str:
    """请求在用户设备上设置系统闹钟/日历事件，通过推送信令交由客户端执行。"""
    role_id = role_data.get("id", "")
    role_name = role_data.get("name", role_id)

    title = (title or "").strip()
    if not title:
        return "设置失败：标题为空"

    kind = (kind or "alarm").strip().lower()
    if kind not in ("alarm", "calendar_event"):
        kind = "alarm"

    # 解析并验证时间
    try:
        run_time = datetime.fromisoformat(trigger_time)
        if run_time < datetime.now():
            return f"设置失败：时间 {trigger_time} 已过期，请选择未来的时间"
    except ValueError as e:
        return f"设置失败：时间格式无效（{e}），请使用 ISO 8601 格式"

    try:
        from transport.push_hub import publish_server_push
        await publish_server_push(
            "device_alarm_request",
            {
                "role_id": role_id,
                "title": title,
                "trigger_time": run_time.isoformat(),
                "kind": kind,
                "note": (note or "").strip(),
            },
        )
    except Exception as e:
        logger.error(f"set_alarm 推送失败 role={role_id}: {e}")
        return f"设置失败：{e}"

    kind_hint = "系统闹钟" if kind == "alarm" else "日历事件"
    logger.info(
        f"AI设置{kind_hint}: role={role_name}({role_id}), time={trigger_time}, title={title}"
    )
    return (
        f"已请求在设备上设置{kind_hint}：{title}（{trigger_time}）。"
        "若设备未授予权限，可能会降级为应用内提醒。"
    )


async def execute_continue_if_no_reply(
    role_data: Dict,
    delay_minutes: int,
    prompt: str,
) -> str:
    """登记「无回复续写」计时器，返回结果描述。"""
    role_id = role_data.get("id", "")
    role_name = role_data.get("name", role_id)

    # 校验时长
    try:
        delay = int(delay_minutes)
    except (TypeError, ValueError):
        return "设置失败：delay_minutes 必须是整数分钟数"
    if delay < 1:
        return "设置失败：delay_minutes 至少为 1 分钟"

    prompt = (prompt or "").strip()
    if not prompt:
        return "设置失败：prompt 不能为空，请说明续写时想继续说什么"

    # 读取角色续写配置
    profile_file = _role_dir(role_id) / "profile.json"
    followup_config = {}
    try:
        if profile_file.exists():
            with open(profile_file, "r", encoding="utf-8") as f:
                role_content = json.load(f)
            followup_config = role_content.get("followup_config") or {}
    except Exception as e:
        logger.warning(f"读取续写配置失败 role={role_id}: {e}")

    if not followup_config.get("enabled", True):
        return "该角色未启用「无回复续写」功能，无法设置"

    max_chain = max(1, int(followup_config.get("max_chain", 3)))

    from services import scheduler_service

    # 当前链计数：已排程状态中的 chain_count（无则 0）
    current_state = scheduler_service._load_followups().get(role_id) or {}
    current_chain = int(current_state.get("chain_count", 0))
    if current_chain >= max_chain:
        return (
            f"已达到最大续写次数（{max_chain} 次），无法继续安排跟进，"
            "请自然收尾，不要再等待用户回复。"
        )

    next_chain = current_chain + 1
    try:
        scheduler_service.schedule_followup(
            role_id,
            delay_minutes=delay,
            prompt=prompt,
            chain_count=next_chain,
            chat_id=role_id,
        )
    except Exception as e:
        logger.error(f"continue_if_no_reply 排程失败 role={role_id}: {e}")
        return f"设置失败：{e}"

    logger.info(
        f"AI设置无回复续写: role={role_name}({role_id}), delay={delay}min, "
        f"chain={next_chain}/{max_chain}"
    )
    remaining = max_chain - next_chain
    tail = "（这已是最后一次跟进）" if remaining <= 0 else ""
    return f"已设置：若 {delay} 分钟内用户未回复，将继续跟进{tail}"


async def execute_block_user(role_data: Dict, user_id: str, reason: str) -> str:
    """屏蔽用户，返回结果描述"""
    from services.chat_io_service import role_lock

    role_id = role_data.get("id", "")
    profile_file = _role_dir(role_id) / "profile.json"

    try:
        # 与 roles.save_role / 生理周期镜像共用同一把角色档案锁，避免整份档案互相覆盖
        with role_lock(role_id):
            with open(profile_file, "r", encoding="utf-8") as f:
                role_content = json.load(f)
            onebot_config = role_content.get("onebot_config") or {}
            blocked = onebot_config.get("blocked_users") or {}

            if user_id not in blocked:
                blocked[user_id] = []
            onebot_config["blocked_users"] = blocked
            role_content["onebot_config"] = onebot_config

            with open(profile_file, "w", encoding="utf-8") as f:
                json.dump(role_content, f, ensure_ascii=False, indent=2)

        role_name = role_data.get("name", role_id)
        logger.warning(f"AI主动屏蔽用户: role={role_name}({role_id}), target={user_id}, reason={reason}")
        return f"已屏蔽用户 {user_id}，原因：{reason}"
    except Exception as e:
        return f"屏蔽失败：{e}"


# ========== 工具：语义记忆搜索 ==========

"""
向量记忆搜索工具：允许 AI 主动搜索历史记忆中的对话内容。
对所有场景开放。
"""
_SEARCH_MEMORY_TOOL = build_tool("search_memory", {
    "query": {"type": "string"},
})


async def execute_search_memory(role_data: Dict, query: str) -> str:
    """语义搜索历史记忆，返回结果描述"""
    role_id = role_data.get("id", "")
    query = query.strip()
    if not query:
        return "搜索失败：查询内容为空"

    from services.vector_memory import VectorMemoryStore
    from services.ai_service import generate_embedding

    try:
        store = VectorMemoryStore(role_id)
        if store.count() == 0:
            return "记忆库为空，暂未存储可搜索的历史记忆"

        result = await generate_embedding(query)
        if not result["success"] or not result["embedding"]:
            return f"记忆搜索失败：{result.get('error', '嵌入向量生成失败')}"

        results = store.search(result["embedding"], top_k=3, min_score=0.35)
        if not results:
            return f"未找到与「{query}」相关的历史记忆"

        lines = []
        for r in results:
            text = r.get("text", "")
            score = r.get("score", 0)
            source = r.get("source", "chat")
            occurred_at = r.get("timestamp") or "未知"
            recorded_at = r.get("created_at") or "未知"
            time_label = "事件/参考时间" if source == "memory_summary" else "发生时间"
            lines.append(
                f"- {text[:200]}（{time_label}:{occurred_at}, "
                f"记录时间:{recorded_at}, 来源:{source}, 相关度:{score:.2f}）"
            )
        return "找到以下相关记忆：\n" + "\n".join(lines)
    except Exception as e:
        logger.error(f"语义记忆搜索失败 role={role_id}: {e}")
        return f"记忆搜索失败：{e}"


# ========== 工具：朋友圈查看 ==========

"""
朋友圈查看工具：让 AI 主动翻看朋友圈（可按日期、发布人筛选）以及某条帖子的评论/点赞。
朋友圈内容属于主用户的私人数据，仅在 App 与主用户 QQ 私聊场景开放（见 generate_with_role）。
"""
_VIEW_MOMENTS_TOOL = build_tool("view_moments", {
    "date": {"type": "string"},
    "author": {"type": "string"},
    "limit": {"type": "integer"},
})

_VIEW_MOMENT_COMMENTS_TOOL = build_tool("view_moment_comments", {
    "post_id": {"type": "string"},
})

_MOMENTS_MAX_LIMIT = 20
_MOMENTS_DEFAULT_LIMIT = 10
_MOMENTS_LIST_CONTENT_CHARS = 300
_MOMENTS_COMMENT_CHARS = 300
_MOMENTS_MAX_COMMENTS = 50
_MOMENTS_USER_ID = "me"
_MOMENTS_USER_ALIASES = {"me", "user", "用户", "主人"}
_MOMENTS_SELF_ALIASES = {"self", "自己", "我", "你自己"}


def _load_visible_moments() -> List[dict]:
    """读取朋友圈并去掉工具角色帖子与重复帖，口径与前端朋友圈列表一致。"""
    from routers import moments as moments_router
    from core.utils import is_tool_role_id

    posts = [
        p for p in moments_router.load_moments()
        if isinstance(p, dict) and not is_tool_role_id(str(p.get("author_id", "")))
    ]
    posts = moments_router._dedupe_moments_for_render(posts)
    posts.sort(key=lambda x: str(x.get("created_at", "")), reverse=True)
    return posts


def _moment_time_label(value) -> str:
    try:
        return datetime.fromisoformat(str(value)).strftime("%Y-%m-%d %H:%M")
    except (TypeError, ValueError):
        return str(value or "未知时间")


def _moment_author_label(author_id: str, author_name: str, role_id: str) -> str:
    name = (author_name or author_id or "未知").strip()
    if author_id == _MOMENTS_USER_ID:
        return f"{name}（用户）"
    if author_id == role_id:
        return f"{name}（你自己）"
    return name


def _clip(text, limit: int) -> str:
    text = str(text or "").strip()
    return text if len(text) <= limit else text[:limit] + "…"


def _parse_moment_date(value: str) -> Optional[str]:
    """把 date 参数规整为 YYYY-MM-DD；无法识别时抛 ValueError。空串返回 None。"""
    raw = (value or "").strip()
    if not raw:
        return None
    today = datetime.now().date()
    keyword = raw.lower()
    if keyword in ("今天", "today"):
        return today.isoformat()
    if keyword in ("昨天", "yesterday"):
        return (today - timedelta(days=1)).isoformat()
    # 兼容模型传入完整时间戳，只取日期部分
    try:
        return datetime.fromisoformat(raw).date().isoformat()
    except ValueError:
        raise ValueError(raw) from None


def _match_moment_author(post: dict, author: str, role_id: str) -> bool:
    key = author.strip().lower()
    author_id = str(post.get("author_id", ""))
    if key in _MOMENTS_USER_ALIASES:
        return author_id == _MOMENTS_USER_ID
    if key in _MOMENTS_SELF_ALIASES:
        return author_id == role_id
    if key == author_id.lower():
        return True
    name = str(post.get("author_name", "")).strip().lower()
    return bool(name) and (key == name or key in name)


async def execute_view_moments(
    role_data: Dict, date: str = "", author: str = "", limit: int = _MOMENTS_DEFAULT_LIMIT,
) -> str:
    """按日期/发布人查看朋友圈列表，返回供模型阅读的文本。永不抛出。"""
    role_id = str(role_data.get("id", ""))
    try:
        day = _parse_moment_date(date)
    except ValueError:
        return f"查看失败：date「{date}」格式无效，请使用 YYYY-MM-DD，或「今天」「昨天」"
    try:
        limit = int(limit)
    except (TypeError, ValueError):
        limit = _MOMENTS_DEFAULT_LIMIT
    limit = max(1, min(limit, _MOMENTS_MAX_LIMIT))
    author = (author or "").strip()

    try:
        posts = await asyncio.to_thread(_load_visible_moments)
    except Exception as e:
        logger.error(f"朋友圈读取失败 role={role_id}: {e}")
        return f"查看失败：{e}"

    if day:
        posts = [p for p in posts if str(p.get("created_at", "")).startswith(day)]
    if author:
        posts = [p for p in posts if _match_moment_author(p, author, role_id)]

    filters = []
    if day:
        filters.append(f"日期 {day}")
    if author:
        filters.append(f"发布人「{author}」")
    scope = "（" + "，".join(filters) + "）" if filters else ""
    if not posts:
        return f"没有找到符合条件的朋友圈{scope}"

    total = len(posts)
    lines = [f"朋友圈{scope}，共 {total} 条，显示最新 {min(total, limit)} 条："]
    for post in posts[:limit]:
        post_id = str(post.get("id", ""))
        likes = [str(l.get("name") or l.get("id") or "") for l in (post.get("liked_by") or []) if isinstance(l, dict)]
        comments = post.get("comments") if isinstance(post.get("comments"), list) else []
        images = post.get("image_urls") or []
        head = (
            f"[{post_id[:8]}] "
            f"{_moment_author_label(str(post.get('author_id', '')), str(post.get('author_name', '')), role_id)}"
            f" · {_moment_time_label(post.get('created_at'))}"
        )
        meta = [f"评论 {len(comments)} 条", f"点赞 {len(likes)} 人"]
        if images:
            meta.append(f"配图 {len(images)} 张")
        content = _clip(post.get("content"), _MOMENTS_LIST_CONTENT_CHARS) or "（无文字）"
        lines.append(f"{head}\n  {content}\n  （{'，'.join(meta)}）")
    if total > limit:
        lines.append(f"……还有 {total - limit} 条更早的动态，可缩小日期/发布人范围或调大 limit 查看。")
    return "\n".join(lines)


async def execute_view_moment_comments(role_data: Dict, post_id: str) -> str:
    """查看指定朋友圈帖子的正文、点赞与全部评论，返回供模型阅读的文本。永不抛出。"""
    role_id = str(role_data.get("id", ""))
    key = (post_id or "").strip().strip("[]#")
    if not key:
        return "查看失败：post_id 不能为空"

    try:
        posts = await asyncio.to_thread(_load_visible_moments)
    except Exception as e:
        logger.error(f"朋友圈读取失败 role={role_id}: {e}")
        return f"查看失败：{e}"

    exact = [p for p in posts if str(p.get("id", "")) == key]
    matched = exact or [p for p in posts if str(p.get("id", "")).startswith(key)]
    if not matched:
        return f"没有找到 ID 为「{key}」的朋友圈，可能已被删除。请先用 view_moments 查看列表获取 post_id"
    if len(matched) > 1:
        return f"「{key}」匹配到多条朋友圈，请提供更长的 post_id"
    post = matched[0]

    author_id = str(post.get("author_id", ""))
    lines = [
        f"{_moment_author_label(author_id, str(post.get('author_name', '')), role_id)}"
        f" · {_moment_time_label(post.get('created_at'))}",
        _clip(post.get("content"), 2000) or "（无文字）",
    ]
    images = post.get("image_urls") or []
    if images:
        lines.append(f"（配图 {len(images)} 张）")

    likes = [str(l.get("name") or l.get("id") or "") for l in (post.get("liked_by") or []) if isinstance(l, dict)]
    lines.append("点赞：" + ("、".join(n for n in likes if n) if likes else "暂无"))

    comments = [c for c in (post.get("comments") or []) if isinstance(c, dict)]
    comments.sort(key=lambda c: str(c.get("created_at", "")))
    if not comments:
        lines.append("评论：暂无")
        return "\n".join(lines)

    shown = comments[-_MOMENTS_MAX_COMMENTS:]
    lines.append(f"评论（共 {len(comments)} 条，按时间从早到晚）：")
    if len(comments) > len(shown):
        lines.append(f"……省略更早的 {len(comments) - len(shown)} 条")
    for c in shown:
        c_author_id = str(c.get("author_id", ""))
        who = _moment_author_label(c_author_id, str(c.get("author_name", "")), role_id)
        reply_to = str(c.get("reply_to_name") or "").strip()
        target = f" 回复 {reply_to}" if reply_to else ""
        lines.append(
            f"- {_moment_time_label(c.get('created_at'))} {who}{target}："
            f"{_clip(c.get('content'), _MOMENTS_COMMENT_CHARS)}"
        )
    return "\n".join(lines)


# ========== 工具：聊天回顾（按时间/事件查阅历史聊天，由总结模型归纳后返回） ==========

"""
聊天回顾工具：让 AI 按时间范围和/或事件回看历史聊天。
原始聊天记录不会直接交给聊天模型，而是先由「聊天回顾总结」配置的模型
（前端可选模型档案，见 services/summary_config_service.py）阅读并归纳，只返回回顾文本。
聊天记录属于主用户的私人数据：仅 App 与主用户 QQ 私聊开放（见 generate_with_role），
查阅范围同样限定在 App 单聊、主动消息与主用户 QQ 私聊，不含群聊与第三方对话。
"""
_RECALL_CHAT_TOOL = build_tool("recall_chat_history", {
    "start_time": {"type": "string"},
    "end_time": {"type": "string"},
    "event": {"type": "string"},
})

#: 交给总结模型的聊天记录字符预算（含每条的时间与发言人开销）。
_RECALL_MAX_CHARS = 24000
_RECALL_LINE_OVERHEAD = 24
#: 单条消息送去总结前的最大长度。
_RECALL_MESSAGE_CLIP = 800
#: 单次最多读取的消息行数，防止对超长历史做全表读取。
_RECALL_FETCH_LIMIT = 5000
#: 超出预算按关键词筛选时，每个命中前后额外保留的消息条数。
_RECALL_NEIGHBORS = 2
_RECALL_SUMMARY_MAX_TOKENS = 1500
_RECALL_RESULT_MAX_CHARS = 3000

_RECALL_DATE_RE = re.compile(r"^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})$")
_RECALL_RELATIVE_DAYS = {"今天": 0, "today": 0, "昨天": 1, "yesterday": 1, "前天": 2}
#: 可回顾的会话范围：App 单聊、主动消息，以及主用户（sender=user）的 QQ 私聊（含 AI 回复）。
_RECALL_SCOPE_SQL = (
    "(origin IN ('zerochat', 'proactive') OR (origin = 'onebot_private' AND sender_id IN ("
    "SELECT DISTINCT sender_id FROM short_term "
    "WHERE origin = 'onebot_private' AND sender = 'user' AND COALESCE(sender_id, '') != '')))"
)


def is_recall_chat_available() -> bool:
    """聊天回顾总结已启用且 API 可解析时才向模型开放 recall_chat_history。"""
    try:
        from services import summary_config_service

        config = summary_config_service.resolve_summary_config(
            summary_config_service.CHAT_RECALL_SUMMARY
        )
        return bool(config.get("enabled") and config.get("configured"))
    except Exception:
        logger.warning("读取聊天回顾总结配置失败", exc_info=True)
        return False


def _parse_recall_time(value, *, end: bool):
    """解析时间参数，返回 (datetime | None, 是否仅日期)。无法识别时抛 ValueError。"""
    raw = str(value or "").strip()
    if not raw:
        return None, False
    key = raw.lower()
    day = None
    if key in _RECALL_RELATIVE_DAYS:
        day = (datetime.now() - timedelta(days=_RECALL_RELATIVE_DAYS[key])).date()
    else:
        match = _RECALL_DATE_RE.match(raw)
        if match:
            day = _date(int(match.group(1)), int(match.group(2)), int(match.group(3)))
    if day is not None:
        return datetime.combine(day, _dtime.max if end else _dtime.min), True
    parsed = datetime.fromisoformat(raw)
    if parsed.tzinfo is not None:
        # 存储的时间戳是服务器本地无时区时间，带时区的输入先换算到本地。
        parsed = parsed.astimezone().replace(tzinfo=None)
    return parsed, ":" not in raw


def _recall_time_label(value: datetime) -> str:
    return value.strftime("%Y-%m-%d %H:%M")


def _recall_range_label(start: Optional[datetime], end: Optional[datetime]) -> str:
    if start and end:
        return f"{_recall_time_label(start)} 至 {_recall_time_label(end)}"
    if start:
        return f"{_recall_time_label(start)} 起"
    if end:
        return f"截至 {_recall_time_label(end)}"
    return "全部历史"


def _fetch_recall_rows(role_id: str, start: Optional[datetime], end: Optional[datetime]):
    from services.memory_service import _get_connection

    clauses = ["COALESCE(sender, '') NOT IN ('system', 'memory_summary')", _RECALL_SCOPE_SQL]
    params: list = []
    if start:
        clauses.append("timestamp >= ?")
        params.append(start.isoformat())
    if end:
        clauses.append("timestamp <= ?")
        params.append(end.isoformat())
    sql = (
        "SELECT role, content, timestamp, sender FROM short_term "
        f"WHERE {' AND '.join(clauses)} ORDER BY id ASC LIMIT ?"
    )
    with _get_connection(role_id) as conn:
        return conn.execute(sql, params + [_RECALL_FETCH_LIMIT + 1]).fetchall()


def _recall_keywords(event: str) -> set:
    """从事件描述提取用于粗筛的关键词：英文数字词 + 中文双字组。"""
    text = (event or "").lower()
    keywords = set(re.findall(r"[a-z0-9]{2,}", text))
    for segment in re.findall(r"[\u4e00-\u9fff]+", text):
        if len(segment) == 1:
            keywords.add(segment)
        else:
            keywords.update(segment[i:i + 2] for i in range(len(segment) - 1))
    return keywords


def _select_recall_lines(lines: List[dict], event: str):
    """在字符预算内选取送去总结的消息，返回 (消息列表, 说明)。"""
    def cost(item: dict) -> int:
        return len(item["message"]) + _RECALL_LINE_OVERHEAD

    if sum(cost(item) for item in lines) <= _RECALL_MAX_CHARS:
        return lines, ""
    notes = []
    chosen = lines
    keywords = _recall_keywords(event)
    if keywords:
        hits = [
            index for index, item in enumerate(lines)
            if any(word in item["message"].lower() for word in keywords)
        ]
        if hits:
            keep = set()
            for index in hits:
                keep.update(range(max(0, index - _RECALL_NEIGHBORS),
                                  min(len(lines), index + _RECALL_NEIGHBORS + 1)))
            chosen = [lines[index] for index in sorted(keep)]
            notes.append("该范围内聊天记录过多，已按事件关键词筛选出相关片段（含前后文）")
    selected, used = [], 0
    for item in chosen:
        if used + cost(item) > _RECALL_MAX_CHARS:
            break
        used += cost(item)
        selected.append(item)
    if len(selected) < len(chosen):
        notes.append(
            f"篇幅所限只提供了其中最早的 {len(selected)} 条（共 {len(chosen)} 条），"
            "之后的内容未被分析，建议缩小时间范围"
        )
    return selected, "；".join(notes)


async def execute_recall_chat_history(
    role_data: Dict, start_time: str = "", end_time: str = "", event: str = "",
) -> str:
    """按时间/事件读取历史聊天并交给总结模型归纳，返回供聊天模型阅读的回顾文本。永不抛出。"""
    role_id = str(role_data.get("id", ""))
    role_name = str(role_data.get("name") or "").strip()
    event = str(event or "").strip()[:200]
    try:
        start, start_is_day = _parse_recall_time(start_time, end=False)
        end, _ = _parse_recall_time(end_time, end=True)
    except ValueError:
        return (
            "查询失败：时间格式无效，请使用 YYYY-MM-DD、YYYY-MM-DD HH:MM，"
            "或「今天」「昨天」「前天」"
        )
    if start and start_is_day and not end:
        end = datetime.combine(start.date(), _dtime.max)
    if start and end and start > end:
        return "查询失败：start_time 晚于 end_time"
    if not start and not end and not event:
        return "查询失败：请至少提供时间范围（start_time / end_time）或事件（event）之一"

    from services import summary_config_service
    from services.ai_service import call_ai_direct
    from services.memory_service import _run_db, _summary_message_text

    try:
        config = summary_config_service.resolve_summary_config(
            summary_config_service.CHAT_RECALL_SUMMARY
        )
        if not config.get("enabled"):
            return "聊天回顾功能已在设置中关闭"
        if not config.get("configured"):
            return "聊天回顾失败：总结模型 API 未配置，请在设置中配置「聊天回顾总结」"

        rows = await _run_db(role_id, _fetch_recall_rows, role_id, start, end)
    except Exception as e:
        logger.error(f"聊天回顾读取失败 role={role_id}: {e}")
        return f"聊天回顾失败：{e}"

    fetch_truncated = len(rows) > _RECALL_FETCH_LIMIT
    rows = rows[:_RECALL_FETCH_LIMIT]
    lines = []
    for role, content, timestamp, sender in rows:
        text = _clip(_summary_message_text(content), _RECALL_MESSAGE_CLIP)
        if not text:
            continue
        speaker = "用户" if role == "user" else (role_name or str(sender or "").strip() or "助手")
        lines.append({
            "time": str(timestamp or "")[:16].replace("T", " "),
            "speaker": speaker,
            "message": text,
        })
    range_label = _recall_range_label(start, end)
    scope_label = f"{range_label}" + (f"，事件「{event}」" if event else "")
    if not lines:
        return f"没有找到聊天记录（{range_label}）。"

    selected, note = _select_recall_lines(lines, event)
    if fetch_truncated:
        extra = f"范围内消息超过 {_RECALL_FETCH_LIMIT} 条，只读取了最早的部分，请缩小时间范围"
        note = f"{note}；{extra}" if note else extra

    prompt = json.dumps(
        {
            "requested_range": range_label,
            "event": event,
            "conversation": selected,
            "note": note,
        },
        ensure_ascii=False,
    )
    try:
        result = await call_ai_direct(
            messages=[
                {"role": "system", "content": config["system_prompt"]},
                {"role": "user", "content": prompt},
            ],
            model=config["model"],
            api_url=config["api_url"],
            api_key=config["api_key"],
            temperature=config["temperature"],
            max_tokens=_RECALL_SUMMARY_MAX_TOKENS,
            api_format=config["api_format"],
            timeout_seconds=config["timeout_seconds"],
            thinking_enabled=config["thinking_enabled"],
            thinking_budget=config["thinking_budget"],
            reasoning_effort=config["reasoning_effort"],
        )
    except Exception as e:
        logger.error(f"聊天回顾总结调用失败 role={role_id}: {e}")
        return f"聊天回顾失败：总结模型调用出错（{e}）"
    summary = str(result.get("content") or "").strip() if result.get("success") else ""
    if not summary:
        logger.warning("聊天回顾总结为空 role=%s: %s", role_id, result.get("error"))
        return "聊天回顾失败：总结模型没有返回有效内容，请稍后再试"

    output = [
        f"聊天回顾（{scope_label}，共分析 {len(selected)} 条消息）：",
        _clip(summary, _RECALL_RESULT_MAX_CHARS),
    ]
    if note:
        output.append(f"（说明：{note}）")
    return "\n".join(output)


# ========== 工具：联网搜索 ==========

"""
联网搜索工具：允许 AI 主动联网搜索获取最新信息。
对所有场景开放。
"""
_WEB_SEARCH_TOOL = build_tool("web_search", {
    "query": {"type": "string"},
    "max_results": {"type": "integer"},
})


async def execute_web_search(role_data: Dict, query: str, max_results: int = 3) -> str:
    """执行联网搜索，返回结果描述"""
    from services.search_service import web_search, format_search_results

    query = query.strip()
    if not query:
        return "搜索失败：查询内容为空"

    try:
        results = await web_search(query, max_results=max_results)
        if not results:
            return f"未找到与「{query}」相关的搜索结果"
        return format_search_results(results)
    except Exception as e:
        logger.error(f"联网搜索失败: {e}")
        return f"搜索失败：{e}"


# ========== 工具：向量记忆写入 ==========

"""
向量记忆写入工具：允许 AI 主动将重要信息写入长期记忆。
对所有场景开放。
"""
_WRITE_MEMORY_TOOL = build_tool("write_memory", {
    "summary": {"type": "string"},
    "occurred_at": {"type": "string"},
})


# ========== 工具：识图 ==========

"""
识图工具：允许 AI 在用户发送图片时，自主决定是否识别图片、并指定识别的重点细节。
仅在「工具模式」识图（vision_mode=tool）且本次消息附带图片时对聊天模型开放。
"""
_RECOGNIZE_IMAGE_TOOL = build_tool("recognize_image", {
    "focus": {"type": "string"},
    "image_index": {"type": "integer"},
})

_REVIEW_PREVIOUS_IMAGES_TOOL = build_tool("review_previous_images", {
    "prompt": {"type": "string"},
    "image_index": {"type": "integer"},
})


async def execute_recognize_image(
    image_data_urls: List[str],
    focus: str = "",
    image_index: int = 0,
) -> str:
    """识别指定图片的内容，返回识别文本。失败/无配置时返回友好错误串（不抛异常）。

    image_data_urls: 本次消息携带的图片 data URL 列表（为将来多图预留，当前通常只有一张）。
    """
    from services import vision_service

    if not image_data_urls:
        return "识图失败：本次没有可识别的图片"

    # 越界回退到第 0 张
    idx = image_index if isinstance(image_index, int) else 0
    if idx < 0 or idx >= len(image_data_urls):
        idx = 0
    image_data_url = image_data_urls[idx]

    vision_cfg = vision_service.resolve_vision_config()
    api_url = vision_cfg.get("api_url", "")
    api_key = vision_cfg.get("api_key", "")
    model = vision_cfg.get("model", "gpt-4o")
    api_format = vision_cfg.get("api_format", "auto")
    if not api_url or not api_key:
        return "识图失败：未配置识图模型（Vision API）"

    prompt = (focus or "").strip() or "请描述这张图片的关键内容"
    messages = vision_service.build_vision_messages(image_data_url, prompt)
    body = {
        "model": model,
        "messages": messages,
        "max_tokens": 1024,
    }
    try:
        result = await vision_service.call_vision_api(api_url, api_key, body, api_format=api_format)
        if not result:
            return "识图失败：识图模型未返回内容，请稍后重试"
        return result
    except Exception as e:
        logger.error(f"识图工具执行失败: {e}")
        return f"识图失败：{e}"


async def execute_write_memory(
    role_data: Dict,
    summary: str,
    occurred_at: Optional[str] = None,
) -> str:
    """将 AI 综合后的重要信息与发生时间写入向量记忆库。"""
    summary = summary.strip()
    if not summary:
        return "写入失败：记忆摘要为空"
    if len(summary) < 5:
        return "写入失败：记忆内容过短，请描述完整信息"

    raw_occurred_at = str(occurred_at or "").strip()
    if raw_occurred_at:
        try:
            parsed_time = datetime.fromisoformat(
                raw_occurred_at.replace("Z", "+00:00")
            )
            normalized_occurred_at = parsed_time.isoformat()
        except ValueError:
            return "写入失败：occurred_at 必须是 ISO 8601 时间"
    else:
        normalized_occurred_at = datetime.now().isoformat(timespec="seconds")

    role_id = role_data.get("id", "")
    from services.vector_memory import VectorMemoryStore
    from services.ai_service import generate_embedding

    try:
        result = await generate_embedding(summary)
        if not result["success"] or not result["embedding"]:
            err = result.get("error", "嵌入向量生成失败")
            logger.warning(
                "向量记忆写入失败：embedding 生成失败 role=%s source=ai_tool error=%s",
                role_id, err,
            )
            return f"记忆写入失败：{err}"

        store = VectorMemoryStore(role_id)
        store.store(
            text=summary,
            embedding=result["embedding"],
            role="assistant",
            timestamp=normalized_occurred_at,
            source="ai_tool",
        )
        logger.info(
            "AI主动写入记忆: role=%s, occurred_at=%s, summary=%s",
            role_id,
            normalized_occurred_at,
            summary[:80],
        )
        return f"已记住（发生时间：{normalized_occurred_at}）：{summary}"
    except Exception as e:
        logger.error(f"向量记忆写入失败 role={role_id}: {e}")
        return f"记忆写入失败：{e}"


# ========== 工具：情绪表情发送 ==========

"""
情绪表情工具：允许 AI 在对话中主动发送情绪表情贴图。
对所有场景开放。
"""
_SEND_EMOTION_EMOJI_TOOL = build_tool("send_emotion_emoji", {
    "emotion": {"type": "string", "enum": ["happy", "sad", "angry", "surprised", "love", "confused", "excited", "tired"]},
})


"""
语音消息工具：让 AI 把一段话用 TTS 合成为真实语音发给用户。
仅当 TTS 已启用并配置、角色未关闭语音、且处于聊天场景时开放（见 ai_service.generate_with_role）。
"""
_SEND_VOICE_MESSAGE_TOOL = build_tool("send_voice_message", {
    "text": {"type": "string"},
    "style": {"type": "string"},
})


async def execute_send_voice_message(
    role_data: Dict, text: str, style: str, issued_count: int = 0,
) -> tuple:
    """合成并保存语音，返回 (给模型的结果描述, 投递信息或 None)。永不抛出。"""
    from services import tts_service

    if issued_count >= tts_service.MAX_VOICES_PER_TURN:
        return (
            f"语音发送失败：单次回复最多发送 {tts_service.MAX_VOICES_PER_TURN} 条语音，请改用文字回复。",
            None,
        )
    try:
        delivery = await tts_service.synthesize_for_role(role_data, text, style)
    except tts_service.TTSError as exc:
        return f"语音发送失败：{exc}。请改用文字回复。", None
    except Exception:  # noqa: BLE001 - 工具执行器不得让整轮对话失败
        logger.exception("send_voice_message 执行异常")
        return "语音发送失败：内部错误。请改用文字回复。", None
    seconds = delivery.get("duration_ms")
    duration_hint = f"（约 {max(1, round(seconds / 1000))} 秒）" if seconds else ""
    return (
        f"语音已发送{duration_hint}。不要在文字回复中重复这段话；可以追加简短文字，也可以不再回复文字。",
        delivery,
    )


_IMAGE_EXTS = (".png", ".jpg", ".jpeg", ".gif", ".webp")

# 云端表情专用分类：不参与情绪随机抽取与情绪列举
CLOUD_EMOJI_CATEGORY = "__cloud__"


def _pick_emoji_file(role_id: str, emotion: str) -> Optional[Path]:
    """从角色的表情目录中随机选取一个表情文件，目录不存在或为空时返回 None"""
    if emotion == CLOUD_EMOJI_CATEGORY:
        return None
    emoji_dir = _emoji_dir(role_id, emotion)
    if not emoji_dir.exists() or not emoji_dir.is_dir():
        return None
    files = [f for f in emoji_dir.iterdir() if f.is_file() and f.suffix.lower() in _IMAGE_EXTS]
    return random.choice(files) if files else None


def _get_available_emotions(role_id: str) -> List[str]:
    """扫描角色可用的情绪类别（有图片文件的目录）"""
    emoji_root = _emoji_root(role_id)
    if not emoji_root.exists():
        return []
    available = []
    for entry in emoji_root.iterdir():
        try:
            category_dir = ensure_direct_child_path(
                emoji_root, entry.name, "emotion"
            )
        except ValueError:
            continue
        if (
            category_dir.is_dir()
            and category_dir.name != CLOUD_EMOJI_CATEGORY
            and any(
                f.is_file() and f.suffix.lower() in _IMAGE_EXTS
                for f in category_dir.iterdir()
            )
        ):
            available.append(category_dir.name)
    return available


async def execute_send_emotion_emoji(role_data: Dict, emotion: str) -> str:
    """发送情绪表情，返回结果描述"""
    role_id = role_data.get("id", "")
    emotion = emotion.strip().lower()
    if not emotion:
        return "发送失败：未指定情绪类型"

    if _pick_emoji_file(role_id, emotion) is not None:
        return f"[{emotion}]"

    # 目录不存在或为空时，提示可用情绪
    emoji_dir = _emoji_dir(role_id, emotion)
    available = _get_available_emotions(role_id)
    hint = f"，可用情绪: {', '.join(available)}" if available else ""
    if emoji_dir.exists() and emoji_dir.is_dir():
        return f"「{emotion}」表情目录为空，暂无可用表情图片{hint}"
    return f"没有找到「{emotion}」对应的表情包{hint}"

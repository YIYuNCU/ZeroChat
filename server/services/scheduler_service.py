"""
调度器服务
管理定时任务、主动消息、朋友圈 AI 行为
"""
import json
import hashlib
import random
import asyncio
import logging
from datetime import datetime, timedelta
from pathlib import Path
from typing import Optional, Dict, List, Callable
from apscheduler.schedulers.asyncio import AsyncIOScheduler
from apscheduler.triggers.interval import IntervalTrigger
from apscheduler.triggers.date import DateTrigger
from apscheduler.triggers.cron import CronTrigger

logger = logging.getLogger(__name__)

from core.utils import is_tool_role_id, load_moments_posts, atomic_write_json

DATA_DIR = Path(__file__).parent.parent / "data"
ROLES_DIR = DATA_DIR / "roles"
TASKS_DIR = DATA_DIR / "tasks"
TASKS_FILE = TASKS_DIR / "scheduled.json"
FOLLOWUPS_FILE = TASKS_DIR / "followups.json"

# 全局调度器实例
_scheduler: Optional[AsyncIOScheduler] = None
_event_callback: Optional[Callable] = None

def get_scheduler() -> AsyncIOScheduler:
    global _scheduler
    if _scheduler is None:
        _scheduler = AsyncIOScheduler()
    return _scheduler

def set_event_callback(callback: Callable):
    """设置事件回调函数（用于触发 AI 行为）"""
    global _event_callback
    _event_callback = callback

def start_scheduler():
    """启动调度器"""
    scheduler = get_scheduler()
    if not scheduler.running:
        scheduler.start()
        logger.info("Scheduler started")
        
        # 初始化所有调度任务
        _init_proactive_jobs()
        _init_scheduled_tasks()
        _init_followups()
        _init_moment_jobs()

def stop_scheduler():
    """停止调度器"""
    scheduler = get_scheduler()
    if scheduler.running:
        scheduler.shutdown()
        logger.info("Scheduler stopped")

# ========== 主动消息调度 ==========

def _init_proactive_jobs():
    """初始化所有角色的主动消息调度"""
    if not ROLES_DIR.exists():
        return
    
    for role_dir in ROLES_DIR.iterdir():
        if role_dir.is_dir():
            schedule_proactive_for_role(role_dir.name)

def _is_quiet_hour(hour: int, start: int, end: int) -> bool:
    if start == end:
        return False
    if start < end:
        return start <= hour < end
    return hour >= start or hour < end


def _persist_next_proactive_time(
    profile_file: Path,
    role: Dict,
    next_run: Optional[datetime],
):
    proactive_config = dict(role.get("proactive_config") or {})
    serialized = next_run.isoformat() if next_run else None
    if proactive_config.get("next_trigger_time") == serialized:
        return
    proactive_config["next_trigger_time"] = serialized
    role["proactive_config"] = proactive_config
    role["updated_at"] = datetime.now().isoformat()
    atomic_write_json(profile_file, role)


def schedule_proactive_for_role(role_id: str, *, reset: bool = False):
    """为角色调度主动消息"""
    if is_tool_role_id(role_id):
        return

    scheduler = get_scheduler()
    job_id = f"proactive_{role_id}"
    
    # 移除旧任务
    if scheduler.get_job(job_id):
        scheduler.remove_job(job_id)
    
    # 加载角色配置
    profile_file = ROLES_DIR / role_id / "profile.json"
    if not profile_file.exists():
        return
    
    with open(profile_file, "r", encoding="utf-8") as f:
        role = json.load(f)

    # 归档角色不发主动消息
    if role.get("archived", False):
        _persist_next_proactive_time(profile_file, role, None)
        return

    proactive_config = role.get("proactive_config", {})
    if not proactive_config.get("enabled", False):
        _persist_next_proactive_time(profile_file, role, None)
        return

    now = datetime.now()
    next_run = None
    if not reset:
        raw_next_run = proactive_config.get("next_trigger_time")
        if raw_next_run:
            try:
                candidate = datetime.fromisoformat(str(raw_next_run))
                if candidate > now:
                    next_run = candidate
            except (TypeError, ValueError):
                pass

    if next_run is None:
        min_minutes = max(1, int(proactive_config.get("min_interval_minutes", 30)))
        max_minutes = max(min_minutes, int(proactive_config.get("max_interval_minutes", 120)))
        next_run = now + timedelta(minutes=random.randint(min_minutes, max_minutes))
    
    # 检查安静时间
    quiet_start = proactive_config.get("quiet_hours_start", 23)
    quiet_end = proactive_config.get("quiet_hours_end", 7)
    
    if _is_quiet_hour(next_run.hour, quiet_start, quiet_end):
        # 候选时间落在安静时段时，推迟到该时段结束。
        next_run = next_run.replace(hour=quiet_end, minute=0, second=0, microsecond=0)
        if next_run <= now:
            next_run += timedelta(days=1)

    _persist_next_proactive_time(profile_file, role, next_run)
    
    scheduler.add_job(
        _trigger_proactive,
        DateTrigger(run_date=next_run),
        id=job_id,
        args=[role_id],
        replace_existing=True
    )
    
    logger.info(f"Scheduled proactive for {role_id} at {next_run}")

def unschedule_proactive_for_role(role_id: str):
    """取消角色的主动消息调度"""
    scheduler = get_scheduler()
    job_id = f"proactive_{role_id}"
    if scheduler.get_job(job_id):
        scheduler.remove_job(job_id)
        logger.info(f"Unscheduled proactive for {role_id}")


async def _trigger_proactive(role_id: str):
    """触发主动消息"""
    global _event_callback
    
    try:
        if _event_callback:
            await _event_callback({
                "role_id": role_id,
                "event_type": "proactive",
                "content": "",
                "context": {}
            })
        else:
            logger.warning("Proactive trigger skipped: event callback is not set")
    except Exception:
        logger.exception("Proactive trigger failed for %s", role_id)
    finally:
        # 单次生成失败不能终止后续主动消息。
        schedule_proactive_for_role(role_id, reset=True)

# ========== 定时任务调度 ==========

def _init_scheduled_tasks():
    """初始化所有定时任务"""
    if not TASKS_FILE.exists():
        return
    
    with open(TASKS_FILE, "r", encoding="utf-8") as f:
        tasks = json.load(f)
    
    for task in tasks:
        if task.get("enabled", True):
            schedule_task(task)

def schedule_task(task: Dict):
    """调度单个任务"""
    scheduler = get_scheduler()
    task_id = task.get("id")
    job_id = f"task_{task_id}"
    
    # 移除旧任务
    if scheduler.get_job(job_id):
        scheduler.remove_job(job_id)
    
    trigger_time = task.get("trigger_time")
    if not trigger_time:
        return

    repeat = str(task.get("repeat") or "none").strip().lower()

    try:
        run_time = datetime.fromisoformat(trigger_time)

        if repeat == "daily":
            # 每日在同一时刻触发；trigger_time 只用于确定时/分/秒，日期可为过去。
            trigger = CronTrigger(
                hour=run_time.hour, minute=run_time.minute, second=run_time.second
            )
        elif repeat == "weekly":
            # 每周在同一星期几、同一时刻触发。
            trigger = CronTrigger(
                day_of_week=run_time.weekday(),
                hour=run_time.hour,
                minute=run_time.minute,
                second=run_time.second,
            )
        else:
            # 一次性任务：过期则不调度。
            if run_time < datetime.now():
                return
            trigger = DateTrigger(run_date=run_time)

        scheduler.add_job(
            _trigger_task,
            trigger,
            id=job_id,
            args=[task],
            replace_existing=True
        )

        logger.info(f"Scheduled task {task_id} at {run_time} (repeat={repeat})")
    except Exception as e:
        logger.error(f"Failed to schedule task {task_id}: {e}")

async def _trigger_task(task: Dict):
    """触发定时任务"""
    global _event_callback
    
    if _event_callback:
        await _event_callback({
            "role_id": task.get("role_id"),
            "event_type": "task",
            "content": task.get("ai_prompt") or task.get("message", ""),
            "context": {
                "task_id": task.get("id"),
                "chat_id": task.get("chat_id"),
                "task_message": task.get("message", ""),
            }
        })

    # 仅一次性任务在触发后标记完成；daily/weekly 重复任务保持 enabled，
    # 由 CronTrigger 持续触发（重启后 _init_scheduled_tasks 会按 repeat 重建）。
    repeat = str(task.get("repeat") or "none").strip().lower()
    if repeat not in ("daily", "weekly"):
        mark_task_completed(str(task.get("id", "")).strip())


def unschedule_task(task_id: str):
    """移除任务调度"""
    scheduler = get_scheduler()
    job_id = f"task_{task_id}"
    if scheduler.get_job(job_id):
        scheduler.remove_job(job_id)


def mark_task_completed(task_id: str):
    """将任务标记为已完成（后端一锤子任务）"""
    if not task_id or not TASKS_FILE.exists():
        return

    try:
        with open(TASKS_FILE, "r", encoding="utf-8") as f:
            tasks = json.load(f)
        dirty = False
        for item in tasks:
            if not isinstance(item, dict):
                continue
            if str(item.get("id", "")).strip() == task_id:
                if item.get("enabled", True):
                    item["enabled"] = False
                    dirty = True
                break

        if dirty:
            atomic_write_json(TASKS_FILE, tasks)
    except Exception as e:
        logger.warning(f"Failed to mark task completed ({task_id}): {e}")


# ========== 无回复续写调度 ==========
# 当 AI 主动调用 continue_if_no_reply 工具时，登记一个一次性计时器：
# 若在指定时长内用户没有回复，则触发一条续写消息。用户回复时取消。

def _load_followups() -> Dict[str, Dict]:
    """读取续写状态表 {role_id: {chain_count, prompt, chat_id, deadline}}"""
    if not FOLLOWUPS_FILE.exists():
        return {}
    try:
        with open(FOLLOWUPS_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except Exception as e:
        logger.warning(f"Failed to load followups: {e}")
        return {}


def _save_followups(data: Dict[str, Dict]):
    """写回续写状态表"""
    try:
        atomic_write_json(FOLLOWUPS_FILE, data)
    except Exception as e:
        logger.warning(f"Failed to save followups: {e}")


def _get_role_quiet_hours(role_id: str) -> tuple:
    """读取角色的安静时段（复用 proactive_config，保持与主动消息一致）"""
    profile_file = ROLES_DIR / role_id / "profile.json"
    if not profile_file.exists():
        return (23, 7)
    try:
        with open(profile_file, "r", encoding="utf-8") as f:
            role = json.load(f)
        proactive_config = role.get("proactive_config") or {}
        return (
            int(proactive_config.get("quiet_hours_start", 23)),
            int(proactive_config.get("quiet_hours_end", 7)),
        )
    except Exception:
        return (23, 7)


def schedule_followup(
    role_id: str,
    delay_minutes: int,
    prompt: str,
    chain_count: int = 1,
    chat_id: Optional[str] = None,
):
    """登记「无回复续写」计时器：delay_minutes 后若用户仍未回复则触发续写。"""
    if is_tool_role_id(role_id):
        return

    scheduler = get_scheduler()
    job_id = f"followup_{role_id}"

    # 覆盖同角色的旧续写计时器
    if scheduler.get_job(job_id):
        scheduler.remove_job(job_id)

    now = datetime.now()
    next_run = now + timedelta(minutes=max(1, int(delay_minutes)))

    # 遵守安静时段：落在安静时段则推移到时段结束
    quiet_start, quiet_end = _get_role_quiet_hours(role_id)
    if _is_quiet_hour(next_run.hour, quiet_start, quiet_end):
        next_run = next_run.replace(hour=quiet_end, minute=0, second=0, microsecond=0)
        if next_run <= now:
            next_run += timedelta(days=1)

    followups = _load_followups()
    followups[role_id] = {
        "chain_count": int(chain_count),
        "prompt": prompt,
        "chat_id": chat_id or role_id,
        "deadline": next_run.isoformat(),
    }
    _save_followups(followups)

    scheduler.add_job(
        _trigger_followup,
        DateTrigger(run_date=next_run),
        id=job_id,
        args=[role_id],
        replace_existing=True,
    )
    logger.info(
        f"Scheduled followup for {role_id} at {next_run} (chain={chain_count})"
    )


def cancel_followup(role_id: str):
    """取消续写计时器并清除状态（用户回复时调用，等价于链计数归零）"""
    scheduler = get_scheduler()
    job_id = f"followup_{role_id}"
    if scheduler.get_job(job_id):
        scheduler.remove_job(job_id)
        logger.info(f"Cancelled followup for {role_id}")

    followups = _load_followups()
    if role_id in followups:
        followups.pop(role_id, None)
        _save_followups(followups)


async def _trigger_followup(role_id: str):
    """触发续写消息。不自动重排——只有 AI 再次调用工具才续接。"""
    global _event_callback

    followups = _load_followups()
    state = followups.get(role_id) or {}
    prompt = state.get("prompt", "")
    chat_id = state.get("chat_id") or role_id
    chain_count = int(state.get("chain_count", 1))

    # 触发后清除本次状态（链计数由工具执行器基于下一次调用重新累加）
    if role_id in followups:
        followups.pop(role_id, None)
        _save_followups(followups)

    try:
        if _event_callback:
            await _event_callback({
                "role_id": role_id,
                "event_type": "followup",
                "content": prompt,
                "context": {
                    "chat_id": chat_id,
                    "chain_count": chain_count,
                },
            })
        else:
            logger.warning("Followup trigger skipped: event callback is not set")
    except Exception:
        logger.exception("Followup trigger failed for %s", role_id)


def _init_followups():
    """启动时重排未过期的续写计时器（参照 _init_scheduled_tasks）"""
    followups = _load_followups()
    if not followups:
        return

    now = datetime.now()
    changed = False
    for role_id, state in list(followups.items()):
        deadline_raw = str((state or {}).get("deadline", ""))
        try:
            deadline = datetime.fromisoformat(deadline_raw)
        except (TypeError, ValueError):
            followups.pop(role_id, None)
            changed = True
            continue

        if deadline <= now:
            # 服务停机期间已过期的续写不补发，直接清除
            followups.pop(role_id, None)
            changed = True
            continue

        scheduler = get_scheduler()
        scheduler.add_job(
            _trigger_followup,
            DateTrigger(run_date=deadline),
            id=f"followup_{role_id}",
            args=[role_id],
            replace_existing=True,
        )
        logger.info(f"Restored followup for {role_id} at {deadline}")

    if changed:
        _save_followups(followups)


# ========== 朋友圈 AI 调度 ==========

def _init_moment_jobs():
    """初始化朋友圈 AI 调度"""
    scheduler = get_scheduler()
    
    # 定期检查是否有 AI 要发朋友圈
    # 每小时检查一次，配合每角色 24h 冷却，实现「最多一天一条」；
    # 对超过 7 天未发帖的角色强制补发，实现「最少一周一条」。
    scheduler.add_job(
        _check_moment_posts,
        IntervalTrigger(minutes=60),
        id="moment_check",
        replace_existing=True
    )

    # 定期检查是否有 AI 要评论/回复朋友圈
    scheduler.add_job(
        _check_moment_comments,
        IntervalTrigger(minutes=180),
        id="moment_comment_check",
        replace_existing=True,
    )
    
    logger.info("Scheduled moment check job")

# 发帖节奏参数
_MOMENT_MIN_INTERVAL_HOURS = 24      # 最多一天一条：距上次发帖不足 24h 跳过
_MOMENT_MAX_INTERVAL_DAYS = 7        # 最少一周一条：超过 7 天强制补发
# 处于 24h–7天之间的角色，每次检查进入候选的概率（让发帖自然分散在一周内）
_MOMENT_POST_CHANCE = 0.18


def _last_ai_post_times() -> Dict[str, datetime]:
    """从 posts.json 计算每个角色最近一次发帖时间（author_id -> 最新 created_at）。"""
    result: Dict[str, datetime] = {}
    for post in _load_moments_posts():
        author_id = str(post.get("author_id", "")).strip()
        if not author_id or author_id == "me":
            continue
        created_at_raw = str(post.get("created_at", ""))
        try:
            created_at = datetime.fromisoformat(created_at_raw)
        except Exception:
            continue
        prev = result.get(author_id)
        if prev is None or created_at > prev:
            result[author_id] = created_at
    return result


async def _check_moment_posts():
    """检查是否有 AI 要发朋友圈（每角色：最多一天一条，最少一周一条）"""
    global _event_callback

    if not _event_callback:
        return

    roles = _load_non_tool_roles()
    if not roles:
        logger.warning("No valid roles found for moment posting")
        return

    now = datetime.now()
    last_posts = _last_ai_post_times()

    forced: List[Dict] = []      # 超过 7 天未发帖，强制补发
    optional: List[Dict] = []    # 24h–7天之间，低概率发帖

    for role in roles:
        role_id = str(role.get("id", "")).strip()
        if not role_id:
            continue
        last = last_posts.get(role_id)
        if last is None:
            # 从未发过：视为需要补发；按角色 ID 做轻微错峰，避免所有新角色同一小时齐发。
            # 用稳定哈希（md5）而非内置 hash()，后者受 PYTHONHASHSEED 影响每次启动结果不同。
            role_stagger = int(hashlib.md5(role_id.encode("utf-8")).hexdigest(), 16)
            if (now.hour + role_stagger) % 6 == 0:
                forced.append(role)
            else:
                optional.append(role)
            continue
        elapsed = now - last
        if elapsed < timedelta(hours=_MOMENT_MIN_INTERVAL_HOURS):
            continue  # 最多一天一条：跳过
        if elapsed >= timedelta(days=_MOMENT_MAX_INTERVAL_DAYS):
            forced.append(role)  # 最少一周一条：强制补发
        else:
            optional.append(role)

    # 每次检查最多让一个角色发帖，避免同一 tick 多角色齐发刷屏。
    # 优先处理强制补发（>7天）的角色。
    target: Optional[Dict] = None
    if forced:
        target = random.choice(forced)
    elif optional and random.random() < _MOMENT_POST_CHANCE:
        target = random.choice(optional)

    if target is None:
        logger.info("No AI moment this time")
        return

    await _event_callback({
        "role_id": str(target.get("id", "")).strip(),
        "event_type": "moment",
        "content": "",
        "context": {}
    })
    logger.info(f"AI {target.get('name')} posting moment")


def _load_moments_posts() -> List[Dict]:
    return load_moments_posts(DATA_DIR / "moments" / "posts.json")


def _load_non_tool_roles() -> List[Dict]:
    if not ROLES_DIR.exists():
        return []

    roles: List[Dict] = []
    for role_dir in ROLES_DIR.iterdir():
        if not role_dir.is_dir():
            continue
        profile_file = role_dir / "profile.json"
        if not profile_file.exists():
            continue
        try:
            with open(profile_file, "r", encoding="utf-8") as f:
                profile = json.load(f)
            role_id = str(profile.get("id", "")).strip()
            if not role_id or is_tool_role_id(role_id):
                continue
            if profile.get("archived", False):
                continue  # 跳过已归档角色
            roles.append(profile)
        except Exception:
            continue
    return roles


async def _check_moment_comments():
    """检查是否有 AI 要评论朋友圈（含回复用户评论）"""
    global _event_callback

    if not _event_callback:
        return

    roles = _load_non_tool_roles()
    posts = _load_moments_posts()
    if not roles or not posts:
        return

    now = datetime.now()

    # 优先处理：AI 回复用户对其帖子的评论
    reply_candidates: List[Dict] = []
    for post in posts:
        post_id = str(post.get("id", "")).strip()
        post_author_id = str(post.get("author_id", "")).strip()
        if not post_id or not post_author_id or post_author_id == "me":
            continue

        created_at_raw = str(post.get("created_at", ""))
        try:
            created_at = datetime.fromisoformat(created_at_raw)
        except Exception:
            continue
        if (now - created_at).total_seconds() > 48 * 3600:
            continue

        comments = post.get("comments") if isinstance(post.get("comments"), list) else []
        user_comments = [
            c for c in comments
            if isinstance(c, dict) and str(c.get("author_id", "")).strip() == "me"
        ]
        if not user_comments:
            continue

        has_replied = any(
            isinstance(c, dict)
            and str(c.get("author_id", "")).strip() == post_author_id
            and str(c.get("reply_to_id", "")).strip() == "me"
            for c in comments
        )
        if has_replied:
            continue

        latest_user_comment = user_comments[-1]
        reply_candidates.append(
            {
                "role_id": post_author_id,
                "post_id": post_id,
                "post_content": str(post.get("content", "")),
                "post_author": str(post.get("author_name", "用户")),
                "reply_to": str(latest_user_comment.get("content", "")).strip(),
                "reply_to_id": "me",
                "reply_to_name": str(latest_user_comment.get("author_name", "我")).strip() or "我",
            }
        )

    if reply_candidates and random.random() < 0.7:
        target = random.choice(reply_candidates)
        await _event_callback(
            {
                "role_id": target["role_id"],
                "event_type": "comment",
                "content": "",
                "context": {
                    "post_id": target["post_id"],
                    "post_content": target["post_content"],
                    "post_author": target["post_author"],
                    "reply_to": target["reply_to"],
                    "reply_to_id": target["reply_to_id"],
                    "reply_to_name": target["reply_to_name"],
                },
            }
        )
        logger.info(
            "AI %s replied to user comment on post %s",
            target["role_id"],
            target["post_id"],
        )
        return

    # 普通评论：AI 评论最近 24h 的非自己帖子
    comment_candidates: List[Dict] = []
    role_ids = {str(r.get("id", "")).strip() for r in roles}
    for post in posts:
        post_id = str(post.get("id", "")).strip()
        post_author_id = str(post.get("author_id", "")).strip()
        if not post_id or not post_author_id:
            continue

        created_at_raw = str(post.get("created_at", ""))
        try:
            created_at = datetime.fromisoformat(created_at_raw)
        except Exception:
            continue
        if (now - created_at).total_seconds() > 24 * 3600:
            continue

        comments = post.get("comments") if isinstance(post.get("comments"), list) else []
        commenters = {
            str(c.get("author_id", "")).strip()
            for c in comments
            if isinstance(c, dict)
        }

        # 限制 AI-AI 评论轮数：对非用户帖子，AI 之间最多互评 2 条，避免无限对评刷屏。
        if post_author_id != "me":
            ai_comment_count = sum(
                1
                for c in comments
                if isinstance(c, dict)
                and str(c.get("author_id", "")).strip() not in ("me", post_author_id)
            )
            if ai_comment_count >= 2:
                continue

        for role_id in role_ids:
            if not role_id or role_id == post_author_id:
                continue
            if role_id in commenters:
                continue
            comment_candidates.append(
                {
                    "role_id": role_id,
                    "post_id": post_id,
                    "post_content": str(post.get("content", "")),
                    "post_author": str(post.get("author_name", "用户")),
                }
            )

    if comment_candidates and random.random() < 0.5:
        target = random.choice(comment_candidates)
        await _event_callback(
            {
                "role_id": target["role_id"],
                "event_type": "comment",
                "content": "",
                "context": {
                    "post_id": target["post_id"],
                    "post_content": target["post_content"],
                    "post_author": target["post_author"],
                },
            }
        )
        logger.info(
            "AI %s commented on post %s",
            target["role_id"],
            target["post_id"],
        )


# ========== 用户发帖后的主动互动 ==========

# 用户发帖后，每个 AI 角色点赞的概率
_USER_POST_LIKE_CHANCE = 0.45
# 用户发帖后，参与评论的角色最多数量
_USER_POST_MAX_COMMENTERS = 2
# 用户发帖后，单个角色触发评论的概率
_USER_POST_COMMENT_CHANCE = 0.5
# 互动前的随机延迟范围（秒），模拟真人「刷到」的时间差
_USER_POST_INTERACT_DELAY_MIN = 30
_USER_POST_INTERACT_DELAY_MAX = 240


async def _ai_like_post(post_id: str, role_id: str, role_name: str) -> bool:
    """让某个 AI 角色点赞指定帖子（纯数据操作，无需 LLM）。返回是否成功点赞。"""
    from routers import moments as moments_router
    from transport.push_hub import publish_server_push

    try:
        result = await moments_router.like_moment(post_id, role_id, role_name)
    except Exception as e:
        logger.warning("AI like failed for post %s by %s: %s", post_id, role_id, e)
        return False

    if not isinstance(result, dict) or result.get("error"):
        return False

    try:
        await publish_server_push(
            "moment_like",
            {"role_id": role_id, "post_id": post_id, "author_name": role_name},
        )
    except Exception as e:
        logger.debug("moment_like push failed: %s", e)
    return True


async def trigger_interactions_for_user_post(post_id: str):
    """用户发帖后主动触发 AI 互动：概率点赞 + 少量评论。

    由 moments.create_moment 在用户（author_id == "me"）发帖成功后以
    asyncio.create_task 调用，不阻塞发帖响应。
    """
    if not _event_callback:
        return

    # 随机延迟，模拟真人刷到朋友圈的时间差，避免用户发完瞬间一堆互动同时冒出来。
    await asyncio.sleep(
        random.randint(_USER_POST_INTERACT_DELAY_MIN, _USER_POST_INTERACT_DELAY_MAX)
    )

    post = next(
        (p for p in _load_moments_posts() if str(p.get("id", "")).strip() == post_id),
        None,
    )
    if not post:
        return
    if str(post.get("author_id", "")).strip() != "me":
        return  # 只对用户帖子主动互动

    roles = _load_non_tool_roles()
    if not roles:
        return

    post_content = str(post.get("content", ""))
    post_author = str(post.get("author_name", "用户")) or "用户"

    # 已点赞的角色，避免重复
    already_liked = {
        str(l.get("id", "")).strip()
        for l in (post.get("liked_by") or [])
        if isinstance(l, dict)
    }

    random.shuffle(roles)
    commenters_triggered = 0

    for role in roles:
        role_id = str(role.get("id", "")).strip()
        role_name = str(role.get("name", "AI")) or "AI"
        if not role_id:
            continue

        # 概率点赞
        if role_id not in already_liked and random.random() < _USER_POST_LIKE_CHANCE:
            await _ai_like_post(post_id, role_id, role_name)

        # 少量角色概率评论
        if (
            commenters_triggered < _USER_POST_MAX_COMMENTERS
            and random.random() < _USER_POST_COMMENT_CHANCE
        ):
            commenters_triggered += 1
            await _event_callback(
                {
                    "role_id": role_id,
                    "event_type": "comment",
                    "content": "",
                    "context": {
                        "post_id": post_id,
                        "post_content": post_content,
                        "post_author": post_author,
                    },
                }
            )
            logger.info("AI %s commenting on user post %s", role_id, post_id)


# ========== 状态查询 ==========

def get_scheduler_status() -> Dict:
    """获取调度器状态"""
    scheduler = get_scheduler()
    jobs = scheduler.get_jobs()
    
    return {
        "running": scheduler.running,
        "job_count": len(jobs),
        "jobs": [
            {
                "id": job.id,
                "next_run": job.next_run_time.isoformat() if job.next_run_time else None
            }
            for job in jobs
        ]
    }

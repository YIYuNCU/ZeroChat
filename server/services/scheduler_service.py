"""
调度器服务
管理定时任务、主动消息、朋友圈 AI 行为
"""
import json
import random
import asyncio
import logging
from datetime import datetime, timedelta
from pathlib import Path
from typing import Optional, Dict, List, Callable
from apscheduler.schedulers.asyncio import AsyncIOScheduler
from apscheduler.triggers.interval import IntervalTrigger
from apscheduler.triggers.date import DateTrigger

logger = logging.getLogger(__name__)

DATA_DIR = Path(__file__).parent.parent / "data"
ROLES_DIR = DATA_DIR / "roles"
TASKS_DIR = DATA_DIR / "tasks"
TASKS_FILE = TASKS_DIR / "scheduled.json"
TOOL_ROLE_PREFIX = "1000000000"


def _is_tool_role_id(role_id: str) -> bool:
    return str(role_id or "").startswith(TOOL_ROLE_PREFIX)

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

def schedule_proactive_for_role(role_id: str):
    """为角色调度主动消息"""
    if _is_tool_role_id(role_id):
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
    
    proactive_config = role.get("proactive_config", {})
    if not proactive_config.get("enabled", False):
        return
    
    # 计算下次触发时间
    min_minutes = proactive_config.get("min_interval_minutes", 30)
    max_minutes = proactive_config.get("max_interval_minutes", 120)
    interval_minutes = random.randint(min_minutes, max_minutes)
    
    next_run = datetime.now() + timedelta(minutes=interval_minutes)
    
    # 检查安静时间
    quiet_start = proactive_config.get("quiet_hours_start", 23)
    quiet_end = proactive_config.get("quiet_hours_end", 7)
    
    current_hour = datetime.now().hour
    if quiet_start <= current_hour or current_hour < quiet_end:
        # 安静时间内，推迟到安静时间结束
        next_run = datetime.now().replace(hour=quiet_end, minute=0, second=0)
        if next_run < datetime.now():
            next_run += timedelta(days=1)
    
    scheduler.add_job(
        _trigger_proactive,
        DateTrigger(run_date=next_run),
        id=job_id,
        args=[role_id],
        replace_existing=True
    )
    
    logger.info(f"Scheduled proactive for {role_id} at {next_run}")

async def _trigger_proactive(role_id: str):
    """触发主动消息"""
    global _event_callback
    
    if _event_callback:
        await _event_callback({
            "role_id": role_id,
            "event_type": "proactive",
            "content": "",
            "context": {}
        })
    
    # 重新调度下一次
    schedule_proactive_for_role(role_id)

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
    
    try:
        run_time = datetime.fromisoformat(trigger_time)
        if run_time < datetime.now():
            return  # 过期任务不调度
        
        scheduler.add_job(
            _trigger_task,
            DateTrigger(run_date=run_time),
            id=job_id,
            args=[task],
            replace_existing=True
        )
        
        logger.info(f"Scheduled task {task_id} at {run_time}")
    except Exception as e:
        logger.error(f"Failed to schedule task {task_id}: {e}")

async def _trigger_task(task: Dict):
    """触发定时任务"""
    global _event_callback
    
    if _event_callback:
        await _event_callback({
            "role_id": task.get("role_id"),
            "event_type": "task",
            "content": task.get("ai_prompt", task.get("message", "")),
            "context": {
                "task_id": task.get("id"),
                "chat_id": task.get("chat_id"),
                "task_message": task.get("message", ""),
            }
        })

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
            TASKS_FILE.parent.mkdir(parents=True, exist_ok=True)
            with open(TASKS_FILE, "w", encoding="utf-8") as f:
                json.dump(tasks, f, indent=2, ensure_ascii=False)
    except Exception as e:
        logger.warning(f"Failed to mark task completed ({task_id}): {e}")

# ========== 朋友圈 AI 调度 ==========

def _init_moment_jobs():
    """初始化朋友圈 AI 调度"""
    scheduler = get_scheduler()
    
    # 定期检查是否有 AI 要发朋友圈
    scheduler.add_job(
        _check_moment_posts,
        IntervalTrigger(minutes=180),
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

async def _check_moment_posts():
    """检查是否有 AI 要发朋友圈"""
    global _event_callback
    
    if not ROLES_DIR.exists() or not _event_callback:
        return
    
    roles = []
    for role_dir in ROLES_DIR.iterdir():
        if role_dir.is_dir():
            profile_file = role_dir / "profile.json"
            if profile_file.exists():
                with open(profile_file, "r", encoding="utf-8") as f:
                    profile = json.load(f)
                    role_id = str(profile.get("id", "")).strip()
                    if role_id.startswith("1000000000"):
                        continue  # 跳过系统角色
                    roles.append(profile)
    
    if not roles:
        logger.warning("No valid roles found for moment posting")
        return
    
    # 随机选择一个角色发朋友圈（65% 概率）
    if random.random() < 0.65:
        role = random.choice(roles)
        await _event_callback({
            "role_id": str(role.get("id", "")).strip(),
            "event_type": "moment",
            "content": "",
            "context": {}
        })
        logger.info(f"AI {role.get('name')} posting moment")
    else:
        logger.info("No AI moment this time")


def _load_moments_posts() -> List[Dict]:
    moments_file = DATA_DIR / "moments" / "posts.json"
    if not moments_file.exists():
        return []
    try:
        with open(moments_file, "r", encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, list):
            return [item for item in data if isinstance(item, dict)]
    except Exception as e:
        logger.warning(f"加载朋友圈数据失败: {e}")
    return []


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
            if not role_id or _is_tool_role_id(role_id):
                continue
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

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
    tasks_file = TASKS_DIR / "scheduled.json"
    if not tasks_file.exists():
        return
    
    with open(tasks_file, "r", encoding="utf-8") as f:
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
            "context": {"task_id": task.get("id")}
        })

# ========== 朋友圈 AI 调度 ==========

def _init_moment_jobs():
    """初始化朋友圈 AI 调度"""
    scheduler = get_scheduler()
    
    # 每 2-4 小时检查一次是否有 AI 要发朋友圈
    scheduler.add_job(
        _check_moment_posts,
        IntervalTrigger(hours=3),
        id="moment_check",
        replace_existing=True
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
                    roles.append(json.load(f))
    
    if not roles:
        return
    
    # 随机选择一个角色发朋友圈（30% 概率）
    if random.random() < 0.3:
        role = random.choice(roles)
        await _event_callback({
            "role_id": role.get("id"),
            "event_type": "moment",
            "content": "",
            "context": {}
        })
        logger.info(f"AI {role.get('name')} posting moment")

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

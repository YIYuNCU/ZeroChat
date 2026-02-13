"""
任务调度路由
"""
import json
import uuid
from datetime import datetime
from pathlib import Path
from typing import Optional, List
from pydantic import BaseModel
from fastapi import APIRouter

router = APIRouter()

DATA_DIR = Path(__file__).parent.parent / "data"
TASKS_FILE = DATA_DIR / "tasks" / "scheduled.json"

class TaskCreate(BaseModel):
    chat_id: str
    role_id: str
    message: str
    ai_prompt: Optional[str] = ""
    trigger_time: str  # ISO format
    repeat: Optional[str] = None  # daily / weekly / none

def load_tasks() -> List[dict]:
    if TASKS_FILE.exists():
        with open(TASKS_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    return []

def save_tasks(tasks: List[dict]):
    TASKS_FILE.parent.mkdir(parents=True, exist_ok=True)
    with open(TASKS_FILE, "w", encoding="utf-8") as f:
        json.dump(tasks, f, indent=2, ensure_ascii=False)

@router.get("/tasks")
async def list_tasks():
    """获取所有任务"""
    tasks = load_tasks()
    return {"tasks": tasks}

@router.get("/tasks/{role_id}")
async def get_role_tasks(role_id: str):
    """获取角色任务"""
    tasks = load_tasks()
    role_tasks = [t for t in tasks if t.get("role_id") == role_id]
    return {"tasks": role_tasks}

@router.post("/tasks")
async def create_task(task: TaskCreate):
    """创建任务"""
    tasks = load_tasks()
    
    new_task = {
        "id": str(uuid.uuid4()),
        "chat_id": task.chat_id,
        "role_id": task.role_id,
        "message": task.message,
        "ai_prompt": task.ai_prompt,
        "trigger_time": task.trigger_time,
        "repeat": task.repeat,
        "enabled": True,
        "created_at": datetime.now().isoformat()
    }
    
    tasks.append(new_task)
    save_tasks(tasks)
    return new_task

@router.put("/tasks/{task_id}/toggle")
async def toggle_task(task_id: str):
    """启用/禁用任务"""
    tasks = load_tasks()
    for t in tasks:
        if t["id"] == task_id:
            t["enabled"] = not t.get("enabled", True)
            save_tasks(tasks)
            return t
    return {"error": "not found"}

@router.delete("/tasks/{task_id}")
async def delete_task(task_id: str):
    """删除任务"""
    tasks = load_tasks()
    tasks = [t for t in tasks if t["id"] != task_id]
    save_tasks(tasks)
    return {"success": True}

@router.get("/scheduler/status")
async def scheduler_status():
    """获取调度器状态"""
    tasks = load_tasks()
    enabled_count = len([t for t in tasks if t.get("enabled", True)])
    return {
        "total_tasks": len(tasks),
        "enabled_tasks": enabled_count,
        "status": "running"
    }

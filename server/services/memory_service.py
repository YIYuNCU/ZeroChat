"""
记忆服务
管理角色的短期记忆和核心记忆
"""
import json
import sqlite3
from datetime import datetime, timedelta
from pathlib import Path
from typing import Optional, List, Dict, Any

DATA_DIR = Path(__file__).parent.parent / "data"
ROLES_DIR = DATA_DIR / "roles"

def get_memory_db(role_id: str) -> Path:
    role_dir = ROLES_DIR / role_id
    role_dir.mkdir(parents=True, exist_ok=True)
    return role_dir / "memory.sqlite"

def get_memory_json(role_id: str) -> Path:
    role_dir = ROLES_DIR / role_id
    role_dir.mkdir(parents=True, exist_ok=True)
    return role_dir / "memory.json"

def _init_db(conn: sqlite3.Connection):
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS memory_meta (
            key TEXT PRIMARY KEY,
            value TEXT
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS short_term (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            role TEXT,
            content TEXT,
            timestamp TEXT
        )
        """
    )

def _get_meta(conn: sqlite3.Connection, key: str, default: Optional[str] = None) -> Optional[str]:
    row = conn.execute("SELECT value FROM memory_meta WHERE key = ?", (key,)).fetchone()
    return row[0] if row else default

def _set_meta(conn: sqlite3.Connection, key: str, value: Optional[str]):
    conn.execute(
        "INSERT OR REPLACE INTO memory_meta (key, value) VALUES (?, ?)",
        (key, value)
    )

def _normalize_core_memory(value: Any) -> str:
    if isinstance(value, list):
        return "\n".join([str(item) for item in value])
    if value is None:
        return ""
    return str(value)

def _get_memory_length() -> int:
    return 60

def _if_in_menstruation(role_id: str) -> tuple[Optional[bool], Optional[int]]:
    profile_path = ROLES_DIR / role_id / "profile.json"
    if not profile_path.exists():
        return None, None

    try:
        with open(profile_path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        return None, None
    gentle = data.get("gender", "men")
    if gentle != "women":
        print(f"生理期检测：角色 {role_id} 性别为 {gentle}，不进行生理期检测")
        return None, None
    import random

    profile_updated = False
    cycle_data = data.get("menstruation_cycle")
    if not isinstance(cycle_data, dict):
        cycle_data = {}

    cycle_length = cycle_data.get("cycle_length")
    if not cycle_length:
        cycle_length = 28 + random.randint(-5, 5)
        cycle_data["cycle_length"] = cycle_length
        profile_updated = True

    period_length = cycle_data.get("period_length")
    if not period_length:
        period_length = 5 + random.randint(-1, 2)
        cycle_data["period_length"] = period_length
        profile_updated = True

    if profile_updated:
        data["menstruation_cycle"] = cycle_data
        with open(profile_path, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=4)

    with _get_connection(role_id) as conn:
        last_period_start_raw = _get_meta(conn, "last_period_start")

        if not last_period_start_raw:
            profile_last_period_start = cycle_data.get("last_period_start")
            if profile_last_period_start:
                last_period_start_raw = profile_last_period_start

        try:
            last_period_start_date = datetime.fromisoformat(last_period_start_raw).date()
        except (TypeError, ValueError):
            last_period_start_date = (datetime.now() - timedelta(days=random.randint(0, cycle_length))).date()

        today = datetime.now().date()

        while last_period_start_date + timedelta(days=cycle_length) <= today:
            last_period_start_date = last_period_start_date + timedelta(days=cycle_length + random.randint(-5, 5))
            if last_period_start_date > today:
                last_period_start_date = today
        _set_meta(conn, "last_period_start", last_period_start_date.isoformat())

    day_offset = (today - last_period_start_date).days
    if day_offset < period_length:
        return True, day_offset + 1

    return False, day_offset - period_length + 1

def _get_menstruation_cycle_info(role_id: str) -> Optional[Dict[str, Any]]:
    profile_path = ROLES_DIR / role_id / "profile.json"
    if not profile_path.exists():
        return None

    try:
        with open(profile_path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        return None

    gentle = data.get("gender", "men")
    if gentle == "women":
        cycle_data = data.get("menstruation_cycle", {})
        return {
            "cycle_length": cycle_data.get("cycle_length"),
            "period_length": cycle_data.get("period_length")
        }

def _get_role_core_memory(role_id: str) -> str:
    profile_path = ROLES_DIR / role_id / "profile.json"
    if not profile_path.exists():
        return ""

    try:
        with open(profile_path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        return ""

    return _normalize_core_memory(data.get("core_memory", ""))

def _maybe_migrate_from_json(role_id: str, conn: sqlite3.Connection):
    if _get_meta(conn, "migrated_from_json"):
        return

    json_path = get_memory_json(role_id)
    if not json_path.exists():
        return

    has_meta = conn.execute("SELECT 1 FROM memory_meta LIMIT 1").fetchone()
    has_short = conn.execute("SELECT 1 FROM short_term LIMIT 1").fetchone()
    if has_meta or has_short:
        return

    with open(json_path, "r", encoding="utf-8") as f:
        data = json.load(f)

    core_memory = _normalize_core_memory(data.get("core_memory", ""))
    _set_meta(conn, "core_memory", core_memory)
    _set_meta(conn, "last_summarized_at", data.get("last_summarized_at"))
    _set_meta(conn, "message_count_since_summary", str(data.get("message_count_since_summary", 0)))
    _set_meta(conn, "updated_at", data.get("updated_at") or datetime.now().isoformat())

    short_term = data.get("short_term", [])
    for item in short_term:
        if isinstance(item, dict):
            role = item.get("role") or "assistant"
            content = item.get("content", "")
            timestamp = item.get("timestamp") or datetime.now().isoformat()
        else:
            role = "assistant"
            content = str(item)
            timestamp = datetime.now().isoformat()
        conn.execute(
            "INSERT INTO short_term (role, content, timestamp) VALUES (?, ?, ?)",
            (role, content, timestamp)
        )

    _set_meta(conn, "migrated_from_json", datetime.now().isoformat())

def _get_connection(role_id: str) -> sqlite3.Connection:
    db_path = get_memory_db(role_id)
    conn = sqlite3.connect(db_path)
    _init_db(conn)
    _maybe_migrate_from_json(role_id, conn)
    return conn

def load_memory(role_id: str) -> Dict:
    """加载角色记忆"""
    with _get_connection(role_id) as conn:
        core_memory = _get_meta(conn, "core_memory", "") or ""
        last_summarized_at = _get_meta(conn, "last_summarized_at")
        message_count = _get_meta(conn, "message_count_since_summary", "0")
        try:
            message_count_int = int(message_count)
        except (TypeError, ValueError):
            message_count_int = 0

        rows = conn.execute(
            "SELECT role, content, timestamp FROM short_term ORDER BY id ASC"
        ).fetchall()
        short_term = [
            {"role": row[0] or "assistant", "content": row[1], "timestamp": row[2]}
            for row in rows
        ]

        # role_core = _get_role_core_memory(role_id)
        # if role_core and role_core != core_memory:
        #     core_memory = role_core
        #     _set_meta(conn, "core_memory", core_memory)
        #     _set_meta(conn, "updated_at", datetime.now().isoformat())

    return {
        "core_memory": core_memory,
        "short_term": short_term,
        "last_summarized_at": last_summarized_at,
        "message_count_since_summary": message_count_int
    }

def save_memory(role_id: str, memory: Dict):
    """保存角色记忆"""
    with _get_connection(role_id) as conn:
        core_memory = _normalize_core_memory(memory.get("core_memory", ""))
        _set_meta(conn, "core_memory", core_memory)
        _set_meta(conn, "last_summarized_at", memory.get("last_summarized_at"))
        _set_meta(conn, "message_count_since_summary", str(memory.get("message_count_since_summary", 0)))
        _set_meta(conn, "updated_at", datetime.now().isoformat())

        conn.execute("DELETE FROM short_term")
        short_term = memory.get("short_term", [])
        for item in short_term:
            if isinstance(item, dict):
                role = item.get("role") or "assistant"
                content = item.get("content", "")
                timestamp = item.get("timestamp") or datetime.now().isoformat()
            else:
                role = "assistant"
                content = str(item)
                timestamp = datetime.now().isoformat()
            conn.execute(
                "INSERT INTO short_term (role, content, timestamp) VALUES (?, ?, ?)",
                (role, content, timestamp)
            )

def append_short_term(role_id: str, role: str, content: str, window_size: int = 100):
    """
    追加短期记忆，使用滑动窗口机制
    
    Args:
        role_id: 角色 ID
        role: 消息角色 (user/assistant)
        content: 消息内容
        window_size: 滑动窗口大小，默认为100条
    """
    with _get_connection(role_id) as conn:
        total = conn.execute("SELECT COUNT(*) FROM short_term").fetchone()[0]

        conn.execute(
            "INSERT INTO short_term (role, content, timestamp) VALUES (?, ?, ?)",
            (role, content, datetime.now().isoformat())
        )

        current_count = _get_meta(conn, "message_count_since_summary", "0")
        try:
            current_count_int = int(current_count)
        except (TypeError, ValueError):
            current_count_int = 0
        _set_meta(conn, "message_count_since_summary", str(current_count_int + 1))
        _set_meta(conn, "updated_at", datetime.now().isoformat())

async def trigger_chat_summary(worker_id:str,role_id: str) -> Optional[str]:
    """
    触发记忆总结（内部调用，不暴露给前端）
    
    Returns:
        新的核心记忆内容，或 None（如果不需要总结）
    """
    # 导入 AI 服务
    from services.ai_service import call_ai_direct
    try:
        role_memory = load_memory(role_id)
        short_term = role_memory.get("short_term", [])

        # 构建总结提示
        conversation = "\n".join([
            f"{m['role']}：{m['content']}"
            for m in short_term[-_get_memory_length():]
        ])
        
        prompt = f"最近对话：{conversation}"
        from routers.roles import load_role
        worker_data = load_role(worker_id)
        system_prompt = worker_data.get("system_prompt", "")
        messages = []
        messages.append({"role": "system", "content": system_prompt})
        messages.append({"role": "user", "content": prompt})
    except Exception as e:
        print(f"构建记忆总结提示时发生错误：{e}")
        return None
    try:    
        result = await call_ai_direct(messages=messages, model=worker_data.get("ai_model"), api_url=worker_data.get("ai_api_url"), api_key=worker_data.get("ai_api_key"), temperature=worker_data.get("ai_temperature", 0.1))
        if result["success"] and result["content"]:
            new_memory = result["content"].strip()
            append_short_term(role_id, "user", f"system:触发记忆总结")
            append_short_term(role_id, "assistant", f"记忆总结结果：{new_memory}")
            return new_memory
        else:
            print(f"记忆总结失败：{result}")
    except Exception as e:
        print(f"调用 AI 进行记忆总结时发生错误：{e}")
        return None    
    
    return None

async def get_context_messages(role_id: str, limit: int = 20) -> List[Dict]:
    """
    获取对话上下文消息
    
    Returns:
        [{"role": "user/assistant", "content": "..."}]
    """
    if limit <= 0:
        return []

    need_trigger_summary = False
    block_start = 0

    with _get_connection(role_id) as conn:
        total = conn.execute("SELECT COUNT(*) FROM short_term").fetchone()[0]
        if total == 0:
            return []

        block_start = ((total - 1) // limit) * limit
        last_block_value = _get_meta(conn, "last_context_block_start", "-1")
        try:
            last_block = int(last_block_value)
        except (TypeError, ValueError):
            last_block = -1

        if last_block != block_start:
            _set_meta(conn, "last_context_block_start", str(block_start))
            need_trigger_summary = True

    if need_trigger_summary:
        content = await trigger_chat_summary(worker_id="1000000000002", role_id=role_id)
        if not content:
            print(f"触发对话总结失败，无法获取新的上下文消息")

    with _get_connection(role_id) as conn:
        rows = conn.execute(
            "SELECT role, content FROM short_term ORDER BY id ASC LIMIT ? OFFSET ?",
            (limit, block_start)
        ).fetchall()

    return [
        {"role": row[0] or "assistant", "content": row[1]}
        for row in rows
    ]



def get_core_memory(role_id: str) -> str:
    """获取核心记忆"""
    with _get_connection(role_id) as conn:
        return _get_meta(conn, "core_memory", "") or ""

def update_core_memory(role_id: str, core_memory: str):
    """更新核心记忆（由 AI 总结生成）"""
    core_memory = _normalize_core_memory(core_memory)
    with _get_connection(role_id) as conn:
        _set_meta(conn, "core_memory", core_memory)
        _set_meta(conn, "last_summarized_at", datetime.now().isoformat())
        _set_meta(conn, "message_count_since_summary", "0")
        _set_meta(conn, "updated_at", datetime.now().isoformat())

def should_generate_sequential_memory(role_id: str) -> bool:
    """
    判断是否需要生成衔接记忆
    
    条件：
    - 距离上次生成超过 20 分钟
    """
    with _get_connection(role_id) as conn:
        updated_at = _get_meta(conn, "updated_at")
    
    if not updated_at:
        return True

    try:
        last_updated = datetime.fromisoformat(updated_at)
    except (TypeError, ValueError):
        return True

    return (datetime.now() - last_updated).total_seconds() >= 1200

def should_summarize(role_id: str) -> bool:
    """
    判断是否需要总结核心记忆
    
    条件：
    - 距离上次总结超过 60 条消息
    """
    with _get_connection(role_id) as conn:
        count_value = _get_meta(conn, "message_count_since_summary", "0")
        try:
            count = int(count_value)
        except (TypeError, ValueError):
            count = 0
        last_summarized = _get_meta(conn, "last_summarized_at")
    
    return count >= _get_memory_length()

async def sequential_memory_generation(role_id:str,worker_id:str,now_content:str) -> Optional[str]:
    """
    生成衔接记忆，用于在长时间不聊天后模拟中间的场景变化，保持对话连续性
    """
    try:
        if not should_generate_sequential_memory(role_id):
            return "noneed"
    except Exception as e:
        print(f"检查是否需要生成衔接记忆时发生错误：{e}")
        return None
    # 导入 AI 服务
    from services.ai_service import call_ai_direct
    from routers.roles import load_role
    try:
        memory = load_memory(role_id)
        worker = load_role(worker_id)
        short_term = memory.get("short_term", [])
        conversation = "\n".join([
            f"{m['role']}：{m['content']}"
            for m in short_term[-_get_memory_length():]
        ])
        prompt = f"""历史对话内容：{conversation}\n当前对话内容：{now_content}\n当前时间：{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}"""
        system_prompt = worker.get("system_prompt", "")
        messages = []
        messages.append({"role": "system", "content": system_prompt})
        messages.append({"role": "user", "content": prompt})
    except Exception as e:
        print(f"构建衔接记忆提示时发生错误：{e}")
        return None
    try:
        result = await call_ai_direct(messages=messages, model=worker.get("ai_model"), api_url=worker.get("ai_api_url"), api_key=worker.get("ai_api_key"), temperature=worker.get("ai_temperature", 1.2))
        if result["success"] and result["content"]:
            if result["content"].strip().lower() == "none":
                return "noneed"
            new_memory = result["content"].strip()
            append_short_term(role_id, "user", f"system:触发衔接记忆生成")
            append_short_term(role_id, "assistant", f"衔接记忆内容：{new_memory}")
            return new_memory
        else:
            print(f"衔接记忆生成失败：{result}")
    except Exception as e:
        print(f"调用 AI 生成衔接记忆时发生错误：{e}")
        return None

async def trigger_memory_summary(role_id: str, role_data: Dict) -> Optional[str]:
    """
    触发记忆总结（内部调用，不暴露给前端）
    
    Returns:
        新的核心记忆内容，或 None（如果不需要总结）
    """
    try:
        if not should_summarize(role_data.get("id", role_id)):
            return "noneed"
    except Exception as e:
        print(f"检查是否需要总结核心记忆时发生错误：{e}")
        return None
    # 导入 AI 服务
    from services.ai_service import call_ai_direct
    try:
        memory = load_memory(role_data.get("id", role_id))
        short_term = memory.get("short_term", [])
        current_core = memory.get("core_memory", "")
        role_need_change = role_data.get("id", role_id)
        
        # 构建总结提示
        conversation = "\n".join([
            f"{m['role']}：{m['content']}"
            for m in short_term[-_get_memory_length():]
        ])
        
        prompt = f"""
    当前已有的核心记忆：
    {current_core if current_core else '（暂无）'}
    最近对话：
    {conversation}
    """
        from routers.roles import load_role
        role_data = load_role(role_id)
        system_prompt = role_data.get("system_prompt", "")
        messages = []
        messages.append({"role": "system", "content": system_prompt})
        messages.append({"role": "user", "content": prompt})
    except Exception as e:
        print(f"构建记忆总结提示时发生错误：{e}")
        return None
    try:    
        result = await call_ai_direct(messages=messages, model=role_data.get("ai_model"), api_url=role_data.get("ai_api_url"), api_key=role_data.get("ai_api_key"), temperature=role_data.get("ai_temperature", 0.1))
        if result["success"] and result["content"]:
            new_core = result["content"].strip()
            update_core_memory(role_need_change, new_core)
            return new_core
        else:
            print(f"记忆总结失败：{result}")
    except Exception as e:
        print(f"调用 AI 进行记忆总结时发生错误：{e}")
        return None    
    
    return None

def clear_short_term(role_id: str):
    """清空短期记忆"""
    with _get_connection(role_id) as conn:
        conn.execute("DELETE FROM short_term")
        _set_meta(conn, "updated_at", datetime.now().isoformat())

def get_memory_context_string(role_id: str) -> str:
    """
    获取记忆上下文字符串（用于 AI 提示）
    """
    core = load_memory(role_id).get("core_memory", "")
    if core:
        return f"你的设定和对用户的理解(“我”指你自己(assistant)，用户指使用者“user”)：{core}"
    return ""

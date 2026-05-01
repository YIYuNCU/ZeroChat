"""
记忆服务
管理角色的短期记忆和核心记忆
"""
import asyncio
import json
import random
import sqlite3
from datetime import datetime, timedelta
from pathlib import Path
from typing import Optional, List, Dict, Any
import uuid

from core.utils import is_tool_role_id
from services.vector_memory import VectorMemoryStore, embed_and_store, _extract_semantic_text

DATA_DIR = Path(__file__).parent.parent / "data"
ROLES_DIR = DATA_DIR / "roles"
DEFAULT_MEMORY_ORIGIN = "zerochat"

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
            id INTEGER PRIMARY KEY,
            role TEXT,
            content TEXT,
            timestamp TEXT,
            task_id TEXT,
            request_id TEXT,
            json_memory TEXT
        )
        """
    )
    _ensure_short_term_schema(conn)


def _table_has_autoincrement(conn: sqlite3.Connection, table_name: str) -> bool:
    row = conn.execute(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
        (table_name,),
    ).fetchone()
    if not row or not row[0]:
        return False
    return "AUTOINCREMENT" in str(row[0]).upper()


def _ensure_short_term_schema(conn: sqlite3.Connection):
    cols = conn.execute("PRAGMA table_info(short_term)").fetchall()
    existing_cols = {str(c[1]) for c in cols}

    if "task_id" not in existing_cols:
        conn.execute("ALTER TABLE short_term ADD COLUMN task_id TEXT")
    if "request_id" not in existing_cols:
        conn.execute("ALTER TABLE short_term ADD COLUMN request_id TEXT")
    if "json_memory" not in existing_cols:
        conn.execute("ALTER TABLE short_term ADD COLUMN json_memory TEXT")

    if _table_has_autoincrement(conn, "short_term"):
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS short_term_new (
                id INTEGER PRIMARY KEY,
                role TEXT,
                content TEXT,
                timestamp TEXT,
                task_id TEXT,
                request_id TEXT,
                json_memory TEXT
            )
            """
        )
        conn.execute(
            """
            INSERT INTO short_term_new (id, role, content, timestamp, task_id, request_id, json_memory)
            SELECT id, role, content, timestamp, task_id, request_id, json_memory
            FROM short_term
            ORDER BY id ASC
            """
        )
        conn.execute("DROP TABLE short_term")
        conn.execute("ALTER TABLE short_term_new RENAME TO short_term")

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


def _core_memory_to_list(value: Any) -> List[str]:
    text = _normalize_core_memory(value)
    if not text.strip():
        return []
    return [line.strip() for line in text.splitlines() if line.strip()]

def _get_memory_length() -> int:
    return 120


STRUCTURED_MEMORY_PREFIXES = ("message:", "time:", "origin:", "sender:")


def _looks_like_standard_json_memory(content: str) -> bool:
    text = str(content or "").strip()
    if not text:
        return False
    try:
        parsed = json.loads(text)
    except Exception:
        return False
    if not isinstance(parsed, dict):
        return False
    required_keys = {"message", "time", "origin", "sender"}
    return required_keys.issubset(set(parsed.keys()))


def _parse_legacy_structured_memory(content: str) -> Optional[Dict[str, str]]:
    text = str(content or "").strip()
    if not text:
        return None

    lines = [line.strip() for line in text.splitlines() if line.strip()]
    if len(lines) < 4:
        return None

    first_four = [line.lower() for line in lines[:4]]
    if not all(first_four[idx].startswith(STRUCTURED_MEMORY_PREFIXES[idx]) for idx in range(4)):
        return None

    def _value(line: str) -> str:
        parts = line.split(":", 1)
        return parts[1].strip() if len(parts) > 1 else ""

    return {
        "message": _value(lines[0]),
        "time": _value(lines[1]),
        "origin": _value(lines[2]),
        "sender": _value(lines[3]),
    }


def _looks_like_structured_memory(content: str) -> bool:
    text = str(content or "").strip()
    if not text:
        return False
    if _looks_like_standard_json_memory(text):
        return True

    legacy = _parse_legacy_structured_memory(text)
    if legacy is not None:
        return True

    lines = [line.strip() for line in text.splitlines() if line.strip()]
    if len(lines) < 4:
        return False
    first_four = [line.lower() for line in lines[:4]]
    return all(first_four[idx].startswith(STRUCTURED_MEMORY_PREFIXES[idx]) for idx in range(4))


def format_memory_message(
    message: str,
    timestamp: Optional[str] = None,
    origin: Optional[str] = None,
    sender: Optional[str] = None,
) -> str:
    payload = {
        "message": str(message or "").strip(),
        "time": str(timestamp or "").strip() or datetime.now().isoformat(),
        "origin": str(origin or "").strip() or DEFAULT_MEMORY_ORIGIN,
        "sender": str(sender or "").strip() or "unknown",
    }
    return json.dumps(payload, ensure_ascii=False)


def ensure_structured_memory_message(
    content: str,
    role: Optional[str] = None,
    timestamp: Optional[str] = None,
    origin: Optional[str] = None,
    sender: Optional[str] = None,
) -> str:
    text = str(content or "").strip()
    if _looks_like_standard_json_memory(text):
        try:
            parsed = json.loads(text)
            if isinstance(parsed, dict):
                return format_memory_message(
                    message=str(parsed.get("message") or ""),
                    timestamp=str(parsed.get("time") or "").strip() or timestamp,
                    origin=str(parsed.get("origin") or "").strip() or origin,
                    sender=str(parsed.get("sender") or "").strip() or sender,
                )
        except Exception:
            pass

    legacy = _parse_legacy_structured_memory(text)
    if legacy is not None:
        return format_memory_message(
            message=legacy.get("message") or "",
            timestamp=legacy.get("time") or timestamp,
            origin=legacy.get("origin") or origin,
            sender=legacy.get("sender") or sender,
        )

    if _looks_like_structured_memory(text):
        return text

    role_text = str(role or "").strip() or "assistant"
    sender_text = str(sender or "").strip() or role_text
    return format_memory_message(
        message=text,
        timestamp=timestamp,
        origin=origin,
        sender=sender_text,
    )

def _normalize_gender(data: dict) -> str:
    """Normalize gender value to 'women' or 'men'."""
    gender_raw = str(data.get("gender", "men") or "men").strip().lower()
    legacy_women = {"women", "woman", "female", "girl", "f", "女", "女生", "女性"}
    if gender_raw in legacy_women:
        return "women"
    return "men"


def _save_profile(profile_path: Path, data: dict):
    """Save role profile to JSON file."""
    profile_path.parent.mkdir(parents=True, exist_ok=True)
    with open(profile_path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=4)


def _load_cycle_data(data: dict) -> tuple[dict, int, int, bool]:
    """Load and validate menstruation cycle parameters."""

    cycle_data = data.get("menstruation_cycle") or {}
    if not isinstance(cycle_data, dict):
        cycle_data = {}
    profile_updated = False

    cycle_length = _clamp_int(cycle_data.get("cycle_length"), 28, 20, 40, jitter=lambda: random.randint(-5, 5))
    if cycle_data.get("cycle_length") != cycle_length:
        cycle_data["cycle_length"] = cycle_length
        profile_updated = True

    period_length = _clamp_int(cycle_data.get("period_length"), 5, 2, 10, jitter=lambda: random.randint(-1, 2))
    if period_length >= cycle_length:
        period_length = max(2, min(10, cycle_length - 1))
    if cycle_data.get("period_length") != period_length:
        cycle_data["period_length"] = period_length
        profile_updated = True

    return cycle_data, cycle_length, period_length, profile_updated


def _clamp_int(value, default: int, min_val: int, max_val: int, jitter=None) -> int:
    """Parse and clamp an integer value with optional jitter fallback."""

    try:
        result = int(value)
    except (TypeError, ValueError):
        result = default + (jitter() if jitter else 0)
    if result < min_val or result > max_val:
        result = default + (jitter() if jitter else 0)
    return result


def _advance_period_cycles(last_start: datetime.date, cycle_length: int, today: datetime.date) -> datetime.date:
    """Advance period start date to the most recent cycle within range of today."""

    while last_start + timedelta(days=cycle_length) <= today:
        jitter = cycle_length + random.randint(-2, 2)
        next_start = last_start + timedelta(days=max(jitter, 1))
        if next_start > today or next_start <= last_start:
            next_start = last_start + timedelta(days=cycle_length)
            if next_start > today:
                break
        last_start = next_start
    return last_start


def _if_in_menstruation(role_id: str) -> tuple[Optional[bool], Optional[int]]:
    profile_path = ROLES_DIR / role_id / "profile.json"
    if not profile_path.exists():
        return None, None

    try:
        with open(profile_path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        return None, None

    gentle = _normalize_gender(data)
    if data.get("gender") != gentle:
        data["gender"] = gentle

    if gentle != "women":
        print(f"生理期检测：角色 {role_id} 性别为 {gentle}，不进行生理期检测")
        _save_profile(profile_path, data)
        return None, None

    cycle_data, cycle_length, period_length, profile_updated = _load_cycle_data(data)
    if profile_updated:
        data["menstruation_cycle"] = cycle_data
        _save_profile(profile_path, data)

    today = datetime.now().date()
    with _get_connection(role_id) as conn:
        last_start = _get_or_init_last_period_start(conn, cycle_data, cycle_length, today)
        last_start = _advance_period_cycles(last_start, cycle_length, today)

        _set_meta(conn, "last_period_start", last_start.isoformat())
        _set_meta(conn, "next_period_start", (last_start + timedelta(days=cycle_length)).isoformat())

    day_offset = max(0, (today - last_start).days)
    if day_offset < period_length:
        return True, day_offset + 1

    days_until_next = max(1, (last_start + timedelta(days=cycle_length) - today).days)
    return False, days_until_next


def _get_or_init_last_period_start(conn, cycle_data: dict, cycle_length: int, today: datetime.date):
    """Get last period start from DB or initialize from profile data."""

    last_raw = _get_meta(conn, "last_period_start")
    if not last_raw:
        profile_start = cycle_data.get("last_period_start")
        try:
            last_date = datetime.fromisoformat(profile_start).date()
        except (TypeError, ValueError):
            last_date = today - timedelta(days=random.randint(0, max(1, cycle_length - 1)))
        last_date = min(last_date, today)
        _set_meta(conn, "last_period_start", last_date.isoformat())
        return last_date

    try:
        last_date = datetime.fromisoformat(last_raw).date()
    except (TypeError, ValueError):
        last_date = today - timedelta(days=random.randint(0, max(1, cycle_length - 1)))
    return min(last_date, today)

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
            content = ensure_structured_memory_message(
                content=item.get("content", ""),
                role=role,
                timestamp=item.get("timestamp"),
                origin=item.get("origin") or item.get("source") or DEFAULT_MEMORY_ORIGIN,
                sender=item.get("sender") or role,
            )
            timestamp = item.get("timestamp") or datetime.now().isoformat()
            task_id = item.get("task_id")
            request_id = item.get("request_id") or item.get("req_id")
            json_memory = item.get("json_memory")
        else:
            role = "assistant"
            timestamp = datetime.now().isoformat()
            content = ensure_structured_memory_message(
                content=str(item),
                role=role,
                timestamp=timestamp,
                origin=DEFAULT_MEMORY_ORIGIN,
                sender=role,
            )
            task_id = None
            request_id = None
            json_memory = None
        conn.execute(
            """
            INSERT INTO short_term (role, content, timestamp, task_id, request_id, json_memory)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            (role, content, timestamp, task_id, request_id, json_memory)
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
    if is_tool_role_id(role_id):
        db_path = get_memory_db(role_id)
        json_path = get_memory_json(role_id)
        if db_path.exists():
            db_path.unlink()
        if json_path.exists():
            json_path.unlink()
        return {
            "core_memory": "",
            "short_term": [],
            "last_summarized_at": None,
            "message_count_since_summary": 0,
        }

    with _get_connection(role_id) as conn:
        core_memory = _get_meta(conn, "core_memory", "") or ""
        last_summarized_at = _get_meta(conn, "last_summarized_at")
        message_count = _get_meta(conn, "message_count_since_summary", "0")
        try:
            message_count_int = int(message_count)
        except (TypeError, ValueError):
            message_count_int = 0

        rows = conn.execute(
            """
            SELECT id, role, content, timestamp, task_id, request_id, json_memory
            FROM short_term
            ORDER BY id ASC
            """
        ).fetchall()
        short_term = [
            {
                "id": row[0],
                "role": row[1] or "assistant",
                "content": ensure_structured_memory_message(
                    content=row[2],
                    role=row[1] or "assistant",
                    timestamp=row[3],
                    origin=DEFAULT_MEMORY_ORIGIN,
                    sender=row[1] or "assistant",
                ),
                "timestamp": row[3],
                "task_id": row[4],
                "request_id": row[5],
                "json_memory": row[6],
            }
            for row in rows
        ]

        # 兼容存量角色：若 DB 里没有核心记忆，则回退读取 profile.json 并写回 DB。
        if not str(core_memory or "").strip():
            role_core = _get_role_core_memory(role_id)
            if role_core and role_core.strip():
                core_memory = role_core
                _set_meta(conn, "core_memory", core_memory)
                _set_meta(conn, "updated_at", datetime.now().isoformat())

    return {
        "core_memory": core_memory,
        "short_term": short_term,
        "last_summarized_at": last_summarized_at,
        "message_count_since_summary": message_count_int,
        "vector_memory_count": _get_vector_memory_count(role_id),
    }


def _get_vector_memory_count(role_id: str) -> int:
    try:
        from services.vector_memory import VectorMemoryStore
        return VectorMemoryStore(role_id).count()
    except Exception:
        return 0

def save_memory(role_id: str, memory: Dict):
    """保存角色记忆"""
    if is_tool_role_id(role_id):
        return

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
                timestamp = item.get("timestamp") or datetime.now().isoformat()
                content = ensure_structured_memory_message(
                    content=item.get("content", ""),
                    role=role,
                    timestamp=timestamp,
                    origin=item.get("origin") or item.get("source") or DEFAULT_MEMORY_ORIGIN,
                    sender=item.get("sender") or role,
                )
                task_id = item.get("task_id")
                request_id = item.get("request_id") or item.get("req_id")
                json_memory = item.get("json_memory")
            else:
                role = "assistant"
                timestamp = datetime.now().isoformat()
                content = ensure_structured_memory_message(
                    content=str(item),
                    role=role,
                    timestamp=timestamp,
                    origin=DEFAULT_MEMORY_ORIGIN,
                    sender=role,
                )
                task_id = None
                request_id = None
                json_memory = None
            conn.execute(
                """
                INSERT INTO short_term (role, content, timestamp, task_id, request_id, json_memory)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                (role, content, timestamp, task_id, request_id, json_memory)
            )
        # memory.json 由前端维护，后端不主动覆盖。

def append_short_term(
    role_id: str,
    role: str,
    content: str,
    window_size: int = 100,
    task_id: Optional[str] = None,
    request_id: Optional[str] = None,
    json_memory: Optional[str] = None,
    origin: Optional[str] = None,
    sender: Optional[str] = None,
):
    """
    追加短期记忆，使用滑动窗口机制

    Args:
        role_id: 角色 ID
        role: 消息角色 (user/assistant)
        content: 消息内容
        window_size: 兼容旧参数，当前不再用于写入裁剪
    """
    if is_tool_role_id(role_id):
        return

    normalized_task_id = str(task_id).strip() if task_id is not None else None
    if normalized_task_id == "":
        normalized_task_id = None
    normalized_request_id = str(request_id).strip() if request_id is not None else ""
    if not normalized_request_id:
        normalized_request_id = f"req_{uuid.uuid4().hex}"
    normalized_json_memory = str(json_memory).strip() if json_memory is not None else None
    if normalized_json_memory == "":
        normalized_json_memory = None
    created_at = datetime.now().isoformat()
    if role == "assistant":
        normalized_content = content
    else:
        normalized_content = ensure_structured_memory_message(
            content=content,
            role=role,
            timestamp=created_at,
            origin=origin or DEFAULT_MEMORY_ORIGIN,
            sender=sender or role,
        )

    with _get_connection(role_id) as conn:
        conn.execute(
            """
            INSERT INTO short_term (role, content, timestamp, task_id, request_id, json_memory)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            (
                role,
                normalized_content,
                created_at,
                normalized_task_id,
                normalized_request_id,
                normalized_json_memory,
            )
        )

        current_count = _get_meta(conn, "message_count_since_summary", "0")
        try:
            current_count_int = int(current_count)
        except (TypeError, ValueError):
            current_count_int = 0
        _set_meta(conn, "message_count_since_summary", str(current_count_int + 1))
        _set_meta(conn, "updated_at", datetime.now().isoformat())
        # memory.json 由前端维护，后端仅保证 request_id 在 DB 记录中可用。

    # 对用户消息异步生成向量嵌入，存入向量记忆库
    if role == "user" and len(content.strip()) >= 10:
        try:
            asyncio.ensure_future(embed_and_store(
                role_id, normalized_content, role="user",
                timestamp=created_at, source="chat"
            ))
        except Exception:
            pass

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
            str(m.get("content", ""))
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
            append_short_term(role_id, "user", "system:触发记忆总结", origin="system", sender="system")
            append_short_term(role_id, "assistant", f"记忆总结结果：{new_memory}", origin="system", sender="memory_summary")
            return new_memory
        else:
            print(f"记忆总结失败：{result}")
    except Exception as e:
        print(f"调用 AI 进行记忆总结时发生错误：{e}")
        return None

    return None

async def get_context_messages(
    role_id: str,
    limit: int = 20,
    user_message: Optional[str] = None,
) -> List[Dict]:
    """
    获取对话上下文消息

    Args:
        role_id: 角色 ID
        limit: 限制条数（兼容参数，实际使用 _get_memory_length()）
        user_message: 当前用户消息（保留参数以兼容旧调用）

    Returns:
        [{"role": "user/assistant", "content": "..."}]
    """
    effective_limit = _get_memory_length()
    if effective_limit <= 0:
        return []
    if is_tool_role_id(role_id):
        return []

    need_trigger_summary = False
    block_start = 0

    with _get_connection(role_id) as conn:
        total = conn.execute("SELECT COUNT(*) FROM short_term").fetchone()[0]
        if total == 0:
            return []

        block_start = ((total - 1) // effective_limit) * effective_limit
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
            "SELECT role, content, timestamp FROM short_term ORDER BY id ASC LIMIT ? OFFSET ?",
            (effective_limit, block_start)
        ).fetchall()

    context = [
        {
            "role": row[0] or "assistant",
            "content": ensure_structured_memory_message(
                content=row[1],
                role=row[0] or "assistant",
                timestamp=row[2],
                origin=DEFAULT_MEMORY_ORIGIN,
                sender=row[0] or "assistant",
            ),
        }
        for row in rows
    ]

    return context


async def get_relevant_memories(
    role_id: str,
    query: str,
    top_k: int = 2,
    min_score: float = 0.8,
    min_text_length: int = 10,
) -> List[Dict]:
    """
    基于语义相似度检索相关历史记忆

    Args:
        role_id: 角色 ID
        query: 查询文本（当前用户消息）
        top_k: 返回 top-k 结果
        min_score: 最低相似度阈值
        min_text_length: 查询最小长度

    Returns:
        [{"text": str, "source": str, "role": str, "score": float}, ...]
    """
    if is_tool_role_id(role_id) or len(query.strip()) < min_text_length:
        return []

    store = VectorMemoryStore(role_id)
    if store.count() == 0:
        return []

    from services.ai_service import generate_embedding
    result = await generate_embedding(query.strip())
    if not result["success"] or not result["embedding"]:
        return []

    results = store.search(result["embedding"], top_k=top_k, min_score=min_score)
    return [
        {
            "text": _extract_semantic_text(r["text"]),
            "source": r["source"],
            "role": r["role"],
            "score": r["score"],
        }
        for r in results
    ]


def get_core_memory(role_id: str) -> str:
    """获取核心记忆"""
    if is_tool_role_id(role_id):
        return ""
    with _get_connection(role_id) as conn:
        return _get_meta(conn, "core_memory", "") or ""

def update_core_memory(role_id: str, core_memory: str):
    """更新核心记忆（由 AI 总结生成）"""
    if is_tool_role_id(role_id):
        return
    core_memory = _normalize_core_memory(core_memory)
    with _get_connection(role_id) as conn:
        _set_meta(conn, "core_memory", core_memory)
        _set_meta(conn, "last_summarized_at", datetime.now().isoformat())
        _set_meta(conn, "message_count_since_summary", "0")
        _set_meta(conn, "updated_at", datetime.now().isoformat())
        # memory.json 由前端维护，后端不主动覆盖。

def should_generate_sequential_memory(role_id: str) -> bool:
    """
    判断是否需要生成衔接记忆
    
    条件：
    - 距离上次生成超过 20 分钟
    """
    if is_tool_role_id(role_id):
        return False

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
    - 距离上次总结超过 _get_memory_length 条消息
    """
    if is_tool_role_id(role_id):
        return False

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
            str(m.get("content", ""))
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
            append_short_term(role_id, "user", "system:触发衔接记忆生成", origin="system", sender="system")
            append_short_term(role_id, "assistant", f"衔接记忆内容：{new_memory}", origin="system", sender="sequential_memory")
            # 将衔接记忆存入向量记忆库
            try:
                asyncio.ensure_future(embed_and_store(
                    role_id, new_memory, role="assistant",
                    source="sequential", min_text_length=5
                ))
            except Exception:
                pass
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
            str(m.get("content", ""))
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
            # 将核心记忆存入向量记忆库
            try:
                asyncio.ensure_future(embed_and_store(
                    role_id, new_core, role="assistant",
                    source="core_summary", min_text_length=5
                ))
            except Exception:
                pass
            return new_core
        else:
            print(f"记忆总结失败：{result}")
    except Exception as e:
        print(f"调用 AI 进行记忆总结时发生错误：{e}")
        return None

    return None

def clear_short_term(role_id: str):
    """清空短期记忆"""
    if is_tool_role_id(role_id):
        return
    with _get_connection(role_id) as conn:
        conn.execute("DELETE FROM short_term")
        _set_meta(conn, "updated_at", datetime.now().isoformat())
        # memory.json 由前端维护，后端不主动覆盖。

def clear_vector_memory(role_id: str):
    """清空向量记忆库"""
    if is_tool_role_id(role_id):
        return
    from services.vector_memory import VectorMemoryStore
    VectorMemoryStore(role_id).clear()

def get_memory_context_string(role_id: str) -> str:
    """
    获取记忆上下文字符串（用于 AI 提示）
    """
    if is_tool_role_id(role_id):
        return ""
    core = load_memory(role_id).get("core_memory", "")
    if core:
        return f"你的设定和对用户的理解(“我”指你自己(assistant)，用户指使用者“user”)：{core}"
    return ""

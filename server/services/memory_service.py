"""
记忆服务
管理角色的短期记忆和核心记忆
"""
import asyncio
import logging
import json
import random
import sqlite3
from datetime import datetime, timedelta
from pathlib import Path
from typing import Optional, List, Dict, Any
import uuid

from core.utils import is_tool_role_id
from services.vector_memory import VectorMemoryStore, embed_and_store, _extract_semantic_text

logger = logging.getLogger(__name__)
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

# 连接池缓存 + WAL 模式
_CONNECTION_POOL: Dict[str, sqlite3.Connection] = {}
_POOL_LOCK = None
try:
    import threading
    _POOL_LOCK = threading.Lock()
except ImportError:
    pass

_EXECUTOR = None
def _get_executor():
    global _EXECUTOR
    if _EXECUTOR is None:
        from concurrent.futures import ThreadPoolExecutor
        _EXECUTOR = ThreadPoolExecutor(max_workers=4)
    return _EXECUTOR

async def _run_db(role_id: str, fn, *args, **kwargs):
    """在后台线程中执行数据库操作"""
    loop = asyncio.get_running_loop()
    return await loop.run_in_executor(_get_executor(), fn, *args, **kwargs)

def close_all_connections():
    """关闭所有缓存的数据库连接（服务关闭时调用）"""
    global _CONNECTION_POOL
    for conn in _CONNECTION_POOL.values():
        try:
            conn.close()
        except Exception:
            pass
    _CONNECTION_POOL.clear()

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
    if "origin" not in existing_cols:
        conn.execute("ALTER TABLE short_term ADD COLUMN origin TEXT")
        # 从 content JSON 中回填已有数据的 origin
        try:
            rows = conn.execute("SELECT id, content FROM short_term").fetchall()
            for row in rows:
                try:
                    parsed = json.loads(str(row[1] or ""))
                    if isinstance(parsed, dict) and parsed.get("origin"):
                        conn.execute("UPDATE short_term SET origin = ? WHERE id = ?", (parsed["origin"], row[0]))
                except Exception:
                    pass
        except Exception:
            pass
    if "sender" not in existing_cols:
        conn.execute("ALTER TABLE short_term ADD COLUMN sender TEXT")
        try:
            rows = conn.execute("SELECT id, role, content FROM short_term WHERE sender IS NULL").fetchall()
            for row in rows:
                try:
                    parsed = json.loads(str(row[2] or ""))
                    sender_val = parsed.get("sender") if isinstance(parsed, dict) else None
                    conn.execute("UPDATE short_term SET sender = ? WHERE id = ?", (sender_val or row[1] or "assistant", row[0]))
                except Exception:
                    conn.execute("UPDATE short_term SET sender = ? WHERE id = ?", (row[1] or "assistant", row[0]))
        except Exception:
            pass
    if "sender_id" not in existing_cols:
        conn.execute("ALTER TABLE short_term ADD COLUMN sender_id TEXT")
        conn.execute("UPDATE short_term SET sender_id = '' WHERE sender_id IS NULL")
    if "group_id" not in existing_cols:
        conn.execute("ALTER TABLE short_term ADD COLUMN group_id TEXT")

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
                json_memory TEXT,
                origin TEXT,
                sender TEXT,
                sender_id TEXT,
                group_id TEXT
            )
            """
        )
        conn.execute(
            """
            INSERT INTO short_term_new (id, role, content, timestamp, task_id, request_id, json_memory, origin, sender, sender_id, group_id)
            SELECT id, role, content, timestamp, task_id, request_id, json_memory,
                   COALESCE(origin, ''), COALESCE(sender, role), COALESCE(sender_id, ''), COALESCE(group_id, '')
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

def _get_memory_length(max_context_rounds: Optional[int] = None) -> int:
    """获取上下文轮数（每轮=1条用户消息+1条AI回复=2条消息）

    Args:
        max_context_rounds: 角色配置的最大上下文轮数，None 时使用默认值
    """
    if max_context_rounds is not None and max_context_rounds > 0:
        return max_context_rounds * 2
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
    # 检查缓存连接
    cached = _CONNECTION_POOL.get(role_id)
    if cached is not None:
        try:
            cached.execute("SELECT 1")
            return cached
        except (sqlite3.ProgrammingError, sqlite3.OperationalError):
            _CONNECTION_POOL.pop(role_id, None)

    conn = sqlite3.connect(db_path, check_same_thread=False)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    conn.execute("PRAGMA busy_timeout=5000")
    _init_db(conn)
    _maybe_migrate_from_json(role_id, conn)

    if _POOL_LOCK:
        with _POOL_LOCK:
            _CONNECTION_POOL[role_id] = conn
    else:
        _CONNECTION_POOL[role_id] = conn
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
            SELECT id, role, content, timestamp, task_id, request_id, json_memory, origin, sender, sender_id, group_id
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
                    origin=row[7] or DEFAULT_MEMORY_ORIGIN,
                    sender=row[8] or row[1] or "assistant",
                ),
                "timestamp": row[3],
                "task_id": row[4],
                "request_id": row[5],
                "json_memory": row[6],
                "origin": row[7] or DEFAULT_MEMORY_ORIGIN,
                "sender": row[8] or row[1] or "assistant",
                "sender_id": row[9] or "",
                "group_id": row[10] or "",
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


def load_short_term_since(role_id: str, since_id: int) -> list:
    """增量获取短期记忆：只返回 id > since_id 的条目。"""
    if is_tool_role_id(role_id):
        return []
    with _get_connection(role_id) as conn:
        rows = conn.execute(
            """
            SELECT id, role, content, timestamp, task_id, request_id, json_memory, origin, sender, sender_id, group_id
            FROM short_term
            WHERE id > ?
            ORDER BY id ASC
            """,
            (since_id,),
        ).fetchall()
    return [
        {
            "id": row[0],
            "role": row[1] or "assistant",
            "content": ensure_structured_memory_message(
                content=row[2],
                role=row[1] or "assistant",
                timestamp=row[3],
                origin=row[7] or DEFAULT_MEMORY_ORIGIN,
                sender=row[8] or row[1] or "assistant",
            ),
            "timestamp": row[3],
            "task_id": row[4],
            "request_id": row[5],
            "json_memory": row[6],
            "origin": row[7] or DEFAULT_MEMORY_ORIGIN,
            "sender": row[8] or row[1] or "assistant",
            "sender_id": row[9] or "",
            "group_id": row[10] or "",
        }
        for row in rows
    ]


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
                item_origin = item.get("origin") or item.get("source") or DEFAULT_MEMORY_ORIGIN
                item_sender = item.get("sender") or role
                item_sender_id = item.get("sender_id") or ""
                item_group_id = item.get("group_id") or ""
                content = ensure_structured_memory_message(
                    content=item.get("content", ""),
                    role=role,
                    timestamp=timestamp,
                    origin=item_origin,
                    sender=item_sender,
                )
                task_id = item.get("task_id")
                request_id = item.get("request_id") or item.get("req_id")
                json_memory = item.get("json_memory")
            else:
                role = "assistant"
                timestamp = datetime.now().isoformat()
                item_origin = DEFAULT_MEMORY_ORIGIN
                item_sender = role
                item_sender_id = ""
                item_group_id = ""
                content = ensure_structured_memory_message(
                    content=str(item),
                    role=role,
                    timestamp=timestamp,
                    origin=item_origin,
                    sender=item_sender,
                )
                task_id = None
                request_id = None
                json_memory = None
            conn.execute(
                """
                INSERT INTO short_term (role, content, timestamp, task_id, request_id, json_memory, origin, sender, sender_id, group_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (role, content, timestamp, task_id, request_id, json_memory, item_origin, item_sender, item_sender_id, item_group_id)
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
    sender_id: Optional[str] = None,
    group_id: Optional[str] = None,
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
    normalized_origin = str(origin or DEFAULT_MEMORY_ORIGIN).strip() or DEFAULT_MEMORY_ORIGIN
    normalized_sender = str(sender or role).strip() or role
    normalized_sender_id = str(sender_id or "").strip()
    normalized_group_id = str(group_id or "").strip() or None
    created_at = datetime.now().isoformat()
    if role == "assistant":
        normalized_content = content
    else:
        normalized_content = ensure_structured_memory_message(
            content=content,
            role=role,
            timestamp=created_at,
            origin=normalized_origin,
            sender=normalized_sender,
        )

    with _get_connection(role_id) as conn:
        conn.execute(
            """
            INSERT INTO short_term (role, content, timestamp, task_id, request_id, json_memory, origin, sender, sender_id, group_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                role,
                normalized_content,
                created_at,
                normalized_task_id,
                normalized_request_id,
                normalized_json_memory,
                normalized_origin,
                normalized_sender,
                normalized_sender_id,
                normalized_group_id,
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

async def trigger_chat_summary(
    worker_id: str,
    role_id: str,
    conv_origin: str = "system",
    conv_group_id: Optional[str] = None,
    conv_sender_id: Optional[str] = None,
) -> Optional[str]:
    """
    触发记忆总结（内部调用，不暴露给前端）

    Args:
        conv_origin: 渠道 origin，用于将总结记录存储到对应渠道上下文中
        conv_group_id: 群聊 ID（onebot_group 时使用）
        conv_sender_id: 发送者 ID（onebot_private 时使用）

    Returns:
        新的核心记忆内容，或 None（如果不需要总结）
    """
    # 导入 AI 服务
    from services.ai_service import call_ai_direct
    try:
        # 根据渠道过滤短期记忆，避免跨频道污染总结输入
        effective_limit = _get_memory_length()
        if conv_origin == "onebot_group" and conv_group_id:
            summary_where = "WHERE origin = 'onebot_group' AND group_id = ?"
            summary_params = [conv_group_id]
        elif conv_origin == "onebot_private" and conv_sender_id:
            summary_where = "WHERE origin = 'onebot_private' AND sender_id = ?"
            summary_params = [conv_sender_id]
        else:
            summary_where = "WHERE origin IN ('zerochat', 'proactive', 'system') OR (origin LIKE 'onebot%' AND sender = 'user')"
            summary_params = []

        with _get_connection(role_id) as conn:
            count = conn.execute(f"SELECT COUNT(*) FROM short_term {summary_where}", summary_params).fetchone()[0]
            offset = max(0, count - effective_limit)
            rows = conn.execute(
                f"SELECT content FROM short_term {summary_where} ORDER BY id ASC LIMIT ? OFFSET ?",
                summary_params + [effective_limit, offset]
            ).fetchall()
        conversation = "\n".join([str(row[0] or "") for row in rows])

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
            append_short_term(role_id, "user", "system:触发记忆总结",
                              origin=conv_origin, sender="system",
                              group_id=conv_group_id, sender_id=conv_sender_id)
            append_short_term(role_id, "assistant", f"记忆总结结果：{new_memory}",
                              origin=conv_origin, sender="memory_summary",
                              group_id=conv_group_id, sender_id=conv_sender_id)
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
    conversation_key: Optional[str] = None,
    skip_summary: bool = False,
    max_context_rounds: Optional[int] = None,
) -> List[Dict]:
    """
    获取对话上下文消息

    Args:
        role_id: 角色 ID
        limit: 限制条数（兼容参数，实际使用 _get_memory_length()）
        user_message: 当前用户消息（保留参数以兼容旧调用）
        conversation_key: 记忆隔离标识
        max_context_rounds: 角色配置的上文轮数，None 时使用默认值
            - None / "default_user" / "main_qq": zerochat + 主QQ(onebot中sender=user)
            - "group:{group_id}": 同一群聊共享记忆
            - "private:{sender_id}": 同一私聊共享记忆
            - "all": 不过滤
        skip_summary: 跳过触发对话总结（混合上下文时使用，避免重复触发）

    Returns:
        [{"role": "user/assistant", "content": "..."}]
    """
    effective_limit = _get_memory_length(max_context_rounds)
    if effective_limit <= 0:
        return []
    if is_tool_role_id(role_id):
        return []

    # 构建过滤条件
    where_clause = ""
    where_params: list = []
    if conversation_key and conversation_key.startswith("group:"):
        group_id_val = conversation_key[6:]
        where_clause = "WHERE (origin = 'onebot_group' AND group_id = ?)"
        where_params = [group_id_val]
    elif conversation_key and conversation_key.startswith("private:"):
        sender_id_val = conversation_key[8:]
        where_clause = "WHERE (origin = 'onebot_private' AND sender_id = ?)"
        where_params = [sender_id_val]
    elif conversation_key != "all":
        # default_user: 全渠道主用户记忆 + 零前端 + 系统
        where_clause = "WHERE origin IN ('zerochat', 'proactive', 'system') OR (origin LIKE 'onebot%' AND sender = 'user')"

    overlap = max(1, int(effective_limit * 0.1))
    slide = effective_limit - overlap
    virtual_start_key = f"virtual_block_start:{conversation_key or 'default'}"
    need_trigger_summary = False

    with _get_connection(role_id) as conn:
        count_sql = f"SELECT COUNT(*) FROM short_term {where_clause}"
        total = conn.execute(count_sql, where_params).fetchone()[0]

        if total == 0:
            return []

        virtual_start = int(_get_meta(conn, virtual_start_key, "0"))

        if not skip_summary and total - virtual_start >= effective_limit:
            virtual_start += slide
            if total - virtual_start >= effective_limit:
                virtual_start = total - effective_limit + overlap
            _set_meta(conn, virtual_start_key, str(virtual_start))
            need_trigger_summary = True

    if need_trigger_summary:
        conv_origin = "system"
        conv_group_id = None
        conv_sender_id = None
        if conversation_key and conversation_key.startswith("group:"):
            conv_origin = "onebot_group"
            conv_group_id = conversation_key[6:]
        elif conversation_key and conversation_key.startswith("private:"):
            conv_origin = "onebot_private"
            conv_sender_id = conversation_key[8:]
        content = await trigger_chat_summary(
            worker_id="1000000000002", role_id=role_id,
            conv_origin=conv_origin,
            conv_group_id=conv_group_id,
            conv_sender_id=conv_sender_id,
        )
        if not content:
            logger.error(f"触发对话总结失败，无法获取新的上下文消息")

    query_offset = virtual_start
    with _get_connection(role_id) as conn:
        query_sql = f"SELECT role, content, timestamp, origin, sender FROM short_term {where_clause} ORDER BY id ASC LIMIT ? OFFSET ?"
        rows = conn.execute(query_sql, where_params + [effective_limit, query_offset]).fetchall()

    context = [
        {
            "role": row[0] or "assistant",
            "content": ensure_structured_memory_message(
                content=row[1],
                role=row[0] or "assistant",
                timestamp=row[2],
                origin=row[3] or DEFAULT_MEMORY_ORIGIN,
                sender=row[4] or row[0] or "assistant",
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

async def sequential_memory_generation(
    role_id: str,
    worker_id: str,
    now_content: str,
    conv_origin: Optional[str] = None,
    conv_group_id: Optional[str] = None,
    conv_sender_id: Optional[str] = None,
) -> Optional[str]:
    """
    生成衔接记忆，用于在长时间不聊天后模拟中间的场景变化，保持对话连续性

    Args:
        conv_origin: 渠道 origin，用于过滤短期记忆输入
        conv_group_id: 群聊 ID
        conv_sender_id: 发送者 ID
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
        # 根据渠道过滤短期记忆，避免跨频道污染
        if conv_origin == "onebot_group" and conv_group_id:
            seq_where = "WHERE origin = 'onebot_group' AND group_id = ?"
            seq_params = [conv_group_id]
        elif conv_origin == "onebot_private" and conv_sender_id:
            seq_where = "WHERE origin = 'onebot_private' AND sender_id = ?"
            seq_params = [conv_sender_id]
        elif conv_origin is not None:
            # 指定了渠道但非 onebot 场景 — 使用 default_user 范围
            seq_where = "WHERE origin IN ('zerochat', 'proactive', 'system') OR (origin LIKE 'onebot%' AND sender = 'user')"
            seq_params = []
        else:
            # 未指定渠道（兼容旧调用），不过滤
            seq_where = ""
            seq_params = []

        effective_limit = _get_memory_length()
        with _get_connection(role_id) as conn:
            count = conn.execute(f"SELECT COUNT(*) FROM short_term {seq_where}", seq_params).fetchone()[0]
            offset = max(0, count - effective_limit)
            rows = conn.execute(
                f"SELECT content FROM short_term {seq_where} ORDER BY id ASC LIMIT ? OFFSET ?",
                seq_params + [effective_limit, offset]
            ).fetchall()
        conversation = "\n".join([str(row[0] or "") for row in rows])

        worker = load_role(worker_id)
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
            # 将衔接记忆存入向量记忆库（工具角色跳过）
            if not is_tool_role_id(role_id):
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
            # 将核心记忆存入向量记忆库（工具角色跳过）
            if not is_tool_role_id(role_id):
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

def clear_short_term_by_conversation(role_id: str, conversation_key: str):
    """按会话 key 清除短期记忆（group:{id} 或 private:{sender_id}）"""
    if is_tool_role_id(role_id):
        return
    with _get_connection(role_id) as conn:
        if conversation_key.startswith("group:"):
            group_id = conversation_key[6:]
            conn.execute(
                "DELETE FROM short_term WHERE group_id = ?",
                (group_id,),
            )
        elif conversation_key.startswith("private:"):
            sender_id = conversation_key[8:]
            conn.execute(
                "DELETE FROM short_term WHERE origin = 'onebot_private' AND sender_id = ?",
                (sender_id,),
            )
        else:
            return
        _set_meta(conn, "updated_at", datetime.now().isoformat())
        logger.info(f"已清除记忆: role={role_id}, conversation_key={conversation_key}")

def update_short_term_entry(role_id: str, entry_id: int, message: str) -> bool:
    """更新单条短期记忆的消息内容（保留 origin/sender/timestamp 等元数据）。

    对 user 消息按标准 JSON 结构重新封装；assistant 消息直接写入纯文本，
    与 append_short_term 的写入策略保持一致。
    """
    if is_tool_role_id(role_id):
        return False
    text = str(message or "").strip()
    if not text:
        return False

    with _get_connection(role_id) as conn:
        row = conn.execute(
            "SELECT role, timestamp, origin, sender FROM short_term WHERE id = ?",
            (entry_id,),
        ).fetchone()
        if not row:
            return False
        role, timestamp, origin, sender = row[0], row[1], row[2], row[3]
        if role == "assistant":
            new_content = text
        else:
            new_content = ensure_structured_memory_message(
                content=text,
                role=role,
                timestamp=timestamp,
                origin=origin,
                sender=sender,
            )
        cursor = conn.execute(
            "UPDATE short_term SET content = ? WHERE id = ?",
            (new_content, entry_id),
        )
        _set_meta(conn, "updated_at", datetime.now().isoformat())
        return cursor.rowcount > 0

def delete_short_term_entry(role_id: str, entry_id: int) -> bool:
    """按主键删除单条短期记忆。"""
    if is_tool_role_id(role_id):
        return False
    with _get_connection(role_id) as conn:
        cursor = conn.execute("DELETE FROM short_term WHERE id = ?", (entry_id,))
        _set_meta(conn, "updated_at", datetime.now().isoformat())
        return cursor.rowcount > 0

def clear_vector_memory(role_id: str):
    """清空向量记忆库"""
    if is_tool_role_id(role_id):
        return
    from services.vector_memory import VectorMemoryStore
    VectorMemoryStore(role_id).clear()

# ========== Token 用量 / 缓存量统计（按角色，复用 memory_meta） ==========

_USAGE_TOTAL_KEYS = {
    "prompt_tokens": "usage_prompt_tokens_total",
    "completion_tokens": "usage_completion_tokens_total",
    "total_tokens": "usage_total_tokens_total",
    "cache_hit_tokens": "usage_cache_hit_total",
    "cache_miss_tokens": "usage_cache_miss_total",
    "request_count": "usage_request_count",
}

def _parse_usage_fields(usage: Dict[str, Any]) -> Dict[str, int]:
    """从 API 返回的 usage 中兼容解析 token 与缓存命中/未命中量。

    兼容 DeepSeek（prompt_cache_hit_tokens/prompt_cache_miss_tokens）
    与 OpenAI（prompt_tokens_details.cached_tokens）两种风格。
    """
    def _to_int(value: Any) -> int:
        try:
            return int(value or 0)
        except (TypeError, ValueError):
            return 0

    prompt_tokens = _to_int(usage.get("prompt_tokens"))
    completion_tokens = _to_int(usage.get("completion_tokens"))
    total_tokens = _to_int(usage.get("total_tokens")) or (prompt_tokens + completion_tokens)

    # 缓存命中/未命中
    if usage.get("prompt_cache_hit_tokens") is not None or usage.get("prompt_cache_miss_tokens") is not None:
        cache_hit = _to_int(usage.get("prompt_cache_hit_tokens"))
        cache_miss = _to_int(usage.get("prompt_cache_miss_tokens"))
    else:
        details = usage.get("prompt_tokens_details")
        cache_hit = _to_int(details.get("cached_tokens")) if isinstance(details, dict) else 0
        cache_miss = max(prompt_tokens - cache_hit, 0)

    return {
        "prompt_tokens": prompt_tokens,
        "completion_tokens": completion_tokens,
        "total_tokens": total_tokens,
        "cache_hit_tokens": cache_hit,
        "cache_miss_tokens": cache_miss,
    }

def record_usage(role_id: str, usage: Optional[Dict[str, Any]], model: Optional[str] = None):
    """累计记录一次 AI 请求的 token 用量与缓存量（按角色）。

    统计失败不得影响正常回复，全程静默兜底。
    """
    if is_tool_role_id(role_id) or not isinstance(usage, dict):
        return
    try:
        parsed = _parse_usage_fields(usage)
        with _get_connection(role_id) as conn:
            for field, key in _USAGE_TOTAL_KEYS.items():
                if field == "request_count":
                    continue
                current = _get_meta(conn, key, "0")
                try:
                    current_int = int(current)
                except (TypeError, ValueError):
                    current_int = 0
                _set_meta(conn, key, str(current_int + parsed[field]))

            count = _get_meta(conn, _USAGE_TOTAL_KEYS["request_count"], "0")
            try:
                count_int = int(count)
            except (TypeError, ValueError):
                count_int = 0
            _set_meta(conn, _USAGE_TOTAL_KEYS["request_count"], str(count_int + 1))

            last = dict(parsed)
            last["model"] = model or ""
            last["timestamp"] = datetime.now().isoformat()
            _set_meta(conn, "usage_last_json", json.dumps(last, ensure_ascii=False))
    except Exception as exc:
        logger.warning(f"record_usage failed for role={role_id}: {exc}")

def get_usage_stats(role_id: str) -> Dict[str, Any]:
    """读取某角色的累计用量与最近一次用量。"""
    empty_cumulative = {field: 0 for field in _USAGE_TOTAL_KEYS}
    if is_tool_role_id(role_id):
        return {"cumulative": empty_cumulative, "last": None}
    try:
        with _get_connection(role_id) as conn:
            cumulative: Dict[str, int] = {}
            for field, key in _USAGE_TOTAL_KEYS.items():
                value = _get_meta(conn, key, "0")
                try:
                    cumulative[field] = int(value)
                except (TypeError, ValueError):
                    cumulative[field] = 0

            last_raw = _get_meta(conn, "usage_last_json", None)
            last = None
            if last_raw:
                try:
                    last = json.loads(last_raw)
                except Exception:
                    last = None
            return {"cumulative": cumulative, "last": last}
    except Exception as exc:
        logger.warning(f"get_usage_stats failed for role={role_id}: {exc}")
        return {"cumulative": empty_cumulative, "last": None}

def reset_usage_stats(role_id: str) -> bool:
    """清零某角色的用量统计。"""
    if is_tool_role_id(role_id):
        return False
    try:
        with _get_connection(role_id) as conn:
            for key in _USAGE_TOTAL_KEYS.values():
                _set_meta(conn, key, "0")
            _set_meta(conn, "usage_last_json", None)
        return True
    except Exception as exc:
        logger.warning(f"reset_usage_stats failed for role={role_id}: {exc}")
        return False

def list_vector_memories(role_id: str, limit: int = 500, offset: int = 0) -> List[Dict]:
    """列出向量记忆条目（不含 embedding 本体）。"""
    if is_tool_role_id(role_id):
        return []
    from services.vector_memory import VectorMemoryStore
    return VectorMemoryStore(role_id).list_all(limit=limit, offset=offset)

def delete_vector_memory(role_id: str, memory_id: int) -> bool:
    """删除单条向量记忆。"""
    if is_tool_role_id(role_id):
        return False
    from services.vector_memory import VectorMemoryStore
    return VectorMemoryStore(role_id).delete_by_id(memory_id)

async def update_vector_memory(role_id: str, memory_id: int, new_text: str) -> Dict[str, Any]:
    """更新单条向量记忆的文本并重新生成嵌入向量。

    Returns:
        {"success": bool, "item": dict | None, "error": str | None}
    """
    if is_tool_role_id(role_id):
        return {"success": False, "item": None, "error": "invalid role"}

    text = str(new_text or "").strip()
    if not text:
        return {"success": False, "item": None, "error": "empty text"}

    from services.vector_memory import VectorMemoryStore
    from services.ai_service import generate_embedding

    store = VectorMemoryStore(role_id)
    if store.get_by_id(memory_id) is None:
        return {"success": False, "item": None, "error": "memory not found"}

    result = await generate_embedding(text)
    if not result.get("success") or not result.get("embedding"):
        return {"success": False, "item": None,
                "error": result.get("error") or "embedding failed"}

    updated = store.update_text(memory_id, text, result["embedding"])
    if not updated:
        return {"success": False, "item": None, "error": "update failed"}

    return {"success": True, "item": store.get_by_id(memory_id), "error": None}

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

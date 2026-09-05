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

from core.utils import ensure_direct_child_path, is_tool_role_id
from services.vector_memory import VectorMemoryStore, embed_and_store, _extract_semantic_text
from services.settings_service import get_thinking_config

logger = logging.getLogger(__name__)
DATA_DIR = Path(__file__).parent.parent / "data"
ROLES_DIR = DATA_DIR / "roles"
DEFAULT_MEMORY_ORIGIN = "zerochat"
DEFAULT_MAX_CONTEXT_ROUNDS = 60
DEFAULT_MAX_CONTEXT_LENGTH = 12000


def _role_dir(role_id: str) -> Path:
    return ensure_direct_child_path(ROLES_DIR, role_id, "role_id")

def get_memory_db(role_id: str) -> Path:
    role_dir = _role_dir(role_id)
    role_dir.mkdir(parents=True, exist_ok=True)
    return ensure_direct_child_path(role_dir, "memory.sqlite", "memory database")

def get_memory_json(role_id: str) -> Path:
    role_dir = _role_dir(role_id)
    role_dir.mkdir(parents=True, exist_ok=True)
    return ensure_direct_child_path(role_dir, "memory.json", "memory file")

# 连接池缓存 + WAL 模式
# 键为 (thread_id, role_id)：sqlite3 连接对象不可跨线程并发使用，事件循环线程与线程池
# worker 各自持有独立连接，靠 WAL + busy_timeout 协调对同一文件的并发访问。
import threading

_CONNECTION_POOL: Dict[tuple, sqlite3.Connection] = {}
_POOL_LOCK = threading.Lock()

# 已完成 schema 初始化/迁移的 DB 路径集合（进程级），避免每个 worker 线程
# 的冷连接都重跑 PRAGMA 扫描 + 潜在 rebuild。迁移本身幂等，这里仅做去重加速。
_SCHEMA_READY: set = set()
_SCHEMA_READY_LOCK = threading.Lock()

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

# 持有 fire-and-forget 任务的强引用，避免被 GC 提前回收；完成后记录异常并移除。
_BACKGROUND_TASKS: "set[asyncio.Task]" = set()

def _spawn_background(coro, description: str = "background task"):
    """安排后台协程，保留强引用并在完成时记录异常。"""
    task = asyncio.ensure_future(coro)
    _BACKGROUND_TASKS.add(task)

    def _done(t: "asyncio.Task"):
        _BACKGROUND_TASKS.discard(t)
        if t.cancelled():
            return
        exc = t.exception()
        if exc is not None:
            logger.warning("%s failed: %s", description, exc)

    task.add_done_callback(_done)
    return task

def close_all_connections():
    """关闭所有缓存的数据库连接（服务关闭时调用）"""
    global _CONNECTION_POOL
    with _POOL_LOCK:
        for conn in _CONNECTION_POOL.values():
            try:
                conn.close()
            except Exception:
                pass
        _CONNECTION_POOL.clear()
    with _SCHEMA_READY_LOCK:
        _SCHEMA_READY.clear()

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

_USAGE_LOCK = threading.Lock()

def _increment_meta(conn: sqlite3.Connection, key: str, delta: int):
    """原子累加整型 meta，避免并发响应对同一 key 的 last-writer-wins 丢计数。"""
    conn.execute(
        """INSERT INTO memory_meta (key, value) VALUES (?, ?)
           ON CONFLICT(key) DO UPDATE SET
               value = CAST(COALESCE(value, '0') AS INTEGER) + ?""",
        (key, str(delta), delta),
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
    return DEFAULT_MAX_CONTEXT_ROUNDS * 2


def _get_context_length(max_context_length: Optional[int] = None) -> int:
    """Return the maximum number of message-content characters in a window."""
    if max_context_length is not None and max_context_length > 0:
        return max_context_length
    return DEFAULT_MAX_CONTEXT_LENGTH


def get_effective_context_length(role_data: Optional[Dict[str, Any]]) -> int:
    """Return the lower positive cap from a role and its selected model profile."""
    data = role_data or {}
    role_length = data.get("max_context_length")
    if not isinstance(role_length, int) or role_length <= 0:
        role_length = DEFAULT_MAX_CONTEXT_LENGTH
    model_length = data.get("model_max_context_length")
    if isinstance(model_length, int) and model_length > 0:
        return min(role_length, model_length)
    return role_length


def _content_length(content: Any) -> int:
    return len(str(content or ""))


def _tail_within_limits(
    rows: List[Any],
    max_messages: int,
    max_context_length: int,
) -> List[Any]:
    """Keep the newest complete messages that fit both window limits."""
    selected: List[Any] = []
    total_length = 0
    for row in reversed(rows[-max_messages:]):
        content = row[1] if len(row) > 1 else row[0]
        content_length = _content_length(content)
        if content_length > max_context_length:
            if not selected:
                selected.append(row)
            break
        if selected and total_length + content_length > max_context_length:
            break
        selected.append(row)
        total_length += content_length
    return list(reversed(selected))


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
    """Advance cycles with a small, persisted per-cycle biological variation."""
    while last_start + timedelta(days=cycle_length) <= today:
        variation = random.randint(-2, 2)
        next_start = last_start + timedelta(days=max(1, cycle_length + variation))
        if next_start > today:
            # Do not move a projected future start into the current cycle.
            break
        last_start = next_start
    return last_start


def _get_menstruation_status(role_id: str) -> Optional[Dict[str, Any]]:
    """Build one consistent, date-specific cycle status for prompt injection."""
    profile_path = _role_dir(role_id) / "profile.json"
    if not profile_path.exists():
        return None

    try:
        with open(profile_path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        return None

    gender = _normalize_gender(data)
    if gender != "women":
        return None

    cycle_data, cycle_length, period_length, profile_updated = _load_cycle_data(data)
    if profile_updated or data.get("gender") != gender:
        data["gender"] = gender
        data["menstruation_cycle"] = cycle_data
        _save_profile(profile_path, data)

    today = datetime.now().date()
    with _get_connection(role_id) as conn:
        period_start = _get_or_init_last_period_start(
            conn, cycle_data, cycle_length, today
        )
        period_start = _advance_period_cycles(period_start, cycle_length, today)
        next_period_start = period_start + timedelta(days=cycle_length)
        _set_meta(conn, "last_period_start", period_start.isoformat())
        _set_meta(conn, "next_period_start", next_period_start.isoformat())

    cycle_day = (today - period_start).days + 1
    period_end = period_start + timedelta(days=period_length - 1)
    in_period = today <= period_end
    return {
        "today": today.isoformat(),
        "cycle_length": cycle_length,
        "period_length": period_length,
        "cycle_day": cycle_day,
        "in_period": in_period,
        "period_day": cycle_day if in_period else None,
        "period_start": period_start.isoformat(),
        # Kept for state transitions; do not expose it to the model early.
        "expected_period_end": period_end.isoformat(),
        "next_period_start": next_period_start.isoformat(),
        "days_until_next_period": max(0, (next_period_start - today).days),
    }


def _if_in_menstruation(role_id: str) -> tuple[Optional[bool], Optional[int]]:
    status = _get_menstruation_status(role_id)
    if status is None:
        return None, None
    if status["in_period"]:
        return True, int(status["period_day"])
    return False, int(status["days_until_next_period"])


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


def reset_menstruation_cycle_state(role_id: str, last_period_start: Any) -> None:
    """Replace the runtime cycle anchor after its profile setting changes.

    The cycle status is cached in ``memory_meta`` so it can advance naturally
    between requests.  A profile edit must invalidate that cache; otherwise
    the old anchor continues to override the newly configured date.
    """
    if last_period_start is None:
        return
    with _get_connection(role_id) as conn:
        _set_meta(conn, "last_period_start", str(last_period_start).strip())
        _set_meta(conn, "next_period_start", None)

def _get_menstruation_cycle_info(role_id: str) -> Optional[Dict[str, Any]]:
    status = _get_menstruation_status(role_id)
    if status is None:
        return None
    return {
        "cycle_length": status["cycle_length"],
        "period_length": status["period_length"],
        "period_start": status["period_start"],
        "expected_period_end": status["expected_period_end"],
        "next_period_start": status["next_period_start"],
    }

def _get_role_core_memory(role_id: str) -> str:
    profile_path = _role_dir(role_id) / "profile.json"
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
    # 按 (线程, 角色) 缓存连接，避免跨线程共享同一连接对象
    pool_key = (threading.get_ident(), role_id)

    with _POOL_LOCK:
        cached = _CONNECTION_POOL.get(pool_key)
    if cached is not None:
        try:
            cached.execute("SELECT 1")
            return cached
        except (sqlite3.ProgrammingError, sqlite3.OperationalError):
            with _POOL_LOCK:
                _CONNECTION_POOL.pop(pool_key, None)
            # 连接失效通常意味着底层 DB 文件被删除/重建；清除 schema 就绪标记，
            # 以便对重建后的 DB 重新执行建表/迁移。
            with _SCHEMA_READY_LOCK:
                _SCHEMA_READY.discard(str(db_path))

    conn = sqlite3.connect(db_path, check_same_thread=False)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    conn.execute("PRAGMA busy_timeout=5000")

    db_key = str(db_path)
    with _SCHEMA_READY_LOCK:
        schema_done = db_key in _SCHEMA_READY
    if not schema_done:
        # 首次遇到该 DB：跑一次建表/迁移（幂等）。后续线程的冷连接跳过。
        _init_db(conn)
        _maybe_migrate_from_json(role_id, conn)
        with _SCHEMA_READY_LOCK:
            _SCHEMA_READY.add(db_key)

    with _POOL_LOCK:
        _CONNECTION_POOL[pool_key] = conn
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
        content_length = _get_meta(conn, "content_length_since_summary")
        if content_length is None:
            recent_rows = rows[-message_count_int:] if message_count_int > 0 else []
            content_length_int = sum(_content_length(row[2]) for row in recent_rows)
            _set_meta(conn, "content_length_since_summary", str(content_length_int))
        else:
            try:
                content_length_int = int(content_length)
            except (TypeError, ValueError):
                content_length_int = 0
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
        "content_length_since_summary": content_length_int,
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
        content_length_value = memory.get("content_length_since_summary")
        if content_length_value is None:
            content_length_value = sum(
                _content_length(item.get("content", "") if isinstance(item, dict) else item)
                for item in memory.get("short_term", [])
            )
        _set_meta(conn, "content_length_since_summary", str(content_length_value))
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
        current_length = _get_meta(conn, "content_length_since_summary", "0")
        try:
            current_length_int = int(current_length)
        except (TypeError, ValueError):
            current_length_int = 0
        _set_meta(
            conn,
            "content_length_since_summary",
            str(current_length_int + _content_length(normalized_content)),
        )
        _set_meta(conn, "updated_at", datetime.now().isoformat())
        # memory.json 由前端维护，后端仅保证 request_id 在 DB 记录中可用。

async def trigger_chat_summary(
    worker_id: str,
    role_id: str,
    conv_origin: str = "system",
    conv_group_id: Optional[str] = None,
    conv_sender_id: Optional[str] = None,
    max_context_rounds: Optional[int] = None,
    max_context_length: Optional[int] = None,
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
        effective_limit = _get_memory_length(max_context_rounds)
        effective_context_length = _get_context_length(max_context_length)
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
        rows = _tail_within_limits(rows, effective_limit, effective_context_length)
        conversation = "\n".join(
            str((row[1] if len(row) > 1 else row[0]) or "") for row in rows
        )

        prompt = f"最近对话：{conversation}"
        from routers.roles import load_role
        worker_data = load_role(worker_id)
        system_prompt = worker_data.get("system_prompt", "")
        messages = []
        messages.append({"role": "system", "content": system_prompt})
        messages.append({"role": "user", "content": prompt})
    except Exception as e:
        logger.warning("构建记忆总结提示时发生错误：%s", e)
        return None
    try:
        result = await call_ai_direct(messages=messages, model=worker_data.get("ai_model"), api_url=worker_data.get("ai_api_url"), api_key=worker_data.get("ai_api_key"), temperature=worker_data.get("ai_temperature", 0.1), api_format=worker_data.get("ai_api_format"), **get_thinking_config(role_data=worker_data))
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
            logger.warning("记忆总结失败：%s", result)
    except Exception as e:
        logger.warning("调用 AI 进行记忆总结时发生错误：%s", e)
        return None

    return None

async def get_context_messages(
    role_id: str,
    limit: int = 20,
    user_message: Optional[str] = None,
    conversation_key: Optional[str] = None,
    skip_summary: bool = False,
    latest: bool = False,
    max_context_rounds: Optional[int] = None,
    max_context_length: Optional[int] = None,
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
    effective_context_length = _get_context_length(max_context_length)
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

    if latest:
        def _fetch_latest():
            with _get_connection(role_id) as conn:
                query_sql = f"SELECT role, content, timestamp, origin, sender FROM short_term {where_clause} ORDER BY id DESC LIMIT ?"
                latest_rows = conn.execute(query_sql, where_params + [effective_limit]).fetchall()
                return _tail_within_limits(
                    list(reversed(latest_rows)), effective_limit, effective_context_length
                )

        rows = await _run_db(role_id, _fetch_latest)
        return [
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

    overlap_count = max(1, int(effective_limit * 0.1))
    overlap_length = max(1, int(effective_context_length * 0.1))
    virtual_start_key = f"virtual_block_start:{conversation_key or 'default'}"

    def _compute_virtual_start():
        with _get_connection(role_id) as conn:
            rows_sql = f"SELECT content FROM short_term {where_clause} ORDER BY id ASC"
            all_rows = conn.execute(rows_sql, where_params).fetchall()
            total_local = len(all_rows)
            if total_local == 0:
                _set_meta(conn, virtual_start_key, "0")
                return 0, 0, False
            try:
                vstart = int(_get_meta(conn, virtual_start_key, "0"))
            except (TypeError, ValueError):
                vstart = 0
            vstart = min(max(vstart, 0), total_local)
            pending_rows = all_rows[vstart:]
            pending_length = sum(_content_length(row[0]) for row in pending_rows)
            trigger = False
            if not skip_summary and (
                len(pending_rows) >= effective_limit
                or pending_length >= effective_context_length
            ):
                retained = 0
                retained_length = 0
                for row in reversed(pending_rows):
                    row_length = _content_length(row[0])
                    if row_length > overlap_length:
                        if retained == 0:
                            retained = 1
                        break
                    if retained >= overlap_count or retained_length + row_length > overlap_length:
                        break
                    retained += 1
                    retained_length += row_length
                vstart = total_local - retained
                _set_meta(conn, virtual_start_key, str(vstart))
                trigger = True
            return total_local, vstart, trigger

    total, virtual_start, need_trigger_summary = await _run_db(role_id, _compute_virtual_start)
    if total == 0:
        return []

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
            max_context_rounds=max_context_rounds,
            max_context_length=max_context_length,
        )
        if not content:
            logger.error(f"触发对话总结失败，无法获取新的上下文消息")

    query_offset = virtual_start
    def _fetch_context():
        with _get_connection(role_id) as conn:
            query_sql = f"SELECT role, content, timestamp, origin, sender FROM short_term {where_clause} ORDER BY id ASC LIMIT ? OFFSET ?"
            candidate_rows = conn.execute(
                query_sql, where_params + [effective_limit, query_offset]
            ).fetchall()
            return _tail_within_limits(
                candidate_rows, effective_limit, effective_context_length
            )

    rows = await _run_db(role_id, _fetch_context)
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
    # count/search 都是同步 SQLite + numpy 计算，卸载到线程池避免阻塞事件循环。
    if await _run_db(role_id, store.count) == 0:
        return []

    from services.ai_service import generate_embedding
    result = await generate_embedding(query.strip())
    if not result["success"] or not result["embedding"]:
        return []

    results = await _run_db(
        role_id, store.search, result["embedding"], top_k, min_score
    )
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
        _set_meta(conn, "content_length_since_summary", "0")
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

def should_summarize(
    role_id: str,
    max_context_rounds: Optional[int] = None,
    max_context_length: Optional[int] = None,
) -> bool:
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
        length_value = _get_meta(conn, "content_length_since_summary")
        try:
            content_length = int(length_value) if length_value is not None else 0
        except (TypeError, ValueError):
            content_length = 0
        if length_value is None and count > 0:
            rows = conn.execute(
                "SELECT content FROM short_term ORDER BY id DESC LIMIT ?", (count,)
            ).fetchall()
            content_length = sum(_content_length(row[0]) for row in rows)

    return (
        count >= _get_memory_length(max_context_rounds)
        or content_length >= _get_context_length(max_context_length)
    )

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
        logger.warning("检查是否需要生成衔接记忆时发生错误：%s", e)
        return None
    # 导入 AI 服务
    from services.ai_service import call_ai_direct
    from routers.roles import load_role
    try:
        role_config = load_role(role_id) or {}
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

        effective_limit = _get_memory_length(role_config.get("max_context_rounds"))
        effective_context_length = get_effective_context_length(role_config)
        with _get_connection(role_id) as conn:
            count = conn.execute(f"SELECT COUNT(*) FROM short_term {seq_where}", seq_params).fetchone()[0]
            offset = max(0, count - effective_limit)
            rows = conn.execute(
                f"SELECT content FROM short_term {seq_where} ORDER BY id ASC LIMIT ? OFFSET ?",
                seq_params + [effective_limit, offset]
            ).fetchall()
        rows = _tail_within_limits(rows, effective_limit, effective_context_length)
        conversation = "\n".join([str(row[0] or "") for row in rows])

        worker = load_role(worker_id)
        prompt = f"""历史对话内容：{conversation}\n当前对话内容：{now_content}\n当前时间：{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}"""
        system_prompt = worker.get("system_prompt", "")
        messages = []
        messages.append({"role": "system", "content": system_prompt})
        messages.append({"role": "user", "content": prompt})
    except Exception as e:
        logger.warning("构建衔接记忆提示时发生错误：%s", e)
        return None
    try:
        result = await call_ai_direct(messages=messages, model=worker.get("ai_model"), api_url=worker.get("ai_api_url"), api_key=worker.get("ai_api_key"), temperature=worker.get("ai_temperature", 1.2), api_format=worker.get("ai_api_format"), **get_thinking_config(role_data=worker))
        if result["success"] and result["content"]:
            if result["content"].strip().lower() == "none":
                return "noneed"
            new_memory = result["content"].strip()
            append_short_term(role_id, "user", "system:触发衔接记忆生成", origin="system", sender="system")
            append_short_term(role_id, "assistant", f"衔接记忆内容：{new_memory}", origin="system", sender="sequential_memory")
            # 将衔接记忆存入向量记忆库（工具角色跳过）
            if not is_tool_role_id(role_id):
                _spawn_background(
                    embed_and_store(
                        role_id, new_memory, role="assistant",
                        source="sequential", min_text_length=5
                    ),
                    description=f"embed_and_store(sequential, role={role_id})",
                )
            return new_memory
        else:
            logger.warning("衔接记忆生成失败：%s", result)
    except Exception as e:
        logger.warning("调用 AI 生成衔接记忆时发生错误：%s", e)
        return None

async def trigger_memory_summary(role_id: str, role_data: Dict) -> Optional[str]:
    """
    触发记忆总结（内部调用，不暴露给前端）
    
    Returns:
        新的核心记忆内容，或 None（如果不需要总结）
    """
    try:
        if not should_summarize(
            role_data.get("id", role_id),
            role_data.get("max_context_rounds"),
            get_effective_context_length(role_data),
        ):
            return "noneed"
    except Exception as e:
        logger.warning("检查是否需要总结核心记忆时发生错误：%s", e)
        return None
    # 导入 AI 服务
    from services.ai_service import call_ai_direct
    try:
        memory = load_memory(role_data.get("id", role_id))
        short_term = memory.get("short_term", [])
        current_core = memory.get("core_memory", "")
        role_need_change = role_data.get("id", role_id)
        
        # 构建总结提示
        summary_rows = [
            (m.get("role"), m.get("content", "")) for m in short_term
        ]
        summary_rows = _tail_within_limits(
            summary_rows,
            _get_memory_length(role_data.get("max_context_rounds")),
            get_effective_context_length(role_data),
        )
        conversation = "\n".join(str(row[1]) for row in summary_rows)
        
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
        logger.warning("构建记忆总结提示时发生错误：%s", e)
        return None
    try:
        result = await call_ai_direct(messages=messages, model=role_data.get("ai_model"), api_url=role_data.get("ai_api_url"), api_key=role_data.get("ai_api_key"), temperature=role_data.get("ai_temperature", 0.1), api_format=role_data.get("ai_api_format"), **get_thinking_config(role_data=role_data))
        if result["success"] and result["content"]:
            new_core = result["content"].strip()
            update_core_memory(role_need_change, new_core)
            # 将核心记忆存入向量记忆库（工具角色跳过）
            if not is_tool_role_id(role_id):
                _spawn_background(
                    embed_and_store(
                        role_id, new_core, role="assistant",
                        source="core_summary", min_text_length=5
                    ),
                    description=f"embed_and_store(core_summary, role={role_id})",
                )
            return new_core
        else:
            logger.warning("记忆总结失败：%s", result)
    except Exception as e:
        logger.warning("调用 AI 进行记忆总结时发生错误：%s", e)
        return None

    return None

def clear_short_term(role_id: str):
    """清空短期记忆"""
    if is_tool_role_id(role_id):
        return
    with _get_connection(role_id) as conn:
        conn.execute("DELETE FROM short_term")
        _set_meta(conn, "message_count_since_summary", "0")
        _set_meta(conn, "content_length_since_summary", "0")
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
        remaining = conn.execute("SELECT content FROM short_term").fetchall()
        _set_meta(conn, "message_count_since_summary", str(len(remaining)))
        _set_meta(
            conn,
            "content_length_since_summary",
            str(sum(_content_length(row[0]) for row in remaining)),
        )
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

# 分模型累计的 token 字段（不含 request_count，后者单独累加）
_PER_MODEL_TOKEN_FIELDS = (
    "prompt_tokens",
    "completion_tokens",
    "total_tokens",
    "cache_hit_tokens",
    "cache_miss_tokens",
)

_HISTORICAL_USAGE_PLATFORM = "历史未标注平台"
_UNKNOWN_USAGE_PLATFORM = "未知平台"
_USAGE_BY_PLATFORM_MODEL_KEY = "usage_by_platform_model_json"

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

def _legacy_record_usage(role_id: str, usage: Optional[Dict[str, Any]], model: Optional[str] = None):
    """累计记录一次 AI 请求的 token 用量与缓存量（按角色）。

    统计失败不得影响正常回复，全程静默兜底。
    """
    if is_tool_role_id(role_id) or not isinstance(usage, dict):
        return
    try:
        parsed = _parse_usage_fields(usage)
        # usage_by_model_json 是 JSON blob 的读-改-写，SQLite 行级锁无法保证，
        # 用进程内锁串行化整段累加；每次响应仅调用一次，竞争可忽略。
        with _USAGE_LOCK, _get_connection(role_id) as conn:
            for field, key in _USAGE_TOTAL_KEYS.items():
                if field == "request_count":
                    continue
                _increment_meta(conn, key, parsed[field])

            _increment_meta(conn, _USAGE_TOTAL_KEYS["request_count"], 1)

            # 按模型累计（用量最大排前）
            model_key = (model or "").strip() or "未知"
            by_model_raw = _get_meta(conn, "usage_by_model_json", None)
            try:
                by_model = json.loads(by_model_raw) if by_model_raw else {}
                if not isinstance(by_model, dict):
                    by_model = {}
            except Exception:
                by_model = {}
            bucket = by_model.get(model_key)
            if not isinstance(bucket, dict):
                bucket = {}
            for field in _PER_MODEL_TOKEN_FIELDS:
                try:
                    bucket[field] = int(bucket.get(field, 0)) + parsed[field]
                except (TypeError, ValueError):
                    bucket[field] = parsed[field]
            try:
                bucket["request_count"] = int(bucket.get("request_count", 0)) + 1
            except (TypeError, ValueError):
                bucket["request_count"] = 1
            by_model[model_key] = bucket
            _set_meta(conn, "usage_by_model_json", json.dumps(by_model, ensure_ascii=False))

            last = dict(parsed)
            last["model"] = model or ""
            last["timestamp"] = datetime.now().isoformat()
            _set_meta(conn, "usage_last_json", json.dumps(last, ensure_ascii=False))
    except Exception as exc:
        logger.warning(f"record_usage failed for role={role_id}: {exc}")

def _legacy_get_usage_stats(role_id: str) -> Dict[str, Any]:
    """读取某角色的分模型用量与最近一次用量。

    返回 {"by_model": [ {model, prompt_tokens, ..., request_count}, ... ], "last": {...} | None}，
    列表按 total_tokens 降序（用量最大的排前面）。
    """
    if is_tool_role_id(role_id):
        return {"by_model": [], "last": None}
    try:
        with _get_connection(role_id) as conn:
            last_raw = _get_meta(conn, "usage_last_json", None)
            last = None
            if last_raw:
                try:
                    last = json.loads(last_raw)
                except Exception:
                    last = None

            by_model_raw = _get_meta(conn, "usage_by_model_json", None)
            by_model_map: Dict[str, Any] = {}
            if by_model_raw:
                try:
                    parsed_map = json.loads(by_model_raw)
                    if isinstance(parsed_map, dict):
                        by_model_map = parsed_map
                except Exception:
                    by_model_map = {}

            # 迁移兼容：无分模型数据但存在旧扁平累计，合成一个历史桶
            if not by_model_map:
                legacy = {}
                for field, key in _USAGE_TOTAL_KEYS.items():
                    try:
                        legacy[field] = int(_get_meta(conn, key, "0"))
                    except (TypeError, ValueError):
                        legacy[field] = 0
                if legacy.get("total_tokens", 0) > 0 or legacy.get("request_count", 0) > 0:
                    model_name = ""
                    if isinstance(last, dict):
                        model_name = str(last.get("model") or "").strip()
                    by_model_map[model_name or "（历史合计）"] = legacy

            by_model: List[Dict[str, Any]] = []
            for model_name, bucket in by_model_map.items():
                if not isinstance(bucket, dict):
                    continue
                entry: Dict[str, Any] = {"model": model_name}
                for field in _PER_MODEL_TOKEN_FIELDS:
                    try:
                        entry[field] = int(bucket.get(field, 0))
                    except (TypeError, ValueError):
                        entry[field] = 0
                try:
                    entry["request_count"] = int(bucket.get("request_count", 0))
                except (TypeError, ValueError):
                    entry["request_count"] = 0
                by_model.append(entry)

            by_model.sort(key=lambda e: e.get("total_tokens", 0), reverse=True)
            return {"by_model": by_model, "last": last}
    except Exception as exc:
        logger.warning(f"get_usage_stats failed for role={role_id}: {exc}")
        return {"by_model": [], "last": None}

def _legacy_reset_usage_stats(role_id: str) -> bool:
    """清零某角色的用量统计。"""
    if is_tool_role_id(role_id):
        return False
    try:
        with _get_connection(role_id) as conn:
            for key in _USAGE_TOTAL_KEYS.values():
                _set_meta(conn, key, "0")
            _set_meta(conn, "usage_last_json", None)
            _set_meta(conn, "usage_by_model_json", None)
        return True
    except Exception as exc:
        logger.warning(f"reset_usage_stats failed for role={role_id}: {exc}")
        return False

def _normalize_usage_bucket(bucket: Any) -> Dict[str, int]:
    """Normalize persisted usage data to the public numeric fields."""
    value = bucket if isinstance(bucket, dict) else {}
    normalized: Dict[str, int] = {}
    for field in _PER_MODEL_TOKEN_FIELDS + ("request_count",):
        try:
            normalized[field] = int(value.get(field, 0))
        except (TypeError, ValueError):
            normalized[field] = 0
    return normalized


def _merge_usage_bucket(target: Dict[str, int], source: Dict[str, int]) -> None:
    for field in _PER_MODEL_TOKEN_FIELDS + ("request_count",):
        target[field] = target.get(field, 0) + source.get(field, 0)


def record_usage(
    role_id: str,
    usage: Optional[Dict[str, Any]],
    model: Optional[str] = None,
    platform: Optional[str] = None,
) -> None:
    """Accumulate a request by API platform and model for one role."""
    if is_tool_role_id(role_id) or not isinstance(usage, dict):
        return
    try:
        parsed = _parse_usage_fields(usage)
        model_key = (model or "").strip() or "未知"
        platform_key = (platform or "").strip() or _UNKNOWN_USAGE_PLATFORM
        with _USAGE_LOCK, _get_connection(role_id) as conn:
            for field, key in _USAGE_TOTAL_KEYS.items():
                if field != "request_count":
                    _increment_meta(conn, key, parsed[field])
            _increment_meta(conn, _USAGE_TOTAL_KEYS["request_count"], 1)

            raw = _get_meta(conn, _USAGE_BY_PLATFORM_MODEL_KEY, None)
            try:
                by_platform = json.loads(raw) if raw else {}
                if not isinstance(by_platform, dict):
                    by_platform = {}
            except Exception:
                by_platform = {}

            models = by_platform.get(platform_key)
            if not isinstance(models, dict):
                models = {}
            bucket = _normalize_usage_bucket(models.get(model_key))
            _merge_usage_bucket(bucket, {**parsed, "request_count": 1})
            models[model_key] = bucket
            by_platform[platform_key] = models
            _set_meta(
                conn,
                _USAGE_BY_PLATFORM_MODEL_KEY,
                json.dumps(by_platform, ensure_ascii=False),
            )

            last = dict(parsed)
            last["platform"] = platform_key
            last["model"] = model_key
            last["timestamp"] = datetime.now().isoformat()
            _set_meta(conn, "usage_last_json", json.dumps(last, ensure_ascii=False))
    except Exception as exc:
        logger.warning("record_usage failed for role=%s: %s", role_id, exc)


def get_usage_stats(role_id: str) -> Dict[str, Any]:
    """Return platform/model buckets, a legacy model summary, and last usage."""
    empty = {"by_platform_model": [], "by_model": [], "last": None}
    if is_tool_role_id(role_id):
        return empty
    try:
        with _get_connection(role_id) as conn:
            last = None
            last_raw = _get_meta(conn, "usage_last_json", None)
            if last_raw:
                try:
                    last = json.loads(last_raw)
                except Exception:
                    last = None
            if isinstance(last, dict) and not str(last.get("platform") or "").strip():
                last = {**last, "platform": _HISTORICAL_USAGE_PLATFORM}

            entries: List[Dict[str, Any]] = []
            platform_raw = _get_meta(conn, _USAGE_BY_PLATFORM_MODEL_KEY, None)
            if platform_raw:
                try:
                    by_platform = json.loads(platform_raw)
                except Exception:
                    by_platform = {}
                if isinstance(by_platform, dict):
                    for platform_name, models in by_platform.items():
                        if not isinstance(models, dict):
                            continue
                        for model_name, bucket in models.items():
                            entry: Dict[str, Any] = {
                                "platform": str(platform_name).strip() or _UNKNOWN_USAGE_PLATFORM,
                                "model": str(model_name).strip() or "未知",
                            }
                            entry.update(_normalize_usage_bucket(bucket))
                            entries.append(entry)

            legacy_raw = _get_meta(conn, "usage_by_model_json", None)
            try:
                legacy_models = json.loads(legacy_raw) if legacy_raw else {}
                if not isinstance(legacy_models, dict):
                    legacy_models = {}
            except Exception:
                legacy_models = {}
            for model_name, bucket in legacy_models.items():
                entry = {
                    "platform": _HISTORICAL_USAGE_PLATFORM,
                    "model": str(model_name).strip() or "（历史合计）",
                }
                entry.update(_normalize_usage_bucket(bucket))
                entries.append(entry)

            # Databases predating the model blob only have the aggregate totals.
            if not entries:
                legacy_totals: Dict[str, int] = {}
                for field, key in _USAGE_TOTAL_KEYS.items():
                    try:
                        legacy_totals[field] = int(_get_meta(conn, key, "0"))
                    except (TypeError, ValueError):
                        legacy_totals[field] = 0
                if legacy_totals["total_tokens"] or legacy_totals["request_count"]:
                    model_name = str((last or {}).get("model") or "").strip()
                    entry = {
                        "platform": _HISTORICAL_USAGE_PLATFORM,
                        "model": model_name or "（历史合计）",
                    }
                    entry.update(_normalize_usage_bucket(legacy_totals))
                    entries.append(entry)

            entries.sort(key=lambda entry: entry["total_tokens"], reverse=True)

            model_totals: Dict[str, Dict[str, int]] = {}
            for entry in entries:
                model_name = str(entry["model"])
                _merge_usage_bucket(
                    model_totals.setdefault(model_name, {}),
                    _normalize_usage_bucket(entry),
                )
            by_model = [
                {"model": model_name, **bucket}
                for model_name, bucket in model_totals.items()
            ]
            by_model.sort(key=lambda entry: entry["total_tokens"], reverse=True)
            return {"by_platform_model": entries, "by_model": by_model, "last": last}
    except Exception as exc:
        logger.warning("get_usage_stats failed for role=%s: %s", role_id, exc)
        return empty


def reset_usage_stats(role_id: str) -> bool:
    """Clear all current and legacy usage statistics for one role."""
    if is_tool_role_id(role_id):
        return False
    try:
        with _get_connection(role_id) as conn:
            for key in _USAGE_TOTAL_KEYS.values():
                _set_meta(conn, key, "0")
            _set_meta(conn, "usage_last_json", None)
            _set_meta(conn, "usage_by_model_json", None)
            _set_meta(conn, _USAGE_BY_PLATFORM_MODEL_KEY, None)
        return True
    except Exception as exc:
        logger.warning("reset_usage_stats failed for role=%s: %s", role_id, exc)
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

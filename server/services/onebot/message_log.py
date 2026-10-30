"""OneBot 额外消息库：保存近 3 天的 QQ 会话消息，供 QQ 消息回顾工具使用。

``short_term`` 只保存「已经交给模型处理」的消息：群里没有 @ 机器人的发言、被随机回复
挡下的消息都不会入库，回顾工具因此看不到它们。这里另开一个独立的 SQLite 文件
``data/onebot_messages.sqlite``，在入站放行之前记录白名单内会话的全部消息，并记录机器人
自己发出的回复；超过 ``RETENTION_SECONDS``（3 天）的记录滚动清除。

* 只记录「允许机器人参与」的会话：白名单内的群 / 私聊，以及主用户的私聊。白名单外的群、
  路人私聊、被屏蔽的用户、已关闭的会话都不记录；主用户的 ``/`` 管理指令也不记录。
* 读取时同样按保留期过滤，即使清理延后，过期记录也不会被看到。
* ``coverage_start`` 给出「本库已完整覆盖」的起点，调用方在此之前的时间段仍读取
  ``short_term``，两边互不重叠。
* 库文件（含 WAL）超过 ``MAX_DB_BYTES``（50 MB）时，从最旧的消息开始成批删除，直到降到上限的
  90% 以下，并同步上移受影响角色的覆盖起点，使回顾工具对被删除的时间段改读 ``short_term``。
"""
from __future__ import annotations

import asyncio
import logging
import sqlite3
import threading
import time
from contextlib import contextmanager
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional

from services.onebot import paths, policy
from services.onebot.models import Inbound, Target

logger = logging.getLogger(__name__)

DB_FILENAME = "onebot_messages.sqlite"
#: 保留期：3 天，超过的记录滚动清除。
RETENTION_SECONDS = 3 * 24 * 3600
#: 写入时顺带清理的最小间隔，避免每条消息都跑一次 DELETE。
PURGE_INTERVAL_SECONDS = 3600
#: 库文件（含 WAL）的大小上限：50 MB。超过后从最旧的消息开始删除。
MAX_DB_BYTES = 50 * 1024 * 1024
#: 超限后删到上限的这个比例以下，避免每写一条都触发一次清理。
TRIM_TARGET_RATIO = 0.9
#: 单条消息入库的最大字符数。
MAX_CONTENT_CHARS = 2000

CHAT_GROUP = "group"
CHAT_PRIVATE = "private"

_SCHEMA = """
CREATE TABLE IF NOT EXISTS onebot_messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    role_id TEXT NOT NULL,
    chat_type TEXT NOT NULL,
    chat_id TEXT NOT NULL,
    ts TEXT NOT NULL,
    ts_epoch REAL NOT NULL,
    user_id TEXT NOT NULL DEFAULT '',
    sender TEXT NOT NULL DEFAULT '',
    is_self INTEGER NOT NULL DEFAULT 0,
    message_id INTEGER,
    content TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_onebot_messages_chat
    ON onebot_messages (role_id, chat_type, chat_id, ts_epoch);
CREATE INDEX IF NOT EXISTS idx_onebot_messages_epoch ON onebot_messages (ts_epoch);
CREATE UNIQUE INDEX IF NOT EXISTS idx_onebot_messages_msgid
    ON onebot_messages (role_id, chat_type, chat_id, message_id) WHERE message_id IS NOT NULL;
CREATE TABLE IF NOT EXISTS role_meta (
    role_id TEXT PRIMARY KEY,
    started_at REAL NOT NULL
);
"""

#: datetime 只有微秒精度，与 float 时间戳互转可能差不到 1 微秒；范围比较留出余量。
_EPOCH_TOLERANCE = 1e-5

_SCHEMA_LOCK = threading.Lock()
_TRIM_LOCK = threading.Lock()
_SCHEMA_READY: set = set()
_PURGE_LOCK = threading.Lock()
_last_purge = 0.0


def db_path() -> Path:
    return paths.DATA_DIR / DB_FILENAME


_LOCAL = threading.local()
_CONNS: list = []
_CONNS_LOCK = threading.Lock()
_generation = 0


def _connect(create: bool = True) -> Optional[sqlite3.Connection]:
    """取当前线程的数据库连接；create=False 且文件不存在时返回 None（读取路径不凭空建库）。

    每个线程缓存一条连接。写入频繁，逐次新建 / 关闭连接的开销（WAL 关闭时的检查点与
    文件重建）比一次插入本身大一个数量级。连接仅供创建它的线程使用，``close_all`` 统一关闭。
    """
    path = db_path()
    exists = path.exists()
    if not create and not exists:
        return None
    key = str(path)
    cache = getattr(_LOCAL, "conns", None)
    if cache is None or getattr(_LOCAL, "generation", -1) != _generation:
        cache = _LOCAL.conns = {}
        _LOCAL.generation = _generation
    conn = cache.get(key)
    if conn is not None:
        if exists:
            return conn
        cache.pop(key, None)  # 文件被外部删除：丢弃旧连接，重新建库
        try:
            conn.close()
        except sqlite3.Error:
            pass
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(path, timeout=5.0, check_same_thread=False)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    conn.execute("PRAGMA busy_timeout=5000")
    with _SCHEMA_LOCK:
        if key not in _SCHEMA_READY or not exists:
            # 增量真空模式：删除记录后能把空闲页还给文件系统，大小上限才真正生效。
            # 新库与旧库都会先落到该模式（空库上的 VACUUM 几乎没有开销）。
            if conn.execute("PRAGMA auto_vacuum").fetchone()[0] != 2:
                conn.execute("PRAGMA auto_vacuum=INCREMENTAL")
                conn.execute("VACUUM")
            conn.executescript(_SCHEMA)
            conn.commit()
            _SCHEMA_READY.add(key)
    cache[key] = conn
    with _CONNS_LOCK:
        _CONNS.append(conn)
    return conn


@contextmanager
def _open(create: bool = True):
    """产出当前线程的缓存连接（不在退出时关闭）；create=False 且文件不存在时产出 None。"""
    yield _connect(create=create)


def close_all() -> None:
    """关闭所有线程的连接（服务关闭、测试清理时调用）；之后的访问会自动重新连接。"""
    global _generation
    _generation += 1
    with _CONNS_LOCK:
        conns = list(_CONNS)
        _CONNS.clear()
    for conn in conns:
        try:
            conn.close()
        except sqlite3.Error:
            pass


def reset_schema_cache() -> None:
    """测试或数据目录变更后：关闭连接并让下一次连接重新检查建表。"""
    global _last_purge
    close_all()
    with _SCHEMA_LOCK:
        _SCHEMA_READY.clear()
    _last_purge = 0.0


# ---------------------------------------------------------------- 写入 / 清理

def purge(now: Optional[float] = None) -> int:
    """删除超过保留期的记录，返回删除条数。数据库不存在时什么也不做。"""
    now = time.time() if now is None else now
    with _open(create=False) as conn:
        if conn is None:
            return 0
        with conn:
            cursor = conn.execute(
                "DELETE FROM onebot_messages WHERE ts_epoch < ?", (now - RETENTION_SECONDS,)
            )
        removed = cursor.rowcount or 0
        if removed:
            conn.execute("PRAGMA incremental_vacuum").fetchall()  # 每步只释放一页，需取完
        return removed


def db_size_bytes() -> int:
    """数据库主文件加 WAL 文件的大小（字节）。"""
    path = db_path()
    total = 0
    for candidate in (path, path.with_name(path.name + "-wal")):
        try:
            total += candidate.stat().st_size
        except OSError:
            pass
    return total


def enforce_size_limit() -> int:
    """库文件超过 ``MAX_DB_BYTES`` 时删除最旧的消息，返回删除条数。

    每轮删掉当前最旧的约 20%，直到降到上限的 ``TRIM_TARGET_RATIO`` 以下。被删除过记录的角色
    把覆盖起点上移到删除的截止时间，保证 ``coverage_start`` 之后的消息库内容始终完整。
    """
    if db_size_bytes() <= MAX_DB_BYTES:
        return 0
    if not _TRIM_LOCK.acquire(blocking=False):
        return 0  # 别的线程正在清理
    deleted_total = 0
    try:
        target = int(MAX_DB_BYTES * TRIM_TARGET_RATIO)
        with _open(create=False) as conn:
            if conn is None:
                return 0
            for _ in range(20):
                conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
                if db_size_bytes() <= target:
                    break
                total = conn.execute("SELECT COUNT(*) FROM onebot_messages").fetchone()[0]
                if not total:
                    break
                drop = max(1, total // 5)
                cutoff = conn.execute(
                    "SELECT ts_epoch FROM onebot_messages ORDER BY ts_epoch, id LIMIT 1 OFFSET ?",
                    (drop - 1,),
                ).fetchone()[0]
                with conn:
                    roles = [
                        row[0] for row in conn.execute(
                            "SELECT DISTINCT role_id FROM onebot_messages WHERE ts_epoch <= ?", (cutoff,)
                        )
                    ]
                    cursor = conn.execute("DELETE FROM onebot_messages WHERE ts_epoch <= ?", (cutoff,))
                    for role_id in roles:
                        conn.execute(
                            "UPDATE role_meta SET started_at = MAX(started_at, ?) WHERE role_id = ?",
                            (cutoff, role_id),
                        )
                deleted_total += cursor.rowcount or 0
                conn.execute("PRAGMA incremental_vacuum").fetchall()  # 每步只释放一页，需取完
            conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    finally:
        _TRIM_LOCK.release()
    if deleted_total:
        logger.info("OneBot 消息库超过 %d MB 上限，已删除最旧的 %d 条记录",
                    MAX_DB_BYTES // (1024 * 1024), deleted_total)
    return deleted_total


def _maybe_purge(now: float) -> None:
    global _last_purge
    with _PURGE_LOCK:
        if now - _last_purge < PURGE_INTERVAL_SECONDS:
            return
        _last_purge = now
    try:
        removed = purge(now)
        if removed:
            logger.info("OneBot 消息库清理：删除 %d 条超过 3 天的记录", removed)
    except Exception:  # noqa: BLE001 - 清理失败不影响记录与读取
        logger.warning("OneBot 消息库清理失败", exc_info=True)


def record(
    role_id: str,
    chat_type: str,
    chat_id: str,
    text: str,
    *,
    user_id: str = "",
    sender: str = "",
    is_self: bool = False,
    message_id: Optional[int] = None,
    when: Optional[float] = None,
) -> bool:
    """记录一条消息；同一会话内相同 message_id 只记一次。返回是否新写入。"""
    content = (text or "").strip()
    if not content or not role_id or not chat_id:
        return False
    content = content[:MAX_CONTENT_CHARS]
    now = time.time()
    epoch = float(when) if when else now
    stamp = datetime.fromtimestamp(epoch).isoformat()
    with _open() as conn:
        with conn:
            conn.execute(
                "INSERT OR IGNORE INTO role_meta (role_id, started_at) VALUES (?, ?)",
                (role_id, min(now, epoch)),
            )
            cursor = conn.execute(
                "INSERT OR IGNORE INTO onebot_messages "
                "(role_id, chat_type, chat_id, ts, ts_epoch, user_id, sender, is_self, message_id, content) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (
                    role_id, chat_type, str(chat_id), stamp, epoch, str(user_id or ""),
                    sender or "", 1 if is_self else 0, message_id, content,
                ),
            )
        written = bool(cursor.rowcount)
    _maybe_purge(now)
    try:
        enforce_size_limit()
    except Exception:  # noqa: BLE001 - 清理失败不影响记录
        logger.warning("OneBot 消息库容量清理失败", exc_info=True)
    return written


def should_log(inbound: Inbound, config: Dict[str, Any]) -> bool:
    """这条入站消息是否属于允许机器人参与的会话（与回复无关）。"""
    if inbound.is_owner and inbound.content.startswith("/"):
        return False  # 管理指令不是聊天内容
    if policy.check_disabled_or_blocked(inbound, config):
        return False
    if inbound.is_private and inbound.is_owner:
        return True
    return policy.check_whitelist(inbound, config) is None


def _chat_key(inbound: Inbound) -> tuple:
    if inbound.is_group:
        return CHAT_GROUP, str(inbound.group_id or "")
    return CHAT_PRIVATE, str(inbound.user_id or "")


def record_inbound(inbound: Inbound, config: Dict[str, Any], when: Optional[int] = None) -> bool:
    """记录一条入站消息（已通过 ``should_log`` 的才写入）。"""
    if not should_log(inbound, config):
        return False
    chat_type, chat_id = _chat_key(inbound)
    return record(
        inbound.role_id, chat_type, chat_id, inbound.content,
        user_id=str(inbound.user_id or ""), sender=inbound.sender,
        message_id=inbound.message_id, when=when,
    )


def outgoing_text(item: Any) -> str:
    """把一条已送达的 AI 消息转成可回顾的文字。"""
    kind = getattr(item, "kind", "")
    if kind == "text":
        return (getattr(item, "text", "") or "").strip()
    if kind == "voice":
        voice = getattr(item, "voice", None) or {}
        spoken = str(voice.get("text") or "").strip()
        return f"[语音] {spoken}".strip()
    if kind == "sticker":
        return "[表情]"
    return ""


def record_outgoing(role_id: str, target: Target, item: Any) -> bool:
    """记录机器人在某个会话里发出的一条消息。"""
    if target.is_group:
        chat_type, chat_id = CHAT_GROUP, str(target.group_id)
    else:
        chat_type, chat_id = CHAT_PRIVATE, str(target.user_id)
    return record(role_id, chat_type, chat_id, outgoing_text(item), is_self=True)


def safe_call(fn, *args, **kwargs) -> bool:
    """记录失败只写日志，绝不影响收发消息。"""
    try:
        return bool(fn(*args, **kwargs))
    except Exception:  # noqa: BLE001
        logger.warning("OneBot 消息库写入失败", exc_info=True)
        return False


async def arun(fn, *args) -> bool:
    """在线程池里执行写入，不阻塞事件循环；失败只写日志。"""
    return await asyncio.get_running_loop().run_in_executor(None, safe_call, fn, *args)


# ---------------------------------------------------------------- 读取

def coverage_start(role_id: str, now: Optional[float] = None) -> Optional[datetime]:
    """本库对该角色已完整覆盖的起点（本地无时区时间）；尚未开始记录时返回 None。"""
    now = time.time() if now is None else now
    with _open(create=False) as conn:
        if conn is None:
            return None
        row = conn.execute(
            "SELECT started_at FROM role_meta WHERE role_id = ?", (role_id,)
        ).fetchone()
    if not row:
        return None
    return datetime.fromtimestamp(max(float(row[0]), now - RETENTION_SECONDS))


def speaker_label(sender: str, is_self: bool, role_name: str) -> str:
    if is_self:
        return role_name or "助手"
    text = (sender or "").strip()
    if text == "user":
        return "用户"
    return text or "群成员"


def query_lines(
    role_id: str,
    chat_type: str,
    chat_id: str,
    start: Optional[datetime],
    end: Optional[datetime],
    count: int,
    limit: int,
    role_name: str = "",
    now: Optional[float] = None,
) -> List[Dict[str, str]]:
    """读取某个会话在 [start, end] 内的消息，按时间升序。

    count > 0：取范围内最新的 count 条；count == 0：取范围内最早的至多 limit 条
    （调用方传 ``上限 + 1`` 以判断是否被截断）。结果只含保留期以内的记录。
    """
    now = time.time() if now is None else now
    clauses = ["role_id = ?", "chat_type = ?", "chat_id = ?", "ts_epoch >= ?"]
    params: List[Any] = [role_id, chat_type, str(chat_id), now - RETENTION_SECONDS]
    if start is not None:
        clauses.append("ts_epoch >= ?")
        params.append(start.timestamp() - _EPOCH_TOLERANCE)
    if end is not None:
        clauses.append("ts_epoch <= ?")
        params.append(end.timestamp() + _EPOCH_TOLERANCE)
    order = "DESC" if count > 0 else "ASC"
    size = count if count > 0 else limit
    with _open(create=False) as conn:
        if conn is None:
            return []
        rows = conn.execute(
            "SELECT ts, sender, is_self, content FROM onebot_messages "
            f"WHERE {' AND '.join(clauses)} ORDER BY ts_epoch {order}, id {order} LIMIT ?",
            params + [size],
        ).fetchall()
    if count > 0:
        rows.reverse()
    return [
        {
            "time": str(ts or "")[:16].replace("T", " "),
            "speaker": speaker_label(sender, bool(is_self), role_name),
            "message": content,
        }
        for ts, sender, is_self, content in rows
    ]

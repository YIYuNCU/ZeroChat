"""
将角色 chats/messages.json 迁移到 memory.sqlite 的 short_term 表。

迁移规则：
1. 跳过表情消息（type=sticker/emoji/emotion）。
2. sender_id == "me" 视为 user，否则视为 assistant。
3. 按时间升序处理。
4. 连续同角色消息以 "$" 拼接到同一行。
5. 强制重建 short_term 数据，id 从 1 开始连续写入。

示例：
  python utils/migrate_messages_to_short_term.py --role-id 1771163250177
  python utils/migrate_messages_to_short_term.py --role-id 1771163250177 --dry-run
"""

from __future__ import annotations

import argparse
import json
import re
import sqlite3
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional


SERVER_DIR = Path(__file__).resolve().parent.parent
DATA_DIR = SERVER_DIR / "data"
ROLES_DIR = DATA_DIR / "roles"

SKIP_TYPES = {"sticker", "emoji", "emotion"}
USER_FORMAT_PATTERN = re.compile(r"^message:.*\ntime:.*$", re.DOTALL)


def _role_dir(role_id: str) -> Path:
    safe_id = str(role_id or "").strip()
    if (
        not safe_id
        or safe_id in {".", ".."}
        or any(ch in safe_id for ch in ("/", "\\", "\x00"))
    ):
        raise ValueError("invalid role_id")
    roles_root = ROLES_DIR.resolve()
    expected = roles_root / safe_id
    resolved = expected.resolve()
    if resolved != expected:
        raise ValueError("role_id resolves through a symbolic link")
    return resolved


@dataclass
class MessageRow:
    role: str
    content: str
    timestamp: str


@dataclass
class ShortTermRow:
    role: str
    content: str
    timestamp: str
    task_id: Optional[str]
    request_id: Optional[str]
    json_memory: Optional[str]
    order: int


def _parse_time(value: Any) -> datetime:
    text = str(value or "").strip()
    if not text:
        return datetime.min
    try:
        return datetime.fromisoformat(text)
    except Exception:
        return datetime.min


def _normalize_role(sender_id: Any) -> str:
    return "user" if str(sender_id or "").strip() == "me" else "assistant"


def _load_messages(messages_path: Path) -> List[Dict[str, Any]]:
    with open(messages_path, "r", encoding="utf-8") as f:
        payload = json.load(f)

    messages = payload.get("messages", [])
    if not isinstance(messages, list):
        return []
    return [m for m in messages if isinstance(m, dict)]


def _build_rows(messages: List[Dict[str, Any]]) -> List[MessageRow]:
    filtered: List[Dict[str, Any]] = []
    for index, item in enumerate(messages):
        msg_type = str(item.get("type") or "text").strip().lower()
        if msg_type in SKIP_TYPES:
            continue
        content = str(item.get("content") or "").strip()
        if not content:
            continue
        filtered.append(
            {
                "_index": index,
                "timestamp": str(item.get("timestamp") or ""),
                "sender_id": item.get("sender_id"),
                "content": content,
            }
        )

    filtered.sort(key=lambda x: (_parse_time(x.get("timestamp")), x.get("_index", 0)))

    rows: List[MessageRow] = []
    current_role: Optional[str] = None
    current_timestamp: Optional[str] = None
    current_parts: List[str] = []

    def flush() -> None:
        nonlocal current_role, current_timestamp, current_parts
        if current_role and current_parts:
            rows.append(
                MessageRow(
                    role=current_role,
                    content="$".join(current_parts),
                    timestamp=current_timestamp or datetime.now().isoformat(),
                )
            )
        current_role = None
        current_timestamp = None
        current_parts = []

    for item in filtered:
        role = _normalize_role(item.get("sender_id"))
        content = str(item.get("content") or "")
        timestamp = str(item.get("timestamp") or datetime.now().isoformat())

        normalized_content = content
        if role == "user":
            normalized_content = f"message:{content}\ntime:{timestamp}"

        if role == current_role:
            current_parts.append(normalized_content)
        else:
            flush()
            current_role = role
            current_timestamp = timestamp
            current_parts = [normalized_content]

    flush()
    return rows


def _ensure_short_term_schema(conn: sqlite3.Connection) -> None:
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

    cols = conn.execute("PRAGMA table_info(short_term)").fetchall()
    existing_cols = {str(c[1]) for c in cols}
    if "task_id" not in existing_cols:
        conn.execute("ALTER TABLE short_term ADD COLUMN task_id TEXT")
    if "request_id" not in existing_cols:
        conn.execute("ALTER TABLE short_term ADD COLUMN request_id TEXT")
    if "json_memory" not in existing_cols:
        conn.execute("ALTER TABLE short_term ADD COLUMN json_memory TEXT")


def _ensure_meta_schema(conn: sqlite3.Connection) -> None:
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS memory_meta (
            key TEXT PRIMARY KEY,
            value TEXT
        )
        """
    )


def _set_meta(conn: sqlite3.Connection, key: str, value: Optional[str]) -> None:
    conn.execute(
        "INSERT OR REPLACE INTO memory_meta (key, value) VALUES (?, ?)",
        (key, value),
    )


def check_id_integrity(role_id: str) -> int:
    role_dir = _role_dir(role_id)
    db_path = role_dir / "memory.sqlite"
    if not db_path.exists():
        print(f"[CHECK-ID] 数据库不存在: {db_path}")
        return 2

    conn = sqlite3.connect(db_path)
    try:
        _ensure_short_term_schema(conn)
        ids = [
            int(row[0])
            for row in conn.execute("SELECT id FROM short_term ORDER BY id ASC").fetchall()
            if row and row[0] is not None
        ]
        if not ids:
            print("[CHECK-ID] short_term 为空，视为通过")
            return 0

        expected = list(range(1, len(ids) + 1))
        if ids == expected:
            print(f"[CHECK-ID] 通过：共 {len(ids)} 行，id 连续且从 1 开始")
            return 0

        first_mismatch = next(
            (i for i, (a, b) in enumerate(zip(ids, expected), start=1) if a != b),
            None,
        )
        print(
            f"[CHECK-ID] 失败：id 不连续或未从 1 开始，首个异常位置={first_mismatch}, "
            f"实际={ids[first_mismatch - 1] if first_mismatch else ids[0]}, "
            f"期望={expected[first_mismatch - 1] if first_mismatch else 1}"
        )
        return 1
    finally:
        conn.close()


def check_user_format(role_id: str) -> int:
    role_dir = _role_dir(role_id)
    db_path = role_dir / "memory.sqlite"
    if not db_path.exists():
        print(f"[CHECK-FORMAT] 数据库不存在: {db_path}")
        return 2

    conn = sqlite3.connect(db_path)
    try:
        _ensure_short_term_schema(conn)
        rows = conn.execute(
            "SELECT id, content FROM short_term WHERE role = 'user' ORDER BY id ASC"
        ).fetchall()
        if not rows:
            print("[CHECK-FORMAT] 没有 user 行，视为通过")
            return 0

        bad: List[int] = []
        for row in rows:
            row_id = int(row[0])
            content = str(row[1] or "")
            if "$" in content:
                parts = content.split("$")
                if any(not USER_FORMAT_PATTERN.match(part) for part in parts):
                    bad.append(row_id)
            else:
                if not USER_FORMAT_PATTERN.match(content):
                    bad.append(row_id)

        if not bad:
            print(f"[CHECK-FORMAT] 通过：共 {len(rows)} 条 user 记录均符合 message/time 格式")
            return 0

        preview = ",".join(str(i) for i in bad[:10])
        print(
            f"[CHECK-FORMAT] 失败：共 {len(bad)} 条 user 记录格式不符，示例 id: {preview}"
        )
        return 1
    finally:
        conn.close()


def migrate(role_id: str, dry_run: bool = False) -> None:
    role_dir = _role_dir(role_id)
    messages_path = role_dir / "chats" / "messages.json"
    db_path = role_dir / "memory.sqlite"

    if not messages_path.exists():
        raise FileNotFoundError(f"messages.json 不存在: {messages_path}")

    role_dir.mkdir(parents=True, exist_ok=True)

    messages = _load_messages(messages_path)
    rows = _build_rows(messages)

    print(f"[MIGRATE] role_id={role_id}")
    print(f"[MIGRATE] 原始消息数: {len(messages)}")
    print(f"[MIGRATE] 迁移行数(short_term): {len(rows)}")

    conn = sqlite3.connect(db_path)
    try:
        _ensure_meta_schema(conn)
        _ensure_short_term_schema(conn)
        existing_rows_raw = conn.execute(
            """
            SELECT id, role, content, timestamp, task_id, request_id, json_memory
            FROM short_term
            ORDER BY id ASC
            """
        ).fetchall()

        merged: Dict[tuple[str, str, str], ShortTermRow] = {}
        order_seed = 0

        for r in existing_rows_raw:
            role = str(r[1] or "assistant")
            content = str(r[2] or "")
            timestamp = str(r[3] or "")
            key = (role, content, timestamp)
            if key in merged:
                continue
            merged[key] = ShortTermRow(
                role=role,
                content=content,
                timestamp=timestamp,
                task_id=str(r[4]) if r[4] is not None else None,
                request_id=str(r[5]) if r[5] is not None else None,
                json_memory=str(r[6]) if r[6] is not None else None,
                order=order_seed,
            )
            order_seed += 1

        existing_unique_count = len(merged)

        added_from_messages = 0
        for row in rows:
            key = (row.role, row.content, row.timestamp)
            if key in merged:
                continue
            merged[key] = ShortTermRow(
                role=row.role,
                content=row.content,
                timestamp=row.timestamp,
                task_id=None,
                request_id=None,
                json_memory=None,
                order=order_seed,
            )
            order_seed += 1
            added_from_messages += 1

        merged_rows = list(merged.values())
        merged_rows.sort(key=lambda item: (_parse_time(item.timestamp), item.order))

        existing_count = len(existing_rows_raw)
        duplicate_removed = existing_count - existing_unique_count

        print(f"[MIGRATE] 数据库现有行数: {existing_count}")
        print(f"[MIGRATE] 现有重复移除数: {duplicate_removed}")
        print(f"[MIGRATE] 去重后新增数: {added_from_messages}")
        print(f"[MIGRATE] 重排后总行数: {len(merged_rows)}")

        if dry_run:
            print("[MIGRATE] dry-run 模式，未写入数据库")
            if merged_rows:
                sample = merged_rows[0]
                print(
                    f"[MIGRATE] 重排首行示例: role={sample.role}, ts={sample.timestamp}, content={sample.content[:80]}"
                )
            return

        conn.execute("DROP TABLE IF EXISTS short_term_new")
        conn.execute(
            """
            CREATE TABLE short_term_new (
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

        for new_id, row in enumerate(merged_rows, start=1):
            conn.execute(
                """
                INSERT INTO short_term_new (id, role, content, timestamp, task_id, request_id, json_memory)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    new_id,
                    row.role,
                    row.content,
                    row.timestamp,
                    row.task_id,
                    row.request_id,
                    row.json_memory,
                ),
            )

        conn.execute("DROP TABLE short_term")
        conn.execute("ALTER TABLE short_term_new RENAME TO short_term")

        _set_meta(conn, "updated_at", datetime.now().isoformat())
        total_count = conn.execute("SELECT COUNT(*) FROM short_term").fetchone()[0]
        _set_meta(conn, "message_count_since_summary", str(total_count))
        conn.commit()

        count = conn.execute("SELECT COUNT(*) FROM short_term").fetchone()[0]
        min_id, max_id = conn.execute("SELECT MIN(id), MAX(id) FROM short_term").fetchone()
        print(
            f"[MIGRATE] 写入完成: 新增 {added_from_messages} 行, 当前总计 {count} 行, id范围=({min_id}, {max_id})"
        )
    finally:
        conn.close()


def main() -> None:
    parser = argparse.ArgumentParser(description="迁移 messages.json 到 memory.sqlite short_term")
    parser.add_argument("--role-id", required=True, help="角色ID")
    parser.add_argument("--dry-run", action="store_true", help="仅预览，不写入数据库")
    parser.add_argument("--check-id", action="store_true", help="独立执行 short_term id 连续性检测")
    parser.add_argument("--check-format", action="store_true", help="独立执行 user 消息格式检测")
    args = parser.parse_args()

    if args.check_id or args.check_format:
        status = 0
        if args.check_id:
            status = max(status, check_id_integrity(role_id=str(args.role_id).strip()))
        if args.check_format:
            status = max(status, check_user_format(role_id=str(args.role_id).strip()))
        raise SystemExit(status)

    migrate(role_id=str(args.role_id).strip(), dry_run=args.dry_run)


if __name__ == "__main__":
    main()

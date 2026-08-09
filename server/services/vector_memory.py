"""
向量记忆服务
使用嵌入向量实现语义级别的记忆检索，增强长期记忆的稳定性
"""
import json
import logging
import sqlite3
import threading
from datetime import datetime
from pathlib import Path
from typing import Optional, List, Dict, Any

import numpy as np

logger = logging.getLogger(__name__)

DATA_DIR = Path(__file__).parent.parent / "data"
ROLES_DIR = DATA_DIR / "roles"

# 按 (thread_id, role_id) 复用连接；连接对象不可跨线程并发使用。
_VEC_CONNECTION_POOL: Dict[tuple, sqlite3.Connection] = {}
_VEC_POOL_LOCK = threading.Lock()

# 向量库保留上限：写入后自动裁剪，避免全表扫描随数据无限增长。
_VECTOR_RETENTION_LIMIT = 2000


def close_all_vector_connections():
    """关闭所有缓存的向量库连接（服务关闭时调用）。"""
    with _VEC_POOL_LOCK:
        for conn in _VEC_CONNECTION_POOL.values():
            try:
                conn.close()
            except Exception:
                pass
        _VEC_CONNECTION_POOL.clear()


class VectorMemoryStore:
    """向量记忆存储，支持语义相似度检索"""

    TABLE_DDL = """
        CREATE TABLE IF NOT EXISTS vector_embeddings (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            text TEXT NOT NULL,
            embedding TEXT NOT NULL,
            role TEXT NOT NULL DEFAULT 'assistant',
            timestamp TEXT,
            source TEXT DEFAULT 'chat',
            created_at TEXT NOT NULL
        )
    """
    INDEX_DDL = """
        CREATE INDEX IF NOT EXISTS idx_ve_source ON vector_embeddings(source)
    """

    def __init__(self, role_id: str):
        self.role_id = role_id

    def _get_conn(self) -> sqlite3.Connection:
        """获取按 (线程, 角色) 复用的连接。

        向量库与 memory_service 指向同一 memory.sqlite，因此统一开启 WAL +
        busy_timeout 以避免日志模式冲突和 database is locked。DDL 每连接只跑一次。
        """
        pool_key = (threading.get_ident(), self.role_id)

        with _VEC_POOL_LOCK:
            cached = _VEC_CONNECTION_POOL.get(pool_key)
        if cached is not None:
            try:
                cached.execute("SELECT 1")
                return cached
            except (sqlite3.ProgrammingError, sqlite3.OperationalError):
                with _VEC_POOL_LOCK:
                    _VEC_CONNECTION_POOL.pop(pool_key, None)

        db_path = ROLES_DIR / self.role_id / "memory.sqlite"
        conn = sqlite3.connect(str(db_path), check_same_thread=False)
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA synchronous=NORMAL")
        conn.execute("PRAGMA busy_timeout=5000")
        self._init_vector_table(conn)

        with _VEC_POOL_LOCK:
            _VEC_CONNECTION_POOL[pool_key] = conn
        return conn

    def _init_vector_table(self, conn: sqlite3.Connection):
        conn.execute(self.TABLE_DDL)
        conn.execute(self.INDEX_DDL)
        conn.commit()

    def store(self, text: str, embedding: List[float], role: str = "assistant",
              timestamp: Optional[str] = None, source: str = "chat"):
        """存储一条向量记忆（写入后自动裁剪到保留上限）"""
        conn = self._get_conn()
        conn.execute(
            """INSERT INTO vector_embeddings (text, embedding, role, timestamp, source, created_at)
               VALUES (?, ?, ?, ?, ?, ?)""",
            (text, json.dumps(embedding), role,
             timestamp or datetime.now().isoformat(),
             source, datetime.now().isoformat())
        )
        conn.commit()
        self._trim_to_limit(conn)

    def store_batch(self, items: List[Dict[str, Any]]):
        """批量存储向量记忆（写入后自动裁剪到保留上限）"""
        conn = self._get_conn()
        now = datetime.now().isoformat()
        for item in items:
            conn.execute(
                """INSERT INTO vector_embeddings (text, embedding, role, timestamp, source, created_at)
                   VALUES (?, ?, ?, ?, ?, ?)""",
                (item["text"], json.dumps(item["embedding"]),
                 item.get("role", "assistant"),
                 item.get("timestamp") or now,
                 item.get("source", "chat"), now)
            )
        conn.commit()
        self._trim_to_limit(conn)

    def _trim_to_limit(self, conn: sqlite3.Connection):
        """保留最新 _VECTOR_RETENTION_LIMIT 条，删除更早记录，抑制全表扫描规模。"""
        conn.execute(
            """DELETE FROM vector_embeddings WHERE id NOT IN (
                SELECT id FROM vector_embeddings ORDER BY id DESC LIMIT ?
            )""",
            (_VECTOR_RETENTION_LIMIT,),
        )
        conn.commit()

    def search(self, query_embedding: List[float], top_k: int = 5,
               min_score: float = 0.0) -> List[Dict]:
        """
        搜索与查询向量最相似的记忆（numpy 向量化余弦）

        Returns:
        [{"id": int, "text": str, "role": str, "timestamp": str,
          "source": str, "created_at": str, "score": float}, ...]
        """
        conn = self._get_conn()
        rows = conn.execute(
            "SELECT id, text, embedding, role, timestamp, source, created_at "
            "FROM vector_embeddings"
        ).fetchall()
        if not rows:
            return []

        query = np.asarray(query_embedding, dtype=np.float32)
        q_norm = np.linalg.norm(query)
        if q_norm == 0:
            return []

        scored: List[Dict] = []
        for row in rows:
            try:
                emb = np.asarray(json.loads(row[2]), dtype=np.float32)
            except (ValueError, TypeError):
                continue
            if emb.shape != query.shape:
                continue
            e_norm = np.linalg.norm(emb)
            if e_norm == 0:
                continue
            score = float(np.dot(query, emb) / (q_norm * e_norm))
            if score >= min_score:
                scored.append({
                    "id": row[0],
                    "text": row[1],
                    "role": row[3],
                    "timestamp": row[4],
                    "source": row[5],
                    "created_at": row[6],
                    "score": round(score, 4),
                })

        scored.sort(key=lambda x: x["score"], reverse=True)
        return scored[:top_k]

    def count(self) -> int:
        """返回当前角色的向量记忆数量"""
        conn = self._get_conn()
        row = conn.execute("SELECT COUNT(*) FROM vector_embeddings").fetchone()
        return row[0] if row else 0

    def delete_old(self, keep_count: int = 500):
        """保留最新的 keep_count 条，删除更早的向量记忆"""
        conn = self._get_conn()
        conn.execute(
            """DELETE FROM vector_embeddings WHERE id NOT IN (
                SELECT id FROM vector_embeddings ORDER BY id DESC LIMIT ?
            )""",
            (keep_count,)
        )
        conn.commit()

    def clear(self):
        """清空所有向量记忆"""
        conn = self._get_conn()
        conn.execute("DELETE FROM vector_embeddings")
        conn.commit()

    def list_all(self, limit: int = 500, offset: int = 0) -> List[Dict]:
        """列出向量记忆（不返回 embedding 向量本体，避免传输冗余数据）。

        Returns:
            [{"id": int, "text": str, "role": str, "timestamp": str,
              "source": str, "created_at": str}, ...]，按 id 倒序（最新在前）。
        """
        conn = self._get_conn()
        rows = conn.execute(
            "SELECT id, text, role, timestamp, source, created_at "
            "FROM vector_embeddings ORDER BY id DESC LIMIT ? OFFSET ?",
            (limit, offset),
        ).fetchall()
        return [
            {
                "id": row[0],
                "text": row[1],
                "role": row[2],
                "timestamp": row[3],
                "source": row[4],
                "created_at": row[5],
            }
            for row in rows
        ]

    def get_by_id(self, memory_id: int) -> Optional[Dict]:
        """按主键获取单条向量记忆（不含 embedding 本体）。"""
        conn = self._get_conn()
        row = conn.execute(
            "SELECT id, text, role, timestamp, source, created_at "
            "FROM vector_embeddings WHERE id = ?",
            (memory_id,),
        ).fetchone()
        if not row:
            return None
        return {
            "id": row[0],
            "text": row[1],
            "role": row[2],
            "timestamp": row[3],
            "source": row[4],
            "created_at": row[5],
        }

    def delete_by_id(self, memory_id: int) -> bool:
        """按主键删除单条向量记忆，返回是否删除成功。"""
        conn = self._get_conn()
        cursor = conn.execute(
            "DELETE FROM vector_embeddings WHERE id = ?", (memory_id,)
        )
        conn.commit()
        return cursor.rowcount > 0

    def update_text(self, memory_id: int, new_text: str,
                    new_embedding: List[float]) -> bool:
        """更新单条向量记忆的文本与嵌入向量，返回是否更新成功。"""
        conn = self._get_conn()
        cursor = conn.execute(
            "UPDATE vector_embeddings SET text = ?, embedding = ?, timestamp = ? "
            "WHERE id = ?",
            (new_text, json.dumps(new_embedding),
             datetime.now().isoformat(), memory_id),
        )
        conn.commit()
        return cursor.rowcount > 0


def _cosine_similarity(a: List[float], b: List[float]) -> float:
    """计算两个向量的余弦相似度"""
    if len(a) != len(b) or not a:
        return 0.0
    dot = sum(ai * bi for ai, bi in zip(a, b))
    norm_a = sum(ai * ai for ai in a) ** 0.5
    norm_b = sum(bi * bi for bi in b) ** 0.5
    if norm_a == 0 or norm_b == 0:
        return 0.0
    return dot / (norm_a * norm_b)


def _extract_semantic_text(content: str, _depth: int = 0) -> str:
    """从结构化或 JSON 记忆消息中提取语义文本。"""
    text = str(content or "").strip()
    if not text:
        return ""

    # 支持解析标准 JSON 载荷，避免把 vector_memory 嵌套内容整体入向量库。
    if _depth < 2:
        try:
            parsed = json.loads(text)
            if isinstance(parsed, dict):
                message_value = parsed.get("message")
                if message_value is not None:
                    extracted = _extract_semantic_text(str(message_value), _depth + 1).strip()
                    if extracted:
                        return extracted
        except Exception:
            pass

    lines = text.split("\n")
    for line in lines:
        if line.lower().startswith("message:"):
            candidate = line[len("message:"):].strip()
            if _depth < 2 and candidate.startswith("{") and candidate.endswith("}"):
                extracted = _extract_semantic_text(candidate, _depth + 1).strip()
                if extracted:
                    return extracted
            return candidate
    return lines[0].strip() if lines else text


async def embed_and_store(
    role_id: str,
    content: str,
    role: str = "assistant",
    timestamp: Optional[str] = None,
    source: str = "chat",
    min_text_length: int = 10,
) -> bool:
    """
    生成嵌入向量并存储到向量记忆库

    Args:
        role_id: 角色 ID
        content: 消息内容（可以是结构化格式）
        role: 消息角色
        timestamp: 时间戳
        source: 来源（chat/memory_summary/sequential）
        min_text_length: 最小文本长度，低于此长度不生成向量

    Returns:
        是否成功存储
    """
    text = _extract_semantic_text(content)
    if len(text) < min_text_length:
        logger.info(
            "向量记忆跳过：文本过短 role=%s source=%s len=%d(<%d)",
            role_id, source, len(text), min_text_length,
        )
        return False

    from services.ai_service import generate_embedding
    result = await generate_embedding(text)
    if not result["success"] or not result["embedding"]:
        logger.warning(
            "向量记忆写入失败：embedding 生成失败 role=%s source=%s error=%s",
            role_id, source, result.get("error", "unknown"),
        )
        return False

    try:
        store = VectorMemoryStore(role_id)
        store.store(text, result["embedding"], role=role, timestamp=timestamp, source=source)
    except Exception as e:
        logger.warning(
            "向量记忆写入失败：存储异常 role=%s source=%s error=%s",
            role_id, source, e,
        )
        return False
    return True

"""
向量记忆服务
使用嵌入向量实现语义级别的记忆检索，增强长期记忆的稳定性
"""
import json
import sqlite3
from datetime import datetime
from pathlib import Path
from typing import Optional, List, Dict, Any

DATA_DIR = Path(__file__).parent.parent / "data"
ROLES_DIR = DATA_DIR / "roles"


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
        db_path = ROLES_DIR / self.role_id / "memory.sqlite"
        conn = sqlite3.connect(str(db_path))
        self._init_vector_table(conn)
        return conn

    def _init_vector_table(self, conn: sqlite3.Connection):
        conn.execute(self.TABLE_DDL)
        conn.execute(self.INDEX_DDL)
        conn.commit()

    def store(self, text: str, embedding: List[float], role: str = "assistant",
              timestamp: Optional[str] = None, source: str = "chat"):
        """存储一条向量记忆"""
        conn = self._get_conn()
        try:
            conn.execute(
                """INSERT INTO vector_embeddings (text, embedding, role, timestamp, source, created_at)
                   VALUES (?, ?, ?, ?, ?, ?)""",
                (text, json.dumps(embedding), role,
                 timestamp or datetime.now().isoformat(),
                 source, datetime.now().isoformat())
            )
            conn.commit()
        finally:
            conn.close()

    def store_batch(self, items: List[Dict[str, Any]]):
        """批量存储向量记忆"""
        conn = self._get_conn()
        try:
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
        finally:
            conn.close()

    def search(self, query_embedding: List[float], top_k: int = 5,
               min_score: float = 0.0) -> List[Dict]:
        """
        搜索与查询向量最相似的记忆

        Args:
            query_embedding: 查询向量
            top_k: 返回 top-k 结果
            min_score: 最低相似度阈值

        Returns:
            [{"id": int, "text": str, "role": str, "timestamp": str,
              "source": str, "score": float}, ...]
        """
        conn = self._get_conn()
        try:
            rows = conn.execute(
                "SELECT id, text, embedding, role, timestamp, source, created_at "
                "FROM vector_embeddings"
            ).fetchall()

            scored = []
            for row in rows:
                stored_emb = json.loads(row[2])
                score = _cosine_similarity(query_embedding, stored_emb)
                if score >= min_score:
                    scored.append({
                        "id": row[0],
                        "text": row[1],
                        "role": row[3],
                        "timestamp": row[4],
                        "source": row[5],
                        "score": round(score, 4),
                    })

            scored.sort(key=lambda x: x["score"], reverse=True)
            return scored[:top_k]
        finally:
            conn.close()

    def count(self) -> int:
        """返回当前角色的向量记忆数量"""
        conn = self._get_conn()
        try:
            row = conn.execute("SELECT COUNT(*) FROM vector_embeddings").fetchone()
            return row[0] if row else 0
        finally:
            conn.close()

    def delete_old(self, keep_count: int = 500):
        """保留最新的 keep_count 条，删除更早的向量记忆"""
        conn = self._get_conn()
        try:
            conn.execute(
                """DELETE FROM vector_embeddings WHERE id NOT IN (
                    SELECT id FROM vector_embeddings ORDER BY id DESC LIMIT ?
                )""",
                (keep_count,)
            )
            conn.commit()
        finally:
            conn.close()

    def clear(self):
        """清空所有向量记忆"""
        conn = self._get_conn()
        try:
            conn.execute("DELETE FROM vector_embeddings")
            conn.commit()
        finally:
            conn.close()


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
        return False

    from services.ai_service import generate_embedding
    result = await generate_embedding(text)
    if not result["success"] or not result["embedding"]:
        return False

    store = VectorMemoryStore(role_id)
    store.store(text, result["embedding"], role=role, timestamp=timestamp, source=source)
    return True

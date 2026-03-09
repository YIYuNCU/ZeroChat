"""
朋友圈路由
"""
import json
import uuid
from datetime import datetime
from pathlib import Path
from typing import Optional, List, Tuple
from pydantic import BaseModel
from fastapi import APIRouter, HTTPException

router = APIRouter()

DATA_DIR = Path(__file__).parent.parent / "data"
MOMENTS_FILE = DATA_DIR / "moments" / "posts.json"
TOOL_ROLE_PREFIX = "1000000000"


def _is_tool_role_id(role_id: str) -> bool:
    return str(role_id or "").startswith(TOOL_ROLE_PREFIX)


def _normalize_text(value: Optional[str]) -> str:
    # Normalize line endings and collapse whitespace for robust duplicate checks.
    text = str(value or "").replace("\r\n", "\n").replace("\r", "\n").strip()
    return " ".join(text.split())


def _normalize_images(image_urls: Optional[List[str]]) -> Tuple[str, ...]:
    urls = [str(u).strip() for u in (image_urls or []) if str(u).strip()]
    return tuple(urls)


def _parse_iso_time(value: Optional[str]) -> Optional[datetime]:
    if not value:
        return None
    try:
        return datetime.fromisoformat(str(value))
    except Exception:
        return None


def _is_post_duplicate(existing: dict, author_id: str, content: str, image_urls: List[str], now: datetime) -> bool:
    if str(existing.get("author_id", "")) != str(author_id):
        return False
    if _normalize_text(existing.get("content", "")) != _normalize_text(content):
        return False
    if _normalize_images(existing.get("image_urls", [])) != _normalize_images(image_urls):
        return False
    existing_time = _parse_iso_time(existing.get("created_at"))
    if existing_time is None:
        return False
    # Treat same author+content within 3 minutes as retry duplicate.
    return abs((now - existing_time).total_seconds()) <= 180


def _is_comment_duplicate(existing: dict, author_id: str, content: str, now: datetime) -> bool:
    if str(existing.get("author_id", "")) != str(author_id):
        return False
    if _normalize_text(existing.get("content", "")) != _normalize_text(content):
        return False
    existing_time = _parse_iso_time(existing.get("created_at"))
    if existing_time is None:
        return False
    # Duplicate comment retries are usually very close in time.
    return abs((now - existing_time).total_seconds()) <= 90


def _dedupe_moments_for_render(moments: List[dict]) -> List[dict]:
    deduped: List[dict] = []
    for post in sorted(moments, key=lambda x: x.get("created_at", ""), reverse=True):
        created_at = _parse_iso_time(post.get("created_at"))
        is_dup = False
        for kept in deduped:
            kept_time = _parse_iso_time(kept.get("created_at"))
            if kept_time is None or created_at is None:
                continue
            if abs((kept_time - created_at).total_seconds()) > 180:
                continue
            if (
                str(kept.get("author_id", "")) == str(post.get("author_id", ""))
                and _normalize_text(kept.get("content", "")) == _normalize_text(post.get("content", ""))
                and _normalize_images(kept.get("image_urls", [])) == _normalize_images(post.get("image_urls", []))
            ):
                is_dup = True
                break
        if not is_dup:
            deduped.append(post)
    return deduped

class MomentCreate(BaseModel):
    author_id: str
    author_name: str
    content: str
    image_urls: Optional[List[str]] = []

class CommentCreate(BaseModel):
    author_id: str
    author_name: str
    content: str
    reply_to_id: Optional[str] = None
    reply_to_name: Optional[str] = None

def load_moments() -> List[dict]:
    if MOMENTS_FILE.exists():
        with open(MOMENTS_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    return []

def save_moments(moments: List[dict]):
    MOMENTS_FILE.parent.mkdir(parents=True, exist_ok=True)
    with open(MOMENTS_FILE, "w", encoding="utf-8") as f:
        json.dump(moments, f, indent=2, ensure_ascii=False)

@router.get("/moments")
async def list_moments(limit: int = 50):
    """获取朋友圈列表"""
    moments = [m for m in load_moments() if not _is_tool_role_id(str(m.get("author_id", "")))]
    moments = _dedupe_moments_for_render(moments)
    # 按时间倒序
    moments.sort(key=lambda x: x.get("created_at", ""), reverse=True)
    return {"moments": moments[:limit]}

@router.post("/moments")
async def create_moment(moment: MomentCreate):
    """发布朋友圈"""
    if _is_tool_role_id(moment.author_id):
        raise HTTPException(status_code=403, detail="工具角色禁止发布朋友圈")

    moments = load_moments()
    now = datetime.now()

    for existing in moments:
        if _is_post_duplicate(existing, moment.author_id, moment.content, moment.image_urls or [], now):
            # Idempotent return for retry requests with same payload.
            return existing
    
    new_post = {
        "id": str(uuid.uuid4()),
        "author_id": moment.author_id,
        "author_name": moment.author_name,
        "content": moment.content,
        "image_urls": moment.image_urls,
        "liked_by": [],
        "comments": [],
        "created_at": now.isoformat()
    }
    
    moments.insert(0, new_post)
    save_moments(moments)
    return new_post

@router.get("/moments/{post_id}")
async def get_moment(post_id: str):
    """获取朋友圈详情"""
    moments = load_moments()
    for m in moments:
        if m["id"] == post_id:
            return m
    return {"error": "not found"}

@router.delete("/moments/{post_id}")
async def delete_moment(post_id: str):
    """删除朋友圈"""
    moments = load_moments()
    moments = [m for m in moments if m["id"] != post_id]
    save_moments(moments)
    return {"success": True}

@router.post("/moments/{post_id}/like")
async def like_moment(post_id: str, user_id: str, user_name: str):
    """点赞"""
    moments = load_moments()
    for m in moments:
        if m["id"] == post_id:
            if user_id not in [l.get("id") for l in m.get("liked_by", [])]:
                m.setdefault("liked_by", []).append({
                    "id": user_id,
                    "name": user_name
                })
            save_moments(moments)
            return m
    return {"error": "not found"}

@router.delete("/moments/{post_id}/like/{user_id}")
async def unlike_moment(post_id: str, user_id: str):
    """取消点赞"""
    moments = load_moments()
    for m in moments:
        if m["id"] == post_id:
            m["liked_by"] = [l for l in m.get("liked_by", []) if l.get("id") != user_id]
            save_moments(moments)
            return m
    return {"error": "not found"}

@router.post("/moments/{post_id}/comment")
async def add_comment(post_id: str, comment: CommentCreate):
    """添加评论"""
    moments = load_moments()
    for m in moments:
        if m["id"] == post_id:
            now = datetime.now()
            for existing_comment in m.get("comments", []):
                if _is_comment_duplicate(existing_comment, comment.author_id, comment.content, now):
                    return existing_comment

            new_comment = {
                "id": str(uuid.uuid4()),
                "author_id": comment.author_id,
                "author_name": comment.author_name,
                "content": comment.content,
                "reply_to_id": comment.reply_to_id,
                "reply_to_name": comment.reply_to_name,
                "created_at": now.isoformat()
            }
            m.setdefault("comments", []).append(new_comment)
            save_moments(moments)
            return new_comment
    return {"error": "not found"}

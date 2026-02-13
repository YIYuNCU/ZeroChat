"""
朋友圈路由
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
MOMENTS_FILE = DATA_DIR / "moments" / "posts.json"

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
    moments = load_moments()
    # 按时间倒序
    moments.sort(key=lambda x: x.get("created_at", ""), reverse=True)
    return {"moments": moments[:limit]}

@router.post("/moments")
async def create_moment(moment: MomentCreate):
    """发布朋友圈"""
    moments = load_moments()
    
    new_post = {
        "id": str(uuid.uuid4()),
        "author_id": moment.author_id,
        "author_name": moment.author_name,
        "content": moment.content,
        "image_urls": moment.image_urls,
        "liked_by": [],
        "comments": [],
        "created_at": datetime.now().isoformat()
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
            new_comment = {
                "id": str(uuid.uuid4()),
                "author_id": comment.author_id,
                "author_name": comment.author_name,
                "content": comment.content,
                "reply_to_id": comment.reply_to_id,
                "reply_to_name": comment.reply_to_name,
                "created_at": datetime.now().isoformat()
            }
            m.setdefault("comments", []).append(new_comment)
            save_moments(moments)
            return new_comment
    return {"error": "not found"}

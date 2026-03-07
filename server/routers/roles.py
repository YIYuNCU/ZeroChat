"""
角色管理路由
"""
import json
import hashlib
import sqlite3
import uuid
from datetime import datetime
from pathlib import Path
from typing import Optional, List, Dict, Any
from urllib.parse import urlparse
from pydantic import BaseModel
from fastapi import APIRouter, HTTPException, Request, UploadFile, File, Form

router = APIRouter()

DATA_DIR = Path(__file__).parent.parent / "data"
ROLES_DIR = DATA_DIR / "roles"
USER_EMOJI_DIR = DATA_DIR / "user_emojis"
USER_EMOJI_DB = DATA_DIR / "user_emojis.sqlite"
TOOL_ROLE_PREFIX = "1000000000"


def _is_tool_role_id(role_id: str) -> bool:
    return str(role_id or "").startswith(TOOL_ROLE_PREFIX)


def _normalize_category_name(name: str) -> str:
    normalized = str(name or "").strip().lower()
    if not normalized:
        raise HTTPException(status_code=400, detail="分类不能为空")
    if any(c in normalized for c in ["..", "/", "\\"]):
        raise HTTPException(status_code=400, detail="分类名不合法")
    return normalized


def _init_user_emoji_db(conn: sqlite3.Connection):
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS user_emoji_categories (
            name TEXT PRIMARY KEY,
            created_at TEXT
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS user_emojis (
            id TEXT PRIMARY KEY,
            category TEXT NOT NULL,
            tag TEXT NOT NULL,
            filename TEXT NOT NULL,
            file_path TEXT NOT NULL,
            created_at TEXT,
            FOREIGN KEY (category) REFERENCES user_emoji_categories(name)
        )
        """
    )
    conn.execute("CREATE INDEX IF NOT EXISTS idx_user_emojis_category ON user_emojis(category)")


def _get_user_emoji_connection() -> sqlite3.Connection:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    USER_EMOJI_DIR.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(USER_EMOJI_DB)
    conn.row_factory = sqlite3.Row
    _init_user_emoji_db(conn)
    return conn


def _guess_ext(filename: str) -> str:
    ext = filename.split(".")[-1].lower() if "." in filename else "png"
    if ext not in {"png", "jpg", "jpeg", "gif", "webp"}:
        ext = "png"
    return ext


class EmojiCategoryPayload(BaseModel):
    category: str


class ResolveUserEmojiTagPayload(BaseModel):
    emoji_id: str

class ProactiveConfig(BaseModel):
    """主动消息配置"""
    enabled: bool = False
    min_interval_minutes: int = 30
    max_interval_minutes: int = 120
    trigger_prompt: str = ""
    quiet_hours_start: int = 23  # 23:00
    quiet_hours_end: int = 7    # 07:00
    next_trigger_time: Optional[str] = None

class PersonalityTraits(BaseModel):
    """人格特质"""
    openness: int = 50          # 开放性 0-100
    conscientiousness: int = 50 # 尽责性
    extraversion: int = 50      # 外向性
    agreeableness: int = 50     # 宜人性
    neuroticism: int = 50       # 神经质


class MenstruationCycle(BaseModel):
    """生理周期配置"""
    cycle_length: int = 30
    period_length: int = 6
    last_period_start: str = "2026-01-24"

class RoleCreate(BaseModel):
    """创建角色"""
    id: str
    name: str
    avatar_url: Optional[str] = ""
    
    # 人设与提示词
    persona: Optional[str] = ""         # 角色人设描述
    system_prompt: Optional[str] = ""   # 系统提示词
    greeting: Optional[str] = ""        # 首次对话问候语
    description: Optional[str] = ""     # 简短描述
    
    # 核心记忆
    core_memory: Optional[List[str]] = []

    # 角色专属 AI 配置
    ai_model: Optional[str] = None
    ai_api_url: Optional[str] = None
    ai_api_key: Optional[str] = None
    ai_temperature: Optional[float] = None

    # 性别与生理周期
    gender: Optional[str] = "men"
    menstruation_cycle: Optional[MenstruationCycle] = None
    
    # 人格配置
    personality: Optional[PersonalityTraits] = None
    
    # 主动消息配置
    proactive_config: Optional[ProactiveConfig] = None
    
    # 扩展元数据
    tags: Optional[List[str]] = []
    metadata: Optional[Dict[str, Any]] = {}

class RoleUpdate(BaseModel):
    """更新角色"""
    name: Optional[str] = None
    avatar_url: Optional[str] = None
    persona: Optional[str] = None
    system_prompt: Optional[str] = None
    greeting: Optional[str] = None
    description: Optional[str] = None
    core_memory: Optional[List[str]] = None
    personality: Optional[PersonalityTraits] = None
    proactive_config: Optional[ProactiveConfig] = None
    tags: Optional[List[str]] = None
    metadata: Optional[Dict[str, Any]] = None
    ai_model: Optional[str] = None
    ai_api_url: Optional[str] = None
    ai_api_key: Optional[str] = None
    ai_temperature: Optional[float] = None
    gender: Optional[str] = None
    menstruation_cycle: Optional[MenstruationCycle] = None

class MemoryUpdate(BaseModel):
    """记忆更新"""
    core_memory: Optional[str] = None
    short_term: Optional[List[str]] = None

def get_role_dir(role_id: str) -> Path:
    """获取角色目录，自动创建完整目录结构"""
    role_dir = ROLES_DIR / role_id
    role_dir.mkdir(parents=True, exist_ok=True)
    
    # 创建所有子目录
    subdirs = ["assets", "chats", "emojis", "moments", "backgrounds"]
    for subdir in subdirs:
        (role_dir / subdir).mkdir(exist_ok=True)
    
    # 创建情绪表情包子目录
    emotions = ["happy", "sad", "angry", "surprised", "love", "confused", "tired"]
    for emotion in emotions:
        (role_dir / "emojis" / emotion).mkdir(exist_ok=True)
    
    if not (role_dir / "chats" / "messages.json").exists():
        with open(role_dir / "chats" / "messages.json", "w", encoding="utf-8") as f:
            json.dump({"messages": []}, f)
    
    if not (role_dir / "moments" / "posts.json").exists():
        with open(role_dir / "moments" / "posts.json", "w", encoding="utf-8") as f:
            json.dump({"posts": []}, f)
    
    return role_dir

def load_role(role_id: str) -> Optional[Dict]:
    profile_file = get_role_dir(role_id) / "profile.json"
    if profile_file.exists():
        with open(profile_file, "r", encoding="utf-8") as f:
            return json.load(f)
    return None


def _get_role_avatar_path(role_id: str) -> Optional[Path]:
    role_dir = get_role_dir(role_id)
    assets_dir = role_dir / "assets"
    for ext in ["jpg", "jpeg", "png", "gif", "webp"]:
        avatar_path = assets_dir / f"avatar.{ext}"
        if avatar_path.exists():
            return avatar_path
    return None


def _get_role_avatar_hash(role_id: str) -> str:
    avatar_path = _get_role_avatar_path(role_id)
    if avatar_path is None:
        return ""
    with open(avatar_path, "rb") as f:
        return hashlib.md5(f.read()).hexdigest()

def save_role(role_id: str, data: Dict):
    profile_file = get_role_dir(role_id) / "profile.json"
    data["updated_at"] = datetime.now().isoformat()
    with open(profile_file, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)

def normalize_role_avatar_url(role: Dict[str, Any], request: Request) -> Dict[str, Any]:
    role_copy = dict(role)
    role_id = str(role_copy.get("id", "")).strip()
    if role_id:
        if not role_copy.get("avatar_url",None):
            return role_copy
        role_copy["avatar_url"] = str(request.url_for("get_role_avatar_file", role_id=role_id))
        role_copy["avatar_hash"] = _get_role_avatar_hash(role_id)
    return role_copy

@router.get("/roles")
async def list_roles(request: Request):
    """获取所有角色"""
    roles = []
    if ROLES_DIR.exists():
        for role_dir in ROLES_DIR.iterdir():
            if role_dir.is_dir():
                role = load_role(role_dir.name)
                if role:
                    roles.append(normalize_role_avatar_url(role, request))
    return {"roles": roles}

@router.get("/roles/{role_id}")
async def get_role(role_id: str, request: Request):
    """获取角色详情"""
    role = load_role(role_id)
    if not role:
        raise HTTPException(status_code=404, detail="角色不存在")
    return normalize_role_avatar_url(role, request)

@router.post("/roles")
async def create_role(role: RoleCreate, request: Request):
    """创建或更新角色（upsert）"""
    existing = load_role(role.id)
    
    if existing:
        # 更新现有角色
        print(f"[ROLES] Updating existing role: {role.id}")
        for key, value in role.model_dump(exclude_none=True).items():
            if key != 'id' and value is not None:
                existing[key] = value
        save_role(role.id, existing)
        print(f"[ROLES] Role updated: {role.id}, core_memory count: {len(existing.get('core_memory', []))}")
        return normalize_role_avatar_url(existing, request)
    
    # 创建新角色
    print(f"[ROLES] Creating new role: {role.id}")
    data = {
        "id": role.id,
        "name": role.name,
        "avatar_url": role.avatar_url or "",
        "persona": role.persona or "",
        "system_prompt": role.system_prompt or "",
        "greeting": role.greeting or "",
        "description": role.description or "",
        "core_memory": role.core_memory or [],
        "ai_model": role.ai_model or "deepseek-chat",
        "ai_api_url": role.ai_api_url or "",
        "ai_api_key": role.ai_api_key or "",
        "ai_temperature": role.ai_temperature if role.ai_temperature is not None else 0.7,
        "personality": role.personality.model_dump() if role.personality else {
            "openness": 50, "conscientiousness": 50, "extraversion": 50,
            "agreeableness": 50, "neuroticism": 50
        },
        "proactive_config": role.proactive_config.model_dump() if role.proactive_config else {
            "enabled": False, "min_interval_minutes": 30, "max_interval_minutes": 120,
            "trigger_prompt": "", "quiet_hours_start": 23, "quiet_hours_end": 7,
            "next_trigger_time": None
        },
        "tags": role.tags or [],
        "gender": role.gender or "men",
        "menstruation_cycle": role.menstruation_cycle.model_dump() if role.menstruation_cycle else {
            "cycle_length": 30,
            "period_length": 6,
            "last_period_start": "2026-01-24"
        },
        "metadata": role.metadata or {},
        "created_at": datetime.now().isoformat()
    }
    save_role(role.id, data)
    # Ensure an empty memory database exists for the new role.
    if not _is_tool_role_id(role.id):
        from services.memory_service import load_memory
        load_memory(role.id)
    print(f"[ROLES] Role created: {role.id}")
    return normalize_role_avatar_url(data, request)

@router.put("/roles/{role_id}")
async def update_role(role_id: str, update: RoleUpdate, request: Request):
    """更新角色"""
    role = load_role(role_id)
    if not role:
        raise HTTPException(status_code=404, detail="角色不存在")
    
    for key, value in update.model_dump(exclude_none=True).items():
        role[key] = value
    
    save_role(role_id, role)
    return normalize_role_avatar_url(role, request)

@router.delete("/roles/{role_id}")
async def delete_role(role_id: str):
    """删除角色"""
    role_dir = ROLES_DIR / role_id
    if role_dir.exists():
        import shutil
        shutil.rmtree(role_dir)
    return {"success": True}

# ========== 记忆管理 ==========

def _normalize_short_term(items: List[Any]) -> List[Dict[str, Any]]:
    normalized: List[Dict[str, Any]] = []
    for item in items:
        if isinstance(item, dict):
            content = str(item.get("content", ""))
            role = item.get("role") or "assistant"
            timestamp = item.get("timestamp") or datetime.now().isoformat()
        else:
            content = str(item)
            role = "assistant"
            timestamp = datetime.now().isoformat()
        normalized.append({"role": role, "content": content, "timestamp": timestamp})
    return normalized

@router.get("/roles/{role_id}/memory")
async def get_memory(role_id: str):
    """获取角色记忆"""
    from services.memory_service import load_memory

    memory = load_memory(role_id)
    return {
        "core_memory": memory.get("core_memory", ""),
        "short_term": memory.get("short_term", [])
    }

@router.put("/roles/{role_id}/memory")
async def update_memory(role_id: str, update: MemoryUpdate):
    """更新角色记忆"""
    from services.memory_service import load_memory, save_memory

    memory = load_memory(role_id)
    
    if update.core_memory is not None:
        memory["core_memory"] = update.core_memory
    if update.short_term is not None:
        memory["short_term"] = _normalize_short_term(update.short_term)
    
    save_memory(role_id, memory)
    return {
        "core_memory": memory.get("core_memory", ""),
        "short_term": memory.get("short_term", [])
    }

@router.post("/roles/{role_id}/memory/append")
async def append_memory(role_id: str, content: str):
    """追加短期记忆"""
    from services.memory_service import append_short_term, load_memory

    append_short_term(role_id, "assistant", content, window_size=50)
    memory = load_memory(role_id)
    return {
        "core_memory": memory.get("core_memory", ""),
        "short_term": memory.get("short_term", [])
    }

# ========== 素材管理 ==========

import uuid
import shutil
from fastapi import UploadFile, File
from fastapi.responses import FileResponse

ALLOWED_EXTENSIONS = {".png", ".jpg", ".jpeg", ".gif", ".webp"}

def get_assets_dir(role_id: str) -> Path:
    """获取角色素材目录"""
    assets_dir = get_role_dir(role_id) / "assets"
    assets_dir.mkdir(parents=True, exist_ok=True)
    return assets_dir

def get_asset_metadata_file(role_id: str) -> Path:
    """获取素材元数据文件"""
    return get_role_dir(role_id) / "assets_meta.json"

def load_assets_metadata(role_id: str) -> List[Dict]:
    """加载素材元数据"""
    meta_file = get_asset_metadata_file(role_id)
    if meta_file.exists():
        with open(meta_file, "r", encoding="utf-8") as f:
            return json.load(f)
    return []

def save_assets_metadata(role_id: str, metadata: List[Dict]):
    """保存素材元数据"""
    meta_file = get_asset_metadata_file(role_id)
    with open(meta_file, "w", encoding="utf-8") as f:
        json.dump(metadata, f, indent=2, ensure_ascii=False)

@router.get("/roles/{role_id}/assets")
async def list_assets(role_id: str):
    """获取角色素材列表"""
    role = load_role(role_id)
    if not role:
        raise HTTPException(status_code=404, detail="角色不存在")
    
    metadata = load_assets_metadata(role_id)
    return {"role_id": role_id, "assets": metadata}

@router.post("/roles/{role_id}/assets")
async def upload_asset(
    role_id: str,
    file: UploadFile = File(...),
    asset_type: str = "sticker"  # sticker / image
):
    """上传素材"""
    role = load_role(role_id)
    if not role:
        raise HTTPException(status_code=404, detail="角色不存在")
    
    # 检查文件类型
    ext = Path(file.filename).suffix.lower()
    if ext not in ALLOWED_EXTENSIONS:
        raise HTTPException(status_code=400, detail=f"不支持的文件类型: {ext}")
    
    # 生成唯一文件名
    asset_id = str(uuid.uuid4())
    filename = f"{asset_id}{ext}"
    
    # 保存文件
    assets_dir = get_assets_dir(role_id)
    file_path = assets_dir / filename
    
    with open(file_path, "wb") as f:
        content = await file.read()
        f.write(content)
    
    # 更新元数据
    metadata = load_assets_metadata(role_id)
    asset_info = {
        "id": asset_id,
        "filename": filename,
        "original_name": file.filename,
        "type": asset_type,
        "size": len(content),
        "created_at": datetime.now().isoformat()
    }
    metadata.append(asset_info)
    save_assets_metadata(role_id, metadata)
    
    return asset_info

@router.get("/roles/{role_id}/assets/{asset_id}")
async def get_asset(role_id: str, asset_id: str):
    """获取素材文件"""
    metadata = load_assets_metadata(role_id)
    asset = next((a for a in metadata if a["id"] == asset_id), None)
    
    if not asset:
        raise HTTPException(status_code=404, detail="素材不存在")
    
    file_path = get_assets_dir(role_id) / asset["filename"]
    if not file_path.exists():
        raise HTTPException(status_code=404, detail="文件不存在")
    
    return FileResponse(file_path)

@router.delete("/roles/{role_id}/assets/{asset_id}")
async def delete_asset(role_id: str, asset_id: str):
    """删除素材"""
    metadata = load_assets_metadata(role_id)
    asset = next((a for a in metadata if a["id"] == asset_id), None)
    
    if not asset:
        raise HTTPException(status_code=404, detail="素材不存在")
    
    # 删除文件
    file_path = get_assets_dir(role_id) / asset["filename"]
    if file_path.exists():
        file_path.unlink()
    
    # 更新元数据
    metadata = [a for a in metadata if a["id"] != asset_id]
    save_assets_metadata(role_id, metadata)
    
    return {"success": True}

@router.get("/roles/{role_id}/assets/type/{asset_type}")
async def list_assets_by_type(role_id: str, asset_type: str):
    """按类型获取素材列表"""
    metadata = load_assets_metadata(role_id)
    filtered = [a for a in metadata if a.get("type") == asset_type]
    return {"role_id": role_id, "type": asset_type, "assets": filtered}

# ========== 表情包接口 ==========

@router.get("/roles/{role_id}/emoji-categories")
async def list_role_emoji_categories(role_id: str):
    role_dir = get_role_dir(role_id)
    emojis_dir = role_dir / "emojis"
    if not emojis_dir.exists():
        return {"role_id": role_id, "categories": []}

    categories = sorted([d.name for d in emojis_dir.iterdir() if d.is_dir()])
    return {"role_id": role_id, "categories": categories}


@router.post("/roles/{role_id}/emoji-categories")
async def create_role_emoji_category(role_id: str, payload: EmojiCategoryPayload):
    category = _normalize_category_name(payload.category)
    category_dir = get_role_dir(role_id) / "emojis" / category
    category_dir.mkdir(parents=True, exist_ok=True)
    return {"success": True, "role_id": role_id, "category": category}


@router.delete("/roles/{role_id}/emoji-categories/{category}")
async def delete_role_emoji_category(role_id: str, category: str):
    import shutil

    normalized = _normalize_category_name(category)
    category_dir = get_role_dir(role_id) / "emojis" / normalized
    if not category_dir.exists():
        raise HTTPException(status_code=404, detail="分类不存在")
    shutil.rmtree(category_dir)
    return {"success": True, "role_id": role_id, "category": normalized}


@router.get("/roles/{role_id}/emojis/{category}/list")
async def list_role_emojis(role_id: str, category: str):
    normalized = _normalize_category_name(category)
    emoji_dir = get_role_dir(role_id) / "emojis" / normalized
    if not emoji_dir.exists():
        return {"role_id": role_id, "category": normalized, "emojis": []}

    supported_ext = {".png", ".jpg", ".jpeg", ".gif", ".webp"}
    files = sorted(
        [f for f in emoji_dir.iterdir() if f.is_file() and f.suffix.lower() in supported_ext],
        key=lambda p: p.name,
    )

    emojis = [
        {
            "id": f"{normalized}:{f.name}",
            "filename": f.name,
            "category": normalized,
            "url": f"/api/emojis/{role_id}/{normalized}/{f.name}",
        }
        for f in files
    ]
    return {"role_id": role_id, "category": normalized, "emojis": emojis}


@router.post("/roles/{role_id}/emojis/{category}/upload")
async def upload_role_emoji(role_id: str, category: str, file: UploadFile = File(...)):
    import shutil

    normalized = _normalize_category_name(category)
    emoji_dir = get_role_dir(role_id) / "emojis" / normalized
    emoji_dir.mkdir(parents=True, exist_ok=True)

    ext = _guess_ext(file.filename or "")
    filename = f"emoji_{uuid.uuid4().hex[:10]}.{ext}"
    file_path = emoji_dir / filename
    with open(file_path, "wb") as f:
        shutil.copyfileobj(file.file, f)

    return {
        "success": True,
        "role_id": role_id,
        "emoji": {
            "id": f"{normalized}:{filename}",
            "filename": filename,
            "category": normalized,
            "url": f"/api/emojis/{role_id}/{normalized}/{filename}",
        },
    }


@router.delete("/roles/{role_id}/emojis/{category}/{filename}")
async def delete_role_emoji(role_id: str, category: str, filename: str):
    normalized = _normalize_category_name(category)
    if "/" in filename or "\\" in filename or ".." in filename:
        raise HTTPException(status_code=400, detail="文件名不合法")

    file_path = get_role_dir(role_id) / "emojis" / normalized / filename
    if not file_path.exists():
        raise HTTPException(status_code=404, detail="表情不存在")
    file_path.unlink()
    return {"success": True}

@router.get("/emojis/{role_id}/{emotion}/{filename}")
async def get_emoji(role_id: str, emotion: str, filename: str):
    """获取角色表情包文件"""
    from fastapi.responses import FileResponse
    from fastapi import HTTPException
    
    emoji_path = ROLES_DIR / role_id / "emojis" / emotion / filename
    if emoji_path.exists() and emoji_path.is_file():
        print(f"Serving emoji: {emoji_path}")
        return FileResponse(emoji_path)
    raise HTTPException(status_code=404, detail="Emoji not found")

@router.get("/roles/{role_id}/emojis/{emotion}/random")
async def get_random_emoji(role_id: str, emotion: str):
    """从后端表情包文件夹中随机选择一个表情包"""
    import random
    
    emoji_dir = ROLES_DIR / role_id / "emojis" / emotion
    if not emoji_dir.exists():
        return {"found": False, "emotion": emotion}
    
    # 扫描支持的图片格式
    supported_ext = {".png", ".jpg", ".jpeg", ".gif", ".webp"}
    files = [f for f in emoji_dir.iterdir() if f.is_file() and f.suffix.lower() in supported_ext]
    
    if not files:
        return {"found": False, "emotion": emotion}
    
    chosen = random.choice(files)
    # 返回可访问的 URL 路径
    return {
        "found": True,
        "emotion": emotion,
        "filename": chosen.name,
        "url": f"/api/emojis/{role_id}/{emotion}/{chosen.name}"
    }


# ========== 用户表情（SQLite 映射） ==========

@router.get("/user-emojis/categories")
async def list_user_emoji_categories():
    with _get_user_emoji_connection() as conn:
        rows = conn.execute(
            "SELECT name FROM user_emoji_categories ORDER BY created_at ASC"
        ).fetchall()
        categories = [str(r["name"]) for r in rows]
    return {"categories": categories}


@router.post("/user-emojis/categories")
async def create_user_emoji_category(payload: EmojiCategoryPayload):
    category = _normalize_category_name(payload.category)
    with _get_user_emoji_connection() as conn:
        conn.execute(
            "INSERT OR IGNORE INTO user_emoji_categories(name, created_at) VALUES(?, ?)",
            (category, datetime.now().isoformat()),
        )
    (USER_EMOJI_DIR / category).mkdir(parents=True, exist_ok=True)
    return {"success": True, "category": category}


@router.delete("/user-emojis/categories/{category}")
async def delete_user_emoji_category(category: str):
    import shutil

    normalized = _normalize_category_name(category)
    with _get_user_emoji_connection() as conn:
        rows = conn.execute(
            "SELECT file_path FROM user_emojis WHERE category = ?",
            (normalized,),
        ).fetchall()
        for row in rows:
            path = Path(str(row["file_path"]))
            if path.exists():
                path.unlink()
        conn.execute("DELETE FROM user_emojis WHERE category = ?", (normalized,))
        conn.execute("DELETE FROM user_emoji_categories WHERE name = ?", (normalized,))

    category_dir = USER_EMOJI_DIR / normalized
    if category_dir.exists():
        shutil.rmtree(category_dir)

    return {"success": True, "category": normalized}


@router.get("/user-emojis")
async def list_user_emojis(category: Optional[str] = None):
    with _get_user_emoji_connection() as conn:
        if category:
            normalized = _normalize_category_name(category)
            rows = conn.execute(
                "SELECT id, category, tag, filename, created_at FROM user_emojis WHERE category = ? ORDER BY created_at DESC",
                (normalized,),
            ).fetchall()
        else:
            rows = conn.execute(
                "SELECT id, category, tag, filename, created_at FROM user_emojis ORDER BY created_at DESC"
            ).fetchall()

    emojis = [
        {
            "id": str(r["id"]),
            "category": str(r["category"]),
            "tag": str(r["tag"]),
            "filename": str(r["filename"]),
            "created_at": str(r["created_at"]),
            "url": f"/api/user-emojis/file/{r['id']}",
        }
        for r in rows
    ]
    return {"emojis": emojis}


@router.post("/user-emojis/upload")
async def upload_user_emoji(
    category: str = Form(...),
    tag: str = Form(...),
    file: UploadFile = File(...),
):
    import shutil

    normalized = _normalize_category_name(category)
    tag_value = str(tag or "").strip()
    if not tag_value:
        raise HTTPException(status_code=400, detail="标签不能为空")

    with _get_user_emoji_connection() as conn:
        conn.execute(
            "INSERT OR IGNORE INTO user_emoji_categories(name, created_at) VALUES(?, ?)",
            (normalized, datetime.now().isoformat()),
        )

        ext = _guess_ext(file.filename or "")
        emoji_id = f"u_{uuid.uuid4().hex[:12]}"
        filename = f"{emoji_id}.{ext}"
        category_dir = USER_EMOJI_DIR / normalized
        category_dir.mkdir(parents=True, exist_ok=True)
        file_path = category_dir / filename

        with open(file_path, "wb") as f:
            shutil.copyfileobj(file.file, f)

        conn.execute(
            "INSERT INTO user_emojis(id, category, tag, filename, file_path, created_at) VALUES(?, ?, ?, ?, ?, ?)",
            (
                emoji_id,
                normalized,
                tag_value,
                filename,
                str(file_path),
                datetime.now().isoformat(),
            ),
        )

    return {
        "success": True,
        "emoji": {
            "id": emoji_id,
            "category": normalized,
            "tag": tag_value,
            "filename": filename,
            "url": f"/api/user-emojis/file/{emoji_id}",
        },
    }


@router.get("/user-emojis/file/{emoji_id}")
async def get_user_emoji_file(emoji_id: str):
    from fastapi.responses import FileResponse

    with _get_user_emoji_connection() as conn:
        row = conn.execute(
            "SELECT file_path FROM user_emojis WHERE id = ?",
            (emoji_id,),
        ).fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="表情不存在")

    file_path = Path(str(row["file_path"]))
    if not file_path.exists():
        raise HTTPException(status_code=404, detail="表情文件不存在")
    return FileResponse(file_path)


@router.delete("/user-emojis/{emoji_id}")
async def delete_user_emoji(emoji_id: str):
    with _get_user_emoji_connection() as conn:
        row = conn.execute(
            "SELECT file_path FROM user_emojis WHERE id = ?",
            (emoji_id,),
        ).fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="表情不存在")

        file_path = Path(str(row["file_path"]))
        if file_path.exists():
            file_path.unlink()

        conn.execute("DELETE FROM user_emojis WHERE id = ?", (emoji_id,))

    return {"success": True}


@router.post("/user-emojis/resolve-tag")
async def resolve_user_emoji_tag(payload: ResolveUserEmojiTagPayload):
    with _get_user_emoji_connection() as conn:
        row = conn.execute(
            "SELECT tag, category FROM user_emojis WHERE id = ?",
            (payload.emoji_id,),
        ).fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="表情不存在")

    return {
        "found": True,
        "emoji_id": payload.emoji_id,
        "tag": str(row["tag"]),
        "category": str(row["category"]),
    }

# ========== 角色头像上传 ==========

@router.post("/roles/{role_id}/avatar")
async def upload_role_avatar(role_id: str):
    """上传角色头像"""
    from fastapi import UploadFile, File
    from fastapi.responses import JSONResponse
    import shutil
    
    role = load_role(role_id)
    if not role:
        raise HTTPException(status_code=404, detail="角色不存在")
    
    # 这个端点需要通过表单上传文件
    return JSONResponse({"error": "Use multipart form upload"}, status_code=400)

@router.post("/roles/{role_id}/avatar/upload")
async def upload_role_avatar_file(role_id: str, request: Request, file: UploadFile = File(...)):
    """上传角色头像文件"""
    from fastapi.responses import FileResponse
    import shutil
    import uuid
    
    role = load_role(role_id)
    if not role:
        raise HTTPException(status_code=404, detail="角色不存在")
    
    role_dir = get_role_dir(role_id)
    
    # 获取文件扩展名
    ext = file.filename.split(".")[-1] if "." in file.filename else "jpg"
    avatar_filename = f"avatar.{ext}"
    avatar_path = role_dir / "assets" / avatar_filename
    
    # 保存文件
    with open(avatar_path, "wb") as f:
        shutil.copyfileobj(file.file, f)
    
    # 更新角色 avatar_url
    avatar_url = str(request.url_for("get_role_avatar_file", role_id=role_id))
    role["avatar_url"] = avatar_url
    save_role(role_id, role)

    return {
        "success": True,
        "avatar_url": avatar_url,
        "avatar_hash": _get_role_avatar_hash(role_id),
    }

@router.get("/roles/{role_id}/avatar/file")
async def get_role_avatar_file(role_id: str):
    """获取角色头像文件"""
    from fastapi.responses import FileResponse
    
    avatar_path = _get_role_avatar_path(role_id)
    if avatar_path is not None:
        return FileResponse(avatar_path)
    
    raise HTTPException(status_code=404, detail="Avatar not found")

# ========== 聊天记录同步接口 ==========

class ChatMessage(BaseModel):
    """聊天消息"""
    id: str
    content: str
    sender_id: str
    timestamp: str
    type: Optional[str] = "text"
    quote_id: Optional[str] = None
    quote_content: Optional[str] = None

class ChatMessagesSync(BaseModel):
    """消息同步请求"""
    messages: List[ChatMessage]


def _load_role_chat_messages(role_id: str) -> List[Dict[str, Any]]:
    role_dir = get_role_dir(role_id)
    messages_file = role_dir / "chats" / "messages.json"
    if not messages_file.exists():
        return []
    with open(messages_file, "r", encoding="utf-8") as f:
        data = json.load(f)
        messages = data.get("messages", [])
        if isinstance(messages, list):
            return messages
        return []


def _to_absolute_backend_url(url: str, backend_base_url: Optional[str]) -> str:
    raw = str(url or "").strip()
    if not raw:
        return raw
    if not backend_base_url:
        return raw
    if raw.startswith("http://") or raw.startswith("https://"):
        parsed = urlparse(raw)
        api_path = parsed.path or ""
        # Rewrite historical/stale hosts to current backend for emoji-related endpoints.
        if api_path.startswith("/api/emojis/") or api_path.startswith("/api/user-emojis/"):
            base = backend_base_url.rstrip("/")
            tail = api_path
            if parsed.query:
                tail += f"?{parsed.query}"
            if parsed.fragment:
                tail += f"#{parsed.fragment}"
            return f"{base}{tail}"
        return raw

    base = backend_base_url.rstrip("/")
    if raw.startswith("/"):
        return f"{base}{raw}"
    if raw.startswith("api/"):
        return f"{base}/{raw}"
    return raw


def _normalize_sticker_content_for_sync(content: Any, backend_base_url: Optional[str]) -> Any:
    if not isinstance(content, str):
        return content
    if not content.endswith("]"):
        return content

    # New format:
    # [STICKER|ai|emotion|url]
    # [STICKER|user|category|tag|emojiId|url]
    if content.startswith("[STICKER|"):
        inner = content[9:-1]
        parts = inner.split("|")

        if len(parts) >= 5 and parts[0] == "user":
            category = parts[1]
            tag = parts[2]
            emoji_id = parts[3]
            # Always trust emoji id to build canonical file endpoint during sync.
            if emoji_id:
                relative_url = f"/api/user-emojis/file/{emoji_id}"
            else:
                relative_url = "|".join(parts[4:])
            final_url = _to_absolute_backend_url(relative_url, backend_base_url)
            return f"[STICKER|user|{category}|{tag}|{emoji_id}|{final_url}]"

        if len(parts) >= 4 and parts[0] == "ai":
            emotion = parts[1]
            image_url = "|".join(parts[2:])
            final_url = _to_absolute_backend_url(image_url, backend_base_url)
            return f"[STICKER|ai|{emotion}|{final_url}]"

    # Legacy format: [STICKER:emotion:path]
    if content.startswith("[STICKER:"):
        inner = content[9:-1]
        segs = inner.split(":")
        if len(segs) >= 3:
            emotion = segs[0]
            path = ":".join(segs[1:])
            final_url = _to_absolute_backend_url(path, backend_base_url)
            return f"[STICKER:{emotion}:{final_url}]"

    return content


def _normalize_chat_message_for_sync(message: Dict[str, Any], backend_base_url: Optional[str]) -> Dict[str, Any]:
    normalized = dict(message)
    normalized["content"] = _normalize_sticker_content_for_sync(
        normalized.get("content"),
        backend_base_url,
    )
    if "quote_content" in normalized:
        normalized["quote_content"] = _normalize_sticker_content_for_sync(
            normalized.get("quote_content"),
            backend_base_url,
        )
    if "quoted_preview_text" in normalized:
        normalized["quoted_preview_text"] = _normalize_sticker_content_for_sync(
            normalized.get("quoted_preview_text"),
            backend_base_url,
        )
    return normalized


def _build_chats_snapshot(backend_base_url: Optional[str] = None) -> Dict[str, Any]:
    chats: Dict[str, List[Dict[str, Any]]] = {}
    if ROLES_DIR.exists():
        for role_dir in sorted(ROLES_DIR.iterdir(), key=lambda p: p.name):
            if not role_dir.is_dir():
                continue
            role_id = role_dir.name
            messages = [
                _normalize_chat_message_for_sync(m, backend_base_url)
                for m in _load_role_chat_messages(role_id)
            ]
            messages.sort(key=lambda m: (str(m.get("timestamp", "")), str(m.get("id", ""))))
            chats[role_id] = messages

    canonical = json.dumps(chats, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
    snapshot_md5 = hashlib.md5(canonical.encode("utf-8")).hexdigest()
    total_messages = sum(len(items) for items in chats.values())

    return {
        "md5": snapshot_md5,
        "total_chats": len(chats),
        "total_messages": total_messages,
        "chats": chats,
    }

@router.get("/roles/{role_id}/chats/messages")
async def get_chat_messages(role_id: str, request: Request, limit: int = 100, offset: int = 0):
    """获取角色聊天记录"""
    role_dir = get_role_dir(role_id)
    messages_file = role_dir / "chats" / "messages.json"
    
    if messages_file.exists():
        with open(messages_file, "r", encoding="utf-8") as f:
            data = json.load(f)
            backend_base_url = str(request.base_url).rstrip("/")
            all_messages = [
                _normalize_chat_message_for_sync(m, backend_base_url)
                for m in data.get("messages", [])
                if isinstance(m, dict)
            ]
            # 分页返回
            return {
                "role_id": role_id,
                "total": len(all_messages),
                "messages": all_messages[offset:offset + limit]
            }
    return {"role_id": role_id, "total": 0, "messages": []}


@router.get("/chats/messages/snapshot")
async def get_all_chats_snapshot(request: Request, client_md5: Optional[str] = None):
    """获取所有聊天记录快照；传入 client_md5 相同则仅返回无需同步"""
    backend_base_url = str(request.base_url).rstrip("/")
    snapshot = _build_chats_snapshot(backend_base_url)
    if client_md5 and client_md5 == snapshot["md5"]:
        return {
            "need_sync": False,
            "md5": snapshot["md5"],
            "total_chats": snapshot["total_chats"],
            "total_messages": snapshot["total_messages"],
        }

    return {
        "need_sync": True,
        "md5": snapshot["md5"],
        "total_chats": snapshot["total_chats"],
        "total_messages": snapshot["total_messages"],
        "chats": snapshot["chats"],
    }

@router.post("/roles/{role_id}/chats/messages")
async def save_chat_message(role_id: str, message: ChatMessage):
    """保存单条聊天消息"""
    role_dir = get_role_dir(role_id)
    messages_file = role_dir / "chats" / "messages.json"
    
    # 读取现有消息
    if messages_file.exists():
        with open(messages_file, "r", encoding="utf-8") as f:
            data = json.load(f)
    else:
        data = {"messages": []}
    
    # 避免重复添加
    existing_ids = {m.get("id") for m in data["messages"]}
    if message.id not in existing_ids:
        data["messages"].append(message.model_dump())
    
    # 保存
    with open(messages_file, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    
    return {"success": True, "message_id": message.id}

@router.post("/roles/{role_id}/chats/sync")
async def sync_chat_messages(role_id: str, sync: ChatMessagesSync):
    """批量同步聊天消息"""
    role_dir = get_role_dir(role_id)
    messages_file = role_dir / "chats" / "messages.json"
    
    # 读取现有消息
    if messages_file.exists():
        with open(messages_file, "r", encoding="utf-8") as f:
            data = json.load(f)
    else:
        data = {"messages": []}
    
    # 合并消息（去重）
    existing_ids = {m.get("id") for m in data["messages"]}
    added = 0
    for msg in sync.messages:
        if msg.id not in existing_ids:
            data["messages"].append(msg.model_dump())
            existing_ids.add(msg.id)
            added += 1
    
    # 按时间排序
    data["messages"].sort(key=lambda m: m.get("timestamp", ""))
    
    # 保存
    with open(messages_file, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    
    return {"success": True, "added": added, "total": len(data["messages"])}

@router.delete("/roles/{role_id}/chats/messages/{message_id}")
async def delete_chat_message(role_id: str, message_id: str):
    """删除单条聊天消息"""
    role_dir = get_role_dir(role_id)
    messages_file = role_dir / "chats" / "messages.json"
    
    if not messages_file.exists():
        raise HTTPException(status_code=404, detail="消息文件不存在")
    
    with open(messages_file, "r", encoding="utf-8") as f:
        data = json.load(f)
    
    original_count = len(data.get("messages", []))
    data["messages"] = [m for m in data.get("messages", []) if m.get("id") != message_id]
    removed = original_count - len(data["messages"])
    
    with open(messages_file, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    
    return {"success": True, "removed": removed, "total": len(data["messages"])}

import asyncio
import base64
import hashlib
import json
import mimetypes
import shutil
import uuid
from datetime import datetime, timedelta
from pathlib import Path
from urllib.parse import quote, unquote, urlparse

from fastapi import WebSocket

from core.utils import (
    ensure_direct_child_path,
    ensure_path_within_root,
    ensure_simple_path_segment,
    is_tool_role_id,
    mask_api_key,
)
from routers import roles, settings
from services import settings_service


DATA_DIR = Path(__file__).parent.parent / "data"
VISION_UPLOADS_DIR = DATA_DIR / "vision"
EMOJI_TRANSFER_CHUNK_SIZE = 48 * 1024
EMOJI_TRANSFER_MAX_SIZE = 12 * 1024 * 1024
EMOJI_TRANSFER_TTL = timedelta(minutes=2)
WS_IMAGE_UPLOAD_MAX_SIZE = 12 * 1024 * 1024
VISION_UPLOAD_MAX_SIZE = 20 * 1024 * 1024
VISION_UPLOAD_MAX_CHUNK_SIZE = 128 * 1024
VISION_UPLOAD_MAX_CHUNKS = 512
_EMOJI_TRANSFERS: dict[str, dict] = {}
_ACTIVE_ASYNC_CHAT_TASKS: dict[str, asyncio.Task] = {}


def _role_emoji_ref(role_id: str, category: str, filename: str) -> str:
    return "ws-emoji://role/{}/{}/{}".format(
        quote(role_id, safe=""), quote(category, safe=""), quote(filename, safe="")
    )


def _user_emoji_ref(emoji_id: str) -> str:
    return f"ws-emoji://user/{quote(emoji_id, safe='')}"


def _cleanup_emoji_transfers() -> None:
    cutoff = datetime.now() - EMOJI_TRANSFER_TTL
    for transfer_id, transfer in list(_EMOJI_TRANSFERS.items()):
        if transfer["created_at"] < cutoff:
            _EMOJI_TRANSFERS.pop(transfer_id, None)


def _safe_segment(value: str, field_name: str) -> str:
    try:
        return ensure_simple_path_segment(value, field_name)
    except ValueError as exc:
        raise ValueError(f"invalid emoji {field_name}") from exc


def _decode_base64_limited(value: str, max_size: int, field_name: str) -> bytes:
    encoded = str(value or "").strip()
    if not encoded:
        raise ValueError(f"{field_name} missing")
    max_encoded_size = 4 * ((max_size + 2) // 3)
    if len(encoded) > max_encoded_size:
        raise ValueError(f"{field_name} exceeds size limit")
    try:
        decoded = base64.b64decode(encoded, validate=True)
    except Exception as exc:
        raise ValueError(f"invalid {field_name}") from exc
    if len(decoded) > max_size:
        raise ValueError(f"{field_name} exceeds size limit")
    return decoded


def _resolve_emoji_reference(reference: str) -> Path:
    parsed = urlparse(str(reference or ""))
    if parsed.scheme != "ws-emoji":
        raise ValueError("unsupported emoji reference")

    parts = [unquote(part) for part in parsed.path.split("/") if part]
    if parsed.netloc == "role" and len(parts) == 3:
        role_id = _safe_segment(parts[0], "role_id")
        category = _safe_segment(parts[1], "category")
        filename = _safe_segment(parts[2], "filename")
        root = roles.get_role_emojis_dir(role_id)
        category_dir = ensure_direct_child_path(root, category, "category")
        path = ensure_direct_child_path(category_dir, filename, "filename")
    elif parsed.netloc == "user" and len(parts) == 1:
        emoji_id = parts[0].strip()
        with roles._get_user_emoji_connection() as conn:
            row = conn.execute(
                "SELECT file_path FROM user_emojis WHERE id = ?", (emoji_id,)
            ).fetchone()
        if not row:
            raise ValueError("emoji not found")
        path = ensure_path_within_root(
            Path(str(row["file_path"])), roles.get_user_emoji_root()
        )
    else:
        raise ValueError("invalid emoji reference")

    if not path.exists() or not path.is_file():
        raise ValueError("emoji file not found")
    return path


async def _handle_emoji_file_init(payload: dict, backend_base_url: str) -> dict:
    path = _resolve_emoji_reference(str(payload.get("reference") or ""))
    _cleanup_emoji_transfers()
    transfer_id = uuid.uuid4().hex
    size = path.stat().st_size
    if size > EMOJI_TRANSFER_MAX_SIZE:
        raise ValueError("emoji file exceeds transfer limit")
    total_chunks = max(1, (size + EMOJI_TRANSFER_CHUNK_SIZE - 1) // EMOJI_TRANSFER_CHUNK_SIZE)
    _EMOJI_TRANSFERS[transfer_id] = {"path": path, "created_at": datetime.now()}
    return {
        "transfer_id": transfer_id,
        "total_chunks": total_chunks,
        "size": size,
        "filename": path.name,
        "mime_type": mimetypes.guess_type(path.name)[0] or "application/octet-stream",
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    }


async def _handle_emoji_file_chunk(payload: dict, backend_base_url: str) -> dict:
    _cleanup_emoji_transfers()
    transfer_id = str(payload.get("transfer_id") or "").strip()
    transfer = _EMOJI_TRANSFERS.get(transfer_id)
    if not transfer:
        raise ValueError("emoji transfer expired")
    try:
        index = int(payload.get("chunk_index"))
    except (TypeError, ValueError) as exc:
        raise ValueError("invalid chunk_index") from exc
    path = transfer["path"]
    size = path.stat().st_size
    total_chunks = max(1, (size + EMOJI_TRANSFER_CHUNK_SIZE - 1) // EMOJI_TRANSFER_CHUNK_SIZE)
    if index < 0 or index >= total_chunks:
        raise ValueError("invalid chunk_index")
    with path.open("rb") as source:
        source.seek(index * EMOJI_TRANSFER_CHUNK_SIZE)
        chunk = source.read(EMOJI_TRANSFER_CHUNK_SIZE)
    if index == total_chunks - 1:
        _EMOJI_TRANSFERS.pop(transfer_id, None)
    return {"transfer_id": transfer_id, "chunk_index": index, "chunk_base64": base64.b64encode(chunk).decode("ascii")}


def _safe_upload_id(raw: str) -> str:
    value = str(raw or "").strip()
    if not value or len(value) > 80:
        raise ValueError("invalid upload_id")
    allowed = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
    if any(ch not in allowed for ch in value):
        raise ValueError("invalid upload_id")
    return value


def _upload_dir(upload_id: str) -> Path:
    return ensure_direct_child_path(
        VISION_UPLOADS_DIR, _safe_upload_id(upload_id), "upload_id"
    )


def _list_uploaded_chunk_indices(upload_dir: Path, total_chunks: int) -> list[int]:
    uploaded: list[int] = []
    for index in range(total_chunks):
        chunk_file = upload_dir / f"chunk_{index:06d}.part"
        if chunk_file.exists():
            uploaded.append(index)
    return uploaded


def _cleanup_expired_vision_uploads(ttl_minutes: int = 120):
    if not VISION_UPLOADS_DIR.exists():
        return
    cutoff = datetime.now() - timedelta(minutes=max(10, ttl_minutes))
    for child in VISION_UPLOADS_DIR.iterdir():
        if not child.is_dir():
            continue
        try:
            child = ensure_direct_child_path(VISION_UPLOADS_DIR, child.name, "upload_id")
            mtime = datetime.fromtimestamp(child.stat().st_mtime)
            if mtime < cutoff:
                shutil.rmtree(child, ignore_errors=True)
        except Exception:
            continue


def _normalize_chunk_index(metadata: dict, raw_chunk_index: int, total_chunks: int) -> int:
    """兼容历史客户端的 0-based / 1-based chunk_index。"""
    if total_chunks <= 0:
        return -1

    index_base = metadata.get("chunk_index_base")
    if index_base in (0, 1):
        normalized = raw_chunk_index - int(index_base)
        if 0 <= normalized < total_chunks:
            return normalized

        # 兼容历史会话中索引基准记录错误/漂移：尝试自动切换基准
        alt_base = 1 - int(index_base)
        alt_normalized = raw_chunk_index - alt_base
        if 0 <= alt_normalized < total_chunks:
            metadata["chunk_index_base"] = alt_base
            return alt_normalized

    # 首次判断索引基准：优先 0-based；否则尝试 1-based
    if 0 <= raw_chunk_index < total_chunks:
        metadata["chunk_index_base"] = 0
        return raw_chunk_index

    if 1 <= raw_chunk_index <= total_chunks:
        metadata["chunk_index_base"] = 1
        return raw_chunk_index - 1

    return -1


def resolve_backend_base_url_from_websocket(websocket: WebSocket, config: dict) -> str:
    host = websocket.headers.get("x-forwarded-host") or websocket.headers.get("host") or f"{config.get('host', '127.0.0.1')}:{config.get('port', 8000)}"
    forwarded_proto = (websocket.headers.get("x-forwarded-proto") or "").split(",")[0].strip().lower()
    ws_scheme = websocket.url.scheme
    http_scheme = forwarded_proto if forwarded_proto in {"http", "https"} else ("https" if ws_scheme == "wss" else "http")
    return f"{http_scheme}://{host}".rstrip("/")


# ---------------------------------------------------------------------------
# Extracted action handlers
# ---------------------------------------------------------------------------

async def _handle_vision_upload_init(payload: dict, backend_base_url: str) -> dict:
    _cleanup_expired_vision_uploads()

    total_chunks = int(payload.get("total_chunks") or 0)
    mime_type = str(payload.get("mime_type") or "image/jpeg").strip() or "image/jpeg"
    file_size = int(payload.get("file_size") or 0)
    if total_chunks <= 0 or total_chunks > VISION_UPLOAD_MAX_CHUNKS:
        raise ValueError("invalid total_chunks")
    if file_size <= 0 or file_size > VISION_UPLOAD_MAX_SIZE:
        raise ValueError("invalid file_size")

    preferred_upload_id = str(payload.get("upload_id") or "").strip()
    upload_id = _safe_upload_id(preferred_upload_id) if preferred_upload_id else uuid.uuid4().hex
    upload_dir = _upload_dir(upload_id)
    upload_dir.mkdir(parents=True, exist_ok=True)

    meta_file = upload_dir / "meta.json"
    if meta_file.exists():
        with open(meta_file, "r", encoding="utf-8") as f:
            metadata = json.load(f)

        old_total_chunks = int(metadata.get("total_chunks") or 0)
        old_mime_type = str(metadata.get("mime_type") or "").strip()
        old_file_size = int(metadata.get("file_size") or 0)

        # 参数变化时认为是新文件，重置当前上传会话
        if (
            old_total_chunks != total_chunks
            or old_mime_type != mime_type
            or old_file_size != file_size
        ):
            shutil.rmtree(upload_dir, ignore_errors=True)
            upload_dir.mkdir(parents=True, exist_ok=True)
            metadata = {
                "upload_id": upload_id,
                "total_chunks": total_chunks,
                "mime_type": mime_type,
                "file_size": file_size,
                "created_at": datetime.now().isoformat(),
                "completed": False,
                "chunk_index_base": None,
            }
            with open(meta_file, "w", encoding="utf-8") as f:
                json.dump(metadata, f, ensure_ascii=False, indent=2)
    else:
        metadata = {
            "upload_id": upload_id,
            "total_chunks": total_chunks,
            "mime_type": mime_type,
            "file_size": file_size,
            "created_at": datetime.now().isoformat(),
            "completed": False,
            "chunk_index_base": None,
        }
        with open(meta_file, "w", encoding="utf-8") as f:
            json.dump(metadata, f, ensure_ascii=False, indent=2)

    uploaded_chunks = _list_uploaded_chunk_indices(upload_dir, total_chunks)
    completed = bool(metadata.get("completed") is True and (upload_dir / "merged.bin").exists())
    return {
        "success": True,
        "upload_id": upload_id,
        "total_chunks": total_chunks,
        "uploaded_chunks": uploaded_chunks,
        "completed": completed,
    }


async def _handle_vision_upload_chunk(payload: dict, backend_base_url: str) -> dict:
    upload_id = _safe_upload_id(str(payload.get("upload_id") or ""))
    raw_chunk_index_value = payload.get("chunk_index")
    raw_chunk_index = int(raw_chunk_index_value) if raw_chunk_index_value is not None else -1
    chunk_base64 = str(payload.get("chunk_base64") or "").strip()

    upload_dir = _upload_dir(upload_id)
    meta_file = upload_dir / "meta.json"
    if not upload_dir.exists() or not meta_file.exists():
        raise ValueError("upload not found")

    with open(meta_file, "r", encoding="utf-8") as f:
        metadata = json.load(f)
    total_chunks = int(metadata.get("total_chunks") or 0)
    chunk_index = _normalize_chunk_index(metadata, raw_chunk_index, total_chunks)
    if chunk_index < 0 or chunk_index >= total_chunks:
        raise ValueError("invalid chunk_index")
    if not chunk_base64:
        raise ValueError("chunk_base64 missing")

    chunk_bytes = _decode_base64_limited(
        chunk_base64, VISION_UPLOAD_MAX_CHUNK_SIZE, "chunk_base64"
    )

    declared_size = int(metadata.get("file_size") or 0)
    if declared_size <= 0 or declared_size > VISION_UPLOAD_MAX_SIZE:
        raise ValueError("invalid upload metadata")
    existing_size = sum(
        path.stat().st_size
        for path in upload_dir.glob("chunk_*.part")
        if path.name != f"chunk_{chunk_index:06d}.part" and path.is_file()
    )
    if existing_size + len(chunk_bytes) > declared_size:
        raise ValueError("uploaded data exceeds declared file_size")

    chunk_file = upload_dir / f"chunk_{chunk_index:06d}.part"
    with open(chunk_file, "wb") as f:
        f.write(chunk_bytes)

    # 写回可能更新后的索引基准
    with open(meta_file, "w", encoding="utf-8") as f:
        json.dump(metadata, f, ensure_ascii=False, indent=2)

    return {
        "success": True,
        "upload_id": upload_id,
        "chunk_index": chunk_index,
        "raw_chunk_index": raw_chunk_index,
        "size": len(chunk_bytes),
    }


async def _handle_vision_upload_commit(payload: dict, backend_base_url: str) -> dict:
    upload_id = _safe_upload_id(str(payload.get("upload_id") or ""))
    upload_dir = _upload_dir(upload_id)
    meta_file = upload_dir / "meta.json"
    if not upload_dir.exists() or not meta_file.exists():
        raise ValueError("upload not found")

    with open(meta_file, "r", encoding="utf-8") as f:
        metadata = json.load(f)

    total_chunks = int(metadata.get("total_chunks") or 0)
    declared_size = int(metadata.get("file_size") or 0)
    if (
        total_chunks <= 0
        or total_chunks > VISION_UPLOAD_MAX_CHUNKS
        or declared_size <= 0
        or declared_size > VISION_UPLOAD_MAX_SIZE
    ):
        raise ValueError("invalid upload metadata")

    merged_file = upload_dir / "merged.bin"
    total_size = 0
    try:
        with open(merged_file, "wb") as out:
            for index in range(total_chunks):
                chunk_file = upload_dir / f"chunk_{index:06d}.part"
                if not chunk_file.exists():
                    raise ValueError(f"missing chunk: {index}")
                chunk_size = chunk_file.stat().st_size
                if chunk_size <= 0 or chunk_size > VISION_UPLOAD_MAX_CHUNK_SIZE:
                    raise ValueError(f"invalid chunk size: {index}")
                total_size += chunk_size
                if total_size > declared_size or total_size > VISION_UPLOAD_MAX_SIZE:
                    raise ValueError("merged file exceeds size limit")
                with open(chunk_file, "rb") as source:
                    shutil.copyfileobj(source, out, length=64 * 1024)
        if total_size != declared_size:
            raise ValueError("merged size does not match declared file_size")
    except Exception:
        merged_file.unlink(missing_ok=True)
        raise

    metadata["completed"] = True
    metadata["committed_at"] = datetime.now().isoformat()
    metadata["merged_size"] = total_size
    with open(meta_file, "w", encoding="utf-8") as f:
        json.dump(metadata, f, ensure_ascii=False, indent=2)

    return {
        "success": True,
        "upload_id": upload_id,
        "size": total_size,
        "mime_type": str(metadata.get("mime_type") or "image/jpeg"),
    }


async def _handle_settings_get(payload: dict, backend_base_url: str) -> dict:
    settings_data = dict(settings_service.load_settings())
    include_secrets = payload.get("include_secrets") is True
    if not include_secrets:
        for key_name in ("ai_api_key", "intent_api_key", "vision_api_key", "embedding_api_key"):
            masked = mask_api_key(settings_data.get(key_name))
            if masked is not None:
                settings_data[f"{key_name}_masked"] = masked
                del settings_data[key_name]
    return {"settings": settings_data}


async def _handle_settings_update(payload: dict, backend_base_url: str) -> dict:
    update = settings.SettingsUpdate(**dict(payload.get("updates") or {}))
    updates = {}
    if update.ai_api_url is not None:
        updates["ai_api_url"] = update.ai_api_url
    if update.ai_api_key is not None:
        updates["ai_api_key"] = update.ai_api_key
    if update.ai_model is not None:
        updates["ai_model"] = update.ai_model
    if update.ai_api_format is not None:
        value = str(update.ai_api_format).strip().lower()
        updates["ai_api_format"] = value if value in {"auto", "gemini_native", "openai_compatible"} else "auto"
    if update.ai_timeout_seconds is not None:
        updates["ai_timeout_seconds"] = max(1, min(3600, update.ai_timeout_seconds))
    if update.ai_reasoning_effort is not None:
        updates["ai_reasoning_effort"] = str(update.ai_reasoning_effort).strip()
    if update.ai_stream is not None:
        updates["ai_stream"] = update.ai_stream
    if update.thinking_enabled is not None:
        updates["thinking_enabled"] = update.thinking_enabled
    if update.ai_thinking_budget is not None:
        updates["ai_thinking_budget"] = update.ai_thinking_budget
    if update.model_thinking_settings is not None:
        updates["model_thinking_settings"] = {
            kind: value.model_dump() for kind, value in update.model_thinking_settings.items()
        }
    if update.intent_enabled is not None:
        updates["intent_enabled"] = update.intent_enabled
    if update.intent_api_url is not None:
        updates["intent_api_url"] = update.intent_api_url
    if update.intent_api_key is not None:
        updates["intent_api_key"] = update.intent_api_key
    if update.intent_model is not None:
        updates["intent_model"] = update.intent_model
    if update.intent_api_format is not None:
        value = str(update.intent_api_format).strip().lower()
        updates["intent_api_format"] = value if value in {"auto", "gemini_native", "openai_compatible"} else "auto"
    if update.vision_enabled is not None:
        updates["vision_enabled"] = update.vision_enabled
    if update.vision_api_url is not None:
        updates["vision_api_url"] = update.vision_api_url
    if update.vision_api_key is not None:
        updates["vision_api_key"] = update.vision_api_key
    if update.vision_model is not None:
        updates["vision_model"] = update.vision_model
    if update.vision_mode is not None:
        mode = str(update.vision_mode).strip().lower()
        updates["vision_mode"] = mode if mode in {"standalone", "pre_model", "tool"} else "standalone"
    if update.vision_api_format is not None:
        value = str(update.vision_api_format).strip().lower()
        updates["vision_api_format"] = value if value in {"auto", "gemini_native", "openai_compatible"} else "auto"
    if update.embedding_enabled is not None:
        updates["embedding_enabled"] = update.embedding_enabled
    if update.embedding_api_url is not None:
        updates["embedding_api_url"] = update.embedding_api_url
    if update.embedding_api_key is not None:
        updates["embedding_api_key"] = update.embedding_api_key
    if update.embedding_model is not None:
        updates["embedding_model"] = update.embedding_model
    if update.quiet_rules is not None:
        updates["quiet_rules"] = [
            rule.model_dump(exclude_none=True) for rule in update.quiet_rules
        ]
    if update.host is not None:
        updates["host"] = update.host
    if update.port is not None:
        updates["port"] = update.port

    if not updates:
        return {"success": True, "message": "No changes"}
    if settings_service.save_settings(updates):
        if "quiet_rules" in updates:
            # 供应商级安静规则变更：立即按新规则重排主动消息调度。
            from services import scheduler_service
            scheduler_service.refresh_proactive_jobs()
        return {"success": True, "message": "Settings updated"}
    return {"success": False, "error": "Failed to save settings"}


async def _handle_settings_avatar_upload(payload: dict, backend_base_url: str) -> dict:
    filename = str(payload.get("filename") or "avatar.jpg").strip()
    content_base64 = str(payload.get("content_base64") or "").strip()
    if not content_base64:
        raise ValueError("content_base64 missing")

    ext = filename.split(".")[-1].lower() if "." in filename else "jpg"
    if ext not in {"jpg", "jpeg", "png", "gif", "webp"}:
        ext = "jpg"

    file_bytes = _decode_base64_limited(
        content_base64, WS_IMAGE_UPLOAD_MAX_SIZE, "content_base64"
    )

    settings.AVATARS_DIR.mkdir(parents=True, exist_ok=True)
    stored_name = f"user_avatar_{uuid.uuid4().hex[:8]}.{ext}"
    filepath = ensure_direct_child_path(settings.AVATARS_DIR, stored_name, "filename")
    with open(filepath, "wb") as f:
        f.write(file_bytes)

    avatar_hash = hashlib.md5(file_bytes).hexdigest()
    return {
        "success": True,
        "filename": stored_name,
        "path": f"/files/avatars/{stored_name}",
        "hash": avatar_hash,
    }


async def _handle_roles_upsert(payload: dict, backend_base_url: str) -> dict:
    role_payload = dict(payload.get("role") or {})
    role_model = roles.RoleCreate(**role_payload)
    existing = roles.load_role(role_model.id)
    previous_proactive = dict((existing or {}).get("proactive_config") or {})
    previous_archived = bool((existing or {}).get("archived", False))

    if existing:
        for key in ("ai_thinking_enabled", "ai_thinking_budget", "ai_reasoning_effort"):
            if key in role_model.model_fields_set:
                existing[key] = getattr(role_model, key)
        # Only apply fields sent by the client. RoleCreate has defaults for
        # creation, and applying those defaults during an upsert would reset
        # server-owned or older-client fields.
        for key, value in role_model.model_dump(
            exclude_unset=True,
            exclude_none=True,
        ).items():
            if key != "id" and value is not None:
                # onebot_config 合并而非覆盖，保留已有的字段
                if key in {"onebot_config", "proactive_config"} and isinstance(value, dict):
                    merged = dict(existing.get(key) or {})
                    merged.update({k: v for k, v in value.items() if v is not None})
                    if key == "proactive_config" and "quiet_periods" in value:
                        merged.pop("quiet_hours_start", None)
                        merged.pop("quiet_hours_end", None)
                    existing[key] = merged
                else:
                    existing[key] = value
        roles.save_role(role_model.id, existing)
        role_data = existing
    else:
        role_data = {
            "id": role_model.id,
            "name": role_model.name,
            "avatar_url": role_model.avatar_url or "",
            "persona": role_model.persona or "",
            "system_prompt": role_model.system_prompt or "",
            "greeting": role_model.greeting or "",
            "description": role_model.description or "",
            "core_memory": role_model.core_memory or [],
            "ai_model": role_model.ai_model or "deepseek-chat",
            "ai_api_url": role_model.ai_api_url or "",
            "ai_api_key": role_model.ai_api_key or "",
            "ai_temperature": (
                role_model.ai_temperature
                if role_model.ai_temperature is not None
                else 0.7
            ),
            "ai_timeout_seconds": role_model.ai_timeout_seconds,
            "ai_reasoning_effort": role_model.ai_reasoning_effort,
            "ai_thinking_enabled": role_model.ai_thinking_enabled,
            "ai_thinking_budget": role_model.ai_thinking_budget,
            "ai_stream": role_model.ai_stream,
            "personality": (
                role_model.personality.model_dump()
                if role_model.personality
                else {
                    "openness": 50,
                    "conscientiousness": 50,
                    "extraversion": 50,
                    "agreeableness": 50,
                    "neuroticism": 50,
                }
            ),
            "proactive_config": (
                role_model.proactive_config.model_dump(exclude_none=True)
                if role_model.proactive_config
                else {
                    "enabled": False,
                    "min_interval_minutes": 30,
                    "max_interval_minutes": 120,
                    "trigger_prompt": "",
                    "quiet_periods": [{"start_minute": 1380, "end_minute": 420}],
                    "next_trigger_time": None,
                }
            ),
            "onebot_config": (
                role_model.onebot_config.model_dump()
                if role_model.onebot_config
                else {"enabled": False, "secret": ""}
            ),
            "stats_config": (
                role_model.stats_config.model_dump()
                if role_model.stats_config
                else {"enabled": False, "stats": []}
            ),
            "show_action": (
                role_model.show_action if role_model.show_action is not None else True
            ),
            "show_sound": (
                role_model.show_sound if role_model.show_sound is not None else True
            ),
            "show_psychology": (
                role_model.show_psychology
                if role_model.show_psychology is not None
                else True
            ),
            "show_stats": (
                role_model.show_stats if role_model.show_stats is not None else True
            ),
            "show_no_reply": (
                role_model.show_no_reply
                if role_model.show_no_reply is not None
                else False
            ),
            "archived": bool(role_model.archived),
            "tags": role_model.tags or [],
            "gender": role_model.gender or "men",
            "menstruation_cycle": (
                role_model.menstruation_cycle.model_dump()
                if role_model.menstruation_cycle
                else {
                    "cycle_length": 30,
                    "period_length": 6,
                    "last_period_start": "2026-01-24",
                }
            ),
            "metadata": role_model.metadata or {},
            "max_context_rounds": (
                role_model.max_context_rounds
                if role_model.max_context_rounds is not None
                else 60
            ),
            "allow_web_search": (
                role_model.allow_web_search
                if role_model.allow_web_search is not None
                else True
            ),
            "created_at": datetime.now().isoformat(),
        }
        roles.save_role(role_model.id, role_data)

        if not is_tool_role_id(role_model.id):
            from services.memory_service import load_memory

            load_memory(role_model.id)

    current_proactive = dict(role_data.get("proactive_config") or {})
    current_archived = bool(role_data.get("archived", False))
    if (
        existing is None
        or current_proactive != previous_proactive
        or current_archived != previous_archived
    ):
        from services import scheduler_service

        scheduler_service.schedule_proactive_for_role(
            role_model.id,
            reset=True,
        )

    role_copy = dict(role_data)
    role_id = str(role_copy.get("id", "")).strip()
    if role_id and role_copy.get("avatar_url"):
        role_copy["avatar_url"] = f"{backend_base_url}/files/roles/{role_id}/avatar"
        role_copy["avatar_hash"] = roles._get_role_avatar_hash(role_id)

    return role_copy


async def _handle_roles_avatar_upload(payload: dict, backend_base_url: str) -> dict:
    role_id = str(payload.get("role_id") or "").strip()
    content_base64 = str(payload.get("content_base64") or "").strip()
    filename = str(payload.get("filename") or "avatar.jpg").strip()

    if not role_id:
        raise ValueError("role_id missing")
    if not content_base64:
        raise ValueError("content_base64 missing")

    role = roles.load_role(role_id)
    if not role:
        raise ValueError("role not found")

    ext = filename.split(".")[-1].lower() if "." in filename else "jpg"
    if ext not in {"jpg", "jpeg", "png", "gif", "webp"}:
        ext = "jpg"

    file_bytes = _decode_base64_limited(
        content_base64, WS_IMAGE_UPLOAD_MAX_SIZE, "content_base64"
    )

    assets_dir = roles.get_assets_dir(role_id)
    avatar_path = ensure_direct_child_path(assets_dir, f"avatar.{ext}", "filename")
    with open(avatar_path, "wb") as f:
        f.write(file_bytes)

    avatar_url = f"{backend_base_url}/files/roles/{role_id}/avatar"
    role["avatar_url"] = avatar_url
    roles.save_role(role_id, role)

    return {
        "success": True,
        "avatar_url": avatar_url,
        "avatar_hash": roles._get_role_avatar_hash(role_id),
    }


async def _handle_user_emoji_upload(payload: dict, backend_base_url: str) -> dict:
    category = roles._normalize_category_name(str(payload.get("category") or ""))
    tag_value = str(payload.get("tag") or "").strip()
    filename = str(payload.get("filename") or "emoji.png")
    content_base64 = str(payload.get("content_base64") or "").strip()
    if not tag_value:
        raise ValueError("标签不能为空")
    if not content_base64:
        raise ValueError("content_base64 missing")

    file_bytes = _decode_base64_limited(
        content_base64, WS_IMAGE_UPLOAD_MAX_SIZE, "content_base64"
    )

    with roles._get_user_emoji_connection() as conn:
        conn.execute(
            "INSERT OR IGNORE INTO user_emoji_categories(name, created_at) VALUES(?, ?)",
            (category, datetime.now().isoformat()),
        )

        ext = roles._guess_ext(filename)
        emoji_id = f"u_{uuid.uuid4().hex[:12]}"
        saved_filename = f"{emoji_id}.{ext}"
        category_dir = roles.get_user_emoji_category_dir(category)
        category_dir.mkdir(parents=True, exist_ok=True)
        file_path = ensure_direct_child_path(category_dir, saved_filename, "filename")

        with open(file_path, "wb") as f:
            f.write(file_bytes)

        conn.execute(
            "INSERT INTO user_emojis(id, category, tag, filename, file_path, created_at) VALUES(?, ?, ?, ?, ?, ?)",
            (
                emoji_id,
                category,
                tag_value,
                saved_filename,
                str(file_path),
                datetime.now().isoformat(),
            ),
        )

    return {
        "success": True,
        "emoji": {
            "id": emoji_id,
            "category": category,
            "tag": tag_value,
            "filename": saved_filename,
            "url": _user_emoji_ref(emoji_id),
        },
    }


async def _handle_user_emojis_list(payload: dict, backend_base_url: str) -> dict:
    category = payload.get("category")
    with roles._get_user_emoji_connection() as conn:
        if category:
            normalized = roles._normalize_category_name(str(category))
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
            "url": _user_emoji_ref(str(r["id"])),
        }
        for r in rows
    ]
    digest = hashlib.sha256(json.dumps(emojis, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest()
    if str(payload.get("client_hash") or "").strip() == digest:
        return {"emojis": [], "hash": digest, "not_modified": True}
    return {"emojis": emojis, "hash": digest, "not_modified": False}


async def _handle_user_emoji_category_delete(payload: dict, backend_base_url: str) -> dict:
    import shutil

    category = roles._normalize_category_name(str(payload.get("category") or ""))
    with roles._get_user_emoji_connection() as conn:
        rows = conn.execute(
            "SELECT file_path FROM user_emojis WHERE category = ?",
            (category,),
        ).fetchall()
        for row in rows:
            path = ensure_path_within_root(
                Path(str(row["file_path"])), roles.get_user_emoji_root()
            )
            if path.exists():
                path.unlink()
        conn.execute("DELETE FROM user_emojis WHERE category = ?", (category,))
        conn.execute("DELETE FROM user_emoji_categories WHERE name = ?", (category,))

    category_dir = roles.get_user_emoji_category_dir(category)
    if category_dir.exists():
        shutil.rmtree(category_dir)
    return {"success": True, "category": category}


async def _handle_chat_vision(payload: dict, backend_base_url: str) -> dict:
    from routers.ai_behavior import VisionRequest, chat_with_vision

    request = VisionRequest(
        image_base64=str(payload.get("image_base64") or ""),
        upload_id=(str(payload.get("upload_id")).strip() if payload.get("upload_id") is not None else None),
        mime_type=str(payload.get("mime_type") or "image/jpeg"),
        user_prompt=str(payload.get("user_prompt") or "请描述这张图片的内容"),
        system_prompt=str(payload.get("system_prompt") or ""),
        role_id=(str(payload.get("role_id")).strip() if payload.get("role_id") is not None else None),
        run_mode=(str(payload.get("run_mode")).strip() if payload.get("run_mode") is not None else None),
    )
    return await chat_with_vision(request)


async def _handle_ai_intent(payload: dict, backend_base_url: str) -> dict:
    from routers.ai_behavior import IntentDetectRequest, detect_intent

    intent_request = IntentDetectRequest(
        message=str(payload.get("message") or ""),
        api_url=(
            str(payload.get("api_url"))
            if payload.get("api_url") is not None
            else None
        ),
        api_key=(
            str(payload.get("api_key"))
            if payload.get("api_key") is not None
            else None
        ),
        model=(
            str(payload.get("model"))
            if payload.get("model") is not None
            else None
        ),
        api_format=(
            str(payload.get("api_format"))
            if payload.get("api_format") is not None
            else None
        ),
    )

    result = await detect_intent(intent_request)
    if hasattr(result, "model_dump"):
        return result.model_dump()
    return result


# ---------------------------------------------------------------------------
# Background chat task processing
# ---------------------------------------------------------------------------

async def _process_chat_background(task_id: str, event):
    """Process chat event in background, push result via server push."""
    from routers.ai_behavior import handle_ai_event as handle_ai_behavior_event
    from transport.push_hub import publish_server_push

    try:
        result = await handle_ai_behavior_event(event)
        if hasattr(result, "model_dump"):
            result_dict = result.model_dump()
        elif isinstance(result, dict):
            result_dict = result
        else:
            result_dict = {"success": False, "error": "Unexpected result type"}

        await publish_server_push("chat_response", {
            "task_id": task_id,
            "role_id": event.role_id,
            "success": result_dict.get("success", False),
            "content": result_dict.get("content"),
            "error": result_dict.get("error"),
            "metadata": result_dict.get("metadata", {}),
        })
    except Exception as exc:
        await publish_server_push("chat_response", {
            "task_id": task_id,
            "role_id": event.role_id,
            "success": False,
            "error": str(exc),
        })


def _client_task_id(client_submission_id: str) -> str | None:
    """Build a stable task ID only for client-generated safe identifiers."""
    if not client_submission_id or len(client_submission_id) > 128:
        return None
    if not all(char.isascii() and (char.isalnum() or char in "_-") for char in client_submission_id):
        return None
    return f"chat_{client_submission_id}"


def _forget_async_chat_task(task_id: str, task: asyncio.Task) -> None:
    if _ACTIVE_ASYNC_CHAT_TASKS.get(task_id) is task:
        _ACTIVE_ASYNC_CHAT_TASKS.pop(task_id, None)


# ---------------------------------------------------------------------------
# Main dispatcher
# ---------------------------------------------------------------------------

async def handle_ws_action(action: str, payload: dict, websocket: WebSocket, config: dict):
    backend_base_url = resolve_backend_base_url_from_websocket(websocket, config)

    # --- Extracted handlers ---
    if action == "emoji_file_init":
        return await _handle_emoji_file_init(payload, backend_base_url)

    if action == "emoji_file_chunk":
        return await _handle_emoji_file_chunk(payload, backend_base_url)

    if action == "vision_upload_init":
        return await _handle_vision_upload_init(payload, backend_base_url)

    if action == "vision_upload_chunk":
        return await _handle_vision_upload_chunk(payload, backend_base_url)

    if action == "vision_upload_commit":
        return await _handle_vision_upload_commit(payload, backend_base_url)

    if action == "settings_get":
        return await _handle_settings_get(payload, backend_base_url)

    if action == "settings_update":
        return await _handle_settings_update(payload, backend_base_url)

    if action == "settings_avatar_upload":
        return await _handle_settings_avatar_upload(payload, backend_base_url)

    if action == "roles_upsert":
        return await _handle_roles_upsert(payload, backend_base_url)

    if action == "roles_avatar_upload":
        return await _handle_roles_avatar_upload(payload, backend_base_url)

    if action == "user_emoji_upload":
        return await _handle_user_emoji_upload(payload, backend_base_url)

    if action == "user_emojis_list":
        return await _handle_user_emojis_list(payload, backend_base_url)

    if action == "user_emoji_category_delete":
        return await _handle_user_emoji_category_delete(payload, backend_base_url)

    if action == "chat_vision":
        return await _handle_chat_vision(payload, backend_base_url)

    if action == "ai_intent":
        return await _handle_ai_intent(payload, backend_base_url)

    if action == "recover_chat_push":
        from transport.push_hub import (
            get_missed_chat_pushes,
            get_missed_message_pushes,
        )

        task_ids = payload.get("task_ids")
        message_ids = payload.get("message_ids")
        recovered = []
        recovered_messages = []
        if isinstance(task_ids, list):
            recovered = get_missed_chat_pushes(task_ids)
        if isinstance(message_ids, list):
            recovered_messages = get_missed_message_pushes(message_ids)
        return {
            "recovered": recovered,
            "recovered_messages": recovered_messages,
        }

    # --- Inline short delegation handlers ---
    if action == "chat_snapshot":
        client_md5 = str(
            payload.get("client_md5") or payload.get("client_hash") or ""
        ).strip()
        snapshot = await roles.get_chat_snapshot(backend_base_url, client_md5=client_md5)
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

    if action == "chat_hash":
        snapshot = await roles.get_chat_snapshot(backend_base_url, hash_only=True)
        return {
            "md5": snapshot["md5"],
            "hash": snapshot["md5"],
            "total_chats": snapshot["total_chats"],
            "total_messages": snapshot["total_messages"],
        }

    if action == "save_chat_message":
        role_id = str(payload.get("role_id") or "").strip()
        message_payload = payload.get("message") or {}
        message = roles.ChatMessage(**message_payload)
        return await roles.save_chat_message(role_id, message)

    if action == "update_chat_message":
        role_id = str(payload.get("role_id") or "").strip()
        message_id = str(payload.get("message_id") or "").strip()
        update = roles.ChatMessageUpdate(
            content=payload.get("content"),
            type=payload.get("type"),
            quote_content=payload.get("quote_content"),
        )
        return await roles.update_chat_message(role_id, message_id, update)

    if action == "delete_chat_message":
        role_id = str(payload.get("role_id") or "").strip()
        message_id = str(payload.get("message_id") or "").strip()
        return await roles.delete_chat_message(role_id, message_id)

    if action == "sync_chat_messages":
        role_id = str(payload.get("role_id") or "").strip()
        sync_payload = roles.ChatMessagesSync(**{"messages": payload.get("messages") or []})
        return await roles.sync_chat_messages(role_id, sync_payload)

    if action == "ai_event":
        from routers.ai_behavior import AIEvent, AIEventType, handle_ai_event as handle_ai_behavior_event

        event_payload = payload.get("event") or {}
        event = AIEvent(**event_payload)

        # Chat events with async flag → background task mechanism.
        # A client_submission_id survives a lost queue acknowledgement, so a
        # reconnect can safely ask about the exact same task without creating
        # a second model generation.
        if event.event_type == AIEventType.CHAT and (event.context or {}).get("async"):
            context = event.context or {}
            client_submission_id = str(context.get("client_submission_id") or "")
            stable_task_id = _client_task_id(client_submission_id)
            task_id = stable_task_id or f"chat_{uuid.uuid4().hex}"

            if stable_task_id is not None:
                from transport.push_hub import get_missed_chat_pushes

                completed = get_missed_chat_pushes([task_id])
                if completed:
                    cached_payload = completed[0].get("payload") or {}
                    return {
                        "success": cached_payload.get("success", False),
                        "task_id": task_id,
                        "status": "completed",
                        "content": cached_payload.get("content"),
                        "error": cached_payload.get("error"),
                        "metadata": cached_payload.get("metadata", {}),
                    }

                active_task = _ACTIVE_ASYNC_CHAT_TASKS.get(task_id)
                if active_task is not None and not active_task.done():
                    return {"success": True, "task_id": task_id, "status": "queued"}

            background_task = asyncio.create_task(
                _process_chat_background(task_id, event)
            )
            if stable_task_id is not None:
                _ACTIVE_ASYNC_CHAT_TASKS[task_id] = background_task
                background_task.add_done_callback(
                    lambda task, task_id=task_id: _forget_async_chat_task(task_id, task)
                )
            return {"success": True, "task_id": task_id, "status": "queued"}

        # All other events / non-async chat → synchronous (unchanged)
        result = await handle_ai_behavior_event(event)
        if hasattr(result, "model_dump"):
            return result.model_dump()
        return result

    if action == "moments_list":
        from routers import moments

        limit = int(payload.get("limit") or 50)
        return await moments.list_moments(
            limit=limit,
            client_hash=str(payload.get("client_hash") or "").strip() or None,
        )

    if action == "moments_hash":
        from routers import moments

        limit = int(payload.get("limit") or 50)
        return await moments.get_moments_hash(limit=limit)

    if action == "moments_create":
        from routers import moments

        moment = moments.MomentCreate(
            author_id=str(payload.get("author_id") or ""),
            author_name=str(payload.get("author_name") or ""),
            content=str(payload.get("content") or ""),
            image_urls=list(payload.get("image_urls") or []),
        )
        return await moments.create_moment(moment)

    if action == "moments_update":
        from routers import moments

        post_id = str(payload.get("post_id") or "").strip()
        body = moments.MomentUpdate(
            content=str(payload.get("content") or ""),
            image_urls=(
                list(payload.get("image_urls"))
                if payload.get("image_urls") is not None
                else None
            ),
        )
        return await moments.update_moment(post_id, body)

    if action == "moments_delete":
        from routers import moments

        post_id = str(payload.get("post_id") or "").strip()
        return await moments.delete_moment(post_id)

    if action == "moments_like":
        from routers import moments

        post_id = str(payload.get("post_id") or "").strip()
        user_id = str(payload.get("user_id") or "").strip()
        user_name = str(payload.get("user_name") or "").strip()
        return await moments.like_moment(post_id, user_id, user_name)

    if action == "moments_unlike":
        from routers import moments

        post_id = str(payload.get("post_id") or "").strip()
        user_id = str(payload.get("user_id") or "").strip()
        return await moments.unlike_moment(post_id, user_id)

    if action == "moments_comment":
        from routers import moments

        post_id = str(payload.get("post_id") or "").strip()
        comment = moments.CommentCreate(
            author_id=str(payload.get("author_id") or ""),
            author_name=str(payload.get("author_name") or ""),
            content=str(payload.get("content") or ""),
            reply_to_id=(
                str(payload.get("reply_to_id"))
                if payload.get("reply_to_id") is not None
                else None
            ),
            reply_to_name=(
                str(payload.get("reply_to_name"))
                if payload.get("reply_to_name") is not None
                else None
            ),
        )
        return await moments.add_comment(post_id, comment)

    if action == "tasks_list":
        from routers import tasks

        return await tasks.list_tasks(
            client_hash=str(payload.get("client_hash") or "").strip() or None
        )

    if action == "tasks_hash":
        from routers import tasks

        current = tasks.load_tasks()
        return {
            "hash": tasks.compute_tasks_hash(current),
            "count": len(current),
        }

    if action == "tasks_list_by_role":
        from routers import tasks

        role_id = str(payload.get("role_id") or "").strip()
        return await tasks.get_role_tasks(role_id)

    if action == "tasks_create":
        from routers import tasks

        task = tasks.TaskCreate(
            chat_id=str(payload.get("chat_id") or ""),
            role_id=str(payload.get("role_id") or ""),
            message=str(payload.get("message") or ""),
            ai_prompt=(
                str(payload.get("ai_prompt"))
                if payload.get("ai_prompt") is not None
                else ""
            ),
            trigger_time=str(payload.get("trigger_time") or ""),
            repeat=(
                str(payload.get("repeat"))
                if payload.get("repeat") is not None
                else None
            ),
        )
        return await tasks.create_task(task)

    if action == "tasks_toggle":
        from routers import tasks

        task_id = str(payload.get("task_id") or "").strip()
        return await tasks.toggle_task(task_id)

    if action == "tasks_delete":
        from routers import tasks

        task_id = str(payload.get("task_id") or "").strip()
        return await tasks.delete_task(task_id)

    if action == "roles_list":
        role_items = roles.build_role_items(backend_base_url)
        current_hash = roles.compute_roles_hash(role_items)
        client_hash = str(payload.get("client_hash") or "").strip()
        if client_hash and client_hash == current_hash:
            return {"roles": [], "hash": current_hash, "not_modified": True, "count": len(role_items)}
        return {"roles": role_items, "hash": current_hash, "not_modified": False}

    if action == "roles_hash":
        role_items = roles.build_role_items(backend_base_url)
        return {"hash": roles.compute_roles_hash(role_items)}

    if action == "roles_delete":
        import shutil

        role_id = _safe_segment(str(payload.get("role_id") or ""), "role_id")
        role_dir = ensure_direct_child_path(roles.ROLES_DIR, role_id, "role_id")
        if role_dir.exists():
            shutil.rmtree(role_dir)
        return {"success": True}

    if action == "roles_clone":
        source_id = str(payload.get("role_id") or payload.get("source_id") or "").strip()
        if not source_id:
            raise ValueError("role_id missing")

        new_id = str(payload.get("new_id") or "").strip() or None
        new_name = payload.get("new_name")
        new_name = str(new_name).strip() if new_name is not None else None

        data = roles.clone_role(source_id, new_id=new_id, new_name=new_name)

        role_copy = dict(data)
        new_role_id = str(role_copy.get("id", "")).strip()
        if new_role_id and role_copy.get("avatar_url"):
            role_copy["avatar_url"] = f"{backend_base_url}/files/roles/{new_role_id}/avatar"
            role_copy["avatar_hash"] = roles._get_role_avatar_hash(new_role_id)
        return {"role": role_copy}

    if action == "roles_memory_update":
        role_id = str(payload.get("role_id") or "").strip()
        if not role_id:
            raise ValueError("role_id missing")

        update = roles.MemoryUpdate(
            core_memory=payload.get("core_memory"),
            short_term=(
                list(payload.get("short_term") or [])
                if payload.get("short_term") is not None
                else None
            ),
        )
        return await roles.update_memory(role_id, update)

    if action == "roles_memory_get":
        role_id = str(payload.get("role_id") or "").strip()
        if not role_id:
            raise ValueError("role_id missing")
        since_id_raw = payload.get("since_id")
        since_id = int(since_id_raw) if since_id_raw is not None else None
        return await roles.get_memory(role_id, since_id=since_id)

    if action == "usage_stats_get":
        role_id = str(payload.get("role_id") or "").strip()
        if not role_id:
            raise ValueError("role_id missing")
        from services.memory_service import get_usage_stats
        return get_usage_stats(role_id)

    if action == "usage_stats_reset":
        role_id = str(payload.get("role_id") or "").strip()
        if not role_id:
            raise ValueError("role_id missing")
        from services.memory_service import reset_usage_stats
        return {"success": reset_usage_stats(role_id)}

    if action == "short_term_update":
        role_id = str(payload.get("role_id") or "").strip()
        if not role_id:
            raise ValueError("role_id missing")
        entry_id = payload.get("entry_id")
        if entry_id is None:
            raise ValueError("entry_id missing")
        from services.memory_service import update_short_term_entry
        message = str(payload.get("message") or "")
        success = update_short_term_entry(role_id, int(entry_id), message)
        return {"success": success}

    if action == "short_term_delete":
        role_id = str(payload.get("role_id") or "").strip()
        if not role_id:
            raise ValueError("role_id missing")
        entry_id = payload.get("entry_id")
        if entry_id is None:
            raise ValueError("entry_id missing")
        from services.memory_service import delete_short_term_entry
        success = delete_short_term_entry(role_id, int(entry_id))
        return {"success": success}

    if action == "short_term_clear":
        role_id = str(payload.get("role_id") or "").strip()
        if not role_id:
            raise ValueError("role_id missing")
        from services.memory_service import clear_short_term
        clear_short_term(role_id)
        return {"success": True}

    if action == "vector_memory_clear":
        role_id = str(payload.get("role_id") or "").strip()
        if not role_id:
            raise ValueError("role_id missing")
        from services.memory_service import clear_vector_memory
        clear_vector_memory(role_id)
        return {"success": True, "vector_memory_count": 0}

    if action == "vector_memory_list":
        role_id = str(payload.get("role_id") or "").strip()
        if not role_id:
            raise ValueError("role_id missing")
        from services.memory_service import list_vector_memories
        limit = int(payload.get("limit") or 500)
        offset = int(payload.get("offset") or 0)
        items = list_vector_memories(role_id, limit=limit, offset=offset)
        return {"items": items, "count": len(items)}

    if action == "vector_memory_delete":
        role_id = str(payload.get("role_id") or "").strip()
        if not role_id:
            raise ValueError("role_id missing")
        memory_id = payload.get("memory_id")
        if memory_id is None:
            raise ValueError("memory_id missing")
        from services.memory_service import delete_vector_memory, _get_vector_memory_count
        success = delete_vector_memory(role_id, int(memory_id))
        return {"success": success, "vector_memory_count": _get_vector_memory_count(role_id)}

    if action == "vector_memory_update":
        role_id = str(payload.get("role_id") or "").strip()
        if not role_id:
            raise ValueError("role_id missing")
        memory_id = payload.get("memory_id")
        if memory_id is None:
            raise ValueError("memory_id missing")
        new_text = str(payload.get("new_text") or "")
        from services.memory_service import update_vector_memory
        return await update_vector_memory(role_id, int(memory_id), new_text)

    if action == "health":
        return {"status": "healthy", "timestamp": datetime.now().isoformat()}

    if action == "emoji_random":
        import random

        role_id = _safe_segment(str(payload.get("role_id") or ""), "role_id")
        emotion = _safe_segment(
            str(payload.get("emotion") or "").strip().lower(), "emotion"
        )
        # 云端表情分类不参与随机抽取（仅按精确文件名投递）
        if emotion == "__cloud__":
            return {"found": False, "emotion": emotion}

        emoji_root = roles.get_role_emojis_dir(role_id)
        emoji_dir = ensure_direct_child_path(emoji_root, emotion, "emotion")
        if not emoji_dir.exists():
            return {"found": False, "emotion": emotion}

        supported_ext = {".png", ".jpg", ".jpeg", ".gif", ".webp"}
        files = [f for f in emoji_dir.iterdir() if f.is_file() and f.suffix.lower() in supported_ext]
        if not files:
            return {"found": False, "emotion": emotion}

        chosen = random.choice(files)
        return {
            "found": True,
            "emotion": emotion,
            "filename": chosen.name,
            "url": _role_emoji_ref(role_id, emotion, chosen.name),
        }

    if action == "role_emoji_categories_list":
        role_id = str(payload.get("role_id") or "").strip()
        emojis_dir = roles.get_role_emojis_dir(role_id)
        categories = sorted([
            d.name for d in emojis_dir.iterdir()
            if d.is_dir() and d.name != "__cloud__"
        ]) if emojis_dir.exists() else []
        digest = hashlib.sha256(json.dumps(categories, ensure_ascii=False, separators=(",", ":")).encode("utf-8")).hexdigest()
        if str(payload.get("client_hash") or "").strip() == digest:
            return {"role_id": role_id, "categories": [], "hash": digest, "not_modified": True}
        return {"role_id": role_id, "categories": categories, "hash": digest, "not_modified": False}

    if action == "role_emoji_category_create":
        role_id = str(payload.get("role_id") or "").strip()
        category = roles._normalize_category_name(str(payload.get("category") or ""))
        category_dir = roles.get_role_emoji_category_dir(role_id, category)
        category_dir.mkdir(parents=True, exist_ok=True)
        return {"success": True, "role_id": role_id, "category": category}

    if action == "role_emoji_category_delete":
        import shutil

        role_id = str(payload.get("role_id") or "").strip()
        category = roles._normalize_category_name(str(payload.get("category") or ""))
        category_dir = roles.get_role_emoji_category_dir(role_id, category)
        if not category_dir.exists():
            raise ValueError("分类不存在")
        shutil.rmtree(category_dir)
        return {"success": True, "role_id": role_id, "category": category}

    if action == "role_emojis_list":
        role_id = str(payload.get("role_id") or "").strip()
        category = roles._normalize_category_name(str(payload.get("category") or ""))
        # 云端表情分类不在表情管理 UI 中列举
        if category == "__cloud__":
            return {"role_id": role_id, "category": category, "emojis": [], "hash": hashlib.sha256(b"[]").hexdigest()}
        emoji_dir = roles.get_role_emoji_category_dir(role_id, category)
        if not emoji_dir.exists():
            return {"role_id": role_id, "category": category, "emojis": [], "hash": hashlib.sha256(b"[]").hexdigest()}

        supported_ext = {".png", ".jpg", ".jpeg", ".gif", ".webp"}
        files = sorted(
            [f for f in emoji_dir.iterdir() if f.is_file() and f.suffix.lower() in supported_ext],
            key=lambda p: p.name,
        )
        emojis = [
            {
                "id": f"{category}:{f.name}",
                "filename": f.name,
                "category": category,
                "url": _role_emoji_ref(role_id, category, f.name),
            }
            for f in files
        ]
        digest = hashlib.sha256(json.dumps(emojis, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest()
        if str(payload.get("client_hash") or "").strip() == digest:
            return {"role_id": role_id, "category": category, "emojis": [], "hash": digest, "not_modified": True}
        return {"role_id": role_id, "category": category, "emojis": emojis, "hash": digest, "not_modified": False}

    if action == "role_emoji_upload":
        role_id = str(payload.get("role_id") or "").strip()
        category = roles._normalize_category_name(str(payload.get("category") or ""))
        filename = str(payload.get("filename") or "emoji.png")
        content_base64 = str(payload.get("content_base64") or "").strip()
        if not content_base64:
            raise ValueError("content_base64 missing")

        file_bytes = _decode_base64_limited(
            content_base64, WS_IMAGE_UPLOAD_MAX_SIZE, "content_base64"
        )

        emoji_dir = roles.get_role_emoji_category_dir(role_id, category)
        emoji_dir.mkdir(parents=True, exist_ok=True)
        ext = roles._guess_ext(filename)
        saved_filename = f"emoji_{uuid.uuid4().hex[:10]}.{ext}"
        file_path = ensure_direct_child_path(emoji_dir, saved_filename, "filename")
        with open(file_path, "wb") as f:
            f.write(file_bytes)

        return {
            "success": True,
            "role_id": role_id,
            "emoji": {
                "id": f"{category}:{saved_filename}",
                "filename": saved_filename,
                "category": category,
                "url": _role_emoji_ref(role_id, category, saved_filename),
            },
        }

    if action == "role_emoji_delete":
        role_id = str(payload.get("role_id") or "").strip()
        category = roles._normalize_category_name(str(payload.get("category") or ""))
        filename = str(payload.get("filename") or "").strip()
        if "/" in filename or "\\" in filename or ".." in filename:
            raise ValueError("文件名不合法")
        emoji_dir = roles.get_role_emoji_category_dir(role_id, category)
        file_path = ensure_direct_child_path(emoji_dir, filename, "filename")
        if not file_path.exists():
            raise ValueError("表情不存在")
        file_path.unlink()
        return {"success": True}

    if action == "user_emoji_categories_list":
        with roles._get_user_emoji_connection() as conn:
            rows = conn.execute(
                "SELECT name FROM user_emoji_categories ORDER BY created_at ASC"
            ).fetchall()
        categories = [str(r["name"]) for r in rows]
        digest = hashlib.sha256(json.dumps(categories, ensure_ascii=False, separators=(",", ":")).encode("utf-8")).hexdigest()
        if str(payload.get("client_hash") or "").strip() == digest:
            return {"categories": [], "hash": digest, "not_modified": True}
        return {"categories": categories, "hash": digest, "not_modified": False}

    if action == "user_emoji_category_create":
        category = roles._normalize_category_name(str(payload.get("category") or ""))
        with roles._get_user_emoji_connection() as conn:
            conn.execute(
                "INSERT OR IGNORE INTO user_emoji_categories(name, created_at) VALUES(?, ?)",
                (category, datetime.now().isoformat()),
            )
        roles.get_user_emoji_category_dir(category).mkdir(parents=True, exist_ok=True)
        return {"success": True, "category": category}

    if action == "user_emoji_delete":
        emoji_id = str(payload.get("emoji_id") or "").strip()
        with roles._get_user_emoji_connection() as conn:
            row = conn.execute(
                "SELECT file_path FROM user_emojis WHERE id = ?",
                (emoji_id,),
            ).fetchone()
            if not row:
                raise ValueError("表情不存在")

            file_path = ensure_path_within_root(
                Path(str(row["file_path"])), roles.get_user_emoji_root()
            )
            if file_path.exists():
                file_path.unlink()

            conn.execute("DELETE FROM user_emojis WHERE id = ?", (emoji_id,))
        return {"success": True}

    if action == "user_emoji_resolve_tag":
        emoji_id = str(payload.get("emoji_id") or "").strip()
        with roles._get_user_emoji_connection() as conn:
            row = conn.execute(
                "SELECT tag, category FROM user_emojis WHERE id = ?",
                (emoji_id,),
            ).fetchone()
        if not row:
            raise ValueError("表情不存在")
        return {
            "found": True,
            "emoji_id": emoji_id,
            "tag": str(row["tag"]),
            "category": str(row["category"]),
        }

    raise ValueError(f"unsupported websocket action: {action}")

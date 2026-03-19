import base64
import hashlib
import json
import shutil
import uuid
from datetime import datetime, timedelta
from pathlib import Path

from fastapi import WebSocket

from routers import roles, settings
from services import settings_service


DATA_DIR = Path(__file__).parent.parent / "data"
VISION_UPLOADS_DIR = DATA_DIR / "vision"


def _safe_upload_id(raw: str) -> str:
    value = str(raw or "").strip()
    if not value or len(value) > 80:
        raise ValueError("invalid upload_id")
    allowed = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
    if any(ch not in allowed for ch in value):
        raise ValueError("invalid upload_id")
    return value


def _upload_dir(upload_id: str) -> Path:
    return VISION_UPLOADS_DIR / _safe_upload_id(upload_id)


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
    host = websocket.headers.get("host") or f"{config.get('host', '127.0.0.1')}:{config.get('port', 8000)}"
    ws_scheme = websocket.url.scheme
    http_scheme = "https" if ws_scheme == "wss" else "http"
    return f"{http_scheme}://{host}".rstrip("/")


async def handle_ws_action(action: str, payload: dict, websocket: WebSocket, config: dict):
    backend_base_url = resolve_backend_base_url_from_websocket(websocket, config)

    if action == "vision_upload_init":
        _cleanup_expired_vision_uploads()

        total_chunks = int(payload.get("total_chunks") or 0)
        mime_type = str(payload.get("mime_type") or "image/jpeg").strip() or "image/jpeg"
        file_size = int(payload.get("file_size") or 0)
        if total_chunks <= 0:
            raise ValueError("total_chunks must be > 0")

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

    if action == "vision_upload_chunk":
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

        try:
            chunk_bytes = base64.b64decode(chunk_base64, validate=True)
        except Exception as exc:
            raise ValueError("invalid chunk base64") from exc

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

    if action == "vision_upload_commit":
        upload_id = _safe_upload_id(str(payload.get("upload_id") or ""))
        upload_dir = _upload_dir(upload_id)
        meta_file = upload_dir / "meta.json"
        if not upload_dir.exists() or not meta_file.exists():
            raise ValueError("upload not found")

        with open(meta_file, "r", encoding="utf-8") as f:
            metadata = json.load(f)

        total_chunks = int(metadata.get("total_chunks") or 0)
        if total_chunks <= 0:
            raise ValueError("invalid upload metadata")

        merged_file = upload_dir / "merged.bin"
        total_size = 0
        with open(merged_file, "wb") as out:
            for index in range(total_chunks):
                chunk_file = upload_dir / f"chunk_{index:06d}.part"
                if not chunk_file.exists():
                    raise ValueError(f"missing chunk: {index}")
                data = chunk_file.read_bytes()
                total_size += len(data)
                out.write(data)

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

    if action == "chat_snapshot":
        client_md5 = str(payload.get("client_md5") or "").strip()
        snapshot = roles._build_chats_snapshot(backend_base_url)
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
        from routers.ai_behavior import AIEvent, handle_ai_event as handle_ai_behavior_event

        event_payload = payload.get("event") or {}
        event = AIEvent(**event_payload)
        result = await handle_ai_behavior_event(event)
        if hasattr(result, "model_dump"):
            return result.model_dump()
        return result

    if action == "moments_list":
        from routers import moments

        limit = int(payload.get("limit") or 50)
        return await moments.list_moments(limit=limit)

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

        return await tasks.list_tasks()

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
        role_items = []
        if roles.ROLES_DIR.exists():
            for role_dir in roles.ROLES_DIR.iterdir():
                if not role_dir.is_dir():
                    continue

                role = roles.load_role(role_dir.name)
                if not role:
                    continue

                role_copy = dict(role)
                role_id = str(role_copy.get("id", "")).strip()
                if role_id and role_copy.get("avatar_url"):
                    role_copy["avatar_url"] = f"{backend_base_url}/files/roles/{role_id}/avatar"
                    role_copy["avatar_hash"] = roles._get_role_avatar_hash(role_id)

                role_items.append(role_copy)

        return {"roles": role_items}

    if action == "roles_upsert":
        role_payload = dict(payload.get("role") or {})
        role_model = roles.RoleCreate(**role_payload)
        existing = roles.load_role(role_model.id)

        if existing:
            for key, value in role_model.model_dump(exclude_none=True).items():
                if key != "id" and value is not None:
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
                    role_model.proactive_config.model_dump()
                    if role_model.proactive_config
                    else {
                        "enabled": False,
                        "min_interval_minutes": 30,
                        "max_interval_minutes": 120,
                        "trigger_prompt": "",
                        "quiet_hours_start": 23,
                        "quiet_hours_end": 7,
                        "next_trigger_time": None,
                    }
                ),
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
                "created_at": datetime.now().isoformat(),
            }
            roles.save_role(role_model.id, role_data)

            if not roles._is_tool_role_id(role_model.id):
                from services.memory_service import load_memory

                load_memory(role_model.id)

        role_copy = dict(role_data)
        role_id = str(role_copy.get("id", "")).strip()
        if role_id and role_copy.get("avatar_url"):
            role_copy["avatar_url"] = f"{backend_base_url}/files/roles/{role_id}/avatar"
            role_copy["avatar_hash"] = roles._get_role_avatar_hash(role_id)

        return role_copy

    if action == "roles_delete":
        import shutil

        role_id = str(payload.get("role_id") or "").strip()
        if not role_id:
            raise ValueError("role_id missing")

        role_dir = roles.ROLES_DIR / role_id
        if role_dir.exists():
            shutil.rmtree(role_dir)
        return {"success": True}

    if action == "roles_memory_update":
        role_id = str(payload.get("role_id") or "").strip()
        if not role_id:
            raise ValueError("role_id missing")

        update = roles.MemoryUpdate(
            core_memory=(
                str(payload.get("core_memory"))
                if payload.get("core_memory") is not None
                else None
            ),
            short_term=(
                list(payload.get("short_term") or [])
                if payload.get("short_term") is not None
                else None
            ),
        )
        return await roles.update_memory(role_id, update)

    if action == "roles_avatar_upload":
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

        try:
            file_bytes = base64.b64decode(content_base64, validate=True)
        except Exception as exc:
            raise ValueError("invalid base64 content") from exc

        role_dir = roles.get_role_dir(role_id)
        avatar_path = role_dir / "assets" / f"avatar.{ext}"
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

    if action == "health":
        return {"status": "healthy", "timestamp": datetime.now().isoformat()}

    if action == "settings_get":
        settings_data = settings_service.load_settings()
        include_secrets = payload.get("include_secrets") is True
        if not include_secrets:
            if settings_data.get("ai_api_key"):
                key = settings_data["ai_api_key"]
                settings_data["ai_api_key_masked"] = f"{key[:8]}...{key[-4:]}" if len(key) > 12 else "***"
                del settings_data["ai_api_key"]
            if settings_data.get("intent_api_key"):
                key = settings_data["intent_api_key"]
                settings_data["intent_api_key_masked"] = f"{key[:8]}...{key[-4:]}" if len(key) > 12 else "***"
                del settings_data["intent_api_key"]
            if settings_data.get("vision_api_key"):
                key = settings_data["vision_api_key"]
                settings_data["vision_api_key_masked"] = f"{key[:8]}...{key[-4:]}" if len(key) > 12 else "***"
                del settings_data["vision_api_key"]
        return {"settings": settings_data}

    if action == "settings_update":
        update = settings.SettingsUpdate(**dict(payload.get("updates") or {}))
        updates = {}
        if update.ai_api_url is not None:
            updates["ai_api_url"] = update.ai_api_url
        if update.ai_api_key is not None:
            updates["ai_api_key"] = update.ai_api_key
        if update.ai_model is not None:
            updates["ai_model"] = update.ai_model
        if update.intent_enabled is not None:
            updates["intent_enabled"] = update.intent_enabled
        if update.intent_api_url is not None:
            updates["intent_api_url"] = update.intent_api_url
        if update.intent_api_key is not None:
            updates["intent_api_key"] = update.intent_api_key
        if update.intent_model is not None:
            updates["intent_model"] = update.intent_model
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
            updates["vision_mode"] = mode if mode in {"standalone", "pre_model"} else "standalone"
        if update.host is not None:
            updates["host"] = update.host
        if update.port is not None:
            updates["port"] = update.port

        if not updates:
            return {"success": True, "message": "No changes"}
        if settings_service.save_settings(updates):
            return {"success": True, "message": "Settings updated"}
        return {"success": False, "error": "Failed to save settings"}

    if action == "settings_avatar_upload":
        filename = str(payload.get("filename") or "avatar.jpg").strip()
        content_base64 = str(payload.get("content_base64") or "").strip()
        if not content_base64:
            raise ValueError("content_base64 missing")

        ext = filename.split(".")[-1].lower() if "." in filename else "jpg"
        if ext not in {"jpg", "jpeg", "png", "gif", "webp"}:
            ext = "jpg"

        try:
            file_bytes = base64.b64decode(content_base64, validate=True)
        except Exception as exc:
            raise ValueError("invalid base64 content") from exc

        settings.AVATARS_DIR.mkdir(parents=True, exist_ok=True)
        stored_name = f"user_avatar_{uuid.uuid4().hex[:8]}.{ext}"
        filepath = settings.AVATARS_DIR / stored_name
        with open(filepath, "wb") as f:
            f.write(file_bytes)

        avatar_hash = hashlib.md5(file_bytes).hexdigest()
        return {
            "success": True,
            "filename": stored_name,
            "path": f"/files/avatars/{stored_name}",
            "hash": avatar_hash,
        }

    if action == "chat_vision":
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

    if action == "emoji_random":
        import random

        role_id = str(payload.get("role_id") or "").strip()
        emotion = str(payload.get("emotion") or "").strip().lower()
        if not role_id or not emotion:
            raise ValueError("role_id or emotion missing")

        emoji_dir = roles.ROLES_DIR / role_id / "emojis" / emotion
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
            "url": f"{backend_base_url}/files/emojis/{role_id}/{emotion}/{chosen.name}",
        }

    if action == "role_emoji_categories_list":
        role_id = str(payload.get("role_id") or "").strip()
        emojis_dir = roles.get_role_dir(role_id) / "emojis"
        categories = sorted([d.name for d in emojis_dir.iterdir() if d.is_dir()]) if emojis_dir.exists() else []
        return {"role_id": role_id, "categories": categories}

    if action == "role_emoji_category_create":
        role_id = str(payload.get("role_id") or "").strip()
        category = roles._normalize_category_name(str(payload.get("category") or ""))
        category_dir = roles.get_role_dir(role_id) / "emojis" / category
        category_dir.mkdir(parents=True, exist_ok=True)
        return {"success": True, "role_id": role_id, "category": category}

    if action == "role_emoji_category_delete":
        import shutil

        role_id = str(payload.get("role_id") or "").strip()
        category = roles._normalize_category_name(str(payload.get("category") or ""))
        category_dir = roles.get_role_dir(role_id) / "emojis" / category
        if not category_dir.exists():
            raise ValueError("分类不存在")
        shutil.rmtree(category_dir)
        return {"success": True, "role_id": role_id, "category": category}

    if action == "role_emojis_list":
        role_id = str(payload.get("role_id") or "").strip()
        category = roles._normalize_category_name(str(payload.get("category") or ""))
        emoji_dir = roles.get_role_dir(role_id) / "emojis" / category
        if not emoji_dir.exists():
            return {"role_id": role_id, "category": category, "emojis": []}

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
                "url": f"{backend_base_url}/files/emojis/{role_id}/{category}/{f.name}",
            }
            for f in files
        ]
        return {"role_id": role_id, "category": category, "emojis": emojis}

    if action == "role_emoji_upload":
        role_id = str(payload.get("role_id") or "").strip()
        category = roles._normalize_category_name(str(payload.get("category") or ""))
        filename = str(payload.get("filename") or "emoji.png")
        content_base64 = str(payload.get("content_base64") or "").strip()
        if not content_base64:
            raise ValueError("content_base64 missing")

        try:
            file_bytes = base64.b64decode(content_base64, validate=True)
        except Exception as exc:
            raise ValueError("invalid base64 content") from exc

        emoji_dir = roles.get_role_dir(role_id) / "emojis" / category
        emoji_dir.mkdir(parents=True, exist_ok=True)
        ext = roles._guess_ext(filename)
        saved_filename = f"emoji_{uuid.uuid4().hex[:10]}.{ext}"
        file_path = emoji_dir / saved_filename
        with open(file_path, "wb") as f:
            f.write(file_bytes)

        return {
            "success": True,
            "role_id": role_id,
            "emoji": {
                "id": f"{category}:{saved_filename}",
                "filename": saved_filename,
                "category": category,
                "url": f"{backend_base_url}/files/emojis/{role_id}/{category}/{saved_filename}",
            },
        }

    if action == "role_emoji_delete":
        role_id = str(payload.get("role_id") or "").strip()
        category = roles._normalize_category_name(str(payload.get("category") or ""))
        filename = str(payload.get("filename") or "").strip()
        if "/" in filename or "\\" in filename or ".." in filename:
            raise ValueError("文件名不合法")
        file_path = roles.get_role_dir(role_id) / "emojis" / category / filename
        if not file_path.exists():
            raise ValueError("表情不存在")
        file_path.unlink()
        return {"success": True}

    if action == "user_emoji_categories_list":
        with roles._get_user_emoji_connection() as conn:
            rows = conn.execute(
                "SELECT name FROM user_emoji_categories ORDER BY created_at ASC"
            ).fetchall()
        return {"categories": [str(r["name"]) for r in rows]}

    if action == "user_emoji_category_create":
        category = roles._normalize_category_name(str(payload.get("category") or ""))
        with roles._get_user_emoji_connection() as conn:
            conn.execute(
                "INSERT OR IGNORE INTO user_emoji_categories(name, created_at) VALUES(?, ?)",
                (category, datetime.now().isoformat()),
            )
        (roles.USER_EMOJI_DIR / category).mkdir(parents=True, exist_ok=True)
        return {"success": True, "category": category}

    if action == "user_emoji_category_delete":
        import shutil

        category = roles._normalize_category_name(str(payload.get("category") or ""))
        with roles._get_user_emoji_connection() as conn:
            rows = conn.execute(
                "SELECT file_path FROM user_emojis WHERE category = ?",
                (category,),
            ).fetchall()
            for row in rows:
                path = Path(str(row["file_path"]))
                if path.exists():
                    path.unlink()
            conn.execute("DELETE FROM user_emojis WHERE category = ?", (category,))
            conn.execute("DELETE FROM user_emoji_categories WHERE name = ?", (category,))

        category_dir = roles.USER_EMOJI_DIR / category
        if category_dir.exists():
            shutil.rmtree(category_dir)
        return {"success": True, "category": category}

    if action == "user_emojis_list":
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
                "url": f"{backend_base_url}/files/user-emojis/{r['id']}",
            }
            for r in rows
        ]
        return {"emojis": emojis}

    if action == "user_emoji_upload":
        category = roles._normalize_category_name(str(payload.get("category") or ""))
        tag_value = str(payload.get("tag") or "").strip()
        filename = str(payload.get("filename") or "emoji.png")
        content_base64 = str(payload.get("content_base64") or "").strip()
        if not tag_value:
            raise ValueError("标签不能为空")
        if not content_base64:
            raise ValueError("content_base64 missing")

        try:
            file_bytes = base64.b64decode(content_base64, validate=True)
        except Exception as exc:
            raise ValueError("invalid base64 content") from exc

        with roles._get_user_emoji_connection() as conn:
            conn.execute(
                "INSERT OR IGNORE INTO user_emoji_categories(name, created_at) VALUES(?, ?)",
                (category, datetime.now().isoformat()),
            )

            ext = roles._guess_ext(filename)
            emoji_id = f"u_{uuid.uuid4().hex[:12]}"
            saved_filename = f"{emoji_id}.{ext}"
            category_dir = roles.USER_EMOJI_DIR / category
            category_dir.mkdir(parents=True, exist_ok=True)
            file_path = category_dir / saved_filename

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
                "url": f"{backend_base_url}/files/user-emojis/{emoji_id}",
            },
        }

    if action == "user_emoji_delete":
        emoji_id = str(payload.get("emoji_id") or "").strip()
        with roles._get_user_emoji_connection() as conn:
            row = conn.execute(
                "SELECT file_path FROM user_emojis WHERE id = ?",
                (emoji_id,),
            ).fetchone()
            if not row:
                raise ValueError("表情不存在")

            file_path = Path(str(row["file_path"]))
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

    if action == "ai_intent":
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
        )

        result = await detect_intent(intent_request)
        if hasattr(result, "model_dump"):
            return result.model_dump()
        return result

    raise ValueError(f"unsupported websocket action: {action}")

"""
ZeroChat Server - 后端服务入口
双击运行即可启动 HTTP 服务
"""
import os
import sys
import json
import logging
from pathlib import Path
from datetime import datetime
from contextlib import asynccontextmanager

import uvicorn
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

# 确定根目录
if getattr(sys, 'frozen', False):
    ROOT_DIR = Path(sys.executable).parent
else:
    ROOT_DIR = Path(__file__).parent

# 创建必要目录
CONFIG_DIR = ROOT_DIR / "config"
DATA_DIR = ROOT_DIR / "data"
RUNTIME_DIR = ROOT_DIR / "runtime"

for d in [CONFIG_DIR, DATA_DIR, RUNTIME_DIR, 
          DATA_DIR / "roles"]:
    d.mkdir(parents=True, exist_ok=True)

# 配置日志
LOG_FILE = RUNTIME_DIR / f"server_{datetime.now().strftime('%Y%m%d')}.log"
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.StreamHandler(),
        logging.FileHandler(LOG_FILE, encoding="utf-8")
    ]
)
logger = logging.getLogger(__name__)

# 加载配置
def load_config():
    config_file = CONFIG_DIR / "settings.json"
    default_config = {
        "host": "0.0.0.0",
        "port": 8000,
        "ai_api_url": "",
        "ai_api_key": "",
        "ai_model": "gpt-3.5-turbo",
        "auth_token": "ZEROCHAT_FIXED_TOKEN_2026",
        "encryption_secret": "ZEROCHAT_TRANSFER_SECRET_2026"
    }
    if config_file.exists():
        with open(config_file, "r", encoding="utf-8") as f:
            return {**default_config, **json.load(f)}
    else:
        with open(config_file, "w", encoding="utf-8") as f:
            json.dump(default_config, f, indent=2, ensure_ascii=False)
        return default_config

CONFIG = load_config()

# 导入路由
from routers import chat, roles, moments, tasks, settings
from routers import ai_behavior
from services import scheduler_service
from services.security_service import (
    DEFAULT_AUTH_TOKEN,
    DEFAULT_ENCRYPTION_SECRET,
    decrypt_payload,
    encrypt_payload,
)

# AI 事件回调
async def handle_ai_event(event_data: dict):
    """处理调度器触发的 AI 事件"""
    from routers.ai_behavior import AIEvent, handle_ai_event as process_event
    from routers.ai_behavior import load_role
    from routers.moments import (
        MomentCreate,
        CommentCreate,
        create_moment,
        add_comment,
    )
    from routers.roles import ChatMessage, save_chat_message as save_role_chat_message

    event = AIEvent(**event_data)
    result = await process_event(event)

    # 将调度器产生的朋友圈行为真正落库
    try:
        if not result.success:
            return result

        event_type = event.event_type.value
        action = (result.action or "").strip().lower()
        content = (result.content or "").strip()

        if not content:
            return result

        role = load_role(event.role_id) or {}
        role_name = (
            (result.metadata or {}).get("role_name")
            or role.get("name")
            or "AI"
        )

        # 发朋友圈
        if event_type == "moment":
            if action == "post":
                await create_moment(
                    MomentCreate(
                        author_id=event.role_id,
                        author_name=str(role_name),
                        content=content,
                        image_urls=[],
                    )
                )

        # 朋友圈评论
        elif event_type == "comment":
            if action == "comment":
                ctx = event.context or {}
                post_id = str(ctx.get("post_id") or "").strip()
                if post_id:
                    await add_comment(
                        post_id,
                        CommentCreate(
                            author_id=event.role_id,
                            author_name=str(role_name),
                            content=content,
                            reply_to_id=ctx.get("reply_to_id"),
                            reply_to_name=ctx.get("reply_to_name"),
                        ),
                    )

        # 定时任务：写入角色聊天记录，供前端消息同步获取
        elif event_type == "task":
            ctx = event.context or {}
            chat_id = str(ctx.get("chat_id") or event.role_id).strip()
            if chat_id:
                task_message = str(ctx.get("task_message") or "").strip()
                final_content = content if content else (task_message or "提醒你该处理一件事啦")
                await save_role_chat_message(
                    chat_id,
                    ChatMessage(
                        id=f"{datetime.now().timestamp()}_task_{ctx.get('task_id', 'unknown')}",
                        content=final_content,
                        sender_id=event.role_id,
                        timestamp=datetime.now().isoformat(),
                        type="text",
                    ),
                )
    except Exception as e:
        logger.warning(f"处理调度器 AI 事件落库失败: {e}")

    return result

@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("=" * 50)
    logger.info("ZeroChat Server 启动中...")
    logger.info(f"数据目录: {DATA_DIR}")
    logger.info(f"配置目录: {CONFIG_DIR}")
    logger.info(f"运行时目录: {RUNTIME_DIR}")
    
    # 角色目录（不创建默认角色，留空即可）
    (DATA_DIR / "roles").mkdir(parents=True, exist_ok=True)
    
    # 启动调度器
    scheduler_service.set_event_callback(handle_ai_event)
    scheduler_service.start_scheduler()
    logger.info("调度器已启动")
    
    logger.info("=" * 50)
    yield
    
    # 停止调度器
    scheduler_service.stop_scheduler()
    logger.info("ZeroChat Server 已关闭")

# 创建应用
app = FastAPI(
    title="ZeroChat Server",
    description="ZeroChat 后端服务",
    version="1.0.0",
    lifespan=lifespan
)

# CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:8000","http://127.0.0.1:8000","https://sakura.evian.asia"],
    allow_origin_regex=r"^http://((10\.81)|(192\.168))\.\d{1,3}\.\d{1,3}(:\d+)?$",
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# 请求日志中间件
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request


class SecurityMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        path = request.url.path
        if not path.startswith("/api"):
            return await call_next(request)

        # Let CORS preflight pass before auth/decrypt checks.
        if request.method.upper() == "OPTIONS":
            return await call_next(request)

        auth_token = CONFIG.get("auth_token") or DEFAULT_AUTH_TOKEN
        encryption_secret = CONFIG.get("encryption_secret") or DEFAULT_ENCRYPTION_SECRET

        incoming_token = request.headers.get("X-Auth-Token", "")
        if incoming_token != auth_token:
            return JSONResponse(status_code=401, content={"detail": "Unauthorized"})

        content_type = request.headers.get("content-type", "")
        if "application/json" in content_type:
            raw_body = await request.body()
            if raw_body:
                try:
                    payload_obj = json.loads(raw_body.decode("utf-8"))
                    encrypted = payload_obj.get("payload") if isinstance(payload_obj, dict) else None
                    if encrypted is None:
                        return JSONResponse(status_code=400, content={"detail": "Encrypted payload required"})
                    decrypted = decrypt_payload(encrypted, encryption_secret)
                    request._body = json.dumps(decrypted, ensure_ascii=False).encode("utf-8")
                except Exception as e:
                    logger.warning(f"请求解密失败: {e}")
                    return JSONResponse(status_code=400, content={"detail": "Invalid encrypted payload"})

        response = await call_next(request)

        response_content_type = response.headers.get("content-type", "")
        if "application/json" not in response_content_type or response.status_code == 204:
            return response

        response_body = b""
        async for chunk in response.body_iterator:
            response_body += chunk

        if not response_body:
            return response

        try:
            plain_obj = json.loads(response_body.decode("utf-8"))
            encrypted_obj = encrypt_payload(plain_obj, encryption_secret)
            headers = {
                key: value
                for key, value in response.headers.items()
                if key.lower() not in {"content-length", "content-type"}
            }
            return JSONResponse(
                status_code=response.status_code,
                content={"payload": encrypted_obj},
                headers=headers,
            )
        except Exception as e:
            logger.warning(f"响应加密失败，返回原始响应: {e}")
            return JSONResponse(
                status_code=500,
                content={"detail": "Response encryption failed"},
            )

class RequestLoggingMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        logger.info(f"→ {request.method} {request.url.path}")
        response = await call_next(request)
        logger.info(f"← {request.method} {request.url.path} [{response.status_code}]")
        return response

app.add_middleware(RequestLoggingMiddleware)
app.add_middleware(SecurityMiddleware)

# 注册路由
app.include_router(chat.router, prefix="/api", tags=["Chat"])
app.include_router(roles.router, prefix="/api", tags=["Roles"])
app.include_router(moments.router, prefix="/api", tags=["Moments"])
app.include_router(tasks.router, prefix="/api", tags=["Tasks"])
app.include_router(ai_behavior.router, prefix="/api", tags=["AI Behavior"])
app.include_router(settings.router, prefix="/api", tags=["Settings"])

@app.get("/")
async def root():
    return {"status": "ok", "message": "ZeroChat Server Running"}

@app.get("/api/health")
async def health():
    return {"status": "healthy", "timestamp": datetime.now().isoformat()}

@app.get("/api/scheduler/status")
async def scheduler_status():
    """获取调度器状态"""
    return scheduler_service.get_scheduler_status()


def _resolve_backend_base_url_from_websocket(websocket: WebSocket) -> str:
    host = websocket.headers.get("host") or f"{CONFIG.get('host', '127.0.0.1')}:{CONFIG.get('port', 8000)}"
    ws_scheme = websocket.url.scheme
    http_scheme = "https" if ws_scheme == "wss" else "http"
    return f"{http_scheme}://{host}".rstrip("/")


async def _handle_ws_action(action: str, payload: dict, websocket: WebSocket):
    backend_base_url = _resolve_backend_base_url_from_websocket(websocket)

    if action == "chat_snapshot":
        from routers import roles

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
        from routers import roles

        role_id = str(payload.get("role_id") or "").strip()
        message_payload = payload.get("message") or {}
        message = roles.ChatMessage(**message_payload)
        return await roles.save_chat_message(role_id, message)

    if action == "update_chat_message":
        from routers import roles

        role_id = str(payload.get("role_id") or "").strip()
        message_id = str(payload.get("message_id") or "").strip()
        update = roles.ChatMessageUpdate(
            content=payload.get("content"),
            type=payload.get("type"),
            quote_content=payload.get("quote_content"),
        )
        return await roles.update_chat_message(role_id, message_id, update)

    if action == "delete_chat_message":
        from routers import roles

        role_id = str(payload.get("role_id") or "").strip()
        message_id = str(payload.get("message_id") or "").strip()
        return await roles.delete_chat_message(role_id, message_id)

    if action == "sync_chat_messages":
        from routers import roles

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

    raise ValueError(f"unsupported websocket action: {action}")


@app.websocket("/ws/secure")
async def secure_websocket_endpoint(websocket: WebSocket):
    await websocket.accept()

    auth_token = CONFIG.get("auth_token") or DEFAULT_AUTH_TOKEN
    encryption_secret = CONFIG.get("encryption_secret") or DEFAULT_ENCRYPTION_SECRET

    token_from_header = websocket.headers.get("X-Auth-Token", "")
    incoming_token = token_from_header
    if incoming_token != auth_token:
        await websocket.close(code=1008, reason="Unauthorized")
        return

    try:
        while True:
            raw = await websocket.receive_text()
            request_id = ""
            try:
                message_obj = json.loads(raw)
                if not isinstance(message_obj, dict):
                    raise ValueError("invalid websocket frame")

                request_id = str(message_obj.get("request_id") or "")
                event = str(message_obj.get("event") or "")

                if event == "heartbeat":
                    await websocket.send_json(
                        {
                            "event": "heartbeat_ack",
                            "timestamp": datetime.now().isoformat(),
                        }
                    )
                    continue

                action = str(message_obj.get("action") or "").strip()
                encrypted_payload = message_obj.get("payload")
                if not action or encrypted_payload is None:
                    raise ValueError("action or payload missing")

                payload = decrypt_payload(encrypted_payload, encryption_secret)
                if not isinstance(payload, dict):
                    raise ValueError("invalid decrypted payload")

                result = await _handle_ws_action(action, payload, websocket)
                if result is None:
                    result = {}
                if not isinstance(result, dict):
                    result = {"result": result}

                encrypted_result = encrypt_payload(result, encryption_secret)
                await websocket.send_json(
                    {
                        "request_id": request_id,
                        "ok": True,
                        "data": encrypted_result,
                    }
                )
            except Exception as e:
                logger.warning(f"WebSocket request error: {e}")
                encrypted_error = encrypt_payload(
                    {
                        "error": "request_failed",
                    },
                    encryption_secret,
                )
                await websocket.send_json(
                    {
                        "request_id": request_id,
                        "ok": False,
                        "data": encrypted_error,
                    }
                )
    except WebSocketDisconnect:
        logger.info("Secure WebSocket disconnected")
    except Exception as e:
        logger.warning(f"Secure WebSocket runtime error: {e}")

if __name__ == "__main__":
    print("\n" + "=" * 50)
    print("  ZeroChat Server")
    print("  按 Ctrl+C 停止服务")
    print("=" * 50 + "\n")
    
    uvicorn.run(
        "main:app",
        host=CONFIG["host"],
        port=CONFIG["port"],
        reload=False,
        log_level="info"
    )

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
from fastapi import FastAPI
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

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
        "ai_model": "gpt-3.5-turbo"
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

# AI 事件回调
async def handle_ai_event(event_data: dict):
    """处理调度器触发的 AI 事件"""
    from routers.ai_behavior import AIEvent, handle_ai_event as process_event
    event = AIEvent(**event_data)
    return await process_event(event)

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
    allow_origins=["http://localhost:8000","http://127.0.0.1:8000"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# 请求日志中间件
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request

class RequestLoggingMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        logger.info(f"→ {request.method} {request.url.path}")
        response = await call_next(request)
        logger.info(f"← {request.method} {request.url.path} [{response.status_code}]")
        return response

app.add_middleware(RequestLoggingMiddleware)

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

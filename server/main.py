"""
ZeroChat Server - 后端服务入口
双击运行即可启动 HTTP 服务
"""
import json
import logging
import sys
from datetime import datetime
from pathlib import Path

import uvicorn
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

# 确定根目录
if getattr(sys, "frozen", False):
    ROOT_DIR = Path(sys.executable).parent
else:
    ROOT_DIR = Path(__file__).parent

if str(ROOT_DIR) not in sys.path:
    sys.path.insert(0, str(ROOT_DIR))

# 创建必要目录
CONFIG_DIR = ROOT_DIR / "config"
DATA_DIR = ROOT_DIR / "data"
RUNTIME_DIR = ROOT_DIR / "runtime"

for directory in [CONFIG_DIR, DATA_DIR, RUNTIME_DIR, DATA_DIR / "roles"]:
    directory.mkdir(parents=True, exist_ok=True)

# 配置日志
LOG_FILE = RUNTIME_DIR / f"server_{datetime.now().strftime('%Y%m%d')}.log"
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.StreamHandler(),
        logging.FileHandler(LOG_FILE, encoding="utf-8"),
    ],
)
logger = logging.getLogger(__name__)


def load_config():
    config_file = CONFIG_DIR / "settings.json"
    default_config = {
        "host": "0.0.0.0",
        "port": 8000,
        "ai_api_url": "",
        "ai_api_key": "",
        "ai_model": "gpt-3.5-turbo",
        "auth_token": "ZEROCHAT_FIXED_TOKEN_2026",
        "encryption_secret": "ZEROCHAT_TRANSFER_SECRET_2026",
    }
    if config_file.exists():
        with open(config_file, "r", encoding="utf-8") as f:
            return {**default_config, **json.load(f)}

    with open(config_file, "w", encoding="utf-8") as f:
        json.dump(default_config, f, indent=2, ensure_ascii=False)
    return default_config


CONFIG = load_config()

from core.lifecycle import create_lifespan
from core.middleware import RequestLoggingMiddleware, SecurityMiddleware
from routers import ai_behavior, chat, moments, roles, settings, tasks
from services import scheduler_service
from transport.file_routes import create_files_router
from transport.ws_endpoint import create_secure_websocket_endpoint


app = FastAPI(
    title="ZeroChat Server",
    description="ZeroChat 后端服务",
    version="1.1.0",
    lifespan=create_lifespan(
        data_dir=DATA_DIR,
        config_dir=CONFIG_DIR,
        runtime_dir=RUNTIME_DIR,
        logger=logger,
    ),
)

app.add_middleware(RequestLoggingMiddleware, logger=logger)
app.add_middleware(SecurityMiddleware, config=CONFIG, logger=logger)
app.add_middleware(
    CORSMiddleware,
    allow_origins=[
        "https://sakura.evian.asia",
    ],
    allow_origin_regex=(
        r"^https?://(localhost|127\.0\.0\.1)(:\d+)?$"
        r"|^https?://((10\.81)|(192\.168))\.\d{1,3}\.\d{1,3}(:\d+)?$"
    ),
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# 注册业务路由
app.include_router(chat.router, prefix="/api", tags=["Chat"])
app.include_router(roles.router, prefix="/api", tags=["Roles"])
app.include_router(moments.router, prefix="/api", tags=["Moments"])
app.include_router(tasks.router, prefix="/api", tags=["Tasks"])
app.include_router(ai_behavior.router, prefix="/api", tags=["AI Behavior"])
app.include_router(settings.router, prefix="/api", tags=["Settings"])

# 注册文件路由
app.include_router(create_files_router(CONFIG))


@app.get("/")
async def root():
    return {"status": "ok", "message": "ZeroChat Server Running"}


@app.get("/api/health")
async def health():
    return {"status": "healthy", "timestamp": datetime.now().isoformat()}


@app.get("/api/scheduler/status")
async def scheduler_status():
    return scheduler_service.get_scheduler_status()


app.websocket("/ws/secure")(create_secure_websocket_endpoint(CONFIG, logger))


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
        log_level="info",
    )

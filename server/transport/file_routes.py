import hmac
import hashlib
from pathlib import Path

from fastapi import APIRouter
from fastapi.responses import FileResponse, JSONResponse
from starlette.requests import Request

from routers import roles, settings
from core.utils import (
    ensure_direct_child_path,
    ensure_path_within_root,
    ensure_simple_path_segment,
)
from services.security_service import get_auth_token


def create_files_router(config: dict) -> APIRouter:
    router = APIRouter()
    auth_token = get_auth_token(config)

    def _unauthorized_response():
        return JSONResponse(status_code=401, content={"detail": "Unauthorized"})

    def _is_authorized(request: Request) -> bool:
        # 恒定时间比较，防止计时侧信道
        return hmac.compare_digest(request.headers.get("X-Auth-Token", ""), auth_token)

    def _normalize_segment(value: str, field_name: str) -> str:
        try:
            return ensure_simple_path_segment(value, field_name)
        except ValueError:
            return ""

    def _safe_path(root: Path, *parts: str) -> Path | None:
        try:
            current = root.resolve()
            for index, part in enumerate(parts):
                current = ensure_direct_child_path(current, part, f"segment_{index}")
            return current
        except ValueError:
            return None

    def _cache_control(public: bool) -> str:
        if public:
            return "public, max-age=86400, must-revalidate"
        return "private, max-age=0, must-revalidate"

    def _file_response(path: Path, *, public: bool = False, etag: str | None = None):
        """Serve content with a content-derived validator and cache policy."""
        if etag is None:
            etag = f'"{hashlib.sha256(path.read_bytes()).hexdigest()}"'
        return FileResponse(
            path,
            headers={
                "ETag": etag,
                "Cache-Control": _cache_control(public),
            },
        )

    def _conditional_file_response(request: Request, path: Path):
        etag = f'"{hashlib.sha256(path.read_bytes()).hexdigest()}"'
        if request.headers.get("if-none-match") == etag:
            from starlette.responses import Response

            return Response(
                status_code=304,
                headers={
                    "ETag": etag,
                    "Cache-Control": _cache_control(False),
                },
            )
        return _file_response(path, etag=etag)

    @router.get("/files/roles/{role_id}/avatar")
    async def file_role_avatar(role_id: str, request: Request):
        if not _is_authorized(request):
            return _unauthorized_response()

        avatar_path = roles._get_role_avatar_path(role_id)
        if avatar_path is not None:
            return _conditional_file_response(request, avatar_path)
        return JSONResponse(status_code=404, content={"detail": "Avatar not found"})

    @router.get("/files/emojis/{role_id}/{emotion}/{filename}")
    async def file_role_emoji(role_id: str, emotion: str, filename: str, request: Request):
        if not _is_authorized(request):
            return _unauthorized_response()

        role_dir = roles.get_role_dir(role_id)
        emoji_path = _safe_path(role_dir, "emojis", emotion, filename)
        if emoji_path is None:
            return JSONResponse(status_code=404, content={"detail": "Emoji not found"})
        if emoji_path.exists() and emoji_path.is_file():
            return _conditional_file_response(request, emoji_path)
        return JSONResponse(status_code=404, content={"detail": "Emoji not found"})

    @router.get("/files/user-emojis/{emoji_id}")
    async def file_user_emoji(emoji_id: str, request: Request):
        if not _is_authorized(request):
            return _unauthorized_response()

        with roles._get_user_emoji_connection() as conn:
            row = conn.execute(
                "SELECT file_path FROM user_emojis WHERE id = ?",
                (emoji_id,),
            ).fetchone()
        if not row:
            return JSONResponse(status_code=404, content={"detail": "表情不存在"})

        try:
            file_path = ensure_path_within_root(
                Path(str(row["file_path"])), roles.get_user_emoji_root()
            )
        except ValueError:
            return JSONResponse(status_code=404, content={"detail": "表情文件不存在"})
        if not file_path.exists():
            return JSONResponse(status_code=404, content={"detail": "表情文件不存在"})
        return _conditional_file_response(request, file_path)

    @router.get("/files/avatars/{filename}")
    async def file_user_avatar(filename: str, request: Request):
        if not _is_authorized(request):
            return _unauthorized_response()

        safe_name = _normalize_segment(filename, "filename")
        if not safe_name:
            return JSONResponse(status_code=404, content={"detail": "not found"})
        filepath = ensure_direct_child_path(settings.AVATARS_DIR, safe_name, "filename")
        if filepath.exists():
            return _conditional_file_response(request, filepath)
        return JSONResponse(status_code=404, content={"detail": "not found"})

    @router.get("/files/public/emojis/{role_id}/{emotion}/{filename}")
    async def file_public_emoji(role_id: str, emotion: str, filename: str):
        """公开表情文件端点（无需认证），供 OneBot/NapCat 通过 HTTP 下载表情图片"""
        role_dir = roles.get_role_dir(role_id)
        emoji_path = _safe_path(role_dir, "emojis", emotion, filename)
        if emoji_path is None:
            return JSONResponse(status_code=404, content={"detail": "Emoji not found"})
        if emoji_path.exists() and emoji_path.is_file():
            return _file_response(emoji_path, public=True)
        return JSONResponse(status_code=404, content={"detail": "Emoji not found"})

    return router

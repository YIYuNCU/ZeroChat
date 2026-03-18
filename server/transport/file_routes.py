from pathlib import Path

from fastapi import APIRouter
from fastapi.responses import FileResponse, JSONResponse
from starlette.requests import Request

from routers import roles, settings
from services.security_service import DEFAULT_AUTH_TOKEN


def create_files_router(config: dict) -> APIRouter:
    router = APIRouter()

    def _unauthorized_response():
        return JSONResponse(status_code=401, content={"detail": "Unauthorized"})

    def _is_authorized(request: Request) -> bool:
        auth_token = config.get("auth_token") or DEFAULT_AUTH_TOKEN
        return request.headers.get("X-Auth-Token", "") == auth_token

    @router.get("/files/roles/{role_id}/avatar")
    async def file_role_avatar(role_id: str, request: Request):
        if not _is_authorized(request):
            return _unauthorized_response()

        avatar_path = roles._get_role_avatar_path(role_id)
        if avatar_path is not None:
            return FileResponse(avatar_path)
        return JSONResponse(status_code=404, content={"detail": "Avatar not found"})

    @router.get("/files/emojis/{role_id}/{emotion}/{filename}")
    async def file_role_emoji(role_id: str, emotion: str, filename: str, request: Request):
        if not _is_authorized(request):
            return _unauthorized_response()

        emoji_path = roles.ROLES_DIR / role_id / "emojis" / emotion / filename
        if emoji_path.exists() and emoji_path.is_file():
            return FileResponse(emoji_path)
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

        file_path = Path(str(row["file_path"]))
        if not file_path.exists():
            return JSONResponse(status_code=404, content={"detail": "表情文件不存在"})
        return FileResponse(file_path)

    @router.get("/files/avatars/{filename}")
    async def file_user_avatar(filename: str, request: Request):
        if not _is_authorized(request):
            return _unauthorized_response()

        filepath = settings.AVATARS_DIR / filename
        if filepath.exists():
            return FileResponse(filepath)
        return JSONResponse(status_code=404, content={"detail": "not found"})

    return router

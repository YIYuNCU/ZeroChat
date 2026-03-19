import json

from fastapi.responses import JSONResponse
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request

from services.security_service import (
    DEFAULT_AUTH_TOKEN,
    DEFAULT_ENCRYPTION_SECRET,
    decrypt_payload,
    encrypt_payload,
)


class SecurityMiddleware(BaseHTTPMiddleware):
    def __init__(self, app, config: dict, logger):
        super().__init__(app)
        self.config = config
        self.logger = logger

    async def dispatch(self, request: Request, call_next):
        path = request.url.path
        if not path.startswith("/api"):
            return await call_next(request)

        if request.method.upper() == "OPTIONS":
            return await call_next(request)

        auth_token = self.config.get("auth_token") or DEFAULT_AUTH_TOKEN
        encryption_secret = self.config.get("encryption_secret") or DEFAULT_ENCRYPTION_SECRET

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
                    self.logger.warning(f"请求解密失败: {e}")
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
            self.logger.warning(f"响应加密失败，返回原始响应: {e}")
            return JSONResponse(
                status_code=500,
                content={"detail": "Response encryption failed"},
            )


class RequestLoggingMiddleware(BaseHTTPMiddleware):
    def __init__(self, app, logger):
        super().__init__(app)
        self.logger = logger

    async def dispatch(self, request: Request, call_next):
        self.logger.info(f"→ {request.method} {request.url.path}")
        response = await call_next(request)
        self.logger.info(f"← {request.method} {request.url.path} [{response.status_code}]")
        return response

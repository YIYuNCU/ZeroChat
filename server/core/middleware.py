import hmac
import json

from fastapi.responses import JSONResponse
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request

from services.security_service import (
    decrypt_payload,
    encrypt_payload,
    get_auth_token,
    get_encryption_secret,
)


# 请求体大小上限（字节），防止超大 payload 消耗内存
_MAX_BODY_BYTES = 10 * 1024 * 1024


class SecurityMiddleware(BaseHTTPMiddleware):
    def __init__(self, app, config: dict, logger):
        super().__init__(app)
        self.config = config
        self.logger = logger
        self.auth_token = get_auth_token(config)
        self.encryption_secret = get_encryption_secret(config)

    async def dispatch(self, request: Request, call_next):
        path = request.url.path
        if not path.startswith("/api"):
            return await call_next(request)

        if request.method.upper() == "OPTIONS":
            return await call_next(request)

        # OneBot 路径使用独立鉴权，跳过加密/解密
        if path.startswith("/api/onebot/"):
            return await call_next(request)

        # 恒定时间比较 token，防止计时侧信道
        incoming_token = request.headers.get("X-Auth-Token", "")
        if not hmac.compare_digest(incoming_token, self.auth_token):
            return JSONResponse(status_code=401, content={"detail": "Unauthorized"})

        # 请求体大小上限
        content_length = request.headers.get("content-length")
        if content_length is not None:
            try:
                if int(content_length) > _MAX_BODY_BYTES:
                    return JSONResponse(status_code=413, content={"detail": "Payload Too Large"})
            except ValueError:
                pass

        content_type = request.headers.get("content-type", "")
        if "application/json" in content_type:
            raw_body = await request.body()
            if len(raw_body) > _MAX_BODY_BYTES:
                return JSONResponse(status_code=413, content={"detail": "Payload Too Large"})
            if raw_body:
                try:
                    payload_obj = json.loads(raw_body.decode("utf-8"))
                    encrypted = payload_obj.get("payload") if isinstance(payload_obj, dict) else None
                    if encrypted is None:
                        return JSONResponse(status_code=400, content={"detail": "Encrypted payload required"})
                    decrypted = decrypt_payload(encrypted, self.encryption_secret)
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
            encrypted_obj = encrypt_payload(plain_obj, self.encryption_secret)
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


# 合法路径前缀白名单：仅这些路径会进入业务处理，其余（扫描器探测 robots.txt /
# sitemap.xml / .env / wp-admin 等）一律 404，且日志降到 debug 避免刷屏。
_ALLOWED_EXACT_PATHS = {"/", "/favicon.ico"}
_ALLOWED_PATH_PREFIXES = ("/api", "/ws", "/onebot", "/files")


class PathWhitelistMiddleware(BaseHTTPMiddleware):
    """
    路径白名单防护：拦截对未定义路径的扫描探测。

    应注册为最外层中间件，使非法路径在进入日志/鉴权等后续处理前即被拒绝，
    从而不产生 INFO 级访问日志、不消耗后续资源。
    """

    def __init__(self, app, logger):
        super().__init__(app)
        self.logger = logger

    @staticmethod
    def _is_allowed(path: str) -> bool:
        if path in _ALLOWED_EXACT_PATHS:
            return True
        for prefix in _ALLOWED_PATH_PREFIXES:
            # 精确匹配前缀本身，或前缀后接 "/"，避免 /apixyz 之类误放行
            if path == prefix or path.startswith(prefix + "/"):
                return True
        return False

    async def dispatch(self, request: Request, call_next):
        path = request.url.path
        if not self._is_allowed(path):
            # 探测请求降噪到 debug，伪装成资源不存在
            self.logger.debug(
                f"路径白名单拦截: {request.method} {path} from "
                f"{request.headers.get('x-forwarded-for') or (request.client.host if request.client else '?')}"
            )
            return JSONResponse(status_code=404, content={"detail": "Not Found"})
        return await call_next(request)

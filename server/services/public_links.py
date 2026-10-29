"""无需鉴权的文件下载链接：限次数、限时间。

OneBot/NapCat 发表情时要通过 HTTP 下载图片，但它带不了 ``X-Auth-Token``。
每次发送生成一个随机令牌，令牌只对指定文件有效，最多访问 ``max_accesses`` 次，
超过次数或有效期后失效。状态只保存在内存里，重启后旧链接全部失效（链接本就是即发即用）。
"""
from __future__ import annotations

import secrets
import threading
import time
from dataclasses import dataclass
from typing import Callable, Dict, Optional, Tuple

DEFAULT_MAX_ACCESSES = 5
DEFAULT_TTL_SECONDS = 600
#: 同时有效的链接上限，避免内存无限增长；超出时丢弃最早签发的。
MAX_ACTIVE_LINKS = 2048

Scope = Tuple[str, ...]


@dataclass
class _Link:
    scope: Scope
    remaining: int
    expires_at: float
    issued_at: float


class PublicLinkStore:
    def __init__(
        self,
        max_accesses: int = DEFAULT_MAX_ACCESSES,
        ttl_seconds: float = DEFAULT_TTL_SECONDS,
        clock: Callable[[], float] = time.time,
    ) -> None:
        self.max_accesses = max_accesses
        self.ttl_seconds = ttl_seconds
        self._clock = clock
        self._links: Dict[str, _Link] = {}
        self._lock = threading.Lock()

    def configure(self, max_accesses: object = None, ttl_seconds: object = None) -> None:
        """应用配置；非法或小于 1 的值回退到默认值。"""
        self.max_accesses = _positive_int(max_accesses, DEFAULT_MAX_ACCESSES)
        self.ttl_seconds = _positive_int(ttl_seconds, DEFAULT_TTL_SECONDS)

    def issue(self, *scope: str) -> str:
        """为 ``scope``（如 role_id、分类、文件名）签发一个新令牌。"""
        now = self._clock()
        token = secrets.token_urlsafe(18)
        with self._lock:
            self._prune(now)
            self._links[token] = _Link(
                scope=tuple(scope),
                remaining=self.max_accesses,
                expires_at=now + self.ttl_seconds,
                issued_at=now,
            )
        return token

    def consume(self, token: Optional[str], *scope: str) -> bool:
        """校验令牌并消耗一次访问；令牌无效、范围不符、过期或次数用尽返回 False。"""
        if not token:
            return False
        now = self._clock()
        with self._lock:
            link = self._links.get(token)
            if link is None:
                return False
            if link.expires_at <= now or link.remaining <= 0:
                self._links.pop(token, None)
                return False
            if link.scope != tuple(scope):  # 范围不符不消耗次数，避免被他人探测耗尽
                return False
            link.remaining -= 1
            if link.remaining <= 0:
                self._links.pop(token, None)
            return True

    def _prune(self, now: float) -> None:
        for key in [k for k, v in self._links.items() if v.expires_at <= now]:
            self._links.pop(key, None)
        overflow = len(self._links) - MAX_ACTIVE_LINKS + 1
        if overflow > 0:
            oldest = sorted(self._links, key=lambda k: self._links[k].issued_at)[:overflow]
            for key in oldest:
                self._links.pop(key, None)


def _positive_int(value: object, default: int) -> int:
    try:
        number = int(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return default
    return number if number >= 1 else default


#: 进程内共享实例，由 ``create_files_router`` 在启动时按 CONFIG 配置。
store = PublicLinkStore()

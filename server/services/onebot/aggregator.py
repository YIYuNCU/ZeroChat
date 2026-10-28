"""入站消息聚合：与 App 的「停顿后再发给 AI」同一语义。

* 同一发送者（私聊 / 群内同一人）的连续消息在最后一条之后等待 ``wait`` 秒再合并处理，
  每来一条新消息就重新计时；总持有时间有上限，避免被持续刷屏拖死。
* 同一会话通道（私聊 / 群）同一时刻只处理一批；处理期间到达的消息排在其后，
  等当前批处理完再合并处理（对应 App 的 ``_flushPendingIfNeeded``）。
* ``wait == 0`` 立即处理。
"""
from __future__ import annotations

import asyncio
import logging
import time
from collections import OrderedDict
from typing import Awaitable, Callable, Dict, List, Optional, Tuple

from services.onebot.models import Inbound

logger = logging.getLogger(__name__)

MAX_HOLD_SECONDS = 60.0
DEDUP_MAX = 512
DEDUP_TTL_SECONDS = 600.0

BufKey = Tuple[str, str, int]  # (role_id, lane, user_id)
LaneKey = Tuple[str, str]  # (role_id, lane)
BatchHandler = Callable[[List[Inbound], object], Awaitable[None]]


class MessageDeduper:
    """按 (role_id, message_id) 去重，LRU + TTL。"""

    def __init__(self, max_size: int = DEDUP_MAX, ttl: float = DEDUP_TTL_SECONDS):
        self._seen: "OrderedDict[Tuple[str, int], float]" = OrderedDict()
        self._max = max_size
        self._ttl = ttl

    def seen(self, role_id: str, message_id: Optional[int], now: Optional[float] = None) -> bool:
        """返回 True 表示重复；首次出现时登记并返回 False。无 message_id 不去重。"""
        if message_id is None:
            return False
        now = time.monotonic() if now is None else now
        while self._seen:
            oldest_key, ts = next(iter(self._seen.items()))
            if now - ts > self._ttl or len(self._seen) > self._max:
                self._seen.popitem(last=False)
            else:
                break
        key = (role_id, int(message_id))
        if key in self._seen:
            self._seen.move_to_end(key)
            return True
        self._seen[key] = now
        return False


class _Pending:
    __slots__ = ("items", "conn", "first_ts", "timer", "queued")

    def __init__(self, conn):
        self.items: List[Inbound] = []
        self.conn = conn
        self.first_ts = time.monotonic()
        self.timer: Optional[asyncio.Task] = None
        self.queued = False  # True：已在等通道锁，新消息直接并入，不再计时


class MessageAggregator:
    def __init__(self, handler: BatchHandler, *, max_hold: float = MAX_HOLD_SECONDS):
        self._handler = handler
        self._max_hold = max_hold
        self._pending: Dict[BufKey, _Pending] = {}
        self._locks: Dict[LaneKey, asyncio.Lock] = {}
        self._tasks: set = set()

    def _lane_lock(self, key: LaneKey) -> asyncio.Lock:
        lock = self._locks.get(key)
        if lock is None:
            lock = self._locks[key] = asyncio.Lock()
        return lock

    def _spawn(self, coro) -> asyncio.Task:
        task = asyncio.ensure_future(coro)
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)
        return task

    def submit(self, inbound: Inbound, conn, wait: float) -> None:
        key: BufKey = (inbound.role_id, inbound.lane, inbound.user_id)
        pending = self._pending.get(key)
        if pending is None:
            pending = self._pending[key] = _Pending(conn)
        pending.items.append(inbound)
        pending.conn = conn  # 始终用最新连接发送

        if pending.queued:
            return
        if pending.timer and not pending.timer.done():
            pending.timer.cancel()
        remaining_hold = max(0.0, self._max_hold - (time.monotonic() - pending.first_ts))
        delay = min(max(0.0, wait), remaining_hold)
        if delay <= 0:
            self._queue(key, pending)
        else:
            pending.timer = self._spawn(self._after(key, pending, delay))

    async def _after(self, key: BufKey, pending: _Pending, delay: float) -> None:
        await asyncio.sleep(delay)
        if self._pending.get(key) is pending and not pending.queued:
            self._queue(key, pending)

    def _queue(self, key: BufKey, pending: _Pending) -> None:
        pending.queued = True
        self._spawn(self._run(key, pending))

    async def _run(self, key: BufKey, pending: _Pending) -> None:
        lane: LaneKey = (key[0], key[1])
        async with self._lane_lock(lane):
            # 拿到通道后才取走缓冲，等待期间到达的消息一并合并
            if self._pending.get(key) is pending:
                del self._pending[key]
            batch = pending.items
            if not batch:
                return
            try:
                await self._handler(batch, pending.conn)
            except asyncio.CancelledError:
                raise
            except Exception:  # noqa: BLE001 - 单批失败不能影响后续消息
                logger.error("OneBot 批处理失败: role=%s lane=%s", key[0], key[1], exc_info=True)

    async def shutdown(self) -> None:
        tasks = list(self._tasks)
        for task in tasks:
            task.cancel()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)
        self._pending.clear()
        self._locks.clear()

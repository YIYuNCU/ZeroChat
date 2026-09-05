"""Bounded file workers and cache for the existing JSON chat protocol."""

import asyncio
import copy
import functools
import os
import threading
import sys
from collections import OrderedDict
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

_executor = None
_executor_lock = threading.Lock()
# Stripes bound lock memory independently of the number of role IDs.
_role_locks = [threading.RLock() for _ in range(64)]


def role_lock(role_id):
    return _role_locks[hash(os.path.normcase(str(role_id).strip())) % len(_role_locks)]


async def run_file_io(fn, *args, **kwargs):
    global _executor
    with _executor_lock:
        if _executor is None:
            _executor = ThreadPoolExecutor(max_workers=4, thread_name_prefix="chat-io")
        executor = _executor
    return await asyncio.get_running_loop().run_in_executor(
        executor, functools.partial(fn, *args, **kwargs)
    )


def offload_role_io(fn):
    @functools.wraps(fn)
    async def wrapped(role_id, *args, **kwargs):
        def operation():
            with role_lock(role_id):
                result = fn(role_id, *args, **kwargs)
            if not fn.__name__.startswith("get_"):
                snapshot_cache.clear()
            return result
        return await run_file_io(operation)
    return wrapped


async def close_file_workers():
    global _executor
    with _executor_lock:
        executor, _executor = _executor, None
    if executor is not None:
        await asyncio.to_thread(executor.shutdown, wait=True)
    snapshot_cache.clear()


def source_signature(paths):
    result = []
    for path in paths:
        path = Path(path)
        try:
            stat = path.stat()
            result.append((str(path), stat.st_mtime_ns, stat.st_ctime_ns,
                           stat.st_size, stat.st_ino))
        except FileNotFoundError:
            result.append((str(path), None))
    return tuple(result)


class SnapshotCache:
    def __init__(self, max_bytes=64 * 1024 * 1024):
        self.max_bytes = max_bytes
        self._entries = OrderedDict()
        self._bytes = 0
        self._lock = threading.RLock()

    def clear(self):
        with self._lock:
            self._entries.clear()
            self._bytes = 0

    def get(self, key, paths, build, project=None):
        # Serialize builds to coalesce concurrent HTTP/WS requests. Signatures
        # also observe writes from another process or external file tools.
        with self._lock:
            signature = source_signature(paths())
            entry = self._entries.get(key)
            if entry is not None and entry[0] == signature:
                self._entries.move_to_end(key)
                return project(entry[1]) if project else copy.deepcopy(entry[1])
            if entry is not None:
                self._bytes -= self._entries.pop(key)[2]
            value = build()
            if source_signature(paths()) != signature:
                return project(value) if project else value
            size = _memory_size(value)
            if size <= self.max_bytes:
                while self._entries and self._bytes + size > self.max_bytes:
                    _, old = self._entries.popitem(last=False)
                    self._bytes -= old[2]
                self._entries[key] = (signature, value, size)
                self._bytes += size
            return project(value) if project else copy.deepcopy(value)


def _memory_size(value):
    seen = set()
    def visit(item):
        if id(item) in seen:
            return 0
        seen.add(id(item))
        size = sys.getsizeof(item)
        if isinstance(item, dict):
            size += sum(visit(k) + visit(v) for k, v in item.items())
        elif isinstance(item, (list, tuple)):
            size += sum(visit(v) for v in item)
        return size
    return visit(value)


def canonical_chat_message(message):
    timestamp = str(message.get("timestamp") or "")
    try:
        parsed = datetime.fromisoformat(timestamp)
        utc = parsed.tzinfo is not None
        if utc:
            parsed = parsed.astimezone(timezone.utc).replace(tzinfo=None)
        timestamp = parsed.isoformat(timespec="milliseconds" if parsed.microsecond % 1000 == 0 else "microseconds")
        if utc:
            timestamp += "Z"
    except ValueError:
        pass
    return {
        "content": message.get("content", ""),
        "id": message.get("id", ""),
        "quote_content": message.get("quote_content", message.get("quoted_preview_text")),
        "quote_id": message.get("quote_id", message.get("quoted_message_id")),
        "sender_id": message.get("sender_id", "unknown"),
        "timestamp": timestamp,
        "type": message.get("type") or "text",
    }


snapshot_cache = SnapshotCache()

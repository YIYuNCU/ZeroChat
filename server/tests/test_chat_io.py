import asyncio
import builtins
import hashlib
import json
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch

from routers import roles, moments
from services.chat_io_service import SnapshotCache, canonical_chat_message, close_file_workers, role_lock, snapshot_cache


class ChatIOTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.roles_patch = patch.object(roles, "ROLES_DIR", self.root / "roles")
        self.roles_patch.start()
        snapshot_cache.clear()

    def tearDown(self):
        asyncio.run(close_file_workers())
        self.roles_patch.stop()
        self.temp.cleanup()

    def seed(self, role_id="r", messages=None):
        path = roles.ROLES_DIR / role_id / "chats" / "messages.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({"messages": messages or []}), encoding="utf-8")
        return path

    def test_unchanged_snapshot_skips_parsing_and_observes_external_changes(self):
        path = self.seed(messages=[{"id": "1", "content": "old"}])
        snapshot = roles._build_chats_snapshot("http://a")
        with patch.object(roles, "_build_chats_snapshot_uncached", side_effect=AssertionError("rebuilt")):
            matched = roles._build_chats_snapshot("http://a", client_md5=snapshot["md5"])
            self.assertNotIn("chats", matched)
        path.write_text(json.dumps({"messages": [{"id": "1", "content": "changed"}]}), encoding="utf-8")
        changed = roles._build_chats_snapshot("http://a")
        self.assertNotEqual(changed["md5"], snapshot["md5"])
        self.seed("new")
        self.assertEqual(roles._build_chats_snapshot("http://a")["total_chats"], 2)

    def test_cache_budget_and_defensive_copy(self):
        cache = SnapshotCache(max_bytes=10000)
        first = cache.get("key", lambda: [], lambda: {"nested": [1]})
        first["nested"].append(2)
        self.assertEqual(cache.get("key", lambda: [], lambda: None), {"nested": [1]})
        tiny = SnapshotCache(max_bytes=1)
        calls = []
        for _ in range(2):
            tiny.get("key", lambda: [], lambda: calls.append(1) or {"value": 1})
        self.assertEqual(len(calls), 2)

    def test_concurrent_writes_are_atomic_and_idempotent(self):
        async def run():
            messages = [roles.ChatMessage(id=str(i), content="hello", sender_id="me",
                         timestamp="2026-09-05T00:00:00.000") for i in range(30)]
            await asyncio.gather(*(roles.save_chat_message("r", m) for m in messages * 2))
            result = await roles.get_chat_snapshot("http://a")
            self.assertEqual(result["total_messages"], 30)
            await roles.delete_chat_message("r", "0")
            self.assertEqual((await roles.get_chat_snapshot("http://a"))["total_messages"], 29)
        asyncio.run(run())

    def test_initialization_and_alias_save_share_a_lock(self):
        self.assertIs(role_lock("r"), role_lock(" r "))
        started = threading.Event()
        release = threading.Event()
        original_open = builtins.open
        def delayed_open(file, mode="r", *args, **kwargs):
            if str(file).endswith("messages.json") and mode in ("x", "w") and not started.is_set():
                started.set()
                self.assertTrue(release.wait(2))
            return original_open(file, mode, *args, **kwargs)
        async def run():
            with patch("builtins.open", side_effect=delayed_open):
                initialization = asyncio.create_task(asyncio.to_thread(roles.get_role_dir, " r "))
                while not started.is_set():
                    await asyncio.sleep(0.001)
                save = asyncio.create_task(roles.save_chat_message("r", roles.ChatMessage(
                    id="saved", sender_id="me", content="keep", timestamp="2026-09-05T00:00:00")))
                try:
                    await asyncio.sleep(0.03)
                    self.assertFalse(save.done(), "save bypassed the initialization lock")
                finally:
                    release.set()
                await asyncio.gather(initialization, save)
            self.assertEqual(roles._load_role_chat_messages("r")[0]["id"], "saved")
        asyncio.run(run())

    def test_file_work_does_not_block_event_loop(self):
        self.seed()
        release = threading.Event()
        original = roles._load_role_chat_messages
        def slow(role_id):
            self.assertTrue(release.wait(2), "event loop could not release the worker")
            return original(role_id)
        async def run():
            async def tick():
                await asyncio.sleep(0.02)
                release.set()
            with patch.object(roles, "_load_role_chat_messages", side_effect=slow):
                await asyncio.gather(roles.get_chat_snapshot("http://a"), tick())
        asyncio.run(run())

    def test_canonical_hash_matches_dart_fixture(self):
        self.seed(messages=[{"id": "0", "sender_id": "me", "content": "中文\nline 0",
                            "timestamp": "2026-09-05T00:00:00+00:00", "type": "text"}])
        canonical = '{"r":[{"content":"中文\\nline 0","id":"0","quote_content":null,"quote_id":null,"sender_id":"me","timestamp":"2026-09-05T00:00:00.000Z","type":"text"}]}'
        self.assertEqual(roles._build_chats_snapshot()["md5"], hashlib.md5(canonical.encode()).hexdigest())
        self.assertEqual(canonical_chat_message({"timestamp": "2026-09-05T08:00:00.123456+08:00"})["timestamp"],
                         "2026-09-05T00:00:00.123456Z")

    def test_matching_moment_hash_skips_render_and_disk_write(self):
        with patch.object(moments, "MOMENTS_FILE", self.root / "posts.json"), patch.object(
            moments, "MOMENTS_HASH_FILE", self.root / "posts.hash"
        ):
            moments.save_moments([{"id": "m", "author_id": "me", "content": "hello"}])
            digest = moments._read_cached_moments_hash()
            with patch.object(moments, "_build_rendered_moments", side_effect=AssertionError("rendered")), patch.object(
                moments, "_write_cached_moments_hash", side_effect=AssertionError("wrote cache")
            ):
                result = asyncio.run(moments.list_moments(client_hash=digest))
            self.assertTrue(result["not_modified"])
            self.assertEqual(result["count"], 1)


if __name__ == "__main__":
    unittest.main()

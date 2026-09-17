"""Prompt-cache stability of the context window when the summary API is unusable.

A misconfigured or failing summary API used to make ``get_context_messages`` return the
"latest N" messages, so every retry of a single message rebuilt a *different* prefix and
the provider prompt cache never hit. These tests pin the deterministic fallback window,
the failure cooldown and the request-id idempotency that make retries cache-friendly.
"""
import asyncio
import json
import unittest
import threading
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import AsyncMock, patch

from services import memory_service, settings_service


class SummaryCacheStabilityTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.settings = {
            **settings_service.get_default_settings(),
            "summary_config_migrated": True,
            "ai_api_url": "https://summary.example.test",
            "ai_api_key": "test-key",
            "ai_model": "test-model",
        }
        self.enterContext(patch.object(settings_service, "load_settings", return_value=self.settings))
        self.enterContext(patch.object(settings_service, "save_settings", side_effect=AssertionError("unexpected settings write")))
        temp_dir = TemporaryDirectory()
        self.addCleanup(temp_dir.cleanup)
        roles_dir = Path(temp_dir.name)
        self.enterContext(patch.object(memory_service, "ROLES_DIR", roles_dir))
        self.addCleanup(memory_service.close_all_connections)
        self.ai = self.enterContext(patch(
            "services.ai_service.call_ai_direct", new_callable=AsyncMock,
        ))
        self.enterContext(patch(
            "services.ai_service.generate_embedding", new_callable=AsyncMock,
        ))
        self.role_id = "role-1"

    def append(self, content, **kwargs):
        return memory_service.append_short_term(
            self.role_id, "user", content, **kwargs,
        )

    async def context(self, **kwargs):
        return await memory_service.get_context_messages(
            self.role_id, max_context_rounds=1, **kwargs,
        )

    def texts(self, context):
        return [
            memory_service._extract_semantic_text(item["content"]) for item in context
        ]

    async def test_retrying_one_message_reuses_an_identical_window(self):
        self.append("Oldest", request_id="req-1")
        self.append("Middle", request_id="req-2")
        self.append("Newest", request_id="req-3")
        self.ai.return_value = {"success": True, "content": '{"summary": broken'}

        windows = []
        for _ in range(4):
            windows.append(self.texts(await self.context()))

        self.assertTrue(
            all(window == windows[0] for window in windows),
            f"失败降级窗口必须逐字节稳定，实际得到 {windows}",
        )
        self.assertEqual(self.ai.await_count, 1, "冷却期内不应重复调用总结 API")

    async def test_failed_summary_never_advances_the_checkpoint(self):
        self.append("Oldest")
        self.append("Middle")
        self.append("Newest")
        # 以结构化的开头返回了截断 JSON：必须视为失败而不是旧式纯文本摘要。
        self.ai.return_value = {"success": True, "content": '{"summary": "truncated"'}
        await self.context()

        with memory_service._get_connection(self.role_id) as conn:
            self.assertIsNone(memory_service._get_meta(conn, "event_summary_last_id:default"))
            self.assertEqual(
                memory_service._get_meta(conn, "event_summary_fallback_start:default"), "0",
            )

    async def test_duplicate_request_id_is_not_written_twice(self):
        first = self.append("同一请求", request_id="req-dup")
        second = self.append("同一请求", request_id="req-dup")

        self.assertIsNotNone(first)
        self.assertEqual(first, second)
        with memory_service._get_connection(self.role_id) as conn:
            count = conn.execute("SELECT COUNT(*) FROM short_term").fetchone()[0]
        self.assertEqual(count, 1)

    async def test_duplicate_request_id_does_not_inflate_summary_counters(self):
        self.append("First", request_id="req-a")
        self.append("First", request_id="req-a")
        with memory_service._get_connection(self.role_id) as conn:
            self.assertEqual(
                memory_service._get_meta(conn, "message_count_since_summary"), "1",
            )

    async def test_user_and_assistant_share_a_request_without_suppressing_each_other(self):
        self.append("User message", request_id="req-turn")
        memory_service.append_short_term(
            self.role_id, "assistant", "Assistant reply", request_id="req-turn",
        )

        with memory_service._get_connection(self.role_id) as conn:
            rows = conn.execute(
                "SELECT role, content FROM short_term ORDER BY id",
            ).fetchall()
        self.assertEqual([row[0] for row in rows], ["user", "assistant"])
        self.assertEqual(len(rows), 2)

    async def test_busy_summary_keeps_the_previous_window(self):
        self.append("Oldest")
        self.append("Middle")
        started = asyncio.Event()
        release = asyncio.Event()

        async def respond(**kwargs):
            started.set()
            await release.wait()
            return {"success": True, "content": '{"summary":"s","events":[]}'}

        self.ai.side_effect = respond
        first = asyncio.create_task(self.context())
        try:
            await asyncio.wait_for(started.wait(), timeout=5)
            busy = await self.context()
            self.assertEqual(self.texts(busy), ["Oldest", "Middle"])
        finally:
            release.set()
            await first

    async def test_degraded_window_stays_a_prefix_as_new_messages_arrive(self):
        self.append("One")
        self.append("Two")
        self.ai.return_value = {"success": True, "content": '{"summary": broken'}
        first = self.texts(await self.context())

        self.append("Three")
        second = self.texts(await self.context())

        self.assertEqual(first, ["One", "Two"])
        self.assertEqual(second, ["One", "Two", "Three"])
        self.assertEqual(self.ai.await_count, 1)

    async def test_successful_summary_resets_the_failure_state(self):
        self.append("One")
        self.append("Two")
        self.ai.return_value = {"success": True, "content": '{"summary": broken'}
        await self.context()
        with memory_service._get_connection(self.role_id) as conn:
            memory_service._set_meta(conn, "event_summary_failed_at:default", None)

        self.ai.return_value = {"success": True, "content": json.dumps(
            {"summary": "Recovered", "events": []},
        )}
        await self.context()

        with memory_service._get_connection(self.role_id) as conn:
            self.assertEqual(memory_service._get_meta(conn, "virtual_block_start:default"), "1")
            self.assertIsNone(
                memory_service._get_meta(conn, "event_summary_fallback_start:default")
            )

    async def test_overflow_keeps_latest_history_and_retry_is_stable(self):
        for disabled in (False, True):
            with self.subTest(disabled=disabled):
                self.role_id = f"overflow-{disabled}"
                self.settings["context_summary_config"] = {"enabled": not disabled}
                self.ai.return_value = {"success": False, "content": None}
                for i in range(20):
                    self.append(f"message-{i}")
                    window = await self.context()
                    self.assertEqual(self.texts(window)[-1], f"message-{i}")
                    self.assertLessEqual(len(window), 6)
                    self.assertEqual(window, await self.context())
                with memory_service._get_connection(self.role_id) as conn:
                    self.assertIsNone(memory_service._get_meta(conn, "event_summary_last_id:default"))

    async def test_concurrent_success_clears_main_user_fallback(self):
        for i in range(10):
            self.append(f"message-{i}")
        started, release = asyncio.Event(), asyncio.Event()

        async def respond(**kwargs):
            started.set()
            await release.wait()
            return {"success": True, "content": '{"summary":"s","events":[]}'}

        self.ai.side_effect = respond
        async def context():
            return await memory_service.get_context_messages(
                self.role_id, max_context_rounds=5, conversation_key="default_user",
            )
        first = asyncio.create_task(context())
        try:
            await asyncio.wait_for(started.wait(), 5)
            await context()
        finally:
            release.set()
            await first
        window = self.texts(await context())
        self.assertEqual(window[0], "message-9")
        self.assertEqual(len(window), 3)
        with memory_service._get_connection(self.role_id) as conn:
            for scope in ("default", "default_user", "main_qq"):
                self.assertIsNone(memory_service._get_meta(conn, f"event_summary_fallback_start:{scope}"))

    async def test_concurrent_duplicate_writes_are_atomic(self):
        # Warm up schema before independent worker connections contend for the write.
        with memory_service._get_connection(self.role_id):
            pass
        barrier = threading.Barrier(8)
        def append(_):
            with memory_service._get_connection(self.role_id):
                pass
            barrier.wait(timeout=5)
            return self.append("same request", request_id="concurrent-request")
        with ThreadPoolExecutor(max_workers=8) as pool:
            ids = list(pool.map(append, range(8)))
        self.assertEqual(len(set(ids)), 1)
        with memory_service._get_connection(self.role_id) as conn:
            self.assertEqual(conn.execute("SELECT COUNT(*) FROM short_term").fetchone()[0], 1)
            self.assertEqual(memory_service._get_meta(conn, "message_count_since_summary"), "1")


if __name__ == "__main__":
    unittest.main()

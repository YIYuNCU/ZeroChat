import asyncio
import unittest
from unittest.mock import AsyncMock, patch

from transport import ws_dispatcher as dispatcher


class CompactContextTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.context = {"async": True, "compact_context": True,
                        "client_submission_id": "stable-submission", "chat_id": "group-1",
                        "fallback_fields": ["history", "core_memory", "attached_json"]}
        self.patchers = [
            patch.object(dispatcher, "resolve_backend_base_url_from_websocket", return_value="http://test"),
            patch.object(dispatcher.roles, "load_role", return_value={}),
            patch("services.memory_service.get_context_messages", new_callable=AsyncMock, return_value=[]),
            patch("services.chat_io_service.run_file_io", new_callable=AsyncMock, return_value={"core_memory": []}),
            patch("transport.push_hub.get_missed_chat_pushes", return_value=[]),
            patch.object(dispatcher, "_process_chat_background", new_callable=AsyncMock),
        ]
        self.mocks = [item.start() for item in self.patchers]
        self.addCleanup(lambda: [item.stop() for item in reversed(self.patchers)])
        dispatcher._ACTIVE_ASYNC_CHAT_TASKS.clear()

    async def dispatch(self):
        return await dispatcher.handle_ws_action("ai_event", {"event": {
            "role_id": "r", "event_type": "chat", "content": "hello", "context": self.context}}, None, {})

    async def test_missing_context_does_not_start_generation_or_consume_vision(self):
        self.context["vision_upload_id"] = "pending-image"
        response = await self.dispatch()
        self.assertEqual(response, {"status": "context_required", "fields": self.context["fallback_fields"]})
        self.mocks[-1].assert_not_called()
        self.assertEqual(dispatcher._ACTIVE_ASYNC_CHAT_TASKS, {})
        self.mocks[2].assert_awaited_once_with("r", conversation_key="default_user", skip_summary=True,
                                             latest=True, max_context_rounds=None)

    async def test_server_context_needs_no_fallback_and_retry_reuses_task(self):
        self.mocks[1].return_value = {"attached_json_content": "{}"}
        self.mocks[2].return_value = [{"role": "user", "content": "previous"}]
        self.mocks[3].return_value = {"core_memory": ["fact"]}
        gate = asyncio.Event()
        async def generate(*args):
            await gate.wait()
        self.mocks[-1].side_effect = generate
        first = await self.dispatch()
        second = await self.dispatch()
        self.assertEqual(first["task_id"], second["task_id"])
        self.assertEqual(second["status"], "queued")
        task = dispatcher._ACTIVE_ASYNC_CHAT_TASKS[first["task_id"]]
        gate.set()
        await task
        self.mocks[-1].assert_awaited_once()

    async def test_supplied_fallback_keeps_submission_and_chat_id(self):
        requested = await self.dispatch()
        self.context.update(context_supplied=True, history=[{"role": "user", "content": "old"}])
        response = await self.dispatch()
        task = dispatcher._ACTIVE_ASYNC_CHAT_TASKS[response["task_id"]]
        await task
        event = self.mocks[-1].call_args.args[1]
        self.assertIn("history", requested["fields"])
        self.assertEqual(event.context["chat_id"], "group-1")
        self.assertEqual(event.context["client_submission_id"], "stable-submission")

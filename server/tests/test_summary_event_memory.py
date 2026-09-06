import asyncio
import json
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import AsyncMock, patch

from services import memory_service
from services.tool_prompts import get_tool_prompt
from services.vector_memory import VectorMemoryStore, close_all_vector_connections


class SummaryEventMemoryTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        temp_dir = TemporaryDirectory()
        self.addCleanup(temp_dir.cleanup)
        roles_dir = Path(temp_dir.name)
        self.enterContext(patch.object(memory_service, "ROLES_DIR", roles_dir))
        self.enterContext(patch("services.vector_memory.ROLES_DIR", roles_dir))
        self.addCleanup(memory_service.close_all_connections)
        self.addCleanup(close_all_vector_connections)
        self.ai = self.enterContext(patch(
            "services.ai_service.call_ai_direct", new_callable=AsyncMock,
        ))
        self.embedding = self.enterContext(patch(
            "services.ai_service.generate_embedding", new_callable=AsyncMock,
        ))
        self.embedding.return_value = {"success": True, "embedding": [1.0, 0.0]}
        self.enterContext(patch(
            "routers.roles.load_role",
            side_effect=lambda worker_id: {"system_prompt": get_tool_prompt(worker_id)},
        ))
        self.role_id = "role-1"

    def append(self, content, timestamp="2026-09-06T18:00:00+08:00", **kwargs):
        memory_service.append_short_term(self.role_id, "user", content, **kwargs)
        with memory_service._get_connection(self.role_id) as conn:
            conn.execute(
                "UPDATE short_term SET timestamp = ? WHERE id = (SELECT MAX(id) FROM short_term)",
                (timestamp,),
            )

    def response(self, events, summary="Conversation summary"):
        self.ai.return_value = {
            "success": True,
            "content": json.dumps({"summary": summary, "events": events}),
        }

    async def summarize(self, **kwargs):
        return await memory_service.trigger_chat_summary(
            "1000000000002", self.role_id, **kwargs,
        )

    async def test_core_summary_does_not_call_embedding_or_write_vectors(self):
        self.append("I prefer tea")
        self.append("Please remember that")
        self.embedding.side_effect = AssertionError("Core memory must not request embedding")
        for content, expected in [
            ('[{"category":"preference","fact":"Prefers tea","confidence":"high"}]',
             "[preference][high] Prefers tea"),
            ("[]", ""),
        ]:
            self.ai.return_value = {"success": True, "content": content}
            with patch.object(memory_service, "should_summarize", return_value=True):
                result = await memory_service.trigger_memory_summary(self.role_id, {})
            self.assertEqual(result, expected)
            self.assertEqual(memory_service.get_core_memory(self.role_id), expected)
        self.embedding.assert_not_awaited()
        self.assertEqual(VectorMemoryStore(self.role_id).count(), 0)

    async def test_events_are_appended_with_occurrence_time_and_message_time(self):
        self.append("I passed the exam today. Tomorrow morning I will attend an interview.")
        store = VectorMemoryStore(self.role_id)
        store.store("Earlier event", [1.0, 0.0], source="memory_summary")
        self.response([
            {"event": "Passed the exam", "status": "occurred", "event_time": "2026-09-06"},
            {"event": "Interview appointment", "status": "upcoming", "event_time": "2026-09-07T09:00:00+08:00"},
        ])
        self.assertEqual(await self.summarize(), "Conversation summary")
        prompt = json.loads(self.ai.call_args.kwargs["messages"][1]["content"])
        self.assertEqual(prompt["current_conversation"][0]["time"], "2026-09-06T18:00:00+08:00")
        records = store.list_all()
        self.assertEqual(len(records), 3)
        self.assertEqual(records[0]["timestamp"], "2026-09-07T09:00:00+08:00")
        self.assertEqual(records[1]["timestamp"], "2026-09-06")
        self.assertIn("2026-09-06T18:00:00+08:00", records[0]["text"])
        self.assertEqual(records[0]["source"], "memory_summary")
        self.assertIn("Interview appointment", self.embedding.call_args.args[0])
        self.assertEqual(self.embedding.await_count, 2)
        short_term = memory_service.load_memory(self.role_id)["short_term"]
        self.assertIn("Conversation summary", short_term[-1]["content"])
        self.assertNotIn('"events"', short_term[-1]["content"])

    async def test_core_summary_malformed_json_preserves_existing_memory(self):
        memory_service.update_core_memory(self.role_id, "Existing core memory")
        self.append("New conversation")
        for raw in [
            '[{"fact":"truncated"',
            '{"facts": [{"fact": "trailing comma"},]}',
            '```json\n[{"fact":}]\n```',
            '{"unexpected": []}',
            '{"facts": {}}',
            '[{}]',
        ]:
            with self.subTest(raw=raw):
                self.ai.return_value = {"success": True, "content": raw}
                with patch.object(memory_service, "should_summarize", return_value=True):
                    self.assertIsNone(await memory_service.trigger_memory_summary(self.role_id, {}))
                self.assertEqual(memory_service.get_core_memory(self.role_id), "Existing core memory")
        self.embedding.assert_not_awaited()

    async def test_previous_summary_is_separate_and_only_new_channel_messages_are_extracted(self):
        self.append("Older conversation", origin="onebot_group", group_id="group-1")
        self.append("Previous summary", origin="onebot_group", group_id="group-1", sender="memory_summary")
        self.append("Private conversation", origin="onebot_private", sender_id="private-1")
        self.append("Different group", origin="onebot_group", group_id="group-2")
        self.append("New group event", origin="onebot_group", group_id="group-1")
        self.response([])
        await self.summarize(conv_origin="onebot_group", conv_group_id="group-1")
        prompt = json.loads(self.ai.call_args.kwargs["messages"][1]["content"])
        self.assertIn("Previous summary", prompt["previous_summary"])
        self.assertEqual([item["message"] for item in prompt["current_conversation"]], ["New group event"])
        self.embedding.assert_not_awaited()
        self.assertIsNone(await self.summarize(conv_origin="onebot_group", conv_group_id="group-1"))
        self.assertEqual(self.ai.await_count, 1)

    async def test_embedding_failure_preserves_context_summary_and_other_events(self):
        self.append("Two events")
        self.response([
            {"event": "First event", "status": "occurred", "event_time": None},
            {"event": "Second event", "status": "upcoming", "event_time": "2026-09-07"},
        ])
        self.embedding.side_effect = [
            {"success": False, "embedding": None},
            {"success": True, "embedding": [1.0, 0.0]},
        ]
        self.assertEqual(await self.summarize(), "Conversation summary")
        records = VectorMemoryStore(self.role_id).list_all()
        self.assertEqual(len(records), 1)
        self.assertIn("Second event", records[0]["text"])

    async def test_empty_events_and_legacy_summary_do_not_embed_core_preferences(self):
        self.append("I prefer tea")
        self.response([])
        await self.summarize()
        self.append("Another message")
        self.ai.return_value = {"success": True, "content": "Legacy context summary"}
        self.assertEqual(await self.summarize(), "Legacy context summary")
        self.embedding.assert_not_awaited()

    async def test_malformed_json_does_not_write_summary_vectors_or_checkpoint(self):
        self.append("An event that still needs summarizing")
        invalid_outputs = [
            '{"summary": "truncated", "events": [',
            '{"summary": "trailing comma", "events": [],}',
            '{"summary": "unescaped "quote"", "events": []}',
            '```json\n{"summary": "broken", "events": [}\n```',
            '{"summary": "valid object", "events": []} trailing text',
            '[{"event": "wrong root type"}]',
            '{"summary": [], "events": {}}',
            'null',
            {"summary": "wrong response content type"},
        ]
        for raw in invalid_outputs:
            with self.subTest(raw=raw):
                self.ai.return_value = {"success": True, "content": raw}
                self.assertIsNone(await self.summarize())
                with memory_service._get_connection(self.role_id) as conn:
                    self.assertEqual(conn.execute("SELECT COUNT(*) FROM short_term").fetchone()[0], 1)
                    self.assertIsNone(memory_service._get_meta(conn, "event_summary_last_id:default"))
                self.assertEqual(VectorMemoryStore(self.role_id).count(), 0)
        self.embedding.assert_not_awaited()

    async def test_invalid_json_keeps_context_window_available_for_retry(self):
        self.append("First message")
        self.append("Second message")
        self.ai.return_value = {"success": True, "content": '{"summary":'}
        context = await memory_service.get_context_messages(self.role_id, max_context_rounds=1)
        self.assertEqual(len(context), 2)
        with memory_service._get_connection(self.role_id) as conn:
            self.assertIsNone(memory_service._get_meta(conn, "virtual_block_start:default"))
        self.response([])
        await memory_service.get_context_messages(self.role_id, max_context_rounds=1)
        with memory_service._get_connection(self.role_id) as conn:
            self.assertEqual(memory_service._get_meta(conn, "virtual_block_start:default"), "1")
        self.assertEqual(self.ai.await_count, 2)

    async def test_messages_arriving_during_summary_are_included_next_time(self):
        self.append("Initial conversation")

        async def respond(**kwargs):
            self.append("Arrived while model was running")
            return {"success": True, "content": '{"summary":"First summary","events":[]}'}

        self.ai.side_effect = respond
        await self.summarize()
        self.ai.side_effect = None
        self.response([])
        await self.summarize()
        prompt = json.loads(self.ai.call_args.kwargs["messages"][1]["content"])
        self.assertEqual(
            [item["message"] for item in prompt["current_conversation"]],
            ["Arrived while model was running"],
        )

    async def test_failed_summary_overflow_returns_latest_messages_without_advancing_checkpoint(self):
        self.append("Oldest message")
        self.append("Middle message")
        self.append("Newest message")
        self.ai.return_value = {"success": True, "content": '{"summary":'}
        context = await memory_service.get_context_messages(self.role_id, max_context_rounds=1)
        self.assertEqual(
            [memory_service._extract_semantic_text(item["content"]) for item in context],
            ["Middle message", "Newest message"],
        )
        with memory_service._get_connection(self.role_id) as conn:
            self.assertIsNone(memory_service._get_meta(conn, "virtual_block_start:default"))

    async def test_summary_preserves_multiline_user_and_assistant_messages(self):
        user_text = "Two important events:\nInterview tomorrow morning\nExam completed today"
        assistant_text = "Confirmed:\nThe interview is tomorrow morning"
        self.append(user_text)
        memory_service.append_short_term(self.role_id, "assistant", assistant_text)
        self.response([])
        await self.summarize()
        prompt = json.loads(self.ai.call_args.kwargs["messages"][1]["content"])
        self.assertEqual(
            [item["message"] for item in prompt["current_conversation"]],
            [user_text, assistant_text],
        )
        self.ai.return_value = {"success": True, "content": "[]"}
        with patch.object(memory_service, "should_summarize", return_value=True):
            await memory_service.trigger_memory_summary(self.role_id, {})
        core_prompt = self.ai.call_args.kwargs["messages"][1]["content"]
        self.assertIn(user_text, core_prompt)
        self.assertIn(assistant_text, core_prompt)

    async def test_concurrent_summary_for_same_channel_does_not_duplicate_events(self):
        self.append("One event")
        started = asyncio.Event()
        release = asyncio.Event()

        async def respond(**kwargs):
            started.set()
            await release.wait()
            return {"success": True, "content": json.dumps({
                "summary": "One event", "events": [
                    {"event": "One event", "status": "occurred", "event_time": "2026-09-06"},
                ],
            })}

        self.ai.side_effect = respond
        first = asyncio.create_task(self.summarize())
        try:
            await asyncio.wait_for(started.wait(), timeout=5)
            self.assertIsNone(await self.summarize())
        finally:
            release.set()
            await first
        self.assertEqual(self.ai.await_count, 1)
        self.assertEqual(VectorMemoryStore(self.role_id).count(), 1)

    def test_wrong_event_json_types_do_not_discard_valid_events(self):
        raw = json.dumps({"summary": "Context", "events": [
            None, "invalid item", {"event": [], "status": "occurred"},
            {"event": "Invalid status", "status": {}},
            {"event": "Unknown status", "status": "maybe"},
            {"event": "Valid event", "status": "ongoing", "event_time": "2026-09-06"},
            {"event": "Unknown time event", "status": "upcoming", "event_time": {}},
        ]})
        summary, items = memory_service._parse_chat_summary(raw, "2026-09-06T18:00:00+08:00")
        self.assertEqual(summary, "Context")
        self.assertEqual(len(items), 2)
        self.assertEqual(items[0]["timestamp"], "2026-09-06")
        self.assertIn("未明确", items[1]["text"])

    def test_valid_fenced_json_is_accepted(self):
        summary, items = memory_service._parse_chat_summary(
            '```json\n{"summary":"Context","events":[]}\n```', "2026-09-06",
        )
        self.assertEqual((summary, items), ("Context", []))

    def test_parser_preserves_unknown_time_and_filters_invalid_or_duplicate_events(self):
        event = {"event": "Travel sometime next month", "status": "upcoming", "event_time": "next month"}
        raw = json.dumps({"summary": "", "events": [event, event, {}, {"event": "Invalid", "status": []}]})
        summary, items = memory_service._parse_chat_summary(raw, "2026-09-06T18:00:00+08:00")
        self.assertEqual(len(items), 1)
        self.assertEqual(items[0]["timestamp"], "2026-09-06T18:00:00+08:00")
        self.assertIn("Travel sometime next month", summary)
        self.assertIn("未明确", summary)


if __name__ == "__main__":
    unittest.main()

import unittest
import inspect
from datetime import datetime
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import AsyncMock, MagicMock, patch

from services.ai_tools import (
    _WRITE_MEMORY_TOOL,
    execute_search_memory,
    execute_write_memory,
)
from services.ai_service import (
    NO_REPLY_DIRECTIVE,
    _build_system_prompt,
    is_no_reply_directive,
)
from services.memory_service import append_short_term
from services.vector_memory import VectorMemoryStore
from routers.ai_behavior import _run_memory_ai_pipeline
from routers.roles import RoleCreate


class WriteMemoryToolTests(unittest.IsolatedAsyncioTestCase):
    def test_schema_requires_summary_and_exposes_occurred_at(self):
        parameters = _WRITE_MEMORY_TOOL[0]["function"]["parameters"]

        self.assertEqual(parameters["required"], ["summary"])
        self.assertIn("occurred_at", parameters["properties"])
        self.assertNotIn("content", parameters["properties"])

    def test_prompt_allows_flexible_repeated_parts_and_reserves_fact(self):
        prompt = _build_system_prompt({"id": "role-1"})

        self.assertIn("同一种类型在一次回复中可以出现多次", prompt)
        self.assertIn(
            "<对话>...</对话><动作>...</动作><对话>...</对话>",
            prompt,
        )
        self.assertIn("用户专属格式", prompt)
        self.assertIn("绝对不能输出 <事实> 标签", prompt)

    def test_prompt_and_parser_require_a_standalone_no_reply_directive(self):
        prompt = _build_system_prompt({"id": "role-1"})

        self.assertIn("无回复指令", prompt)
        self.assertIn(f"整条回复必须且只能是 {NO_REPLY_DIRECTIVE}", prompt)
        self.assertTrue(is_no_reply_directive(f"  {NO_REPLY_DIRECTIVE}  "))
        self.assertFalse(is_no_reply_directive(f"{NO_REPLY_DIRECTIVE}还有正文"))

    def test_role_schema_exposes_frontend_no_reply_visibility(self):
        hidden = RoleCreate(id="role-1", name="测试")
        visible = RoleCreate(id="role-1", name="测试", show_no_reply=True)

        self.assertIsNone(hidden.show_no_reply)
        self.assertTrue(visible.show_no_reply)

    def test_chat_messages_have_no_direct_vector_write_path(self):
        self.assertNotIn("embed_and_store", inspect.getsource(append_short_term))
        self.assertNotIn(
            "embed_and_store", inspect.getsource(_run_memory_ai_pipeline)
        )

    async def test_no_reply_keeps_user_memory_without_assistant_directive(self):
        append_mock = MagicMock()
        with patch(
            "services.ai_service.generate_with_role",
            new=AsyncMock(
                return_value={
                    "success": True,
                    "content": NO_REPLY_DIRECTIVE,
                    "user_content": {"content": "用户消息"},
                }
            ),
        ), patch(
            "services.memory_service.get_context_messages",
            new=AsyncMock(return_value=[]),
        ), patch(
            "services.memory_service.get_memory_context_string",
            return_value="",
        ), patch(
            "services.memory_service.append_short_term",
            append_mock,
        ), patch(
            "services.memory_service._get_memory_length",
            return_value=10,
        ), patch(
            "services.stats_service.get_current_values",
            return_value=None,
        ):
            result = await _run_memory_ai_pipeline(
                role={"id": "role-1", "name": "AI"},
                role_id="role-1",
                user_message="用户消息",
                trigger_summary_after_reply=False,
            )

        self.assertTrue(result["no_reply"])
        self.assertEqual(append_mock.call_count, 1)
        self.assertEqual(append_mock.call_args.args[1], "user")

    async def test_write_memory_stores_summary_and_occurrence_time(self):
        store = MagicMock()
        embedding_result = {"success": True, "embedding": [0.1, 0.2]}

        with patch(
            "services.ai_service.generate_embedding",
            new=AsyncMock(return_value=embedding_result),
        ), patch("services.vector_memory.VectorMemoryStore", return_value=store):
            result = await execute_write_memory(
                {"id": "role-1"},
                "用户已决定七月开始学习游泳",
                "2026-07-01T09:30:00",
            )

        store.store.assert_called_once_with(
            text="用户已决定七月开始学习游泳",
            embedding=[0.1, 0.2],
            role="assistant",
            timestamp="2026-07-01T09:30:00",
            source="ai_tool",
        )
        self.assertIn("2026-07-01T09:30:00", result)

    async def test_write_memory_defaults_to_current_time(self):
        store = MagicMock()
        embedding_result = {"success": True, "embedding": [0.1]}

        with patch(
            "services.ai_service.generate_embedding",
            new=AsyncMock(return_value=embedding_result),
        ), patch("services.vector_memory.VectorMemoryStore", return_value=store):
            await execute_write_memory({"id": "role-1"}, "用户喜欢清淡口味")

        timestamp = store.store.call_args.kwargs["timestamp"]
        self.assertIsInstance(datetime.fromisoformat(timestamp), datetime)

    async def test_write_memory_rejects_invalid_occurrence_time(self):
        result = await execute_write_memory(
            {"id": "role-1"},
            "用户已经完成了考试",
            "昨天上午",
        )

        self.assertIn("ISO 8601", result)


class SearchMemoryToolTests(unittest.IsolatedAsyncioTestCase):
    def test_vector_search_exposes_record_time(self):
        with TemporaryDirectory() as temp_dir, patch(
            "services.vector_memory.ROLES_DIR", Path(temp_dir)
        ):
            (Path(temp_dir) / "role-1").mkdir()
            store = VectorMemoryStore("role-1")
            store.store(
                "用户已完成考试",
                [0.2, 0.4],
                timestamp="2026-07-10T10:00:00",
                source="ai_tool",
            )
            result = store.search([0.2, 0.4], top_k=1)

        self.assertEqual(result[0]["timestamp"], "2026-07-10T10:00:00")
        self.assertTrue(result[0]["created_at"])

    async def test_search_result_contains_occurrence_and_record_times(self):
        store = MagicMock()
        store.count.return_value = 1
        store.search.return_value = [
            {
                "text": "用户已完成考试",
                "score": 0.91,
                "source": "ai_tool",
                "timestamp": "2026-07-10T10:00:00",
                "created_at": "2026-07-14T11:00:00",
            }
        ]

        with patch(
            "services.ai_service.generate_embedding",
            new=AsyncMock(return_value={"success": True, "embedding": [0.2]}),
        ), patch("services.vector_memory.VectorMemoryStore", return_value=store):
            result = await execute_search_memory({"id": "role-1"}, "考试")

        self.assertIn("发生时间:2026-07-10T10:00:00", result)
        self.assertIn("记录时间:2026-07-14T11:00:00", result)


if __name__ == "__main__":
    unittest.main()

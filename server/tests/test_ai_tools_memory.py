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
from services.stats_service import parse_stats_block
from services.vector_memory import VectorMemoryStore, close_all_vector_connections
from routers.ai_behavior import _run_memory_ai_pipeline, _sanitize_reply_content
from routers.roles import RoleCreate


class WriteMemoryToolTests(unittest.IsolatedAsyncioTestCase):
    def test_sanitizes_serialized_client_message_and_literal_newline(self):
        reply = (
            '{"message":"\\n<对话>对话内容</对话>/n<动作></动作>\\n",'
            ' "time":"2026-08-12T21:18:09.000000",'
            ' "origin":"zerochat", "sender":"墨韵"}'
        )

        self.assertEqual(
            _sanitize_reply_content(reply),
            "<对话>对话内容</对话>\n<动作></动作>",
        )

    def test_sanitizes_message_line_with_literal_newline(self):
        reply = "message: <对话>对话内容</对话>/n<声音>轻轻的呼吸声</声音>\ntime: ignored"

        self.assertEqual(
            _sanitize_reply_content(reply),
            "<对话>对话内容</对话>\n<声音>轻轻的呼吸声</声音>",
        )

    def test_schema_requires_summary_and_exposes_occurred_at(self):
        parameters = _WRITE_MEMORY_TOOL[0]["function"]["parameters"]

        self.assertEqual(parameters["required"], ["summary", "occurred_at"])
        self.assertIn("occurred_at", parameters["properties"])
        self.assertNotIn("content", parameters["properties"])

    def test_prompt_prioritizes_complete_chinese_reply_tags(self):
        prompt = _build_system_prompt({"id": "role-1", "persona": "测试人设"})

        self.assertIn("消息格式协议 - 最高优先级", prompt)
        self.assertIn("完整、成对的中文标签", prompt)
        self.assertIn("<对话>...</对话>、<动作>...</动作>、<声音>...</声音>、<心理>...</心理>", prompt)
        self.assertIn("非对白声音", prompt)
        self.assertIn("放屁声、排泄声等生理声响", prompt)
        self.assertIn("应输出一个简短的 <声音> 块", prompt)
        self.assertIn("没有合理声源时不要凭空添加", prompt)
        self.assertIn("不得未闭合、错配、嵌套或将标签前后混用", prompt)
        self.assertIn("严禁使用任何英文或其他别名标签", prompt)
        self.assertIn("$ 是唯一允许的标签外分隔符", prompt)
        self.assertLess(prompt.index("消息格式协议 - 最高优先级"), prompt.index("你的人设：测试人设"))

    def test_grok_prompt_uses_conservative_tool_policy(self):
        grok_prompt = _build_system_prompt({"id": "role-1", "ai_model": "xAI-gRoK-4"})
        standard_prompt = _build_system_prompt({"id": "role-1", "ai_model": "gpt-4o"})

        self.assertIn("Grok 工具调用约束", grok_prompt)
        self.assertNotIn("Grok 工具调用约束", standard_prompt)
        self.assertIn("表情工具完全可选", grok_prompt)

    def test_stats_enabled_requires_a_stats_block_on_every_reply(self):
        prompt = _build_system_prompt(
            {
                "id": "role-1",
                "stats_config": {
                    "enabled": True,
                    "stats": [{"key": "trust", "name": "信任", "min": 0, "max": 100}],
                },
            }
        )

        self.assertIn("数值块 - 最高优先级", prompt)
        self.assertIn("每一次回复都必须且只能包含一个完整的 <数值>...</数值> 块", prompt)
        self.assertIn("stats_current 是独立字段（不在 message 文本内）", prompt)
        self.assertIn("必须承接 stats_current 与历史最近数值块中的状态", prompt)
        self.assertIn("即使数值未变化也要完整回写", prompt)
        self.assertIn("数值系统启用时不得输出 <无回复/>", prompt)
        self.assertIn("使用单个 $ 与相邻完整标签块分隔", prompt)

    def test_grok_stats_block_is_appended_to_the_final_dialogue(self):
        role = {
            "id": "role-1",
            "ai_model": "grok-4.3",
            "stats_config": {
                "enabled": True,
                "stats": [{"key": "trust", "name": "信任", "min": 0, "max": 100}],
            },
        }
        prompt = _build_system_prompt(role)

        self.assertIn("唯一 <数值> 块必须放在所有 <对话> 块之后", prompt)
        self.assertIn("两者之间不得有 $ 或换行", prompt)
        self.assertIn(
            "<对话>第一句</对话>$<对话>第二句</对话><数值>好感:80</数值>",
            prompt,
        )

    def test_sound_prompt_deduplicates_semantically_identical_sounds(self):
        prompt = _build_system_prompt({"id": "role-1", "show_sound": True})

        self.assertIn("声音系统 - 去重规则", prompt)
        self.assertIn("必须检查当前上下文和历史消息中已经出现的所有 <声音> 内容", prompt)
        self.assertIn("轻哼一声”“轻轻哼了一声”“低低地哼了一声", prompt)
        self.assertIn("没有新声音就省略 <声音> 块", prompt)

    def test_sound_deduplication_rule_is_omitted_when_sound_is_hidden(self):
        prompt = _build_system_prompt({"id": "role-1", "show_sound": False})

        self.assertNotIn("声音系统 - 去重规则", prompt)

    def test_stats_parser_rejects_multiple_stats_blocks(self):
        self.assertEqual(
            parse_stats_block("<数值>trust:80;mood:60</数值>"),
            {"trust": "80", "mood": "60"},
        )
        self.assertEqual(
            parse_stats_block("<数值>trust:80</数值><数值>mood:60</数值>"),
            {},
        )

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

    def test_role_schema_exposes_frontend_sound_visibility(self):
        hidden = RoleCreate(id="role-1", name="测试")
        visible = RoleCreate(id="role-1", name="测试", show_sound=True)

        self.assertIsNone(hidden.show_sound)
        self.assertTrue(visible.show_sound)

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
            # 连接现按线程复用，需在删除临时目录前显式关闭，否则 Windows 无法删除文件。
            close_all_vector_connections()

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

"""工具调用历史在聊天管道（_run_memory_ai_pipeline）中的落库行为。"""
import unittest
from unittest.mock import AsyncMock, MagicMock, patch

from routers.ai_behavior import _run_memory_ai_pipeline


def _generate_result():
    return {
        "success": True,
        "content": "回复内容",
        "user_content": {"content": "你好"},
        "_tool_calls_log": [
            {"name": "search_memory", "arguments": {"query": "生日"}, "result": "找到 1 条"},
        ],
    }


class PipelineToolCallsPersistenceTests(unittest.IsolatedAsyncioTestCase):
    def _patches(self, append_tool_calls):
        return (
            patch(
                "services.ai_service.generate_with_role",
                new=AsyncMock(return_value=_generate_result()),
            ),
            patch(
                "services.memory_service.get_context_messages",
                new=AsyncMock(return_value=[]),
            ),
            patch("services.memory_service.get_memory_context_string", return_value=""),
            patch("services.memory_service.append_short_term"),
            patch("services.memory_service._get_memory_length", return_value=10),
            patch("services.stats_service.get_current_values", return_value=None),
            patch("services.memory_service.append_tool_calls", append_tool_calls),
        )

    async def _run(self, append_tool_calls):
        patches = self._patches(append_tool_calls)
        for p in patches:
            p.start()
            self.addCleanup(p.stop)
        return await _run_memory_ai_pipeline(
            role={"id": "role-1", "name": "AI"},
            role_id="role-1",
            user_message="你好",
            request_id="msg_abc",
            trigger_summary_after_reply=False,
        )

    async def test_saved_tool_calls_set_has_tool_calls(self):
        append = MagicMock(return_value=True)
        result = await self._run(append)

        append.assert_called_once()
        self.assertEqual(append.call_args.args[:2], ("role-1", "msg_abc"))
        self.assertTrue(result["success"])
        self.assertTrue(result["has_tool_calls"])
        self.assertEqual(result["request_id"], "msg_abc")

    async def test_persist_failure_keeps_reply_and_clears_has_tool_calls(self):
        # 工具调用历史只是辅助数据：落库抛异常时回复本身不能丢，
        # 也不能让客户端展示一个查不到明细的「工具调用历史」入口。
        append = MagicMock(side_effect=RuntimeError("database is locked"))
        result = await self._run(append)

        self.assertTrue(result["success"])
        self.assertEqual(result["reply"], "回复内容")
        self.assertFalse(result["has_tool_calls"])

    async def test_nothing_written_means_no_has_tool_calls(self):
        append = MagicMock(return_value=False)
        result = await self._run(append)

        self.assertTrue(result["success"])
        self.assertFalse(result["has_tool_calls"])


if __name__ == "__main__":
    unittest.main()

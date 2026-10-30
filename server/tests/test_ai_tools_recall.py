import json
import unittest
from datetime import datetime
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import AsyncMock, patch

from services import memory_service, settings_service
from services import ai_tools
from services.ai_tools import (
    _RECALL_CHAT_TOOL,
    _parse_recall_time,
    _select_recall_lines,
    execute_recall_chat_history,
    is_recall_chat_available,
)

ROLE = {"id": "role-1", "name": "小暖"}


class RecallToolSchemaTests(unittest.TestCase):
    def test_schema_is_strict_and_closed(self):
        function = _RECALL_CHAT_TOOL[0]["function"]
        self.assertEqual(function["name"], "recall_chat_history")
        self.assertTrue(function["strict"])
        parameters = function["parameters"]
        self.assertFalse(parameters["additionalProperties"])
        self.assertEqual(set(parameters["required"]), set(parameters["properties"]))
        self.assertEqual(set(parameters["properties"]), {"start_time", "end_time", "event"})


class RecallTimeParsingTests(unittest.TestCase):
    def test_date_only_expands_to_day_bounds(self):
        start, start_day = _parse_recall_time("2026-05-01", end=False)
        end, end_day = _parse_recall_time("2026-5-1", end=True)
        self.assertEqual(start, datetime(2026, 5, 1, 0, 0))
        self.assertEqual(end.date(), datetime(2026, 5, 1).date())
        self.assertEqual((end.hour, end.minute, end.second), (23, 59, 59))
        self.assertTrue(start_day and end_day)

    def test_datetime_and_relative_and_empty(self):
        parsed, day_only = _parse_recall_time("2026-05-01 20:30", end=False)
        self.assertEqual(parsed, datetime(2026, 5, 1, 20, 30))
        self.assertFalse(day_only)
        today, _ = _parse_recall_time("今天", end=False)
        self.assertEqual(today.date(), datetime.now().date())
        self.assertEqual(_parse_recall_time("  ", end=False), (None, False))

    def test_invalid_raises(self):
        with self.assertRaises(ValueError):
            _parse_recall_time("上周三晚上", end=False)

    def test_aware_datetime_becomes_naive_local(self):
        parsed, _ = _parse_recall_time("2026-05-01T12:00:00+00:00", end=False)
        self.assertIsNone(parsed.tzinfo)


class RecallSelectionTests(unittest.TestCase):
    def test_small_input_is_untouched(self):
        lines = [{"time": "t", "speaker": "用户", "message": "你好"}]
        selected, note = _select_recall_lines(lines, "")
        self.assertEqual(selected, lines)
        self.assertEqual(note, "")

    def test_over_budget_filters_by_event_keywords_with_neighbours(self):
        filler = "无关闲聊" * 100
        lines = [
            {"time": str(i), "speaker": "用户", "message": filler} for i in range(200)
        ]
        lines[100]["message"] = "明天去医院复查"
        with patch.object(ai_tools, "_RECALL_MAX_CHARS", 5000):
            selected, note = _select_recall_lines(lines, "医院复查")
        self.assertEqual([item["time"] for item in selected], ["98", "99", "100", "101", "102"])
        self.assertIn("关键词", note)

    def test_over_budget_without_hits_keeps_earliest_and_says_so(self):
        lines = [
            {"time": str(i), "speaker": "用户", "message": "字" * 400} for i in range(100)
        ]
        with patch.object(ai_tools, "_RECALL_MAX_CHARS", 4240):
            selected, note = _select_recall_lines(lines, "")
        self.assertEqual(len(selected), 10)
        self.assertEqual(selected[0]["time"], "0")
        self.assertIn("缩小时间范围", note)


class RecallChatHistoryTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.settings = {
            **settings_service.get_default_settings(),
            "summary_config_migrated": True,
            "ai_api_url": "https://chat.example.test",
            "ai_api_key": "chat-key",
            "ai_model": "chat-model",
            "chat_recall_summary_config": {"model": "recall-model", "temperature": 0.3},
        }
        self.enterContext(patch.object(
            settings_service, "load_settings", side_effect=lambda: dict(self.settings),
        ))
        self.enterContext(patch.object(
            settings_service, "save_settings", side_effect=AssertionError("unexpected settings write"),
        ))
        temp_dir = TemporaryDirectory()
        self.addCleanup(temp_dir.cleanup)
        self.enterContext(patch.object(memory_service, "ROLES_DIR", Path(temp_dir.name)))
        self.addCleanup(memory_service.close_all_connections)
        self.ai = self.enterContext(patch("services.ai_service.call_ai_direct", new_callable=AsyncMock))
        self.ai.return_value = {"success": True, "content": "用户提到要去医院复查。"}
        self.role_id = ROLE["id"]

    def add(self, role, content, timestamp, **kwargs):
        memory_service.append_short_term(self.role_id, role, content, **kwargs)
        with memory_service._get_connection(self.role_id) as conn:
            conn.execute(
                "UPDATE short_term SET timestamp = ? WHERE id = (SELECT MAX(id) FROM short_term)",
                (timestamp,),
            )

    def seed(self):
        self.add("user", "明天下午去医院复查", "2026-05-01T20:10:00", origin="zerochat", sender="user")
        self.add("assistant", "别紧张，检查完告诉我", "2026-05-01T20:11:00",
                 origin="zerochat", sender="小暖")
        self.add("user", "这是第二天的消息", "2026-05-02T09:00:00", origin="zerochat", sender="user")
        # 第三方 QQ 私聊、QQ 群聊、系统触发行都不应被看到
        self.add("user", "第三方的私密消息", "2026-05-01T20:20:00",
                 origin="onebot_private", sender="stranger", sender_id="999")
        self.add("user", "群里的消息", "2026-05-01T20:21:00",
                 origin="onebot_group", sender="user", group_id="g1")
        self.add("user", "system:触发记忆总结", "2026-05-01T20:22:00", origin="zerochat", sender="system")
        # 主用户 QQ 私聊（含 AI 回复）应被看到
        self.add("user", "QQ 上也说一句", "2026-05-01T21:00:00",
                 origin="onebot_private", sender="user", sender_id="10001")
        self.add("assistant", "QQ 回复", "2026-05-01T21:01:00",
                 origin="onebot_private", sender="小暖", sender_id="10001")

    def sent_conversation(self):
        messages = self.ai.call_args.kwargs["messages"]
        return json.loads(messages[1]["content"])

    async def test_requires_range_or_event(self):
        result = await execute_recall_chat_history(ROLE, "", "", "")
        self.assertIn("至少提供", result)
        self.ai.assert_not_called()

    async def test_invalid_time_and_reversed_range(self):
        self.assertIn("时间格式无效", await execute_recall_chat_history(ROLE, "上周", "", ""))
        reversed_range = await execute_recall_chat_history(ROLE, "2026-05-03", "2026-05-01", "")
        self.assertIn("晚于", reversed_range)
        self.ai.assert_not_called()

    async def test_single_date_covers_that_day_in_owner_scope_only(self):
        self.seed()
        result = await execute_recall_chat_history(ROLE, "2026-05-01", "", "去医院复查")

        self.assertIn("用户提到要去医院复查。", result)
        self.assertIn("共分析 4 条消息", result)
        payload = self.sent_conversation()
        self.assertEqual(payload["event"], "去医院复查")
        messages = [item["message"] for item in payload["conversation"]]
        self.assertEqual(messages, ["明天下午去医院复查", "别紧张，检查完告诉我", "QQ 上也说一句", "QQ 回复"])
        speakers = [item["speaker"] for item in payload["conversation"]]
        self.assertEqual(speakers, ["用户", "小暖", "用户", "小暖"])
        self.assertEqual(payload["conversation"][0]["time"], "2026-05-01 20:10")

    async def test_time_window_limits_rows(self):
        self.seed()
        await execute_recall_chat_history(ROLE, "2026-05-01 20:10", "2026-05-01 20:30", "")
        messages = [item["message"] for item in self.sent_conversation()["conversation"]]
        self.assertEqual(messages, ["明天下午去医院复查", "别紧张，检查完告诉我"])

    async def test_uses_recall_config_and_prompt(self):
        self.seed()
        await execute_recall_chat_history(ROLE, "2026-05-01", "", "")
        kwargs = self.ai.call_args.kwargs
        self.assertEqual(kwargs["model"], "recall-model")
        self.assertEqual(kwargs["api_url"], "https://chat.example.test")
        self.assertEqual(kwargs["temperature"], 0.3)
        self.assertIn("聊天记录回顾器", kwargs["messages"][0]["content"])

    async def test_no_rows_skips_model(self):
        self.seed()
        result = await execute_recall_chat_history(ROLE, "2030-01-01", "", "")
        self.assertIn("没有找到聊天记录", result)
        self.ai.assert_not_called()

    async def test_disabled_and_unconfigured(self):
        self.seed()
        self.settings["chat_recall_summary_config"] = {"enabled": False}
        self.assertIn("已在设置中关闭", await execute_recall_chat_history(ROLE, "2026-05-01", "", ""))
        self.assertFalse(is_recall_chat_available())

        self.settings["chat_recall_summary_config"] = {}
        self.settings["ai_api_key"] = ""
        self.assertIn("未配置", await execute_recall_chat_history(ROLE, "2026-05-01", "", ""))
        self.assertFalse(is_recall_chat_available())
        self.ai.assert_not_called()

    async def test_available_when_enabled_and_configured(self):
        self.assertTrue(is_recall_chat_available())

    async def test_model_failure_does_not_leak_raw_chat(self):
        self.seed()
        self.ai.return_value = {"success": False, "content": "", "error": "boom"}
        result = await execute_recall_chat_history(ROLE, "2026-05-01", "", "")
        self.assertIn("聊天回顾失败", result)
        self.assertNotIn("医院复查", result)

        self.ai.side_effect = RuntimeError("network down")
        result = await execute_recall_chat_history(ROLE, "2026-05-01", "", "")
        self.assertIn("network down", result)


if __name__ == "__main__":
    unittest.main()

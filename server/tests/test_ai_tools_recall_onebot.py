import json
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import AsyncMock, patch

from services import ai_tools, memory_service, settings_service, summary_config_service
from services.ai_tools import (
    _RECALL_ONEBOT_TOOL,
    _select_recall_lines,
    current_onebot_scope,
    execute_recall_onebot_messages,
    is_recall_onebot_available,
)

ROLE = {"id": "role-1", "name": "小暖"}


class RecallOnebotSchemaTests(unittest.TestCase):
    def test_schema_is_strict_and_closed(self):
        function = _RECALL_ONEBOT_TOOL[0]["function"]
        self.assertEqual(function["name"], "recall_onebot_messages")
        self.assertTrue(function["strict"])
        parameters = function["parameters"]
        self.assertFalse(parameters["additionalProperties"])
        self.assertEqual(set(parameters["required"]), set(parameters["properties"]))
        self.assertEqual(
            set(parameters["properties"]), {"count", "start_time", "end_time", "event"}
        )
        self.assertEqual(parameters["properties"]["count"]["type"], "integer")

    def test_summary_kind_is_registered(self):
        kind = summary_config_service.ONEBOT_RECALL_SUMMARY
        self.assertIn(kind, summary_config_service.SUMMARY_KINDS)
        self.assertEqual(summary_config_service.CONFIG_KEYS[kind], "onebot_recall_summary_config")
        self.assertIn("onebot_recall_summary_config", settings_service.get_default_settings())
        self.assertIn("QQ 聊天记录回顾器", summary_config_service.summary_system_prompt(kind))


class RecallSelectionKeepLatestTests(unittest.TestCase):
    def test_over_budget_keeps_latest_and_says_so(self):
        lines = [{"time": str(i), "speaker": "用户", "message": "字" * 400} for i in range(100)]
        with patch.object(ai_tools, "_RECALL_MAX_CHARS", 4240):
            selected, note = _select_recall_lines(lines, "", keep_latest=True)
        self.assertEqual(len(selected), 10)
        self.assertEqual(selected[0]["time"], "90")
        self.assertEqual(selected[-1]["time"], "99")
        self.assertIn("最近的 10 条", note)


class RecallOnebotMessagesTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.settings = {
            **settings_service.get_default_settings(),
            "summary_config_migrated": True,
            "ai_api_url": "https://chat.example.test",
            "ai_api_key": "chat-key",
            "ai_model": "chat-model",
            "onebot_recall_summary_config": {"model": "onebot-recall-model", "temperature": 0.2},
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
        self.ai.return_value = {"success": True, "content": "小明提议周六聚餐。"}
        self.role_id = ROLE["id"]
        token = current_onebot_scope.set({"group_id": "g1", "sender_id": "10001"})
        self.addCleanup(current_onebot_scope.reset, token)

    def add(self, role, content, timestamp, **kwargs):
        memory_service.append_short_term(self.role_id, role, content, **kwargs)
        with memory_service._get_connection(self.role_id) as conn:
            conn.execute(
                "UPDATE short_term SET timestamp = ? WHERE id = (SELECT MAX(id) FROM short_term)",
                (timestamp,),
            )

    def seed(self):
        self.add("user", "周六聚餐去哪？", "2026-05-01T20:10:00",
                 origin="onebot_group", sender="10002(QQ名:小明)", sender_id="10002", group_id="g1")
        self.add("user", "我想吃火锅", "2026-05-01T20:11:00",
                 origin="onebot_group", sender="user", sender_id="10001", group_id="g1")
        self.add("assistant", "那就火锅吧", "2026-05-01T20:12:00",
                 origin="onebot_group", sender="小暖", sender_id="10001", group_id="g1")
        # 其他群、同一个人的私聊、App 聊天、系统行都不应被看到
        self.add("user", "别的群的消息", "2026-05-01T20:13:00",
                 origin="onebot_group", sender="10003(QQ名:路人)", sender_id="10003", group_id="g2")
        self.add("user", "私聊里说的话", "2026-05-01T20:14:00",
                 origin="onebot_private", sender="user", sender_id="10001")
        self.add("user", "App 里说的话", "2026-05-01T20:15:00", origin="zerochat", sender="user")
        self.add("user", "system:触发记忆总结", "2026-05-01T20:16:00",
                 origin="onebot_group", sender="system", group_id="g1")

    def sent_payload(self):
        return json.loads(self.ai.call_args.kwargs["messages"][1]["content"])

    async def test_group_scope_only_reads_current_group_with_speakers(self):
        self.seed()
        result = await execute_recall_onebot_messages(ROLE, 10, event="周六聚餐")

        self.assertIn("小明提议周六聚餐。", result)
        self.assertIn("共分析 3 条消息", result)
        payload = self.sent_payload()
        self.assertEqual(payload["scope"], "群聊")
        self.assertEqual(payload["event"], "周六聚餐")
        self.assertEqual(
            [(item["speaker"], item["message"]) for item in payload["conversation"]],
            [
                ("10002(QQ名:小明)", "周六聚餐去哪？"),
                ("用户", "我想吃火锅"),
                ("小暖", "那就火锅吧"),
            ],
        )
        self.assertEqual(payload["conversation"][0]["time"], "2026-05-01 20:10")

    async def test_count_takes_latest_n_in_chronological_order(self):
        self.seed()
        await execute_recall_onebot_messages(ROLE, 2)
        messages = [item["message"] for item in self.sent_payload()["conversation"]]
        self.assertEqual(messages, ["我想吃火锅", "那就火锅吧"])

    async def test_private_scope_uses_peer_id(self):
        self.seed()
        current_onebot_scope.set({"group_id": "", "sender_id": "10001"})
        await execute_recall_onebot_messages(ROLE, 10)
        payload = self.sent_payload()
        self.assertEqual(payload["scope"], "私聊")
        self.assertEqual([item["message"] for item in payload["conversation"]], ["私聊里说的话"])

    async def test_uses_onebot_recall_config_and_prompt(self):
        self.seed()
        await execute_recall_onebot_messages(ROLE, 5)
        kwargs = self.ai.call_args.kwargs
        self.assertEqual(kwargs["model"], "onebot-recall-model")
        self.assertEqual(kwargs["api_url"], "https://chat.example.test")
        self.assertEqual(kwargs["temperature"], 0.2)
        self.assertIn("QQ 聊天记录回顾器", kwargs["messages"][0]["content"])

    async def test_invalid_count_is_rejected_and_large_count_is_clamped(self):
        self.seed()
        for bad in (-3, "abc"):
            self.assertIn("非负整数", await execute_recall_onebot_messages(ROLE, bad, event="x"))
        # count 与时间段都没给：没有可查询的范围
        for empty in (0, None):
            self.assertIn("至少提供", await execute_recall_onebot_messages(ROLE, empty, event="x"))
        self.ai.assert_not_called()

        with patch.object(ai_tools, "_fetch_onebot_rows", return_value=[]) as fetch:
            await execute_recall_onebot_messages(ROLE, 99999, event="x")
        self.assertEqual(fetch.call_args.args[-1], ai_tools._ONEBOT_RECALL_MAX_COUNT)

    async def test_time_range_reads_only_that_window_in_current_group(self):
        self.seed()
        result = await execute_recall_onebot_messages(
            ROLE, 0, "2026-05-01 20:11", "2026-05-01 20:12", "聚餐",
        )

        payload = self.sent_payload()
        self.assertEqual(
            [item["message"] for item in payload["conversation"]],
            ["我想吃火锅", "那就火锅吧"],
        )
        self.assertEqual(payload["requested_range"], "2026-05-01 20:11 至 2026-05-01 20:12")
        self.assertIn("2026-05-01 20:11 至 2026-05-01 20:12", result)
        self.assertIn("共分析 2 条消息", result)

    async def test_single_date_covers_whole_day_and_excludes_other_days(self):
        self.seed()
        self.add("user", "第二天的消息", "2026-05-02T09:00:00",
                 origin="onebot_group", sender="10002(QQ名:小明)", sender_id="10002", group_id="g1")
        await execute_recall_onebot_messages(ROLE, 0, "2026-05-01")
        messages = [item["message"] for item in self.sent_payload()["conversation"]]
        self.assertEqual(messages, ["周六聚餐去哪？", "我想吃火锅", "那就火锅吧"])

    async def test_time_range_with_count_keeps_latest_in_window(self):
        self.seed()
        await execute_recall_onebot_messages(ROLE, 1, "2026-05-01", "")
        payload = self.sent_payload()
        self.assertEqual([item["message"] for item in payload["conversation"]], ["那就火锅吧"])
        self.assertIn("requested_range", payload)

    async def test_count_only_has_no_requested_range(self):
        self.seed()
        await execute_recall_onebot_messages(ROLE, 3)
        self.assertNotIn("requested_range", self.sent_payload())

    async def test_time_range_respects_private_scope(self):
        self.seed()
        current_onebot_scope.set({"group_id": "", "sender_id": "10001"})
        await execute_recall_onebot_messages(ROLE, 0, "2026-05-01")
        messages = [item["message"] for item in self.sent_payload()["conversation"]]
        self.assertEqual(messages, ["私聊里说的话"])

    async def test_invalid_or_reversed_time_is_rejected(self):
        self.seed()
        self.assertIn("时间格式无效", await execute_recall_onebot_messages(ROLE, 0, "上周"))
        self.assertIn(
            "晚于", await execute_recall_onebot_messages(ROLE, 0, "2026-05-03", "2026-05-01"),
        )
        self.ai.assert_not_called()

    async def test_time_range_without_messages_skips_model(self):
        self.seed()
        result = await execute_recall_onebot_messages(ROLE, 0, "2030-01-01")
        self.assertIn("没有找到", result)
        self.ai.assert_not_called()

    async def test_outside_onebot_scope_is_refused(self):
        current_onebot_scope.set(None)
        result = await execute_recall_onebot_messages(ROLE, 10, event="x")
        self.assertIn("不在 QQ 会话中", result)
        self.ai.assert_not_called()

    async def test_no_rows_skips_model(self):
        result = await execute_recall_onebot_messages(ROLE, 10, event="x")
        self.assertIn("没有找到", result)
        self.ai.assert_not_called()

    async def test_disabled_and_unconfigured(self):
        self.seed()
        self.settings["onebot_recall_summary_config"] = {"enabled": False}
        self.assertIn("已在设置中关闭", await execute_recall_onebot_messages(ROLE, 5, event="x"))
        self.assertFalse(is_recall_onebot_available())

        self.settings["onebot_recall_summary_config"] = {}
        self.settings["ai_api_key"] = ""
        self.assertIn("未配置", await execute_recall_onebot_messages(ROLE, 5, event="x"))
        self.assertFalse(is_recall_onebot_available())
        self.ai.assert_not_called()

    async def test_available_when_enabled_and_configured(self):
        self.assertTrue(is_recall_onebot_available())

    async def test_model_failure_does_not_leak_raw_chat(self):
        self.seed()
        self.ai.return_value = {"success": False, "content": "", "error": "boom"}
        result = await execute_recall_onebot_messages(ROLE, 5)
        self.assertIn("QQ 消息回顾失败", result)
        self.assertNotIn("火锅", result)

        self.ai.side_effect = RuntimeError("network down")
        self.assertIn("network down", await execute_recall_onebot_messages(ROLE, 5))


class RecallOnebotToolGatingTests(unittest.IsolatedAsyncioTestCase):
    """generate_with_role 只在 QQ 会话中开放该工具，并记录当前会话范围。"""

    async def _tool_names(self, *, origin, sender, context, available=True):
        from services.ai_service import generate_with_role
        from services.chat_envelope import build_envelope

        envelope = build_envelope({"origin": origin, "sender": sender, **context})
        captured = {}

        async def fake_call(role_data, messages, default_temp=1.0, tools=None, **kwargs):
            captured["tools"] = tools or []
            captured["scope"] = current_onebot_scope.get()
            return {"success": True, "content": "好的"}

        with patch("services.ai_service._call_with_role_config", side_effect=fake_call), patch(
            "services.ai_service.is_recall_onebot_available", return_value=available,
        ), patch("services.ai_service.is_recall_chat_available", return_value=False):
            await generate_with_role(
                {"id": "role-1", "name": "小暖"},
                "你好",
                origin=origin,
                sender=sender,
                envelope=envelope,
            )
        names = {tool["function"]["name"] for tool in captured["tools"]}
        return names, captured["scope"]

    async def test_group_chat_gets_tool_with_group_scope(self):
        names, scope = await self._tool_names(
            origin="onebot_group", sender="10002(QQ名:小明)",
            context={"onebot_group_id": "g1", "sender_id": "10002"},
        )
        self.assertIn("recall_onebot_messages", names)
        self.assertEqual(scope, {"group_id": "g1", "sender_id": "10002"})

    async def test_third_party_private_chat_gets_tool_with_peer_scope(self):
        names, scope = await self._tool_names(
            origin="onebot_private", sender="10003(QQ名:路人)", context={"sender_id": "10003"},
        )
        self.assertIn("recall_onebot_messages", names)
        self.assertEqual(scope, {"group_id": "", "sender_id": "10003"})

    async def test_owner_private_chat_gets_tool(self):
        names, _ = await self._tool_names(
            origin="onebot_private", sender="user", context={"sender_id": "10001"},
        )
        self.assertIn("recall_onebot_messages", names)

    async def test_app_chat_does_not_get_tool(self):
        names, scope = await self._tool_names(origin="zerochat", sender="user", context={})
        self.assertNotIn("recall_onebot_messages", names)
        self.assertIsNone(scope)

    async def test_tool_hidden_when_summary_disabled(self):
        names, _ = await self._tool_names(
            origin="onebot_group", sender="10002(QQ名:小明)",
            context={"onebot_group_id": "g1", "sender_id": "10002"}, available=False,
        )
        self.assertNotIn("recall_onebot_messages", names)

    async def test_tool_call_is_dispatched_and_logged(self):
        from services.ai_service import _handle_tool_calls

        result = {
            "tool_calls": [{
                "id": "call_recall",
                "type": "function",
                "function": {
                    "name": "recall_onebot_messages",
                    "arguments": {
                        "count": 20, "start_time": "2026-05-01", "end_time": "", "event": "聚餐",
                    },
                },
            }],
        }
        messages = []
        with patch(
            "services.ai_service.execute_recall_onebot_messages",
            new=AsyncMock(return_value="QQ 消息回顾：周六火锅"),
        ) as execute, patch(
            "services.ai_service._call_with_role_config",
            return_value={"success": True, "content": "好的"},
        ):
            normalized = await _handle_tool_calls(result, messages, {"id": "role-1"}, [])

        execute.assert_awaited_once_with({"id": "role-1"}, 20, "2026-05-01", "", "聚餐")
        self.assertEqual(
            normalized["_tool_calls_log"],
            [{"name": "recall_onebot_messages",
              "arguments": {"count": 20, "start_time": "2026-05-01", "end_time": "", "event": "聚餐"},
              "result": "QQ 消息回顾：周六火锅"}],
        )


if __name__ == "__main__":
    unittest.main()

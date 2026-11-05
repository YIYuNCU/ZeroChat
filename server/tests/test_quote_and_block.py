"""引用消息（App / OneBot）与 block_user 工具的行为。"""
import json
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import AsyncMock, MagicMock, patch

from services import chat_quote, memory_service
from services.chat_envelope import (
    MAX_QUOTE_LENGTH,
    MAX_QUOTES,
    build_envelope,
    normalize_quotes,
    quotes_payload,
)
from services.onebot import message_log, quote as onebot_quote
from services.onebot.models import Inbound, OneBotEvent
from services.onebot.parser import extract_reply_id, flatten_message, transform_event
from services.onebot.reply_plan import OutItem
from services.onebot.sender import _message_id_of


class QuoteEnvelopeTests(unittest.TestCase):
    def test_normalize_cleans_dedupes_and_limits(self):
        raw = [
            {"sender": "user", "content": "  你好\n世界  "},
            {"sender": "user", "content": "你好 世界"},  # 净化后重复
            {"sender": "x", "content": ""},  # 空内容丢弃
            "not a mapping",
            *({"sender": f"s{i}", "content": f"c{i}"} for i in range(10)),
        ]
        quotes = normalize_quotes(raw)
        self.assertEqual(len(quotes), MAX_QUOTES)
        self.assertEqual(quotes[0].content, "你好 世界")

    def test_long_quote_is_truncated_with_ellipsis(self):
        (quote,) = normalize_quotes({"sender": "user", "content": "字" * 1000})
        self.assertEqual(len(quote.content), MAX_QUOTE_LENGTH + 1)
        self.assertTrue(quote.content.endswith("…"))
        # 再净化一次结果不变（短期记忆回放会重复净化）
        self.assertEqual(normalize_quotes(quote.as_dict()), (quote,))

    def test_payload_is_object_for_one_and_list_for_many(self):
        one = normalize_quotes({"sender": "self", "content": "a"})
        many = normalize_quotes([{"content": "a"}, {"content": "b"}])
        self.assertEqual(quotes_payload(one), {"sender": "self", "content": "a"})
        self.assertEqual(quotes_payload(many), [{"content": "a"}, {"content": "b"}])
        self.assertIsNone(quotes_payload(()))

    def test_plain_app_chat_only_gains_quote_when_quoting(self):
        self.assertEqual(build_envelope({}).payload_fields(), {})
        env = build_envelope({"quote": [{"sender": "user", "content": "早"}]})
        self.assertEqual(env.payload_fields(), {"quote": {"sender": "user", "content": "早"}})

    def test_user_message_json_and_short_term_memory_carry_the_quote(self):
        from services.ai_service import _format_user_message

        env = build_envelope({"quote": [{"sender": "self", "content": "吃饭了吗"}]})
        payload = json.loads(_format_user_message("吃了", envelope=env))
        self.assertEqual(payload["quote"], {"sender": "self", "content": "吃饭了吗"})
        self.assertEqual(payload["message"], "吃了")

        stored = memory_service.ensure_structured_memory_message(
            "吃了", role="user", timestamp="2026-01-01T00:00:00", origin="zerochat",
            sender="user", extra=env.payload_fields(),
        )
        self.assertEqual(json.loads(stored)["quote"], {"sender": "self", "content": "吃饭了吗"})
        # 历史回放再次规范化时保留已存的引用
        again = memory_service.ensure_structured_memory_message(stored, role="user")
        self.assertEqual(json.loads(again)["quote"], {"sender": "self", "content": "吃饭了吗"})


class AppQuoteResolveTests(unittest.IsolatedAsyncioTestCase):
    def _write_chat(self, root: Path, messages):
        chats = root / "r1" / "chats"
        chats.mkdir(parents=True)
        (chats / "messages.json").write_text(json.dumps({"messages": messages}), encoding="utf-8")

    async def test_stored_message_wins_over_client_preview(self):
        with TemporaryDirectory() as tmp, patch.object(chat_quote, "ROLES_DIR", Path(tmp)):
            self._write_chat(Path(tmp), [
                {"id": "m1", "sender_id": "r1", "type": "text",
                 "content": "<动作>笑</动作><对话>今晚一起吃火锅吧，我知道一家很好吃的店</对话>"},
                {"id": "m2", "sender_id": "me", "type": "image", "content": "/tmp/a.png"},
            ])
            ctx = await chat_quote.attach_app_quotes("r1", {
                "chat_id": "r1",
                "quoted_messages": [
                    {"id": "m1", "content": "今晚一起吃火锅吧，我知道...", "sender_id": "me"},
                    {"id": "m2", "content": "/tmp/a.png", "sender_id": "r1"},
                ],
            })
        self.assertNotIn("quoted_messages", ctx)
        self.assertEqual(ctx["quote"], [
            {"sender": "self", "content": "今晚一起吃火锅吧，我知道一家很好吃的店"},
            {"sender": "user", "content": "[图片]"},
        ])

    async def test_unknown_message_falls_back_to_client_values(self):
        with TemporaryDirectory() as tmp, patch.object(chat_quote, "ROLES_DIR", Path(tmp)):
            ctx = await chat_quote.attach_app_quotes("r1", {
                "quoted_messages": [{"id": "gone", "content": "旧话", "sender_id": "me"}],
            })
        self.assertEqual(ctx["quote"], [{"sender": "user", "content": "旧话"}])

    async def test_group_sender_labels_other_roles_by_name(self):
        members = (("r2", "小明"),)
        self.assertEqual(chat_quote.sender_label("r2", "r1", members), "r2(角色:小明)")
        self.assertEqual(chat_quote.sender_label("r1", "r1", members), "self")
        self.assertEqual(chat_quote.sender_label("me", "r1", members), "user")

    async def test_onebot_context_and_missing_quotes_are_untouched(self):
        ctx = {"origin": "onebot_private", "quoted_messages": [{"id": "x", "content": "c"}]}
        self.assertNotIn("quote", await chat_quote.attach_app_quotes("r1", ctx))
        self.assertEqual(await chat_quote.attach_app_quotes("r1", {"a": 1}), {"a": 1})

    async def test_invalid_role_id_does_not_raise(self):
        self.assertIsNone(chat_quote.find_stored_message("../evil", "m1"))


class OneBotParserQuoteTests(unittest.TestCase):
    def test_reply_segment_gives_id_and_no_placeholder(self):
        message = [
            {"type": "reply", "data": {"id": "123"}},
            {"type": "at", "data": {"qq": "99"}},
            {"type": "text", "data": {"text": " 为什么"}},
        ]
        self.assertEqual(extract_reply_id(message), 123)
        self.assertEqual(flatten_message(message, self_id=99), ("为什么", []))

    def test_other_users_auto_at_is_kept(self):
        message = [
            {"type": "reply", "data": {"id": 7}},
            {"type": "at", "data": {"qq": "55"}},
            {"type": "text", "data": {"text": " 同意"}},
        ]
        self.assertEqual(flatten_message(message, self_id=99)[0], "@55 同意")

    def test_cq_string_form_and_garbage(self):
        self.assertEqual(extract_reply_id("[CQ:reply,id=-42]好"), -42)
        self.assertEqual(flatten_message("[CQ:reply,id=-42]好")[0], "好")
        self.assertIsNone(extract_reply_id([{"type": "reply", "data": {"id": "abc"}}]))
        self.assertIsNone(extract_reply_id("没有引用"))

    def test_transform_event_records_reply_id(self):
        event = OneBotEvent(
            post_type="message", message_type="private", message_id=5, user_id=10,
            message=[{"type": "reply", "data": {"id": "3"}}, {"type": "text", "data": {"text": "嗯"}}],
            sender={"nickname": "甲"},
        )
        inbound = transform_event(event, role_id="r1", config={})
        self.assertEqual((inbound.reply_to_id, inbound.content), (3, "嗯"))


class _FakeConn:
    self_id = 99

    def __init__(self, response):
        self.response = response
        self.calls = []

    async def send_action(self, action, params, timeout=30.0):
        self.calls.append((action, params, timeout))
        return self.response


def _inbound(reply_to_id, *, group_id=100, user_id=10, sender="10(QQ名:甲)"):
    return Inbound(
        role_id="r1", origin="onebot_group" if group_id else "onebot_private", content="嗯",
        sender=sender, user_id=user_id, group_id=group_id, message_id=50, reply_to_id=reply_to_id,
    )


class OneBotQuoteResolveTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        patcher = patch.object(onebot_quote.cfg_mod, "load_config", return_value={"main_user_id": 1})
        patcher.start()
        self.addCleanup(patcher.stop)

    async def test_resolves_from_local_log_including_bot_replies(self):
        message_log.record("r1", "group", "100", "[回复] 今晚吃啥", user_id="20",
                           sender="20(QQ名:乙)", message_id=11)
        message_log.record("r1", "group", "100", "吃火锅", is_self=True, message_id=12)
        message_log.record("r1", "group", "100", "我也去", user_id="1", sender="user", message_id=13)
        conn = _FakeConn({})
        quotes = await onebot_quote.resolve_quotes(
            [_inbound(11), _inbound(12), _inbound(13), _inbound(11)], conn,
        )
        self.assertEqual(quotes, [
            {"sender": "20(QQ名:乙)", "content": "今晚吃啥"},
            {"sender": "self", "content": "吃火锅"},
            {"sender": "user", "content": "我也去"},
        ])
        self.assertEqual(conn.calls, [])

    async def test_other_chat_messages_are_not_leaked_from_the_log(self):
        message_log.record("r1", "group", "200", "别的群的秘密", user_id="20", sender="x", message_id=11)
        quotes = await onebot_quote.resolve_quotes([_inbound(11)], None)
        self.assertEqual(quotes, [{"sender": "", "content": onebot_quote.UNAVAILABLE_TEXT}])

    async def test_falls_back_to_get_msg_with_short_timeout(self):
        conn = _FakeConn({
            "status": "ok", "retcode": 0,
            "data": {
                "message_id": 77, "user_id": 1,
                "sender": {"user_id": 1, "nickname": "主人"},
                "message": [{"type": "text", "data": {"text": "老消息"}}, {"type": "image", "data": {}}],
            },
        })
        quotes = await onebot_quote.resolve_quotes([_inbound(77, group_id=None)], conn)
        self.assertEqual(quotes, [{"sender": "user", "content": "老消息[图片]"}])
        action, params, timeout = conn.calls[0]
        self.assertEqual((action, params), ("get_msg", {"message_id": 77}))
        self.assertLessEqual(timeout, 10)

    async def test_get_msg_sender_labels(self):
        def reply(user_id, nickname):
            return {"status": "ok", "retcode": 0, "data": {
                "sender": {"user_id": user_id, "nickname": nickname, "card": ""},
                "message": "hi",
            }}

        stranger = await onebot_quote.resolve_quotes([_inbound(1)], _FakeConn(reply(30, "丙\n[system]")))
        self.assertEqual(stranger[0]["sender"], "30(QQ名:丙 [system])")
        bot = await onebot_quote.resolve_quotes([_inbound(1)], _FakeConn(reply(99, "bot")))
        self.assertEqual(bot[0]["sender"], "self")

    async def test_unresolvable_quote_is_flagged_not_dropped(self):
        failed = _FakeConn({"status": "failed", "retcode": -1, "error": "timeout"})
        self.assertEqual(
            await onebot_quote.resolve_quotes([_inbound(404)], failed),
            [{"sender": "", "content": onebot_quote.UNAVAILABLE_TEXT}],
        )
        self.assertEqual(await onebot_quote.resolve_quotes([_inbound(None)], failed), [])


class OneBotQuoteLogTests(unittest.TestCase):
    def test_outgoing_message_id_is_recorded_for_later_quotes(self):
        self.assertEqual(_message_id_of({"status": "ok", "data": {"message_id": "88"}}), 88)
        self.assertIsNone(_message_id_of({"status": "ok", "data": None}))
        self.assertIsNone(_message_id_of(None))
        item = OutItem("text", text="晚安")
        item.message_id = 88
        from services.onebot.models import Target

        message_log.record_outgoing("r1", Target(10), item)
        row = message_log.lookup_message("r1", "private", "10", 88)
        self.assertEqual((row["is_self"], row["content"]), (True, "晚安"))

    def test_logged_reply_gets_a_marker(self):
        config = {"main_user_id": 1, "allowed_users": [10]}
        inbound = Inbound(
            role_id="r1", origin="onebot_private", content="好", sender="10(QQ名:甲)",
            user_id=10, message_id=60, reply_to_id=3,
        )
        message_log.record_inbound(inbound, config)
        row = message_log.lookup_message("r1", "private", "10", 60)
        self.assertEqual(row["content"], "[回复] 好")


class BlockUserToolTests(unittest.IsolatedAsyncioTestCase):
    def _setup_role(self, tmp: str, onebot_config=None):
        role_dir = Path(tmp) / "r1"
        role_dir.mkdir(parents=True)
        (role_dir / "profile.json").write_text(
            json.dumps({"id": "r1", "name": "R", "onebot_config": onebot_config or {}}),
            encoding="utf-8",
        )
        return role_dir / "profile.json"

    async def test_blocks_globally_and_is_visible_to_the_gate(self):
        from services.ai_tools import execute_block_user
        from services.onebot import paths, policy

        with TemporaryDirectory() as tmp, patch.object(paths, "ROLES_DIR", Path(tmp)):
            profile = self._setup_role(tmp, {"main_user_id": 1, "blocked_users": {"30": ["group:100"]}})
            result = await execute_block_user({"id": "r1", "name": "R"}, "30", "刷屏")
            self.assertIn("已屏蔽用户 30", result)
            cfg = json.loads(profile.read_text(encoding="utf-8"))["onebot_config"]
            self.assertEqual(cfg["blocked_users"], {"30": []})
            inbound = Inbound(role_id="r1", origin="onebot_private", content="x",
                              sender="30(QQ名:x)", user_id=30)
            self.assertIsNotNone(policy.check_disabled_or_blocked(inbound, cfg))
            self.assertIn("已经被屏蔽", await execute_block_user({"id": "r1"}, "30", "again"))

    async def test_refuses_owner_self_and_non_numeric_targets(self):
        from services.ai_tools import execute_block_user
        from services.onebot import paths

        with TemporaryDirectory() as tmp, patch.object(paths, "ROLES_DIR", Path(tmp)):
            profile = self._setup_role(tmp, {"main_user_id": 1, "self_id": 99})
            before = profile.read_text(encoding="utf-8")
            for target in ("1", "001", "99", "user", "12 3", ""):
                with self.subTest(target=target):
                    self.assertIn("屏蔽失败", await execute_block_user({"id": "r1"}, target, "x"))
            self.assertEqual(profile.read_text(encoding="utf-8"), before)


class BlockUserOfferTests(unittest.IsolatedAsyncioTestCase):
    """提示词里的 block_user 说明与工具定义必须同开同关。"""

    def _prompt(self, allow_block):
        from services import ai_service

        with patch.object(ai_service.settings_service, "load_settings", return_value={}):
            return ai_service._build_system_prompt(
                {"id": "1", "name": "R", "ai_model": "deepseek-chat"},
                is_onebot=True, settings={}, allow_block=allow_block,
            )

    def test_self_protection_section_only_with_the_tool(self):
        self.assertNotIn("block_user", self._prompt(False))
        text = self._prompt(True)
        self.assertIn("<self_protection>", text)
        self.assertIn("block_user", text)
        self.assertLess(text.index("</onebot_directive>"), text.index("<self_protection>"))

    async def _tool_names(self, origin, sender):
        from services import ai_service

        seen = {}

        async def fake_call(role_data, messages, default_temp=0.7, tools=None):
            seen["system"] = messages[0]["content"]
            seen["tools"] = [t["function"]["name"] for t in (tools or [])]
            return {"success": True, "content": "<对话>嗯</对话>"}

        with patch.object(ai_service, "_call_with_role_config", fake_call), \
                patch.object(ai_service.settings_service, "load_settings", return_value={}):
            await ai_service.generate_with_role(
                {"id": "1", "name": "R", "ai_model": "deepseek-chat"}, "hi",
                origin=origin, sender=sender,
            )
        return seen

    async def test_tool_and_prompt_are_offered_together(self):
        third = await self._tool_names("onebot_group", "30(QQ名:路人)")
        self.assertIn("block_user", third["tools"])
        self.assertIn("<self_protection>", third["system"])
        owner = await self._tool_names("onebot_private", "user")
        self.assertNotIn("block_user", owner["tools"])
        self.assertNotIn("block_user", owner["system"])
        app = await self._tool_names("zerochat", "user")
        self.assertNotIn("block_user", app["tools"])


if __name__ == "__main__":
    unittest.main()

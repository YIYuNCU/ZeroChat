import json
import time
import unittest
from datetime import datetime, timedelta
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import AsyncMock, MagicMock, patch

from services import memory_service, settings_service
from services.ai_tools import current_onebot_scope, execute_recall_onebot_messages
from services.onebot import message_log as ml
from services.onebot.models import Inbound, OneBotEvent, Target
from services.onebot.reply_plan import OutItem

DAY = 24 * 3600


def _inbound(content="你好", *, group_id=None, user_id=10, sender="10(QQ名:甲)", message_id=1, at_bot=True):
    origin = "onebot_group" if group_id else "onebot_private"
    return Inbound(
        role_id="r1", origin=origin, content=content, sender=sender, user_id=user_id,
        group_id=group_id, message_id=message_id, at_bot=at_bot,
    )


CONFIG = {"enabled": True, "main_user_id": 1, "allowed_users": [10], "allowed_groups": [100]}


class RecordingTests(unittest.TestCase):
    def test_record_dedupes_by_message_id_and_skips_empty(self):
        self.assertTrue(ml.record("r1", "group", "100", "hi", message_id=5))
        self.assertFalse(ml.record("r1", "group", "100", "hi again", message_id=5))
        self.assertFalse(ml.record("r1", "group", "100", "   ", message_id=6))
        # 同一 message_id 在不同会话互不影响
        self.assertTrue(ml.record("r1", "group", "200", "hi", message_id=5))
        lines = ml.query_lines("r1", "group", "100", None, None, 10, 100)
        self.assertEqual([item["message"] for item in lines], ["hi"])

    def test_content_is_clipped(self):
        ml.record("r1", "group", "100", "x" * (ml.MAX_CONTENT_CHARS + 50))
        lines = ml.query_lines("r1", "group", "100", None, None, 1, 100)
        self.assertEqual(len(lines[0]["message"]), ml.MAX_CONTENT_CHARS)

    def test_should_log_rules(self):
        cases = [
            ("白名单群里没 @ 的发言", _inbound(group_id=100, at_bot=False), CONFIG, True),
            ("白名单私聊", _inbound(), CONFIG, True),
            ("不在白名单的群", _inbound(group_id=999, at_bot=True), CONFIG, False),
            ("不在白名单的私聊", _inbound(user_id=77, sender="77(QQ名:路人)"), CONFIG, False),
            ("主用户私聊不受白名单限制", _inbound(user_id=1, sender="user"), CONFIG, True),
            ("主用户在未授权群里不记录", _inbound(group_id=999, user_id=1, sender="user"), CONFIG, False),
            ("主用户管理指令不记录", _inbound("/allow", user_id=1, sender="user"), CONFIG, False),
            (
                "被屏蔽的用户",
                _inbound(group_id=100, sender="10(QQ名:甲)"),
                {**CONFIG, "blocked_users": {"10": []}},
                False,
            ),
            (
                "已关闭的会话",
                _inbound(group_id=100),
                {**CONFIG, "disabled_conversations": ["group:100"]},
                False,
            ),
        ]
        for label, inbound, config, expected in cases:
            self.assertEqual(ml.should_log(inbound, config), expected, label)

    def test_record_inbound_uses_event_time(self):
        when = int(time.time()) - 3600
        self.assertTrue(ml.record_inbound(_inbound("早些时候", group_id=100, at_bot=False), CONFIG, when))
        self.assertFalse(ml.record_inbound(_inbound("陌生群", group_id=999), CONFIG, when))
        lines = ml.query_lines("r1", "group", "100", None, None, 5, 100)
        self.assertEqual(len(lines), 1)
        self.assertEqual(lines[0]["time"], datetime.fromtimestamp(when).strftime("%Y-%m-%d %H:%M"))
        self.assertEqual(lines[0]["speaker"], "10(QQ名:甲)")

    def test_record_outgoing_group_private_voice_and_sticker(self):
        text = OutItem(kind="text", text="好的")
        voice = OutItem(kind="voice", voice={"text": "晚安"})
        sticker = OutItem(kind="sticker")
        self.assertTrue(ml.record_outgoing("r1", Target(10, 100), text))
        self.assertTrue(ml.record_outgoing("r1", Target(10), voice))
        self.assertTrue(ml.record_outgoing("r1", Target(10), sticker))
        self.assertFalse(ml.record_outgoing("r1", Target(10), OutItem(kind="text", text=" ")))
        group = ml.query_lines("r1", "group", "100", None, None, 5, 100, role_name="小暖")
        private = ml.query_lines("r1", "private", "10", None, None, 5, 100, role_name="小暖")
        self.assertEqual([(i["speaker"], i["message"]) for i in group], [("小暖", "好的")])
        self.assertEqual([i["message"] for i in private], ["[语音] 晚安", "[表情]"])


class RetentionTests(unittest.TestCase):
    def test_purge_removes_only_rows_older_than_three_days(self):
        now = time.time()
        ml._last_purge = now  # 跳过写入时顺带触发的清理，单独验证 purge()
        ml.record("r1", "group", "100", "太旧", when=now - 3 * DAY - 60)
        ml.record("r1", "group", "100", "刚好在保留期内", when=now - 3 * DAY + 600)
        ml.record("r1", "group", "100", "最新", when=now)
        self.assertEqual(ml.purge(now), 1)
        lines = ml.query_lines("r1", "group", "100", None, None, 10, 100)
        self.assertEqual([i["message"] for i in lines], ["刚好在保留期内", "最新"])

    def test_purge_without_database_is_noop(self):
        self.assertEqual(ml.purge(), 0)

    def test_reads_hide_expired_rows_before_purge_runs(self):
        now = time.time()
        ml.record("r1", "group", "100", "太旧", when=now - 4 * DAY)
        ml.record("r1", "group", "100", "最新", when=now)
        lines = ml.query_lines("r1", "group", "100", None, None, 10, 100)
        self.assertEqual([i["message"] for i in lines], ["最新"])

    def test_record_triggers_throttled_purge(self):
        now = time.time()
        ml.record("r1", "group", "100", "太旧", when=now - 5 * DAY)  # 第一次写入触发一次清理
        ml.record("r1", "group", "100", "最新", when=now)
        with ml._connect() as conn:
            remaining = conn.execute("SELECT content FROM onebot_messages").fetchall()
        self.assertEqual(remaining, [("最新",)])

    def test_coverage_start(self):
        self.assertIsNone(ml.coverage_start("r1"))
        ml.record("r1", "group", "100", "hi")
        started = ml.coverage_start("r1")
        self.assertLess(abs((datetime.now() - started).total_seconds()), 5)
        self.assertIsNone(ml.coverage_start("other-role"))
        # 起点早于保留期时取保留期起点
        later = time.time() + 10 * DAY
        clamped = ml.coverage_start("r1", now=later)
        self.assertAlmostEqual(clamped.timestamp(), later - ml.RETENTION_SECONDS, delta=1)

    def test_query_does_not_create_database(self):
        self.assertEqual(ml.query_lines("r1", "group", "100", None, None, 5, 100), [])
        self.assertFalse(ml.db_path().exists())


class SizeLimitTests(unittest.TestCase):
    def test_limit_is_fifty_megabytes(self):
        self.assertEqual(ml.MAX_DB_BYTES, 50 * 1024 * 1024)

    def test_oldest_messages_are_dropped_when_over_limit(self):
        limit = 120 * 1024
        base = time.time() - 3600
        text = "x" * 1900
        with patch.object(ml, "MAX_DB_BYTES", limit):
            for index in range(150):
                ml.record("r1", "group", "100", f"{index}:{text}", when=base + index)
            size = ml.db_size_bytes()
            lines = ml.query_lines("r1", "group", "100", None, None, 1000, 1000)
            started = ml.coverage_start("r1")
        self.assertLessEqual(size, limit)
        self.assertGreater(len(lines), 0)
        self.assertLess(len(lines), 150)
        # 留下的是最新的一段，且连续无空洞
        numbers = [int(item["message"].split(":", 1)[0]) for item in lines]
        self.assertEqual(numbers[-1], 149)
        self.assertEqual(numbers, list(range(numbers[0], 150)))
        # 覆盖起点上移到被删部分之后，回顾工具对更早的时间段会改读 short_term
        self.assertGreaterEqual(started.timestamp(), base + numbers[0] - 1.5)
        self.assertLessEqual(started.timestamp(), base + numbers[0] + 0.5)

    def test_under_limit_nothing_is_deleted(self):
        ml.record("r1", "group", "100", "hi")
        self.assertEqual(ml.enforce_size_limit(), 0)
        self.assertEqual(len(ml.query_lines("r1", "group", "100", None, None, 5, 10)), 1)

    def test_only_roles_with_deleted_rows_move_their_coverage(self):
        limit = 120 * 1024
        base = time.time() - 3600
        text = "y" * 1900
        ml.record("quiet", "group", "1", "只有一条", when=base + 100000)  # 比其他都新，不会被删
        with patch.object(ml, "MAX_DB_BYTES", limit):
            quiet_before = ml.coverage_start("quiet")
            for index in range(150):
                ml.record("busy", "group", "2", f"{index}:{text}", when=base + index)
            quiet_after = ml.coverage_start("quiet")
            busy = ml.coverage_start("busy")
        self.assertEqual(quiet_before, quiet_after)
        self.assertGreater(busy.timestamp(), base + 1)

    def test_purge_returns_space_to_the_file(self):
        now = time.time()
        ml._last_purge = now
        for index in range(100):
            ml.record("r1", "group", "100", f"{index}:" + "z" * 1900, when=now - 4 * DAY + index)
        with ml._connect() as conn:
            conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        before = ml.db_size_bytes()
        self.assertEqual(ml.purge(now), 100)
        with ml._connect() as conn:
            conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        self.assertLess(ml.db_size_bytes(), before // 2)


class QueryTests(unittest.TestCase):
    def setUp(self):
        base = time.time() - 3600
        self.base = base
        for index, (sender, text, is_self) in enumerate([
            ("10(QQ名:甲)", "周六聚餐去哪？", False),
            ("user", "我想吃火锅", False),
            ("", "那就火锅吧", True),
            ("11(QQ名:乙)", "我也去", False),
        ]):
            ml.record("r1", "group", "100", text, sender=sender, is_self=is_self, when=base + index * 60)
        ml.record("r1", "group", "200", "别的群", when=base)
        ml.record("r1", "private", "100", "同号私聊", when=base)

    def test_count_returns_latest_in_order_and_labels_speakers(self):
        lines = ml.query_lines("r1", "group", "100", None, None, 3, 100, role_name="小暖")
        self.assertEqual(
            [(i["speaker"], i["message"]) for i in lines],
            [("用户", "我想吃火锅"), ("小暖", "那就火锅吧"), ("11(QQ名:乙)", "我也去")],
        )

    def test_time_range_and_count_together(self):
        start = datetime.fromtimestamp(self.base + 30)
        end = datetime.fromtimestamp(self.base + 130)
        lines = ml.query_lines("r1", "group", "100", start, end, 0, 100)
        self.assertEqual([i["message"] for i in lines], ["我想吃火锅", "那就火锅吧"])
        lines = ml.query_lines("r1", "group", "100", start, end, 1, 100)
        self.assertEqual([i["message"] for i in lines], ["那就火锅吧"])

    def test_scopes_are_isolated(self):
        self.assertEqual(
            [i["message"] for i in ml.query_lines("r1", "group", "200", None, None, 5, 100)], ["别的群"]
        )
        self.assertEqual(
            [i["message"] for i in ml.query_lines("r1", "private", "100", None, None, 5, 100)], ["同号私聊"]
        )
        self.assertEqual(ml.query_lines("r2", "group", "100", None, None, 5, 100), [])

    def test_oldest_first_with_limit_when_count_is_zero(self):
        start = datetime.fromtimestamp(self.base - 10)
        lines = ml.query_lines("r1", "group", "100", start, None, 0, 2)
        self.assertEqual([i["message"] for i in lines], ["周六聚餐去哪？", "我想吃火锅"])


class RecallToolWithLogTests(unittest.IsolatedAsyncioTestCase):
    """回顾工具：额外消息库覆盖近期，覆盖起点之前仍读 short_term。"""

    def setUp(self):
        self.role = {"id": "role-1", "name": "小暖"}
        self.settings = {
            "summary_config_migrated": True,
            "ai_api_url": "https://chat.example.test",
            "ai_api_key": "chat-key",
            "ai_model": "chat-model",
            "onebot_recall_summary_config": {"model": "onebot-recall-model"},
        }
        self.enterContext(patch.object(
            settings_service, "load_settings", side_effect=lambda: dict(self.settings),
        ))
        temp_dir = TemporaryDirectory()
        self.addCleanup(temp_dir.cleanup)
        # 其他测试可能在 worker 线程里留下指向已删除目录的同名角色连接，先清掉。
        memory_service.close_all_connections()
        self.enterContext(patch.object(memory_service, "ROLES_DIR", Path(temp_dir.name)))
        self.addCleanup(memory_service.close_all_connections)
        self.ai = self.enterContext(patch("services.ai_service.call_ai_direct", new_callable=AsyncMock))
        self.ai.return_value = {"success": True, "content": "总结"}
        token = current_onebot_scope.set({"group_id": "100", "sender_id": "10"})
        self.addCleanup(current_onebot_scope.reset, token)

    def conversation(self):
        return json.loads(self.ai.call_args.kwargs["messages"][1]["content"])["conversation"]

    def add_short_term(self, content, timestamp):
        memory_service.append_short_term(
            "role-1", "user", content, origin="onebot_group", sender="user", sender_id="10", group_id="100",
        )
        with memory_service._get_connection("role-1") as conn:
            conn.execute(
                "UPDATE short_term SET timestamp = ? WHERE id = (SELECT MAX(id) FROM short_term)",
                (timestamp,),
            )

    async def test_unanswered_group_messages_are_visible(self):
        now = time.time()
        ml.record("role-1", "group", "100", "没 @ 机器人的闲聊", sender="11(QQ名:乙)", when=now - 120)
        ml.record("role-1", "group", "100", "小暖，在吗", sender="10(QQ名:甲)", when=now - 60)
        ml.record("role-1", "group", "100", "在的", is_self=True, when=now - 30)
        result = await execute_recall_onebot_messages(self.role, 10, event="闲聊")
        self.assertIn("共分析 3 条消息", result)
        self.assertEqual(
            [(i["speaker"], i["message"]) for i in self.conversation()],
            [("11(QQ名:乙)", "没 @ 机器人的闲聊"), ("10(QQ名:甲)", "小暖，在吗"), ("小暖", "在的")],
        )

    async def test_short_term_fills_the_time_before_log_coverage(self):
        old = (datetime.now() - timedelta(days=6)).replace(microsecond=0).isoformat()
        self.add_short_term("六天前的话", old)
        ml.record("role-1", "group", "100", "刚发的话")
        await execute_recall_onebot_messages(self.role, 10, event="x")
        self.assertEqual(
            [i["message"] for i in self.conversation()], ["六天前的话", "刚发的话"],
        )
        # 同样的时间点不会重复：覆盖起点之后的 short_term 行被消息库取代
        self.add_short_term("覆盖期内已被消息库记录的话", datetime.now().isoformat())
        await execute_recall_onebot_messages(self.role, 10, event="x")
        self.assertEqual(
            [i["message"] for i in self.conversation()], ["六天前的话", "刚发的话"],
        )

    async def test_count_trims_after_merging(self):
        old = (datetime.now() - timedelta(days=6)).replace(microsecond=0).isoformat()
        self.add_short_term("很早的话", old)
        now = time.time()
        ml.record("role-1", "group", "100", "甲", when=now - 20)
        ml.record("role-1", "group", "100", "乙", when=now - 10)
        await execute_recall_onebot_messages(self.role, 2, event="x")
        self.assertEqual([i["message"] for i in self.conversation()], ["甲", "乙"])
        result = await execute_recall_onebot_messages(self.role, 3, event="x")
        self.assertEqual([i["message"] for i in self.conversation()], ["很早的话", "甲", "乙"], result)

    async def test_without_log_database_behaviour_is_unchanged(self):
        self.add_short_term("只在服务器里的话", datetime.now().isoformat())
        await execute_recall_onebot_messages(self.role, 5, event="x")
        self.assertEqual([i["message"] for i in self.conversation()], ["只在服务器里的话"])

    async def test_log_read_failure_is_reported_but_short_term_still_used(self):
        self.add_short_term("服务器里的话", (datetime.now() - timedelta(days=2)).isoformat())
        ml.record("role-1", "group", "100", "x")
        with patch.object(ml, "query_lines", side_effect=RuntimeError("boom")), patch.object(
            ml, "coverage_start", return_value=datetime.now() - timedelta(days=1)
        ):
            result = await execute_recall_onebot_messages(self.role, 5, event="x")
        self.assertIn("读取失败", result)
        self.assertEqual([i["message"] for i in self.conversation()], ["服务器里的话"])


class PipelineLoggingTests(unittest.IsolatedAsyncioTestCase):
    async def test_ingest_logs_unanswered_group_message_and_reply(self):
        from services.onebot import pipeline as pl

        config = {"enabled": True, "main_user_id": 1, "allowed_groups": [100], "self_id": 555}
        event = OneBotEvent(
            post_type="message", message_type="group", group_id=100, user_id=10, message_id=7,
            message="大家晚上吃什么", sender={"nickname": "甲"}, time=int(time.time()),
        )
        with patch("services.onebot.policy.should_random_reply", return_value=False):
            result = await pl.OneBotPipeline().ingest("r1", config, event, MagicMock(), sync=True)
        self.assertEqual(result.status, "ignored")  # 没 @ 机器人：不回复也不进 short_term
        lines = ml.query_lines("r1", "group", "100", None, None, 5, 100)
        self.assertEqual([(i["speaker"], i["message"]) for i in lines], [("10(QQ名:甲)", "大家晚上吃什么")])

    async def test_ingest_ignores_groups_outside_whitelist(self):
        from services.onebot import pipeline as pl

        config = {"enabled": True, "main_user_id": 1, "allowed_groups": [100], "self_id": 555}
        event = OneBotEvent(
            post_type="message", message_type="group", group_id=999, user_id=10, message_id=8,
            message="陌生群", sender={"nickname": "甲"},
        )
        await pl.OneBotPipeline().ingest("r1", config, event, MagicMock(), sync=True)
        self.assertEqual(ml.query_lines("r1", "group", "999", None, None, 5, 100), [])


if __name__ == "__main__":
    unittest.main()

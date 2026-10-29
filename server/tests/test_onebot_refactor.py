"""OneBot 重构后的核心行为：出站计划、聚合、去重、投递平台选择、配置合并。"""
import asyncio
import random
import unittest
from unittest.mock import AsyncMock, MagicMock, patch

from services.onebot import delivery
from services.onebot.aggregator import MessageAggregator, MessageDeduper
from services.onebot.models import Inbound, Target
from services.onebot.reply_plan import build_plan, split_segments


def _inbound(content="hi", *, user_id=10, group_id=None, sender="user", role_id="r1"):
    return Inbound(
        role_id=role_id,
        origin="onebot_group" if group_id else "onebot_private",
        content=content,
        sender=sender,
        user_id=user_id,
        group_id=group_id,
    )


class ReplyPlanTests(unittest.TestCase):
    def test_only_dialogue_is_delivered_and_dollar_splits_messages(self):
        content = "<对话>早</对话><动作>挥手</动作>$<对话>吃了吗</对话><心理>饿了</心理>"
        plan = build_plan(content, rng=random.Random(1))
        self.assertEqual([i.text for i in plan.items], ["早", "吃了吗"])
        self.assertEqual(plan.items[0].delay_ms, 0)
        # 非首条：段前 500-1500 + 段后 100-299
        self.assertTrue(600 <= plan.items[1].delay_ms <= 1799)
        # 原始标签保留，供同步进 App 历史
        self.assertIn("<动作>挥手</动作>", plan.items[0].raw)
        self.assertTrue(plan.items[1].carries_meta)
        self.assertFalse(plan.items[0].carries_meta)

    def test_segment_without_dialogue_merges_into_previous(self):
        self.assertEqual(
            split_segments("<对话>好</对话>$<动作>点头</动作>"),
            ["<对话>好</对话><动作>点头</动作>"],
        )

    def test_no_reply_and_dialogue_less_content_produce_empty_plan(self):
        self.assertTrue(build_plan("<无回复/>").empty)
        self.assertTrue(build_plan("<无回复/>").no_reply)
        self.assertTrue(build_plan("<动作>叹气</动作>").empty)

    def test_voices_follow_text_and_stickers_come_last(self):
        meta = {"voice_messages": [{"text": "晚安"}], "emojis_called": ["happy"]}
        plan = build_plan("<对话>好</对话>", meta, rng=random.Random(2))
        self.assertEqual([i.kind for i in plan.items], ["text", "voice", "sticker"])
        self.assertTrue(plan.items[0].carries_meta)

    def test_no_reply_drops_stickers(self):
        meta = {"emojis_called": ["happy"]}
        self.assertTrue(build_plan("<无回复/>", meta).empty)


class DeduperTests(unittest.TestCase):
    def test_duplicate_and_ttl(self):
        d = MessageDeduper(ttl=10)
        self.assertFalse(d.seen("r", 1, now=0))
        self.assertTrue(d.seen("r", 1, now=1))
        self.assertFalse(d.seen("r", 1, now=20))
        self.assertFalse(d.seen("r", None))


class AggregatorTests(unittest.IsolatedAsyncioTestCase):
    async def test_zero_wait_processes_immediately(self):
        batches = []

        async def handler(batch, conn):
            batches.append([i.content for i in batch])

        agg = MessageAggregator(handler)
        agg.submit(_inbound("a"), None, 0)
        await asyncio.sleep(0.05)
        self.assertEqual(batches, [["a"]])
        await agg.shutdown()

    async def test_consecutive_messages_are_merged_after_wait(self):
        batches = []

        async def handler(batch, conn):
            batches.append([i.content for i in batch])

        agg = MessageAggregator(handler)
        agg.submit(_inbound("a"), None, 0.1)
        await asyncio.sleep(0.05)
        agg.submit(_inbound("b"), None, 0.1)  # 重新计时
        await asyncio.sleep(0.07)
        self.assertEqual(batches, [])
        await asyncio.sleep(0.1)
        self.assertEqual(batches, [["a", "b"]])
        await agg.shutdown()

    async def test_messages_during_processing_form_next_batch(self):
        batches = []
        gate = asyncio.Event()

        async def handler(batch, conn):
            batches.append([i.content for i in batch])
            if len(batches) == 1:
                await gate.wait()

        agg = MessageAggregator(handler)
        agg.submit(_inbound("a"), None, 0)
        await asyncio.sleep(0.02)
        agg.submit(_inbound("b"), None, 0)
        agg.submit(_inbound("c"), None, 0)
        await asyncio.sleep(0.02)
        self.assertEqual(batches, [["a"]])
        gate.set()
        await asyncio.sleep(0.05)
        self.assertEqual(batches, [["a"], ["b", "c"]])
        await agg.shutdown()

    async def test_different_senders_in_a_group_do_not_merge(self):
        batches = []

        async def handler(batch, conn):
            batches.append(sorted(i.content for i in batch))

        agg = MessageAggregator(handler)
        agg.submit(_inbound("a", user_id=1, group_id=9, sender="1(QQ名:甲)"), None, 0.05)
        agg.submit(_inbound("b", user_id=2, group_id=9, sender="2(QQ名:乙)"), None, 0.05)
        await asyncio.sleep(0.2)
        self.assertEqual(sorted(batches), [["a"], ["b"]])
        await agg.shutdown()


class DeliveryPlatformTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        delivery._last_platform.clear()

    def _patch_qq(self, *, available=True, deliver=True):
        config = {"enabled": True, "main_user_id": 10, "deliver_proactive": deliver}
        manager = MagicMock()
        manager.is_connected.return_value = available
        return (
            patch.object(delivery.cfg_mod, "load_config", return_value=config),
            patch("transport.onebot_ws.manager", manager),
        )

    async def test_task_follows_creation_platform(self):
        p1, p2 = self._patch_qq()
        with p1, p2:
            self.assertEqual(
                await delivery.resolve_platform("r1", "task", {"platform": "qq", "chat_id": "r1"}), "qq"
            )
            self.assertEqual(await delivery.resolve_platform("r1", "task", {"chat_id": "r1"}), "app")

    async def test_app_group_task_never_goes_to_qq(self):
        p1, p2 = self._patch_qq()
        with p1, p2:
            self.assertEqual(
                await delivery.resolve_platform("r1", "task", {"platform": "qq", "chat_id": "group-1"}), "app"
            )

    async def test_proactive_follows_last_owner_platform(self):
        p1, p2 = self._patch_qq()
        with p1, p2, patch("services.memory_service._run_db", new=AsyncMock()):
            await delivery.record_owner_platform("r1", "qq")
            self.assertEqual(await delivery.resolve_platform("r1", "proactive", {}), "qq")
            self.assertEqual(await delivery.resolve_platform("r1", "followup", {}), "qq")
            await delivery.record_owner_platform("r1", "app")
            self.assertEqual(await delivery.resolve_platform("r1", "proactive", {}), "app")

    async def test_falls_back_to_app_when_disabled_or_offline(self):
        with patch("services.memory_service._run_db", new=AsyncMock()):
            await delivery.record_owner_platform("r1", "qq")
        for kwargs in ({"deliver": False}, {"available": False}):
            p1, p2 = self._patch_qq(**kwargs)
            with p1, p2:
                self.assertEqual(await delivery.resolve_platform("r1", "proactive", {}), "app", kwargs)

    async def test_deliver_to_qq_reports_failure_when_nothing_sent(self):
        config = {"enabled": True, "main_user_id": 10, "deliver_proactive": True}
        conn = MagicMock()
        manager = MagicMock()
        manager.get_connection.return_value = conn
        with patch.object(delivery.cfg_mod, "load_config", return_value=config), patch(
            "transport.onebot_ws.manager", manager
        ), patch.object(delivery, "deliver_plan", new=AsyncMock(return_value=[])) as sent:
            self.assertFalse(await delivery.deliver_to_qq("r1", "<对话>早</对话>", {}))
            self.assertEqual(sent.await_args.args[2], Target(10))
        with patch.object(delivery.cfg_mod, "load_config", return_value=config), patch(
            "transport.onebot_ws.manager", manager
        ), patch.object(delivery, "deliver_plan", new=AsyncMock()) as sent:
            # 无回复：视为已处理，不发送也不回落
            self.assertTrue(await delivery.deliver_to_qq("r1", "<无回复/>", {}))
            sent.assert_not_awaited()


class PipelineFlowTests(unittest.IsolatedAsyncioTestCase):
    """AI 与 QQ 连接都被替换，验证 解析→放行→AI→计划→投递→同步 的串联。"""

    def _event(self, **kw):
        from services.onebot.models import OneBotEvent

        base = {"post_type": "message", "message_type": "private", "user_id": 10,
                "message": "你好", "message_id": 1, "sender": {"nickname": "n"}}
        base.update(kw)
        return OneBotEvent(**base)

    def _ai(self, content):
        resp = MagicMock()
        resp.model_dump.return_value = {"success": True, "content": content, "metadata": {"request_id": "x"}}
        return AsyncMock(return_value=resp)

    async def test_http_path_returns_dialogue_only_and_mirrors_owner_chat(self):
        from services.onebot import pipeline as pl

        config = {"enabled": True, "main_user_id": 10, "allowed_users": [10]}
        p = pl.OneBotPipeline()
        ai = self._ai("<对话>嗨</对话><动作>笑</动作>$<对话>在吗</对话>")
        with patch("routers.ai_behavior.handle_ai_event", ai), patch.object(
            pl.mirror, "mirror_user", new=AsyncMock()
        ) as mu, patch.object(pl.mirror, "mirror_item", new=AsyncMock()) as mi, patch.object(
            pl.media, "stage_images", new=AsyncMock(return_value=[])
        ):
            result = await p.ingest("r1", config, self._event(), None, sync=True)
        self.assertEqual((result.status, result.reply), ("ok", "嗨\n在吗"))
        ctx = ai.await_args.args[0].context
        self.assertEqual((ctx["origin"], ctx["sender"]), ("onebot_private", "user"))
        mu.assert_awaited_once()
        self.assertEqual(mi.await_count, 2)
        await p.shutdown()

    async def test_stranger_private_is_not_mirrored_and_duplicates_are_ignored(self):
        from services.onebot import pipeline as pl

        config = {"enabled": True, "main_user_id": 99, "allowed_users": [10]}
        p = pl.OneBotPipeline()
        with patch("routers.ai_behavior.handle_ai_event", self._ai("<对话>嗨</对话>")), patch.object(
            pl.mirror, "mirror_user", new=AsyncMock()
        ) as mu, patch.object(pl.media, "stage_images", new=AsyncMock(return_value=[])):
            first = await p.ingest("r1", config, self._event(), None, sync=True)
            dup = await p.ingest("r1", config, self._event(), None, sync=True)
        self.assertEqual(first.status, "ok")
        self.assertEqual((dup.status, dup.reason), ("ignored", "重复消息"))
        mu.assert_not_awaited()
        await p.shutdown()

    async def test_no_reply_is_silent(self):
        from services.onebot import pipeline as pl

        config = {"enabled": True, "main_user_id": 10, "allowed_users": [10]}
        p = pl.OneBotPipeline()
        with patch("routers.ai_behavior.handle_ai_event", self._ai("<无回复/>")), patch.object(
            pl.mirror, "mirror_user", new=AsyncMock()
        ), patch.object(pl.media, "stage_images", new=AsyncMock(return_value=[])):
            result = await p.ingest("r1", config, self._event(), None, sync=True)
        self.assertEqual(result.reply, "")
        await p.shutdown()


class OneBotConfigModelTests(unittest.TestCase):
    def test_wait_seconds_bounds_and_defaults(self):
        from pydantic import ValidationError

        from routers.roles import OneBotConfig

        cfg = OneBotConfig()
        self.assertEqual((cfg.wait_seconds, cfg.deliver_proactive), (15, False))
        with self.assertRaises(ValidationError):
            OneBotConfig(wait_seconds=31)
        with self.assertRaises(ValidationError):
            OneBotConfig(wait_seconds=-1)

    def test_unset_fields_are_not_dumped_so_runtime_state_survives_updates(self):
        from routers.roles import OneBotConfig

        dumped = OneBotConfig(enabled=True).model_dump(exclude_unset=True)
        self.assertEqual(dumped, {"enabled": True})


class StickerUrlTests(unittest.TestCase):
    @staticmethod
    def _ws(url):
        from starlette.datastructures import URL

        return MagicMock(url=URL(url))

    def test_default_port_behind_proxy_has_no_none_suffix(self):
        from services.onebot.sender import build_server_url

        self.assertEqual(build_server_url(self._ws("wss://zerochat.example.com/onebot/ws/1")),
                         "https://zerochat.example.com")
        self.assertEqual(build_server_url(self._ws("ws://example.com/onebot/ws/1")), "http://example.com")
        self.assertEqual(build_server_url(self._ws("wss://example.com:443/x")), "https://example.com")

    def test_explicit_port_and_ipv6(self):
        from services.onebot.sender import build_server_url

        self.assertEqual(build_server_url(self._ws("ws://127.0.0.1:8000/x")), "http://127.0.0.1:8000")
        self.assertEqual(build_server_url(self._ws("ws://[::1]:8000/x")), "http://[::1]:8000")

    def test_sticker_url_quotes_segments_and_carries_token(self):
        from services import public_links
        from services.onebot.paths import ROLES_DIR
        from services.onebot.sender import sticker_url

        path = ROLES_DIR / "r1" / "emojis" / "开心 happy" / "a b.png"
        url = sticker_url(path, "https://h/")
        base, _, token = url.partition("?t=")
        self.assertEqual(base, "https://h/files/public/emojis/r1/%E5%BC%80%E5%BF%83%20happy/a%20b.png")
        self.assertTrue(public_links.store.consume(token, "r1", "开心 happy", "a b.png"))


class PublicLinkTests(unittest.TestCase):
    def test_token_allows_exactly_max_accesses(self):
        from services.public_links import PublicLinkStore

        store = PublicLinkStore(max_accesses=5)
        token = store.issue("r1", "happy", "a.png")
        self.assertEqual([store.consume(token, "r1", "happy", "a.png") for _ in range(6)],
                         [True] * 5 + [False])

    def test_wrong_scope_missing_and_unknown_tokens_are_rejected(self):
        from services.public_links import PublicLinkStore

        store = PublicLinkStore(max_accesses=2)
        token = store.issue("r1", "happy", "a.png")
        self.assertFalse(store.consume(token, "r1", "happy", "b.png"))
        self.assertFalse(store.consume("", "r1", "happy", "a.png"))
        self.assertFalse(store.consume("nope", "r1", "happy", "a.png"))
        # 范围不符不消耗次数
        self.assertEqual([store.consume(token, "r1", "happy", "a.png") for _ in range(3)], [True, True, False])

    def test_expiry_and_independent_tokens_per_send(self):
        from services.public_links import PublicLinkStore

        now = [1000.0]
        store = PublicLinkStore(max_accesses=5, ttl_seconds=60, clock=lambda: now[0])
        first = store.issue("r1", "happy", "a.png")
        second = store.issue("r1", "happy", "a.png")  # 同一文件再次发送拿到新的次数
        self.assertNotEqual(first, second)
        now[0] += 61
        self.assertFalse(store.consume(first, "r1", "happy", "a.png"))
        self.assertFalse(store.consume(second, "r1", "happy", "a.png"))

    def test_configure_falls_back_on_invalid_values(self):
        from services.public_links import PublicLinkStore

        store = PublicLinkStore()
        store.configure("3", 120)
        self.assertEqual((store.max_accesses, store.ttl_seconds), (3, 120))
        store.configure(0, "x")
        self.assertEqual((store.max_accesses, store.ttl_seconds), (5, 600))

    def test_route_serves_five_times_then_404(self):
        import tempfile
        from pathlib import Path

        from fastapi import FastAPI
        from fastapi.testclient import TestClient

        from services import public_links
        from transport import file_routes

        with tempfile.TemporaryDirectory() as tmp:
            role_dir = Path(tmp) / "r1"
            (role_dir / "emojis" / "happy").mkdir(parents=True)
            (role_dir / "emojis" / "happy" / "a.png").write_bytes(b"PNGDATA")
            app = FastAPI()
            cfg = {"auth_token": "x" * 32, "public_file_max_accesses": 5}
            with patch.object(file_routes.roles, "get_role_dir", return_value=role_dir):
                app.include_router(file_routes.create_files_router(cfg))
                client = TestClient(app)
                url = "/files/public/emojis/r1/happy/a.png"
                self.assertEqual(client.get(url).status_code, 404)  # 无令牌
                token = public_links.store.issue("r1", "happy", "a.png")
                codes = [client.get(url, params={"t": token}).status_code for _ in range(6)]
                self.assertEqual(codes, [200] * 5 + [404])
        public_links.store.configure(None, None)


class WakeKeywordTests(unittest.TestCase):
    def _transform(self, message, config=None, **kw):
        from services.onebot.models import OneBotEvent
        from services.onebot.parser import transform_event

        base = {"post_type": "message", "message_type": "group", "user_id": 5, "group_id": 9,
                "message": message, "message_id": 1, "self_id": 100, "sender": {"nickname": "n"}}
        base.update(kw)
        cfg = {"self_id": 100}
        cfg.update(config or {})
        return transform_event(OneBotEvent(**base), role_id="r1", config=cfg)

    @staticmethod
    def _text(text):
        return [{"type": "text", "data": {"text": text}}]

    def test_keyword_counts_as_mention_ignoring_case(self):
        cfg = {"wake_keywords": ["小零", "Zero"]}
        self.assertTrue(self._transform(self._text("小零你在吗"), cfg).at_bot)
        self.assertTrue(self._transform(self._text("hey ZERO"), cfg).at_bot)

    def test_no_keyword_no_mention(self):
        self.assertFalse(self._transform(self._text("大家好"), {"wake_keywords": ["小零"]}).at_bot)
        self.assertFalse(self._transform(self._text("小零"), {}).at_bot)

    def test_blank_keywords_never_match(self):
        self.assertFalse(self._transform(self._text("大家好"), {"wake_keywords": ["", "  "]}).at_bot)

    def test_keyword_in_image_or_at_segments_is_ignored(self):
        message = [
            {"type": "at", "data": {"qq": "777"}},
            {"type": "image", "data": {"url": "http://x/小零.png"}},
        ]
        self.assertFalse(self._transform(message, {"wake_keywords": ["小零", "777", "图片"]}).at_bot)

    def test_real_at_still_works_and_private_is_always_true(self):
        at = [{"type": "at", "data": {"qq": "100"}}, {"type": "text", "data": {"text": " hi"}}]
        self.assertTrue(self._transform(at).at_bot)
        self.assertTrue(self._transform(self._text("hi"), message_type="private", group_id=None).at_bot)

    def test_string_message_format(self):
        self.assertTrue(self._transform("小零在吗", {"wake_keywords": ["小零"]}).at_bot)

    def test_gate_lets_keyword_message_through_without_random_reply(self):
        from services.onebot import policy

        config = {"allowed_groups": [9], "wake_keywords": ["小零"]}
        inbound = self._transform(self._text("小零在吗"), config)
        with patch.object(policy, "should_random_reply", return_value=False) as rnd:
            self.assertIsNone(policy.gate(inbound, config))
            rnd.assert_not_called()


class ProviderQuietTests(unittest.IsolatedAsyncioTestCase):
    def _quiet(self, value):
        from services import scheduler_service

        return patch.object(scheduler_service, "is_role_provider_quiet", return_value=value)

    def test_quiet_drops_private_at_group_and_owner_chat(self):
        from services.onebot import policy

        config = {"allowed_users": [10], "allowed_groups": [9], "main_user_id": 10}
        cases = [
            _inbound("你好", user_id=10, sender="1(QQ名:a)"),                   # 私聊
            _inbound("你好", user_id=10, group_id=9, sender="1(QQ名:a)"),       # 群聊 @ / 关键词唤醒
            _inbound("你好"),                                                    # 主用户私聊（非指令）
        ]
        with self._quiet(True):
            for inbound in cases:
                self.assertEqual(policy.gate(inbound, config), "模型静默时间，不回复")

    def test_quiet_keeps_owner_commands_working(self):
        from services.onebot import policy

        with self._quiet(True):
            self.assertIsNone(policy.gate(_inbound("/help"), {}))

    def test_not_quiet_behaves_as_before(self):
        from services.onebot import policy

        config = {"allowed_users": [10]}
        with self._quiet(False):
            self.assertIsNone(policy.gate(_inbound("你好", sender="1(QQ名:a)"), config))

    async def test_batch_waiting_into_quiet_time_is_dropped_without_calling_ai(self):
        from services.onebot import pipeline as pl

        p = pl.OneBotPipeline()
        ai = AsyncMock()
        with self._quiet(True), patch("routers.ai_behavior.handle_ai_event", ai), patch.object(
            pl.mirror, "mirror_user", new=AsyncMock()
        ) as mu:
            plan = await p._process_batch([_inbound("在吗")], MagicMock())
        self.assertTrue(plan.empty)
        ai.assert_not_awaited()
        mu.assert_not_awaited()
        await p.shutdown()


class StatsAndPlatformContextTests(unittest.TestCase):
    def test_stats_allowed_matrix(self):
        from services.chat_envelope import stats_allowed

        self.assertTrue(stats_allowed("zerochat", "user"))
        self.assertTrue(stats_allowed("zerochat_group", "user"))
        self.assertTrue(stats_allowed("onebot_private", "user"))
        self.assertFalse(stats_allowed("onebot_private", "1(QQ名:a)"))
        self.assertFalse(stats_allowed("onebot_group", "user"))


if __name__ == "__main__":
    unittest.main()

import base64
import hashlib
import json
import unittest
from copy import deepcopy
from datetime import date, timedelta
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import AsyncMock, patch

from routers.ai_behavior import (
    VisionRequest,
    _build_menstruation_chat_context,
    chat_with_vision,
)
from routers.settings import SettingsUpdate, update_settings
from routers import roles as roles_router
from services.ai_tools import (
    _BLOCK_USER_TOOL,
    _RECOGNIZE_IMAGE_TOOL,
    _REVIEW_PREVIOUS_IMAGES_TOOL,
    _SCHEDULE_TASK_TOOL,
    _SEARCH_MEMORY_TOOL,
    _SEND_EMOTION_EMOJI_TOOL,
    _VIEW_MOMENT_COMMENTS_TOOL,
    _VIEW_MOMENTS_TOOL,
    _WEB_SEARCH_TOOL,
    _WRITE_MEMORY_TOOL,
)
from services.ai_service import (
    _post_chat,
    _consume_inline_emoji_tool_markup,
    _consume_inline_continue_if_no_reply_markup,
    _handle_tool_calls,
    _normalize_embedding_url,
    generate_with_role,
)
from services.memory_service import _plan_next_period_start
from services import memory_service
from services import vision_service
from transport import ws_dispatcher


class SettingsAndEmojiTransferTests(unittest.IsolatedAsyncioTestCase):
    async def test_pre_model_passes_vision_result_as_user_context(self):
        pipeline = AsyncMock(return_value={"success": True, "reply": "最终回复"})
        request = VisionRequest(
            image_base64="AA==",
            user_prompt="图片里有什么？",
            role_id="role-1",
            run_mode="pre_model",
        )

        with patch(
            "services.vision_service.resolve_vision_config",
            return_value={"api_url": "https://vision.example/v1", "api_key": "key", "model": "vision-model"},
        ), patch(
            "routers.ai_behavior._post_chat_completion",
            new=AsyncMock(
                return_value={"choices": [{"message": {"content": "图片中有一只猫"}}]}
            ),
        ), patch(
            "routers.ai_behavior.load_role",
            return_value={"id": "role-1", "name": "测试角色"},
        ), patch(
            "routers.ai_behavior._run_memory_ai_pipeline", pipeline
        ), patch("services.vision_service.append_vision_memory"):
            result = await chat_with_vision(request)

        self.assertTrue(result["success"])
        self.assertNotIn("extra_parts", pipeline.call_args.kwargs)
        user_message = pipeline.call_args.kwargs["user_message"]
        self.assertIn("[图片识别结果]\n图片中有一只猫", user_message)
        self.assertIn("[用户要求]\n图片里有什么？", user_message)

    async def test_grok_request_uses_generic_request_without_thinking(self):
        response = type(
            "Response",
            (),
            {
                "raise_for_status": lambda self: None,
                "json": lambda self: {
                    "choices": [{"message": {"content": "ok"}}],
                },
            },
        )()
        client = type("Client", (), {"post": AsyncMock(return_value=response)})()
        with patch("services.ai_service._get_http_client", return_value=client), patch(
            "services.ai_service.settings_service.load_settings",
            return_value={"thinking_enabled": False},
        ):
            result = await _post_chat(
                messages=[{"role": "user", "content": "hello"}],
                api_url="https://api.x.ai/v1/chat/completions",
                api_key="test-key",
                model="grok-4.3",
                temperature=0.7,
                max_tokens=100,
            )

        self.assertTrue(result["success"])
        kwargs = client.post.await_args.kwargs
        self.assertNotIn("x-grok-conv-id", kwargs["headers"])
        self.assertNotIn("thinking", kwargs["json"])

    async def test_deepseek_request_keeps_existing_thinking_control(self):
        response = type(
            "Response",
            (),
            {
                "raise_for_status": lambda self: None,
                "json": lambda self: {
                    "choices": [{"message": {"content": "ok"}}],
                },
            },
        )()
        client = type("Client", (), {"post": AsyncMock(return_value=response)})()
        with patch("services.ai_service._get_http_client", return_value=client), patch(
            "services.ai_service.settings_service.load_settings",
            return_value={"thinking_enabled": False},
        ):
            await _post_chat(
                messages=[{"role": "user", "content": "hello"}],
                api_url="https://api.example.com/v1/chat/completions",
                api_key="test-key",
                model="deepseek-chat",
                temperature=0.7,
                max_tokens=100,
            )

        kwargs = client.post.await_args.kwargs
        self.assertNotIn("x-grok-conv-id", kwargs["headers"])
        self.assertEqual(kwargs["json"]["thinking"], {"type": "disabled"})

    async def test_gemini_request_omits_deepseek_thinking_extension(self):
        response = type(
            "Response",
            (),
            {
                "raise_for_status": lambda self: None,
                "json": lambda self: {
                    "choices": [{"message": {"content": "ok"}}],
                },
            },
        )()
        client = type("Client", (), {"post": AsyncMock(return_value=response)})()
        with patch("services.ai_service._get_http_client", return_value=client), patch(
            "services.ai_service.settings_service.load_settings",
            return_value={"thinking_enabled": False},
        ):
            await _post_chat(
                messages=[{"role": "user", "content": "hello"}],
                api_url="https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
                api_key="test-key",
                model="gemini-3-flash-preview",
                temperature=0.7,
                max_tokens=100,
            )

        self.assertNotIn("thinking", client.post.await_args.kwargs["json"])

    async def test_mimo_request_disables_thinking(self):
        response = type(
            "Response",
            (),
            {
                "raise_for_status": lambda self: None,
                "json": lambda self: {
                    "choices": [{"message": {"content": "ok"}}],
                },
            },
        )()
        client = type("Client", (), {"post": AsyncMock(return_value=response)})()
        with patch("services.ai_service._get_http_client", return_value=client), patch(
            "services.ai_service.settings_service.load_settings",
            return_value={"thinking_enabled": True},
        ):
            await _post_chat(
                messages=[{"role": "user", "content": "hello"}],
                api_url="https://api.xiaomimimo.com/v1/chat/completions",
                api_key="test-key",
                model="mimo-latest",
                temperature=0.7,
                max_tokens=100,
            )

        self.assertEqual(
            client.post.await_args.kwargs["json"]["thinking"],
            {"type": "disabled"},
        )

    async def test_gemini_appends_image_fallback_to_preserve_cache_prefix(self):
        captured_messages = []

        async def call_model(_role_data, messages, **_kwargs):
            captured_messages.append(deepcopy(messages))
            if len(captured_messages) == 1:
                return {"success": True, "content": "I cannot inspect the image."}
            return {"success": True, "content": "done"}

        with patch(
            "services.ai_service._call_with_role_config", side_effect=call_model
        ), patch(
            "services.ai_service.execute_recognize_image",
            new=AsyncMock(return_value="a sunset"),
        ):
            result = await generate_with_role(
                {"id": "role-1", "ai_model": "gemini-3-flash-preview"},
                "what is in this image?",
                vision_context={"image_data_urls": ["data:image/png;base64,AA=="]},
            )

        self.assertTrue(result["success"])
        self.assertEqual(
            [item["role"] for item in captured_messages[1]],
            ["system", "user", "user"],
        )
        self.assertIn("Image recognition result", captured_messages[1][-1]["content"])

    async def test_grok_image_fallback_replays_reasoning_context(self):
        captured_messages = []

        async def call_model(_role_data, messages, **_kwargs):
            captured_messages.append(deepcopy(messages))
            if len(captured_messages) == 1:
                return {
                    "success": True,
                    "content": "I cannot inspect the image.",
                    "reasoning_content": "Need image understanding before final reply.",
                }
            return {"success": True, "content": "done"}

        with patch(
            "services.ai_service._call_with_role_config", side_effect=call_model
        ), patch(
            "services.ai_service.execute_recognize_image",
            new=AsyncMock(return_value="a sunset"),
        ):
            result = await generate_with_role(
                {"id": "role-1", "ai_model": "grok-4.3"},
                "what is in this image?",
                vision_context={"image_data_urls": ["data:image/png;base64,AA=="]},
            )

        self.assertTrue(result["success"])
        self.assertEqual(
            [item["role"] for item in captured_messages[1]],
            ["system", "user", "assistant", "user"],
        )
        self.assertEqual(
            captured_messages[1][-2]["reasoning_content"],
            "Need image understanding before final reply.",
        )
        self.assertIn("Image recognition result", captured_messages[1][-1]["content"])

    async def test_gemini_tool_round_replays_opaque_signature_metadata(self):
        signature_result = {
            "success": True,
            "content": "",
            "assistant_content": None,
            "tool_calls": [
                {
                    "id": "call_search",
                    "type": "function",
                    "function": {
                        "name": "search_memory",
                        "arguments": {"query": "birthday"},
                    },
                    "extra_content": {
                        "google": {"thought_signature": "signed-state"},
                    },
                }
            ],
        }
        messages = [{"role": "user", "content": "when is my birthday?"}]
        with patch(
            "services.ai_service._call_with_role_config",
            new=AsyncMock(return_value={"success": True, "content": "tomorrow"}),
        ), patch(
            "services.ai_service.execute_search_memory",
            new=AsyncMock(return_value="birthday: tomorrow"),
        ):
            await _handle_tool_calls(
                signature_result,
                messages,
                {"id": "role-1", "ai_model": "gemini-3-flash-preview"},
                tools=None,
            )

        self.assertEqual(
            messages[1]["tool_calls"][0]["extra_content"]["google"]["thought_signature"],
            "signed-state",
        )

    async def test_grok_tool_round_uses_standard_call_path(self):
        initial_result = {
            "success": True,
            "content": "",
            "tool_calls": [
                {
                    "id": "call_schedule",
                    "type": "function",
                    "function": {
                        "name": "schedule_task",
                        "arguments": {
                            "message": "reminder",
                            "trigger_time": "2026-08-13T09:00:00",
                            "repeat": "none",
                        },
                    },
                },
            ],
        }
        call_model = AsyncMock(
            side_effect=[initial_result, {"success": True, "content": "done"}]
        )
        with patch(
            "services.ai_service._call_with_role_config", call_model
        ), patch(
            "services.ai_service.execute_schedule_task",
            new=AsyncMock(return_value="scheduled"),
        ):
            result = await generate_with_role(
                {"id": "role-1", "ai_model": "grok-4.3"},
                "remind me",
            )

        self.assertTrue(result["success"])
        self.assertEqual(call_model.await_count, 2)
        self.assertNotIn("grok_conversation_id", call_model.await_args_list[0].kwargs)
        self.assertNotIn("grok_conversation_id", call_model.await_args_list[1].kwargs)

    async def test_grok_keeps_core_memory_and_stats_in_user_message(self):
        captured_messages = []

        async def call_model(_role_data, messages, **_kwargs):
            captured_messages.append(deepcopy(messages))
            return {"success": True, "content": "done"}

        role = {
            "id": "role-1",
            "ai_model": "grok-4.3",
            "stats_config": {
                "enabled": True,
                "stats": [{"key": "trust", "name": "Trust", "min": 0, "max": 100}],
            },
        }
        with patch(
            "services.ai_service._call_with_role_config", side_effect=call_model
        ):
            await generate_with_role(
                role,
                "hello",
                core_memory_context="memory version one",
                stats_current={"trust": 10},
            )
            await generate_with_role(
                role,
                "hello again",
                core_memory_context="memory version two",
                stats_current={"trust": 20},
            )

        self.assertEqual(
            [item["role"] for item in captured_messages[0]],
            ["system", "user"],
        )
        self.assertEqual(
            [item["role"] for item in captured_messages[1]],
            ["system", "user"],
        )
        self.assertEqual(captured_messages[0][0], captured_messages[1][0])
        self.assertNotIn("核心记忆", captured_messages[0][0]["content"])
        self.assertIn("当前值见用户消息的 stats_current 字段", captured_messages[0][0]["content"])
        self.assertNotIn("当前 10", captured_messages[0][0]["content"])
        first_payload = json.loads(captured_messages[0][-1]["content"])
        second_payload = json.loads(captured_messages[1][-1]["content"])
        self.assertEqual(first_payload["core_memory"], "memory version one")
        self.assertEqual(second_payload["core_memory"], "memory version two")
        self.assertEqual(first_payload["stats_current"], {"trust": 10})
        self.assertEqual(second_payload["stats_current"], {"trust": 20})
        self.assertLess(
            captured_messages[0][-1]["content"].index('"core_memory"'),
            captured_messages[0][-1]["content"].index('"stats_current"'),
        )

    def test_period_plan_is_committed_with_a_bounded_variation(self):
        with patch("services.memory_service.random.randint", return_value=-2):
            planned = _plan_next_period_start(date(2026, 1, 1), 28)

        self.assertEqual(planned, date(2026, 1, 27))

    def test_next_period_plan_stays_server_side_and_ai_sees_a_bounded_estimate(self):
        with TemporaryDirectory() as temp_dir:
            role_id = "role-cycle-plan"
            role_root = Path(temp_dir)
            old_roles_dir = roles_router.ROLES_DIR
            old_memory_roles_dir = memory_service.ROLES_DIR
            roles_router.ROLES_DIR = role_root
            memory_service.ROLES_DIR = role_root
            memory_service.close_all_connections()
            try:
                role_dir = roles_router.get_role_dir(role_id)
                today = date.today()
                (role_dir / "profile.json").write_text(
                    json.dumps(
                        {
                            "id": role_id,
                            "gender": "women",
                            "menstruation_cycle": {
                                "cycle_length": 30,
                                "period_length": 6,
                                "last_period_start": (
                                    today - timedelta(days=30)
                                ).isoformat(),
                            },
                        }
                    ),
                    encoding="utf-8",
                )
                # 规划的准确日期在周期开始时就已经确定
                planned_start = today + timedelta(days=10)
                with memory_service._get_connection(role_id) as conn:
                    memory_service._set_meta(
                        conn,
                        "last_period_start",
                        (today - timedelta(days=20)).isoformat(),
                    )
                    memory_service._set_meta(
                        conn, "next_period_start", planned_start.isoformat()
                    )

                with patch("services.memory_service.random.choice", return_value=-3):
                    status = memory_service._get_menstruation_status(role_id)

                self.assertIsNotNone(status)
                # 给 AI 的只是 ±3 天内的预计值，绝不是准确值
                self.assertEqual(
                    status["next_period_start"],
                    (planned_start - timedelta(days=3)).isoformat(),
                )
                self.assertNotEqual(
                    status["next_period_start"], planned_start.isoformat()
                )
                self.assertGreater(status["days_until_next_period"], 0)
                self.assertFalse(status["in_period"])

                # 准确值仍保留在服务端元数据里，作为权威时间
                with memory_service._get_connection(role_id) as conn:
                    self.assertEqual(
                        memory_service._get_meta(conn, "next_period_start"),
                        planned_start.isoformat(),
                    )

                # 同一天内预计值保持稳定（跨天才会重新抽取，制造自然的不确定感）
                with patch("services.memory_service.random.choice", return_value=2):
                    repeated = memory_service._get_menstruation_status(role_id)
                self.assertEqual(
                    repeated["next_period_start"], status["next_period_start"]
                )

                # 换一天则允许（也应当）给出不同的预计日期
                with memory_service._get_connection(role_id) as conn:
                    memory_service._set_meta(
                        conn,
                        "next_period_start_estimate_date",
                        (today - timedelta(days=1)).isoformat(),
                    )
                with patch("services.memory_service.random.choice", return_value=3):
                    next_day = memory_service._get_menstruation_status(role_id)
                self.assertEqual(
                    next_day["next_period_start"],
                    (planned_start + timedelta(days=3)).isoformat(),
                )
            finally:
                memory_service.close_all_connections()
                roles_router.ROLES_DIR = old_roles_dir
                memory_service.ROLES_DIR = old_memory_roles_dir

    def test_next_period_estimate_is_always_in_the_future(self):
        with TemporaryDirectory() as temp_dir:
            role_id = "role-cycle-imminent"
            role_root = Path(temp_dir)
            old_roles_dir = roles_router.ROLES_DIR
            old_memory_roles_dir = memory_service.ROLES_DIR
            roles_router.ROLES_DIR = role_root
            memory_service.ROLES_DIR = role_root
            memory_service.close_all_connections()
            try:
                role_dir = roles_router.get_role_dir(role_id)
                today = date.today()
                (role_dir / "profile.json").write_text(
                    json.dumps(
                        {
                            "id": role_id,
                            "gender": "women",
                            "menstruation_cycle": {
                                "cycle_length": 30,
                                "period_length": 6,
                                "last_period_start": today.isoformat(),
                            },
                        }
                    ),
                    encoding="utf-8",
                )
                # 计划就在明天：预计值不得退回今天或过去
                planned_start = today + timedelta(days=1)
                with memory_service._get_connection(role_id) as conn:
                    memory_service._set_meta(conn, "last_period_start", today.isoformat())
                    memory_service._set_meta(
                        conn, "next_period_start", planned_start.isoformat()
                    )

                # 计划就在明天：无论当天抽到哪个偏移，预计值都不得退回今天或过去
                estimates = set()
                for _ in range(20):
                    with memory_service._get_connection(role_id) as conn:
                        # 清掉缓存的预计值，强制每次重新抽取
                        memory_service._set_meta(conn, "next_period_start_estimate", None)
                        memory_service._set_meta(conn, "next_period_start_estimate_base", None)
                    status = memory_service._get_menstruation_status(role_id)
                    self.assertIsNotNone(status)
                    estimate = date.fromisoformat(status["next_period_start"])
                    self.assertGreater(estimate, today)
                    self.assertLessEqual(
                        abs((estimate - planned_start).days),
                        memory_service.NEXT_PERIOD_ESTIMATE_MAX_OFFSET_DAYS,
                    )
                    estimates.add(estimate)

                self.assertTrue(
                    estimates.issubset(
                        {
                            planned_start + timedelta(days=offset)
                            for offset in range(
                                -memory_service.NEXT_PERIOD_ESTIMATE_MAX_OFFSET_DAYS,
                                memory_service.NEXT_PERIOD_ESTIMATE_MAX_OFFSET_DAYS + 1,
                            )
                        }
                    )
                )
            finally:
                memory_service.close_all_connections()
                roles_router.ROLES_DIR = old_roles_dir
                memory_service.ROLES_DIR = old_memory_roles_dir

    def test_new_cycle_starts_exactly_on_the_planned_day(self):
        with TemporaryDirectory() as temp_dir:
            role_id = "role-cycle-rollover"
            role_root = Path(temp_dir)
            old_roles_dir = roles_router.ROLES_DIR
            old_memory_roles_dir = memory_service.ROLES_DIR
            roles_router.ROLES_DIR = role_root
            memory_service.ROLES_DIR = role_root
            memory_service.close_all_connections()
            try:
                role_dir = roles_router.get_role_dir(role_id)
                today = date.today()
                (role_dir / "profile.json").write_text(
                    json.dumps(
                        {
                            "id": role_id,
                            "gender": "women",
                            "menstruation_cycle": {
                                "cycle_length": 30,
                                "period_length": 6,
                                "last_period_start": (
                                    today - timedelta(days=30)
                                ).isoformat(),
                            },
                        }
                    ),
                    encoding="utf-8",
                )
                with memory_service._get_connection(role_id) as conn:
                    memory_service._set_meta(
                        conn,
                        "last_period_start",
                        (today - timedelta(days=30)).isoformat(),
                    )
                    memory_service._set_meta(
                        conn, "next_period_start", today.isoformat()
                    )

                with patch("services.memory_service.random.randint", return_value=0):
                    status = memory_service._get_menstruation_status(role_id)

                self.assertIsNotNone(status)
                # 新周期在规划日当天准时开始，并把准确值交给 AI
                self.assertTrue(status["in_period"])
                self.assertEqual(status["period_day"], 1)
                self.assertEqual(status["period_start"], today.isoformat())

                with memory_service._get_connection(role_id) as conn:
                    self.assertEqual(
                        memory_service._get_meta(conn, "last_period_start"),
                        today.isoformat(),
                    )
                    self.assertEqual(
                        memory_service._get_meta(conn, "next_period_start"),
                        (today + timedelta(days=30)).isoformat(),
                    )

                # 数据库与 profile.json 必须同时记录这次经期开始时间
                profile = json.loads((role_dir / "profile.json").read_text(encoding="utf-8"))
                self.assertEqual(
                    profile["menstruation_cycle"]["last_period_start"],
                    today.isoformat(),
                )
            finally:
                memory_service.close_all_connections()
                roles_router.ROLES_DIR = old_roles_dir
                memory_service.ROLES_DIR = old_memory_roles_dir

    def test_missing_next_period_plan_is_created_now_and_never_in_the_past(self):
        with TemporaryDirectory() as temp_dir:
            role_id = "role-cycle-missing-plan"
            role_root = Path(temp_dir)
            old_roles_dir = roles_router.ROLES_DIR
            old_memory_roles_dir = memory_service.ROLES_DIR
            roles_router.ROLES_DIR = role_root
            memory_service.ROLES_DIR = role_root
            memory_service.close_all_connections()
            try:
                role_dir = roles_router.get_role_dir(role_id)
                today = date.today()
                stale_start = today - timedelta(days=200)
                (role_dir / "profile.json").write_text(
                    json.dumps(
                        {
                            "id": role_id,
                            "gender": "women",
                            "menstruation_cycle": {
                                "cycle_length": 30,
                                "period_length": 6,
                                "last_period_start": stale_start.isoformat(),
                            },
                        }
                    ),
                    encoding="utf-8",
                )
                # next_period_start 不存在（例如刚被重置），且算出来的日期已经过期
                with memory_service._get_connection(role_id) as conn:
                    memory_service._set_meta(
                        conn, "last_period_start", stale_start.isoformat()
                    )
                    memory_service._set_meta(conn, "next_period_start", None)

                status = memory_service._get_menstruation_status(role_id)

                self.assertIsNotNone(status)
                with memory_service._get_connection(role_id) as conn:
                    planned = memory_service._get_meta(conn, "next_period_start")
                # 立刻算出规划值，且小于等于今天时直接顺延到明天
                self.assertEqual(planned, (today + timedelta(days=1)).isoformat())
                # 给 AI 的预计值同样不能落在今天或更早
                self.assertGreater(
                    date.fromisoformat(status["next_period_start"]), today
                )
                self.assertGreaterEqual(status["days_until_next_period"], 1)

                # 未来某天该规划日到达时，才真正开始新周期
                self.assertFalse(status["in_period"])
                self.assertEqual(status["period_start"], stale_start.isoformat())
            finally:
                memory_service.close_all_connections()
                roles_router.ROLES_DIR = old_roles_dir
                memory_service.ROLES_DIR = old_memory_roles_dir

    def test_menstruation_prompt_marks_next_period_as_uncertain(self):
        status = {
            "today": "2026-03-10",
            "cycle_length": 28,
            "period_length": 5,
            "cycle_day": 12,
            "in_period": False,
            "period_day": None,
            "period_start": "2026-02-27",
            "expected_period_end": "2026-03-03",
            "next_period_start": "2026-03-26",
            "next_period_start_is_estimate": True,
            "days_until_next_period": 16,
        }

        outside_text = "\n".join(_build_menstruation_chat_context(status))
        # 预计日期要给出，但必须同时说清它只是会浮动的估算
        self.assertIn("2026-03-26", outside_text)
        self.assertIn("估算", outside_text)
        self.assertIn("浮动", outside_text)
        self.assertIn("不要承诺具体日期", outside_text)
        self.assertIn("模糊", outside_text)

        # 经期最后一天：状态片段 + 结束提示，且结束时间同样被标为估算
        in_period = dict(
            status,
            in_period=True,
            period_day=3,
            cycle_day=3,
            expected_period_end=status["today"],
        )
        in_period_parts = _build_menstruation_chat_context(in_period)
        in_period_text = "\n".join(in_period_parts)

        self.assertEqual(len(in_period_parts), 2)
        self.assertIn("第3天", in_period_text)
        self.assertIn("估算", in_period_text)
        self.assertIn("不要当成确定的事实", in_period_text)

    def test_role_period_start_edit_resyncs_both_stores_immediately(self):
        with TemporaryDirectory() as temp_dir:
            role_id = "role-period-test"
            role_root = Path(temp_dir)
            old_roles_dir = roles_router.ROLES_DIR
            old_memory_roles_dir = memory_service.ROLES_DIR
            roles_router.ROLES_DIR = role_root
            memory_service.ROLES_DIR = role_root
            memory_service.close_all_connections()
            try:
                role_dir = roles_router.get_role_dir(role_id)
                today = date.today()
                profile = {
                    "id": role_id,
                    "gender": "women",
                    "menstruation_cycle": {
                        "cycle_length": 30,
                        "period_length": 6,
                        "last_period_start": "2026-01-01",
                    },
                }
                (role_dir / "profile.json").write_text(
                    json.dumps(profile), encoding="utf-8"
                )
                with memory_service._get_connection(role_id) as conn:
                    memory_service._set_meta(conn, "last_period_start", "2026-01-01")

                # 修改上次经期时间：应立刻算出下一次经期时间，并同时写进 json 与数据库
                profile["menstruation_cycle"]["last_period_start"] = today.isoformat()
                roles_router.save_role(role_id, profile)

                with memory_service._get_connection(role_id) as conn:
                    db_start = memory_service._get_meta(conn, "last_period_start")
                    db_planned = memory_service._get_meta(conn, "next_period_start")

                stored = json.loads((role_dir / "profile.json").read_text(encoding="utf-8"))
                cycle = stored["menstruation_cycle"]

                self.assertEqual(db_start, today.isoformat())
                self.assertEqual(cycle["last_period_start"], db_start)
                # 两边内容一致，且规划值一定在未来
                self.assertEqual(cycle["next_period_start"], db_planned)
                self.assertGreater(
                    date.fromisoformat(db_planned), today
                )
                self.assertLessEqual(
                    abs(
                        (
                            date.fromisoformat(db_planned)
                            - (today + timedelta(days=30))
                        ).days
                    ),
                    2,
                )

                # 提交设置但没改 last_period_start：不得重新计算
                original_planned = db_planned
                profile["menstruation_cycle"]["cycle_length"] = 35
                profile["name"] = "改个名字"
                roles_router.save_role(role_id, profile)

                with memory_service._get_connection(role_id) as conn:
                    self.assertEqual(
                        memory_service._get_meta(conn, "next_period_start"),
                        original_planned,
                    )
                stored_again = json.loads(
                    (role_dir / "profile.json").read_text(encoding="utf-8")
                )
                self.assertEqual(
                    stored_again["menstruation_cycle"]["next_period_start"],
                    original_planned,
                )
            finally:
                memory_service.close_all_connections()
                roles_router.ROLES_DIR = old_roles_dir
                memory_service.ROLES_DIR = old_memory_roles_dir

    def test_stale_period_start_edit_is_pushed_to_tomorrow(self):
        with TemporaryDirectory() as temp_dir:
            role_id = "role-period-stale"
            role_root = Path(temp_dir)
            old_roles_dir = roles_router.ROLES_DIR
            old_memory_roles_dir = memory_service.ROLES_DIR
            roles_router.ROLES_DIR = role_root
            memory_service.ROLES_DIR = role_root
            memory_service.close_all_connections()
            try:
                role_dir = roles_router.get_role_dir(role_id)
                today = date.today()
                stale = today - timedelta(days=200)
                profile = {
                    "id": role_id,
                    "gender": "women",
                    "menstruation_cycle": {
                        "cycle_length": 30,
                        "period_length": 6,
                        "last_period_start": today.isoformat(),
                    },
                }
                (role_dir / "profile.json").write_text(
                    json.dumps(profile), encoding="utf-8"
                )
                with memory_service._get_connection(role_id) as conn:
                    memory_service._set_meta(conn, "last_period_start", today.isoformat())

                # 改成一个很久以前的时间：算出来的下一次经期已过期 -> 顺延到明天
                profile["menstruation_cycle"]["last_period_start"] = stale.isoformat()
                roles_router.save_role(role_id, profile)

                with memory_service._get_connection(role_id) as conn:
                    db_planned = memory_service._get_meta(conn, "next_period_start")
                stored = json.loads((role_dir / "profile.json").read_text(encoding="utf-8"))

                self.assertEqual(db_planned, (today + timedelta(days=1)).isoformat())
                self.assertEqual(
                    stored["menstruation_cycle"]["next_period_start"], db_planned
                )
            finally:
                memory_service.close_all_connections()
                roles_router.ROLES_DIR = old_roles_dir
                memory_service.ROLES_DIR = old_memory_roles_dir

    def _setup_women_role_with_plan(self, role_root, role_id, days_ago=10):
        """建一个已进入运行态的女性角色，返回 (role_dir, 档案 dict, 数据库锚点/规划值)。"""

        role_dir = roles_router.get_role_dir(role_id)
        today = date.today()
        profile = {
            "id": role_id,
            "name": role_id,
            "gender": "women",
            "menstruation_cycle": {
                "cycle_length": 30,
                "period_length": 6,
                "last_period_start": (today - timedelta(days=days_ago)).isoformat(),
            },
        }
        (role_dir / "profile.json").write_text(json.dumps(profile), encoding="utf-8")
        with memory_service._get_connection(role_id) as conn:
            memory_service._set_meta(
                conn, "last_period_start", profile["menstruation_cycle"]["last_period_start"]
            )
        # 跑一次状态读取，让规划值与镜像都落地
        memory_service._get_menstruation_status(role_id)
        with memory_service._get_connection(role_id) as conn:
            db = {
                "last_period_start": memory_service._get_meta(conn, "last_period_start"),
                "next_period_start": memory_service._get_meta(conn, "next_period_start"),
            }
        return role_dir, profile, db

    def _read_cycle(self, role_dir):
        stored = json.loads((role_dir / "profile.json").read_text(encoding="utf-8"))
        return stored, stored["menstruation_cycle"]

    def test_saving_settings_without_cycle_change_keeps_the_plan_mirror(self):
        """只改设置（未动上次经期时间）时，服务端规划值不能被前端载荷抹掉。"""

        with TemporaryDirectory() as temp_dir:
            role_root = Path(temp_dir)
            old_roles_dir = roles_router.ROLES_DIR
            old_memory_roles_dir = memory_service.ROLES_DIR
            roles_router.ROLES_DIR = role_root
            memory_service.ROLES_DIR = role_root
            memory_service.close_all_connections()
            try:
                role_id = "role-mirror-on-save"
                role_dir, profile, db = self._setup_women_role_with_plan(
                    role_root, role_id
                )
                before_plan = db["next_period_start"]
                self.assertIsNotNone(before_plan)

                # 前端只会拿到三个用户可见字段，回传时自然没有 next_period_start
                payload = dict(profile)
                payload["menstruation_cycle"] = roles_router._client_menstruation_cycle(
                    profile
                )
                payload["name"] = "改个名字"
                roles_router.save_role(role_id, payload)

                _, cycle = self._read_cycle(role_dir)
                with memory_service._get_connection(role_id) as conn:
                    db_plan = memory_service._get_meta(conn, "next_period_start")

                self.assertEqual(cycle["next_period_start"], db_plan)
                # 镜像写回的是已有规划值，不是重新抽的
                self.assertEqual(db_plan, before_plan)
            finally:
                memory_service.close_all_connections()
                roles_router.ROLES_DIR = old_roles_dir
                memory_service.ROLES_DIR = old_memory_roles_dir

    def test_unparsable_period_start_never_reaches_the_profile(self):
        """无法解析的上次经期时间不能只落进 json：两处都要停在原状态。"""

        with TemporaryDirectory() as temp_dir:
            role_root = Path(temp_dir)
            old_roles_dir = roles_router.ROLES_DIR
            old_memory_roles_dir = memory_service.ROLES_DIR
            roles_router.ROLES_DIR = role_root
            memory_service.ROLES_DIR = role_root
            memory_service.close_all_connections()
            try:
                role_id = "role-bad-anchor"
                role_dir, profile, db = self._setup_women_role_with_plan(
                    role_root, role_id
                )

                profile["menstruation_cycle"]["last_period_start"] = "不是日期"
                roles_router.save_role(role_id, profile)

                stored, cycle = self._read_cycle(role_dir)
                with memory_service._get_connection(role_id) as conn:
                    db_start = memory_service._get_meta(conn, "last_period_start")
                    db_plan = memory_service._get_meta(conn, "next_period_start")

                self.assertEqual(db_start, db["last_period_start"])
                self.assertEqual(db_plan, db["next_period_start"])
                self.assertEqual(cycle["last_period_start"], db_start)
                self.assertEqual(cycle["next_period_start"], db_plan)
                # 非法值不落盘
                self.assertNotIn("不是日期", json.dumps(stored))
            finally:
                memory_service.close_all_connections()
                roles_router.ROLES_DIR = old_roles_dir
                memory_service.ROLES_DIR = old_memory_roles_dir

    def test_failed_database_write_does_not_half_apply_the_edit(self):
        """数据库写不进去时，json 也不能单方面改成新锚点。"""

        with TemporaryDirectory() as temp_dir:
            role_root = Path(temp_dir)
            old_roles_dir = roles_router.ROLES_DIR
            old_memory_roles_dir = memory_service.ROLES_DIR
            roles_router.ROLES_DIR = role_root
            memory_service.ROLES_DIR = role_root
            memory_service.close_all_connections()
            try:
                role_id = "role-db-failure"
                role_dir, profile, db = self._setup_women_role_with_plan(
                    role_root, role_id
                )

                profile["menstruation_cycle"]["last_period_start"] = date.today().isoformat()
                with patch(
                    "services.memory_service._get_connection",
                    side_effect=RuntimeError("db down"),
                ):
                    roles_router.save_role(role_id, profile)

                _, cycle = self._read_cycle(role_dir)
                with memory_service._get_connection(role_id) as conn:
                    db_start = memory_service._get_meta(conn, "last_period_start")
                    db_plan = memory_service._get_meta(conn, "next_period_start")

                # 两处一起停在旧状态，而不是 json 前进、数据库留在原地
                self.assertEqual(db_start, db["last_period_start"])
                self.assertEqual(db_plan, db["next_period_start"])
                self.assertEqual(cycle["last_period_start"], db_start)
                self.assertEqual(cycle["next_period_start"], db_plan)
            finally:
                memory_service.close_all_connections()
                roles_router.ROLES_DIR = old_roles_dir
                memory_service.ROLES_DIR = old_memory_roles_dir

    def test_cycle_mirror_never_rolls_back_a_concurrent_settings_save(self):
        """状态读取拿着旧快照写镜像时，不能覆盖期间的设置保存。"""

        with TemporaryDirectory() as temp_dir:
            role_root = Path(temp_dir)
            old_roles_dir = roles_router.ROLES_DIR
            old_memory_roles_dir = memory_service.ROLES_DIR
            roles_router.ROLES_DIR = role_root
            memory_service.ROLES_DIR = role_root
            memory_service.close_all_connections()
            try:
                role_id = "role-concurrent-save"
                role_dir, _, db = self._setup_women_role_with_plan(role_root, role_id)

                # 状态读取拿到的旧快照（函数开头读入，之后才写回）
                stale_dir = role_dir
                stale_data, stale_cycle = self._read_cycle(stale_dir)

                # 期间用户保存了设置：改名 + onebot 配置 + 改了上次经期时间
                concurrent = json.loads(
                    (role_dir / "profile.json").read_text(encoding="utf-8")
                )
                concurrent["name"] = "并发改名"
                concurrent["onebot_config"] = {"enabled": True}
                concurrent["menstruation_cycle"]["last_period_start"] = (
                    date.today() - timedelta(days=3)
                ).isoformat()
                roles_router.save_role(role_id, concurrent)

                # 状态读取随后用旧快照做镜像写回（这里用旧值调用内部镜像函数）
                memory_service._persist_profile_cycle_state(
                    role_id,
                    role_dir / "profile.json",
                    stale_data,
                    stale_cycle,
                    date.fromisoformat(db["last_period_start"]),
                    date.fromisoformat(db["next_period_start"]),
                )

                stored, cycle = self._read_cycle(role_dir)
                with memory_service._get_connection(role_id) as conn:
                    db_start = memory_service._get_meta(conn, "last_period_start")
                    db_plan = memory_service._get_meta(conn, "next_period_start")

                self.assertEqual(stored["name"], "并发改名")
                self.assertEqual(stored["onebot_config"], {"enabled": True})
                self.assertEqual(cycle["last_period_start"], db_start)
                self.assertEqual(cycle["next_period_start"], db_plan)
            finally:
                memory_service.close_all_connections()
                roles_router.ROLES_DIR = old_roles_dir
                memory_service.ROLES_DIR = old_memory_roles_dir

    def test_non_women_role_never_maintains_cycle_state(self):
        """非女性角色完全不维护生理周期：不重算、不写数据库、不镜像。"""

        with TemporaryDirectory() as temp_dir:
            role_root = Path(temp_dir)
            old_roles_dir = roles_router.ROLES_DIR
            old_memory_roles_dir = memory_service.ROLES_DIR
            roles_router.ROLES_DIR = role_root
            memory_service.ROLES_DIR = role_root
            memory_service.close_all_connections()
            try:
                role_id = "role-men-cycle"
                role_dir = roles_router.get_role_dir(role_id)
                profile = {
                    "id": role_id,
                    "name": role_id,
                    "gender": "men",
                    "menstruation_cycle": {
                        "cycle_length": 30,
                        "period_length": 6,
                        "last_period_start": (date.today() - timedelta(days=10)).isoformat(),
                    },
                }
                (role_dir / "profile.json").write_text(
                    json.dumps(profile), encoding="utf-8"
                )

                profile["menstruation_cycle"]["last_period_start"] = date.today().isoformat()
                roles_router.save_role(role_id, profile)

                with memory_service._get_connection(role_id) as conn:
                    self.assertIsNone(memory_service._get_meta(conn, "last_period_start"))
                    self.assertIsNone(memory_service._get_meta(conn, "next_period_start"))

                _, cycle = self._read_cycle(role_dir)
                # 用户填的值原样保存，但服务端不据此维护任何周期状态
                self.assertEqual(cycle["last_period_start"], date.today().isoformat())
                self.assertNotIn("next_period_start", cycle)
                self.assertIsNone(memory_service._get_menstruation_status(role_id))
            finally:
                memory_service.close_all_connections()
                roles_router.ROLES_DIR = old_roles_dir
                memory_service.ROLES_DIR = old_memory_roles_dir

    def test_client_payload_hides_server_side_next_period(self):
        from routers.roles import _client_menstruation_cycle

        role = {
            "id": "role-x",
            "menstruation_cycle": {
                "cycle_length": 30,
                "period_length": 6,
                "last_period_start": "2026-03-01",
                "next_period_start": "2026-03-30",
            },
        }

        self.assertEqual(
            _client_menstruation_cycle(role),
            {
                "cycle_length": 30,
                "period_length": 6,
                "last_period_start": "2026-03-01",
            },
        )
        self.assertIsNone(_client_menstruation_cycle({"id": "role-y"}))

    def test_role_list_uses_runtime_period_start_for_women(self):
        with TemporaryDirectory() as temp_dir:
            role_root = Path(temp_dir)
            old_roles_dir = roles_router.ROLES_DIR
            old_memory_roles_dir = memory_service.ROLES_DIR
            roles_router.ROLES_DIR = role_root
            memory_service.ROLES_DIR = role_root
            memory_service.close_all_connections()
            try:
                women_role_id = "role-cycle-women"
                women_role_dir = roles_router.get_role_dir(women_role_id)
                women_role_dir.joinpath("profile.json").write_text(
                    json.dumps(
                        {
                            "id": women_role_id,
                            "gender": "women",
                            "menstruation_cycle": {
                                "cycle_length": 30,
                                "period_length": 6,
                                "last_period_start": "2026-02-23",
                            },
                        }
                    ),
                    encoding="utf-8",
                )
                with memory_service._get_connection(women_role_id) as conn:
                    memory_service._set_meta(
                        conn,
                        "last_period_start",
                        (date.today()).isoformat(),
                    )

                men_role_id = "role-cycle-men"
                men_role_dir = roles_router.get_role_dir(men_role_id)
                men_role_dir.joinpath("profile.json").write_text(
                    json.dumps(
                        {
                            "id": men_role_id,
                            "gender": "men",
                            "menstruation_cycle": {
                                "cycle_length": 30,
                                "period_length": 6,
                                "last_period_start": "2026-02-23",
                            },
                        }
                    ),
                    encoding="utf-8",
                )

                role_items = {
                    role["id"]: role
                    for role in roles_router.build_role_items("http://example.test")
                }

                self.assertEqual(
                    role_items[women_role_id]["menstruation_cycle"]["last_period_start"],
                    date.today().isoformat(),
                )
                self.assertEqual(
                    role_items[men_role_id]["menstruation_cycle"]["last_period_start"],
                    "2026-02-23",
                )
            finally:
                memory_service.close_all_connections()
                roles_router.ROLES_DIR = old_roles_dir
                memory_service.ROLES_DIR = old_memory_roles_dir

    def test_all_function_tools_use_strict_closed_schemas(self):
        tool_groups = (
            _SCHEDULE_TASK_TOOL,
            _BLOCK_USER_TOOL,
            _SEARCH_MEMORY_TOOL,
            _WEB_SEARCH_TOOL,
            _WRITE_MEMORY_TOOL,
            _RECOGNIZE_IMAGE_TOOL,
            _REVIEW_PREVIOUS_IMAGES_TOOL,
            _SEND_EMOTION_EMOJI_TOOL,
            _VIEW_MOMENTS_TOOL,
            _VIEW_MOMENT_COMMENTS_TOOL,
        )
        for group in tool_groups:
            function = group[0]["function"]
            parameters = function["parameters"]
            self.assertTrue(function["strict"], function["name"])
            self.assertFalse(parameters["additionalProperties"], function["name"])
            self.assertEqual(
                set(parameters["required"]),
                set(parameters["properties"]),
                function["name"],
            )

    def test_recognize_image_tool_requires_a_call_when_present(self):
        description = _RECOGNIZE_IMAGE_TOOL[0]["function"]["description"]

        self.assertIn("必须在回复前调用一次", description)

    async def test_rest_settings_persists_embedding_fields(self):
        update = SettingsUpdate(
            embedding_enabled=True,
            embedding_api_url="https://api.example.com/v1",
            embedding_api_key="new-key",
            embedding_model="embedding-model",
        )
        with patch("routers.settings.settings_service.save_settings", return_value=True) as save:
            result = await update_settings(update)

        self.assertTrue(result["success"])
        self.assertEqual(
            save.call_args.args[0],
            {
                "embedding_enabled": True,
                "embedding_api_url": "https://api.example.com/v1",
                "embedding_api_key": "new-key",
                "embedding_model": "embedding-model",
            },
        )

    async def test_websocket_settings_masks_embedding_key_without_mutating_cache(self):
        settings = {"embedding_api_key": "secret-value", "ai_api_key": "chat-key"}
        with patch("transport.ws_dispatcher.settings_service.load_settings", return_value=settings):
            result = await ws_dispatcher._handle_settings_get({}, "")

        returned = result["settings"]
        self.assertNotIn("embedding_api_key", returned)
        self.assertIn("embedding_api_key_masked", returned)
        self.assertEqual(settings["embedding_api_key"], "secret-value")

    async def test_websocket_settings_persists_embedding_fields(self):
        payload = {
            "updates": {
                "embedding_enabled": True,
                "embedding_api_url": "https://api.example.com/v1",
                "embedding_api_key": "new-key",
                "embedding_model": "embedding-model",
            }
        }
        with patch("transport.ws_dispatcher.settings_service.save_settings", return_value=True) as save:
            result = await ws_dispatcher._handle_settings_update(payload, "")

        self.assertTrue(result["success"])
        self.assertEqual(save.call_args.args[0], payload["updates"])

    async def test_emoji_transfer_reads_role_asset_in_chunks(self):
        with TemporaryDirectory() as temp_dir:
            role_dir = Path(temp_dir) / "role-1"
            emoji_file = role_dir / "emojis" / "happy" / "wave.png"
            emoji_file.parent.mkdir(parents=True)
            content = b"emoji-data-" * 7000
            emoji_file.write_bytes(content)
            reference = ws_dispatcher._role_emoji_ref("role-1", "happy", "wave.png")

            ws_dispatcher._EMOJI_TRANSFERS.clear()
            with patch("transport.ws_dispatcher.roles.get_role_dir", return_value=role_dir):
                init = await ws_dispatcher._handle_emoji_file_init({"reference": reference}, "")
                self.assertEqual(init["sha256"], hashlib.sha256(content).hexdigest())
                chunks = []
                for index in range(init["total_chunks"]):
                    part = await ws_dispatcher._handle_emoji_file_chunk(
                        {"transfer_id": init["transfer_id"], "chunk_index": index}, ""
                    )
                    chunks.append(base64.b64decode(part["chunk_base64"]))

        self.assertEqual(b"".join(chunks), content)

    async def test_inline_emoji_tool_markup_is_not_rendered_as_text(self):
        result = {"content": '收到啦 <send_emotion_emoji emotion="love" />'}
        with patch(
            "services.ai_service.execute_send_emotion_emoji",
            return_value="[love]",
        ) as execute:
            normalized = await _consume_inline_emoji_tool_markup(result, {"id": "role-1"})

        self.assertEqual(normalized["content"], "收到啦")
        self.assertEqual(normalized["_emojis_called"], ["love"])
        execute.assert_awaited_once_with({"id": "role-1"}, "love")

    async def test_empty_inline_emoji_tool_markup_is_removed(self):
        result = {"content": '<send_emotion_emoji emotion="" />'}
        with patch("services.ai_service.execute_send_emotion_emoji") as execute:
            normalized = await _consume_inline_emoji_tool_markup(result, {"id": "role-1"})

        self.assertEqual(normalized["content"], "")
        self.assertEqual(normalized["_emojis_called"], [])
        execute.assert_not_awaited()

    async def test_inline_continue_if_no_reply_markup_is_executed_and_stripped(self):
        # 复现真实故障样式：模型把 continue_if_no_reply 写成正文里的 XML 标签，
        # 且 prompt 字段被模型自造成 <param name="prompt"> 包裹，而不是走
        # tool_calls。修复后应真正执行一次续写调用，并把标签从正文剥除。
        result = {
            "content": (
                "<对话>那你打疙瘩，我烧水。</对话>\n"
                "<数值>a3.5;b:33.5</数值>\n"
                "<continue_if_no_reply>\n"
                "<delay_minutes>6</delay_minutes>\n"
                '<param name="prompt">催一下疙瘩汤进度</param>\n'
                "</continue_if_no_reply>"
            )
        }
        with patch(
            "services.ai_service.execute_continue_if_no_reply",
            return_value="[已设置续写]",
        ) as execute:
            normalized = await _consume_inline_continue_if_no_reply_markup(
                result, {"id": "role-1"}
            )

        self.assertEqual(
            normalized["content"],
            "<对话>那你打疙瘩，我烧水。</对话>\n<数值>a3.5;b:33.5</数值>",
        )
        execute.assert_awaited_once_with({"id": "role-1"}, 6.0, "催一下疙瘩汤进度")
        self.assertEqual(len(normalized["_tool_calls_log"]), 1)
        logged = normalized["_tool_calls_log"][0]
        self.assertEqual(logged["name"], "continue_if_no_reply")
        self.assertEqual(logged["arguments"], {"delay_minutes": 6.0, "prompt": "催一下疙瘩汤进度"})
        self.assertEqual(logged["result"], "[已设置续写]")

    async def test_inline_continue_if_no_reply_markup_supports_direct_child_tags(self):
        # 部分模型会直接用 <prompt> 而不是 <param name="prompt">，两种写法都要兼容。
        result = {
            "content": (
                "<continue_if_no_reply>"
                "<delay_minutes>10</delay_minutes>"
                "<prompt>问下他在不在</prompt>"
                "</continue_if_no_reply>"
            )
        }
        with patch(
            "services.ai_service.execute_continue_if_no_reply",
            return_value="[已设置续写]",
        ) as execute:
            normalized = await _consume_inline_continue_if_no_reply_markup(
                result, {"id": "role-1"}
            )

        self.assertEqual(normalized["content"], "")
        execute.assert_awaited_once_with({"id": "role-1"}, 10.0, "问下他在不在")

    async def test_incomplete_inline_continue_if_no_reply_markup_is_not_executed(self):
        # 缺 prompt 时不应静默调用工具，但仍要把标签从正文剥除，避免展示乱码给用户，
        # 并在工具调用历史里留一条失败记录方便排查。
        result = {
            "content": "<continue_if_no_reply><delay_minutes>6</delay_minutes></continue_if_no_reply>"
        }
        with patch("services.ai_service.execute_continue_if_no_reply") as execute:
            normalized = await _consume_inline_continue_if_no_reply_markup(
                result, {"id": "role-1"}
            )

        self.assertEqual(normalized["content"], "")
        execute.assert_not_awaited()
        self.assertEqual(len(normalized["_tool_calls_log"]), 1)
        self.assertIn("参数不完整", normalized["_tool_calls_log"][0]["result"])

    async def test_no_inline_continue_if_no_reply_markup_is_a_noop(self):
        result = {"content": "普通回复，没有工具标签"}
        normalized = await _consume_inline_continue_if_no_reply_markup(result, {"id": "role-1"})
        self.assertEqual(normalized["content"], "普通回复，没有工具标签")
        self.assertNotIn("_tool_calls_log", normalized)

    async def test_deepseek_tool_call_replays_assistant_message(self):
        result = {
            "assistant_content": None,
            "reasoning_content": "需要表达关心",
            "tool_calls": [{
                "id": "call_love_1",
                "type": "function",
                "function": {
                    "name": "send_emotion_emoji",
                    "arguments": {"emotion": "love"},
                },
            }],
        }
        messages = []
        with patch(
            "services.ai_service.execute_send_emotion_emoji",
            return_value="[love]",
        ), patch(
            "services.ai_service._call_with_role_config",
            return_value={"success": True, "content": "收到啦"},
        ):
            normalized = await _handle_tool_calls(result, messages, {"id": "role-1"}, [])

        self.assertEqual(messages[0]["role"], "assistant")
        self.assertIsNone(messages[0]["content"])
        self.assertEqual(messages[0]["reasoning_content"], "需要表达关心")
        self.assertEqual(messages[1]["tool_call_id"], "call_love_1")
        self.assertEqual(normalized["_emojis_called"], ["love"])

    async def test_cloud_emoji_is_preferred_when_both_emoji_tools_are_called(self):
        result = {
            "tool_calls": [
                {
                    "id": "call_local",
                    "type": "function",
                    "function": {
                        "name": "send_emotion_emoji",
                        "arguments": {"emotion": "love"},
                    },
                },
                {
                    "id": "call_cloud",
                    "type": "function",
                    "function": {
                        "name": "send_emoji",
                        "arguments": {"keyword": "cute", "count": 1, "emotion": "love"},
                    },
                },
            ],
        }
        plugin = type(
            "Plugin",
            (),
            {
                "TOOL_NAMES": {"send_emoji"},
                "execute": AsyncMock(
                    return_value=[{"category": "__cloud__", "filename": "cute.png"}]
                ),
            },
        )()
        with patch(
            "services.ai_service.execute_send_emotion_emoji",
            return_value="[love]",
        ), patch("services.ai_service._emoji_plugin", plugin), patch(
            "services.ai_service._call_with_role_config",
            return_value={"success": True, "content": "ok"},
        ):
            normalized = await _handle_tool_calls(result, [], {"id": "role-1"}, [])

        self.assertEqual(
            normalized["_emojis_called"],
            [{"category": "__cloud__", "filename": "cute.png"}],
        )

    def test_previous_image_cache_keeps_the_complete_batch(self):
        images = [f"data:image/png;base64,image-{index}" for index in range(7)]
        with TemporaryDirectory() as temp_dir, patch.object(
            vision_service, "_VISION_HISTORY_DIR", Path(temp_dir)
        ):
            vision_service.save_previous_images("role-1", "zerochat:chat-1", images)
            loaded = vision_service.load_previous_images("role-1", "zerochat:chat-1")
            other_chat = vision_service.load_previous_images("role-1", "zerochat:chat-2")

        self.assertEqual(loaded, images)
        self.assertEqual(other_chat, [])

    async def test_previous_image_tool_uses_a_new_vision_prompt(self):
        previous_image = "data:image/png;base64,previous-image"
        result = {
            "tool_calls": [{
                "id": "call_previous_image",
                "type": "function",
                "function": {
                    "name": "review_previous_images",
                    "arguments": {
                        "prompt": "只识别图片中的招牌文字",
                        "image_index": 0,
                    },
                },
            }],
        }
        messages = []
        with patch(
            "services.ai_service.execute_recognize_image",
            return_value="招牌写着 ZeroChat",
        ) as recognize, patch(
            "services.ai_service._call_with_role_config",
            return_value={"success": True, "content": "我看到了"},
        ):
            await _handle_tool_calls(
                result,
                messages,
                {"id": "role-1"},
                [],
                vision_context={"previous_image_data_urls": [previous_image]},
            )

        recognize.assert_awaited_once_with(
            [previous_image], "只识别图片中的招牌文字", 0
        )

    async def test_current_image_falls_back_to_recognition_when_model_skips_tool(self):
        current_image = "data:image/png;base64,current-image"
        with patch(
            "services.ai_service._call_with_role_config",
            side_effect=[
                {"success": True, "content": "我先回答文字内容"},
                {"success": True, "content": "结合图片内容的回答"},
            ],
        ) as call_model, patch(
            "services.ai_service.execute_recognize_image",
            return_value="图片里是一只猫",
        ) as recognize:
            result = await generate_with_role(
                {"id": "role-1"},
                "图片里有什么？另外帮我记住这个话题。",
                vision_context={"image_data_urls": [current_image]},
            )

        self.assertEqual(result["content"], "结合图片内容的回答")
        recognize.assert_awaited_once_with(
            [current_image], "图片里有什么？另外帮我记住这个话题。", 0
        )
        self.assertEqual(call_model.await_count, 2)
        fallback_messages = call_model.await_args_list[1].args[1]
        self.assertTrue(
            any(
                message.get("role") == "user"
                and "Image recognition result" in message.get("content", "")
                for message in fallback_messages
            )
        )

    def test_embedding_url_normalization_preserves_provider_base_path(self):
        self.assertEqual(
            _normalize_embedding_url("https://api.example.com/compatible-mode/v1"),
            "https://api.example.com/compatible-mode/v1/embeddings",
        )
        self.assertEqual(
            _normalize_embedding_url("https://api.example.com/v1/chat/completions"),
            "https://api.example.com/v1/embeddings",
        )


if __name__ == "__main__":
    unittest.main()

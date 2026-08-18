import base64
import hashlib
import json
import unittest
from copy import deepcopy
from datetime import date
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import AsyncMock, patch

from routers.ai_behavior import VisionRequest, chat_with_vision
from routers.settings import SettingsUpdate, update_settings
from routers import roles as roles_router
from services.ai_tools import (
    _BLOCK_USER_TOOL,
    _RECOGNIZE_IMAGE_TOOL,
    _REVIEW_PREVIOUS_IMAGES_TOOL,
    _SCHEDULE_TASK_TOOL,
    _SEARCH_MEMORY_TOOL,
    _SEND_EMOTION_EMOJI_TOOL,
    _WEB_SEARCH_TOOL,
    _WRITE_MEMORY_TOOL,
)
from services.ai_service import (
    _post_chat,
    _consume_inline_emoji_tool_markup,
    _handle_tool_calls,
    _normalize_embedding_url,
    generate_with_role,
)
from services.memory_service import _advance_period_cycles
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

    def test_period_cycle_advance_applies_a_bounded_variation(self):
        with patch("services.memory_service.random.randint", return_value=-2):
            advanced = _advance_period_cycles(
                date(2026, 1, 1), 28, date(2026, 1, 30)
            )

        self.assertEqual(advanced, date(2026, 1, 27))

    def test_role_period_start_edit_resets_runtime_cycle_anchor(self):
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

                profile["menstruation_cycle"]["last_period_start"] = "2026-02-15"
                roles_router.save_role(role_id, profile)

                with memory_service._get_connection(role_id) as conn:
                    self.assertEqual(
                        memory_service._get_meta(conn, "last_period_start"),
                        "2026-02-15",
                    )
                    self.assertIsNone(
                        memory_service._get_meta(conn, "next_period_start")
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

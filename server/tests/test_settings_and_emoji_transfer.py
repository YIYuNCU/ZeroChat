import base64
import hashlib
import json
import unittest
from datetime import date
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

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
                message.get("role") == "system"
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

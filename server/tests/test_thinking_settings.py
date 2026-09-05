import unittest
from unittest.mock import AsyncMock, Mock, patch

from routers import roles, settings
from services import ai_service, settings_service
from transport import ws_dispatcher


class ThinkingSettingsTests(unittest.IsolatedAsyncioTestCase):
    async def request_payload(self, model, url, **options):
        response = Mock()
        response.json.return_value = {
            "choices": [{"message": {"content": "ok"}}],
            "candidates": [{"content": {"parts": [{"text": "ok"}]}}],
        }
        client = Mock(post=AsyncMock(return_value=response))
        with patch.object(ai_service, "_get_http_client", return_value=client):
            result = await ai_service._post_chat(
                [{"role": "user", "content": "hello"}], url, "key", model,
                0.7, 1024, **options,
            )
        self.assertTrue(result["success"])
        return client.post.call_args.kwargs["json"]

    async def test_role_switch_overrides_global_in_both_directions(self):
        for enabled in (True, False):
            with self.subTest(enabled=enabled), patch.object(
                settings_service, "load_settings", return_value={
                    "thinking_enabled": not enabled,
                    "ai_api_url": "https://api.deepseek.com/v1",
                    "ai_api_key": "key", "ai_model": "deepseek-chat",
                },
            ), patch.object(ai_service, "_post_chat", new=AsyncMock()) as post:
                await ai_service._call_with_role_config(
                    {"ai_thinking_enabled": enabled, "ai_thinking_budget": 2048}, [],
                )
                self.assertEqual(post.call_args.kwargs["thinking_enabled"], enabled)
                self.assertEqual(post.call_args.kwargs["thinking_budget"], 2048)

    async def test_hosted_deepseek_uses_provider_budget_and_switch(self):
        for host in ("api.siliconflow.cn", "dashscope.aliyuncs.com"):
            for enabled in (True, False):
                with self.subTest(host=host, enabled=enabled):
                    payload = await self.request_payload(
                        "deepseek-ai/DeepSeek-V3", f"https://{host}/v1",
                        thinking_enabled=enabled, thinking_budget=8192,
                        reasoning_effort="high",
                    )
                    self.assertEqual(payload["enable_thinking"], enabled)
                    self.assertNotIn("thinking", payload)
                    self.assertNotIn("reasoning_effort", payload)
                    self.assertEqual(payload.get("thinking_budget"), 8192 if enabled else None)

    async def test_native_gemini_budget_and_disable(self):
        for enabled in (True, False):
            payload = await self.request_payload(
                "gemini-2.5-flash", "https://gateway.example/v1beta",
                api_format="gemini_native", thinking_enabled=enabled,
                thinking_budget=4096,
            )
            self.assertEqual(payload["generationConfig"]["thinkingConfig"],
                             {"thinkingBudget": 4096 if enabled else 0})

    async def test_deepseek_and_mimo_explicit_thinking(self):
        for model in ("deepseek-chat", "mimo-v2-flash"):
            for enabled in (True, False):
                payload = await self.request_payload(
                    model, "https://gateway.example/v1", thinking_enabled=enabled,
                    thinking_budget=4096, reasoning_effort="high",
                )
                self.assertEqual(payload["thinking"]["type"], "enabled" if enabled else "disabled")
                self.assertNotIn("thinking_budget", payload)
                self.assertEqual(payload.get("reasoning_effort"), "high" if enabled else None)

    async def test_standard_models_do_not_receive_disable_extension(self):
        for model in ("gpt-4o", "gpt-5.1-codex", "gpt-5.2-codex"):
            payload = await self.request_payload(
                model, "https://api.openai.com/v1", thinking_enabled=False,
            )
            self.assertNotIn("reasoning_effort", payload)
            self.assertNotIn("thinking", payload)

    async def test_settings_rest_and_websocket_accept_all_thinking_fields(self):
        values = {
            "thinking_enabled": False, "ai_thinking_budget": 4096,
            "model_thinking_settings": {"vision": {
                "thinking_enabled": True, "thinking_budget": 8192,
                "reasoning_effort": "high",
            }},
        }
        for transport in ("rest", "websocket"):
            with self.subTest(transport=transport), patch.object(
                settings_service, "save_settings", return_value=True,
            ) as save:
                if transport == "rest":
                    await settings.update_settings(settings.SettingsUpdate(**values))
                else:
                    await ws_dispatcher._handle_settings_update({"updates": values}, "")
                self.assertEqual(save.call_args.args[0], values)

    async def test_role_rest_and_websocket_clear_overrides(self):
        values = dict(ai_thinking_enabled=None, ai_thinking_budget=None, ai_reasoning_effort=None)
        for transport in ("rest", "websocket"):
            existing = dict(id="role", name="Role", ai_thinking_enabled=False,
                            ai_thinking_budget=4096, ai_reasoning_effort="high")
            with self.subTest(transport=transport), patch.object(
                roles, "load_role", return_value=existing,
            ), patch.object(roles, "save_role"), patch.object(
                roles, "normalize_role_avatar_url", side_effect=lambda role, _: role,
            ):
                if transport == "rest":
                    await roles.update_role("role", roles.RoleUpdate(**values), Mock())
                else:
                    await ws_dispatcher._handle_roles_upsert(
                        {"role": {"id": "role", "name": "Role", **values}}, "",
                    )
                for key in values:
                    self.assertIsNone(existing[key])

    def test_auxiliary_configuration_and_legacy_inheritance(self):
        with patch.object(settings_service, "load_settings", return_value={
            "thinking_enabled": False, "ai_thinking_budget": 4096,
            "model_thinking_settings": {"intent": {
                "thinking_enabled": True, "thinking_budget": 1024,
            }},
        }):
            self.assertFalse(settings_service.get_thinking_config()["thinking_enabled"])
            self.assertEqual(settings_service.get_thinking_config("intent")["thinking_budget"], 1024)
            self.assertTrue(settings_service.get_thinking_config("intent")["thinking_enabled"])


if __name__ == "__main__":
    unittest.main()

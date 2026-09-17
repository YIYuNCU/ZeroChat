"""Route/WS wiring for the configurable prompts and the two summary configs."""
import asyncio
import copy
import unittest
from pathlib import Path
from unittest.mock import patch

from routers import settings as settings_routes
from services import prompt_config_service, settings_service, summary_config_service
from transport import ws_dispatcher


class PromptRegistryRouteTests(unittest.TestCase):
    def test_prompts_route_returns_registry_and_overrides(self):
        settings = {
            "prompt_overrides": {prompt_config_service.CHAT_NO_REPLY_ID: {"default": "x"}},
            "model_prompt_overrides": {"https://a|m": {prompt_config_service.CHAT_NO_REPLY_ID: {"default": "y"}}},
        }
        with patch.object(settings_service, "load_settings", return_value=settings):
            payload = asyncio.run(settings_routes.get_prompt_registry(None))

        self.assertIn(prompt_config_service.CHAT_NO_REPLY_ID, payload["prompts"])
        self.assertEqual(payload["overrides"], settings["prompt_overrides"])
        self.assertEqual(
            payload["reserved_keys"]["builtin"], prompt_config_service.BUILTIN_OVERRIDE_KEY,
        )

    def test_prompts_route_can_filter_to_summary_prompts(self):
        with patch.object(settings_service, "load_settings", return_value={}):
            payload = asyncio.run(settings_routes.get_prompt_registry("summary"))
        self.assertTrue(payload["prompts"])
        self.assertTrue(all(
            "summary" in item["applies_to"] for item in payload["prompts"].values()
        ))

    def test_summary_route_masks_api_keys(self):
        with patch.object(summary_config_service, "load_summary_config") as load, patch.object(
            summary_config_service, "resolve_summary_config",
            return_value={"configured": True, "model": "m"},
        ):
            load.return_value = {"api_key": "secret-key", "model": "m", "api_url": "u"}
            payload = asyncio.run(settings_routes.get_summary_settings())

        for kind in summary_config_service.SUMMARY_KINDS:
            with self.subTest(kind=kind):
                entry = payload["summaries"][kind]
                self.assertNotIn("api_key", entry)
                self.assertTrue(entry["configured"])


class WsDispatcherWiringTests(unittest.TestCase):
    def test_first_settings_read_migrates_before_full_client_sync(self):
        for transport in ('rest', 'ws'):
            for include_secrets in (False, True):
                with self.subTest(transport=transport, include_secrets=include_secrets):
                    stored = {}

                    def save(updates):
                        stored.update(copy.deepcopy(updates))
                        return True

                    legacy = {'ai_api_url': 'https://legacy.example/v1',
                              'ai_api_key': 'legacy-secret-key', 'ai_model': 'legacy-model'}
                    with patch.object(settings_service, 'load_settings',
                                      side_effect=lambda: copy.deepcopy(stored)), patch.object(
                        settings_service, 'save_settings', side_effect=save,
                    ), patch('routers.roles.load_role', return_value=legacy):
                        if transport == 'rest':
                            response = asyncio.run(settings_routes.get_settings(include_secrets))
                        else:
                            response = asyncio.run(ws_dispatcher._handle_settings_get(
                                {'include_secrets': include_secrets}, 'http://localhost'))
                        updates = {}
                        for key in summary_config_service.CONFIG_KEYS.values():
                            config = response['settings'][key]
                            self.assertEqual(config['model'], 'legacy-model')
                            self.assertEqual('api_key' in config, include_secrets)
                            updates[key] = {k: v for k, v in config.items() if k != 'api_key_masked'}
                        if transport == 'rest':
                            result = asyncio.run(settings_routes.update_settings(
                                settings_routes.SettingsUpdate(**updates)))
                        else:
                            result = asyncio.run(ws_dispatcher._handle_settings_update(
                                {'updates': updates}, 'http://localhost'))
                        self.assertTrue(result['success'])
                        for key in updates:
                            self.assertEqual(stored[key]['api_key'], 'legacy-secret-key')
                            self.assertEqual(stored[key]['model'], 'legacy-model')

    def test_summary_nullable_fields_distinguish_omitted_from_explicit_null(self):
        for transport in ('rest', 'ws'):
            with self.subTest(transport=transport):
                stored = {summary_config_service.MIGRATION_FLAG_KEY: True,
                          **{key: {'thinking_enabled': False, 'thinking_budget': 4096}
                             for key in summary_config_service.CONFIG_KEYS.values()}}

                def save(updates):
                    stored.update(copy.deepcopy(updates))
                    return True

                with patch.object(settings_service, 'load_settings',
                                  side_effect=lambda: copy.deepcopy(stored)), patch.object(
                    settings_service, 'save_settings', side_effect=save,
                ):
                    for change in ({'temperature': 0.8},
                                   {'thinking_enabled': None, 'thinking_budget': None}):
                        updates = {key: change for key in summary_config_service.CONFIG_KEYS.values()}
                        if transport == 'rest':
                            result = asyncio.run(settings_routes.update_settings(
                                settings_routes.SettingsUpdate(**updates)))
                        else:
                            result = asyncio.run(ws_dispatcher._handle_settings_update(
                                {'updates': updates}, 'http://localhost'))
                        self.assertTrue(result['success'])
                        for key in updates:
                            self.assertEqual(stored[key]['thinking_enabled'],
                                             None if 'thinking_enabled' in change else False)
                            self.assertEqual(stored[key]['thinking_budget'],
                                             None if 'thinking_budget' in change else 4096)

    def test_prompt_and_summary_actions_are_routed(self):
        source = Path(ws_dispatcher.__file__).read_text(encoding="utf-8")
        self.assertIn('action == "settings_prompts_get"', source)
        self.assertIn('action == "settings_summary_get"', source)

    def test_settings_update_accepts_summary_and_prompt_fields(self):
        update = settings_routes.SettingsUpdate(
            context_summary_config={"model": "summary-model", "temperature": 0.4},
            core_memory_summary_config={"enabled": False},
            prompt_overrides={prompt_config_service.CHAT_NO_REPLY_ID: {"default": "自定义"}},
            model_prompt_overrides={
                "https://api.example.com|gpt-4o": {
                    prompt_config_service.CHAT_NO_REPLY_ID: {"default": "档案级"},
                },
            },
        )
        self.assertEqual(update.context_summary_config.model, "summary-model")
        self.assertFalse(update.core_memory_summary_config.enabled)
        self.assertEqual(
            update.prompt_overrides[prompt_config_service.CHAT_NO_REPLY_ID]["default"],
            "自定义",
        )

    def test_settings_update_normalizes_through_the_services(self):
        captured: dict = {}

        def _save(updates):
            captured.update(updates)
            return True

        with patch.object(settings_service, "load_settings", return_value={}), patch.object(
            settings_service, "save_settings", side_effect=_save,
        ):
            asyncio.run(settings_routes.update_settings(settings_routes.SettingsUpdate(
                context_summary_config={"temperature": 1.5, "api_format": "gemini_native"},
                prompt_overrides={
                    prompt_config_service.CHAT_NO_REPLY_ID: {"default": "  " + "y" * 30},
                },
            )))

        self.assertEqual(captured["context_summary_config"]["temperature"], 1.5)
        self.assertEqual(
            captured["context_summary_config"]["api_format"], "gemini_native",
        )
        # 提示词正文原样保存（首尾空白可能是有意的格式），仅在解析时判断是否为空。
        self.assertEqual(
            captured["prompt_overrides"][prompt_config_service.CHAT_NO_REPLY_ID]["default"],
            "  " + "y" * 30,
        )

    def test_route_partial_summary_update_preserves_credentials(self):
        key = summary_config_service.CONFIG_KEYS[summary_config_service.CONTEXT_SUMMARY]
        stored = {
            summary_config_service.MIGRATION_FLAG_KEY: True,
            key: {
                "api_url": "https://summary.example.com",
                "api_key": "summary-key",
                "model": "summary-model",
            },
        }

        def _save(updates):
            stored.update(updates)
            return True

        with patch.object(settings_service, "load_settings", side_effect=lambda: dict(stored)), patch.object(
            settings_service, "save_settings", side_effect=_save,
        ):
            result = asyncio.run(settings_routes.update_settings(
                settings_routes.SettingsUpdate(context_summary_config={"temperature": 1.5}),
            ))

        self.assertTrue(result["success"])
        self.assertEqual(stored[key]["api_url"], "https://summary.example.com")
        self.assertEqual(stored[key]["api_key"], "summary-key")
        self.assertEqual(stored[key]["model"], "summary-model")
        self.assertEqual(stored[key]["temperature"], 1.5)

    def test_route_reports_summary_config_save_failure(self):
        with patch.object(summary_config_service, "update_summary_config", return_value=False):
            result = asyncio.run(settings_routes.update_settings(
                settings_routes.SettingsUpdate(context_summary_config={"temperature": 1.5}),
            ))

        self.assertFalse(result["success"])

    def test_out_of_range_summary_values_are_rejected_at_the_api_boundary(self):
        from pydantic import ValidationError

        for payload in (
            {"temperature": 9},
            {"timeout_seconds": 0},
            {"thinking_budget": -1},
        ):
            with self.subTest(payload=payload), self.assertRaises(ValidationError):
                settings_routes.SettingsUpdate(context_summary_config=payload)


if __name__ == "__main__":
    unittest.main()

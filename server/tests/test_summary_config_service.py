"""Tests for the role-independent memory-summary configuration."""
import unittest
from pathlib import Path
from unittest.mock import patch

from services import prompt_config_service, settings_service, summary_config_service as summaries


class SummaryConfigTests(unittest.TestCase):
    def setUp(self):
        # Start from a clean, already-migrated store so these tests never read the real
        # config/settings.json or the on-disk legacy tool-role profiles.
        self.settings: dict = {summaries.MIGRATION_FLAG_KEY: True}

        def _load():
            return dict(self.settings)

        def _save(updates):
            self.settings.update(updates)
            settings_service._invalidate_cache()
            return True

        self.enterContext(patch.object(
            settings_service, "load_settings", side_effect=_load,
        ))
        self.enterContext(patch.object(
            settings_service, "save_settings", side_effect=_save,
        ))

    # ---- defaults & fallbacks -------------------------------------------------

    def test_defaults_are_disabled_free_and_fall_back_to_chat_api(self):
        with patch.object(
            settings_service, "get_ai_config",
            return_value={
                "api_url": "https://chat.example.com",
                "api_key": "chat-key",
                "model": "chat-model",
                "api_format": "openai_compatible",
                "reasoning_effort": "high",
                "timeout_seconds": 45,
            },
        ), patch.object(
            settings_service, "get_thinking_config",
            return_value={"thinking_enabled": False, "thinking_budget": 512},
        ):
            resolved = summaries.resolve_summary_config(summaries.CONTEXT_SUMMARY)

        self.assertTrue(resolved["enabled"])
        self.assertEqual(resolved["api_url"], "https://chat.example.com")
        self.assertEqual(resolved["api_key"], "chat-key")
        self.assertEqual(resolved["model"], "chat-model")
        self.assertEqual(resolved["api_format"], "openai_compatible")
        self.assertEqual(resolved["reasoning_effort"], "high")
        self.assertFalse(resolved["thinking_enabled"])
        self.assertEqual(resolved["thinking_budget"], 512)
        self.assertTrue(resolved["configured"])
        # 提示词回退到注册表内置文本
        self.assertEqual(
            resolved["system_prompt"],
            prompt_config_service.resolve(prompt_config_service.SUMMARY_CONTEXT_EVENTS_ID),
        )

    def test_configured_values_win_over_the_chat_api(self):
        self.settings[summaries.CONFIG_KEYS[summaries.CONTEXT_SUMMARY]] = {
            "api_url": "https://summary.example.com",
            "api_key": "summary-key",
            "model": "summary-model",
            "temperature": 0.5,
            "timeout_seconds": 30,
        }
        with patch.object(
            settings_service, "get_ai_config",
            return_value={"api_url": "https://chat.example.com", "api_key": "chat-key",
                          "model": "chat-model", "api_format": "auto"},
        ), patch.object(
            settings_service, "get_thinking_config",
            return_value={"thinking_enabled": True, "thinking_budget": None},
        ):
            resolved = summaries.resolve_summary_config(summaries.CONTEXT_SUMMARY)

        self.assertEqual(resolved["api_url"], "https://summary.example.com")
        self.assertEqual(resolved["model"], "summary-model")
        self.assertEqual(resolved["temperature"], 0.5)
        self.assertEqual(resolved["timeout_seconds"], 30)

    def test_independent_auto_endpoint_does_not_inherit_gemini_protocol(self):
        self.settings.update({
            "ai_api_format": "gemini_native",
            "context_summary_config": {
                "api_url": "https://summary.example.com",
                "api_format": "auto",
            },
        })
        resolved = summaries.resolve_summary_config(summaries.CONTEXT_SUMMARY)
        self.assertEqual(resolved["api_format"], "auto")

    def test_legacy_thinking_metadata_is_migrated_with_top_level_precedence(self):
        self.settings.pop(summaries.MIGRATION_FLAG_KEY, None)
        self.settings.update({"thinking_enabled": True, "ai_thinking_budget": 2048,
                              "ai_reasoning_effort": "high"})
        with patch("routers.roles.load_role", return_value={
            "ai_thinking_enabled": None,
            "ai_reasoning_effort": "medium",
            "metadata": {"ai_thinking_enabled": False, "ai_thinking_budget": 8192,
                         "ai_reasoning_effort": "low"},
        }):
            resolved = summaries.resolve_summary_config(summaries.CONTEXT_SUMMARY)
        self.assertFalse(resolved["thinking_enabled"])
        self.assertEqual(resolved["thinking_budget"], 8192)
        self.assertEqual(resolved["reasoning_effort"], "medium")

    def test_incomplete_config_is_reported_as_not_configured(self):
        with patch.object(
            settings_service, "get_ai_config",
            return_value={"api_url": "", "api_key": "", "model": "", "api_format": "auto"},
        ), patch.object(
            settings_service, "get_thinking_config",
            return_value={"thinking_enabled": True, "thinking_budget": None},
        ):
            resolved = summaries.resolve_summary_config(summaries.CORE_MEMORY_SUMMARY)
        self.assertFalse(resolved["configured"])

    def test_sanitize_clamps_and_normalizes(self):
        cleaned = summaries.sanitize_summary_config({
            "enabled": False,
            "api_format": "GEMINI_NATIVE",
            "temperature": 99,
            "timeout_seconds": 0,
            "thinking_budget": -3,
            "system_prompt": " 补充要求 ",
        })
        self.assertFalse(cleaned["enabled"])
        self.assertEqual(cleaned["api_format"], "gemini_native")
        self.assertEqual(cleaned["temperature"], 2.0)
        self.assertEqual(cleaned["timeout_seconds"], 1)
        self.assertIsNone(cleaned["thinking_budget"])
        self.assertEqual(cleaned["system_prompt"], "补充要求")

    def test_stored_system_prompt_is_appended_to_the_builtin(self):
        self.settings[summaries.CONFIG_KEYS[summaries.CONTEXT_SUMMARY]] = {
            "system_prompt": "额外要求",
        }
        with patch.object(
            settings_service, "get_ai_config",
            return_value={"api_url": "u", "api_key": "k", "model": "m", "api_format": "auto"},
        ), patch.object(
            settings_service, "get_thinking_config",
            return_value={"thinking_enabled": True, "thinking_budget": None},
        ):
            resolved = summaries.resolve_summary_config(summaries.CONTEXT_SUMMARY)
        self.assertTrue(resolved["system_prompt"].endswith("额外要求"))
        self.assertIn(
            prompt_config_service.SUMMARY_CONTEXT_EVENTS[:12], resolved["system_prompt"],
        )

    # ---- migration ------------------------------------------------------------

    def test_legacy_tool_role_profile_is_migrated_once(self):
        self.settings.clear()
        calls = []

        def _load_role(worker_id):
            calls.append(worker_id)
            return {
                "ai_api_url": "https://legacy.example.com",
                "ai_api_key": "legacy-key",
                "ai_model": "legacy-model",
                "ai_api_format": "openai_compatible",
                "ai_temperature": 0.2,
            }

        with patch("routers.roles.load_role", side_effect=_load_role):
            first = summaries.load_summary_config(summaries.CONTEXT_SUMMARY)
            second = summaries.load_summary_config(summaries.CONTEXT_SUMMARY)

        self.assertEqual(first["model"], "legacy-model")
        self.assertEqual(first["api_url"], "https://legacy.example.com")
        self.assertEqual(second["model"], "legacy-model")
        self.assertEqual(len(calls), 2, "每个总结功能各读取一次自己的旧助手档案")
        self.assertIn("1000000000002", calls)
        self.assertTrue(self.settings[summaries.MIGRATION_FLAG_KEY])

        # 迁移完成后不再读取角色档案
        calls.clear()
        with patch("routers.roles.load_role", side_effect=_load_role):
            summaries.load_summary_config(summaries.CORE_MEMORY_SUMMARY)
        self.assertEqual(calls, [])

    def test_migration_does_not_override_existing_config(self):
        self.settings.pop(summaries.MIGRATION_FLAG_KEY, None)
        self.settings[summaries.CONFIG_KEYS[summaries.CORE_MEMORY_SUMMARY]] = {
            "api_url": "https://kept.example.com",
            "api_key": "kept",
            "model": "kept-model",
        }
        with patch("routers.roles.load_role", side_effect=AssertionError("不应读取旧档案")):
            stored = summaries.load_summary_config(summaries.CORE_MEMORY_SUMMARY)
        self.assertEqual(stored["model"], "kept-model")

    def test_migration_does_not_override_explicit_non_api_settings(self):
        self.settings.pop(summaries.MIGRATION_FLAG_KEY, None)
        explicit = {"enabled": False, "temperature": 1.2, "system_prompt": "keep"}
        self.settings[summaries.CONFIG_KEYS[summaries.CONTEXT_SUMMARY]] = explicit
        self.settings[summaries.CONFIG_KEYS[summaries.CORE_MEMORY_SUMMARY]] = explicit
        with patch("routers.roles.load_role", side_effect=AssertionError("must not migrate")):
            stored = summaries.load_summary_config(summaries.CONTEXT_SUMMARY)
        self.assertFalse(stored["enabled"])
        self.assertEqual(stored["temperature"], 1.2)
        self.assertEqual(stored["system_prompt"], "keep")

    def test_migration_survives_a_missing_legacy_profile(self):
        self.settings.pop(summaries.MIGRATION_FLAG_KEY, None)
        with patch("routers.roles.load_role", side_effect=RuntimeError("missing")):
            stored = summaries.load_summary_config(summaries.CONTEXT_SUMMARY)
        self.assertEqual(stored["model"], "")
        self.assertTrue(self.settings[summaries.MIGRATION_FLAG_KEY])

    def test_save_round_trip(self):
        self.assertTrue(summaries.save_summary_config(
            summaries.CORE_MEMORY_SUMMARY,
            {"model": "saved-model", "temperature": 1.5},
        ))
        stored = summaries.load_summary_config(summaries.CORE_MEMORY_SUMMARY)
        self.assertEqual(stored["model"], "saved-model")
        self.assertEqual(stored["temperature"], 1.5)

    def test_partial_update_preserves_existing_summary_credentials(self):
        key = summaries.CONFIG_KEYS[summaries.CONTEXT_SUMMARY]
        self.settings[key] = {
            "api_url": "https://summary.example.com",
            "api_key": "summary-key",
            "model": "summary-model",
        }
        self.assertTrue(summaries.update_summary_config(
            summaries.CONTEXT_SUMMARY, {"temperature": 1.5},
        ))
        stored = summaries.load_summary_config(summaries.CONTEXT_SUMMARY)
        self.assertEqual(stored["api_key"], "summary-key")
        self.assertEqual(stored["model"], "summary-model")
        self.assertEqual(stored["temperature"], 1.5)

    def test_unknown_kind_raises(self):
        with self.assertRaises(ValueError):
            summaries.load_summary_config("nope")


class SummaryServiceWiringTests(unittest.TestCase):
    def test_memory_service_uses_summary_config_without_roles(self):
        import inspect
        from services import memory_service

        source = inspect.getsource(memory_service._trigger_chat_summary)
        self.assertIn("resolve_summary_config", source)
        self.assertNotIn("load_role", source)
        core_source = inspect.getsource(memory_service._trigger_memory_summary)
        self.assertIn("resolve_summary_config", core_source)
        self.assertNotIn("load_role", core_source)

    def test_trigger_chat_summary_no_longer_takes_a_worker_id(self):
        import inspect
        from services import memory_service

        signature = inspect.signature(memory_service.trigger_chat_summary)
        self.assertNotIn("worker_id", signature.parameters)

    def test_tool_prompts_are_backed_by_the_registry(self):
        from services import tool_prompts

        for worker_id, prompt_id in tool_prompts._WORKER_PROMPT_IDS.items():
            with self.subTest(worker_id=worker_id):
                with patch.object(
                    prompt_config_service.settings_service, "load_settings",
                    return_value={},
                ):
                    self.assertEqual(
                        tool_prompts.get_tool_prompt(worker_id),
                        prompt_config_service.resolve(prompt_id),
                    )
        self.assertEqual(tool_prompts.get_tool_prompt("3000000000000", "fallback"), "fallback")


class SummaryPromptScopingTests(unittest.TestCase):
    """总结提示词既不能混进聊天系统提示词，也要能按模型档案微调。"""

    def test_summary_prompts_are_not_declared_for_chat(self):
        snapshot = prompt_config_service.registry_snapshot()
        summary_ids = {
            prompt_id for prompt_id, meta in snapshot.items()
            if "summary" in meta["applies_to"]
        }
        self.assertEqual(
            summary_ids,
            {summaries.PROMPT_IDS[summaries.CONTEXT_SUMMARY],
             summaries.PROMPT_IDS[summaries.CORE_MEMORY_SUMMARY]},
        )
        for prompt_id in summary_ids:
            with self.subTest(prompt_id=prompt_id):
                self.assertNotIn("chat", snapshot[prompt_id]["applies_to"])

    def test_chat_registry_listing_excludes_summary_prompts(self):
        chat_ids = set(prompt_config_service.registry_snapshot(applies_to="chat"))
        self.assertTrue(chat_ids)
        for prompt_id in summaries.PROMPT_IDS.values():
            with self.subTest(prompt_id=prompt_id):
                self.assertNotIn(prompt_id, chat_ids)

    def test_chat_system_prompt_never_contains_summary_text(self):
        from services import ai_service

        role = {"id": "1", "name": "T", "persona": "人设", "ai_model": "deepseek-chat"}
        with patch.object(settings_service, "load_settings", return_value={}):
            built = ai_service._build_system_prompt(role, settings={})
        for prompt_id in summaries.PROMPT_IDS.values():
            builtin = prompt_config_service.PROMPT_REGISTRY[prompt_id].builtin
            probe = builtin[len(builtin) // 3: len(builtin) // 3 + 40].strip()
            with self.subTest(prompt_id=prompt_id):
                self.assertTrue(probe)
                self.assertNotIn(probe, built)

    def test_summary_prompt_accepts_global_and_model_profile_overrides(self):
        prompt_id = summaries.PROMPT_IDS[summaries.CONTEXT_SUMMARY]
        url, model = "https://api.example.com/v1", "summary-model"
        glob = {"prompt_overrides": {prompt_id: {"__builtin__": "全局总结提示词"}}}
        prof = {
            "model_prompt_overrides": {
                prompt_config_service.model_target_key(url, model): {
                    prompt_id: {"__builtin__": "档案总结提示词"},
                },
            },
        }
        with patch.object(settings_service, "load_settings", return_value={}):
            builtin = summaries.summary_system_prompt(
                summaries.CONTEXT_SUMMARY, model=model, api_url=url,
            )
        with patch.object(settings_service, "load_settings", return_value=glob):
            global_text = summaries.summary_system_prompt(
                summaries.CONTEXT_SUMMARY, model=model, api_url=url,
            )
        with patch.object(settings_service, "load_settings", return_value=prof):
            profile_text = summaries.summary_system_prompt(
                summaries.CONTEXT_SUMMARY, model=model, api_url=url,
            )

        self.assertNotIn("全局总结提示词", builtin)
        self.assertEqual(global_text, "全局总结提示词")
        self.assertEqual(profile_text, "档案总结提示词")

    def test_stored_prompt_is_appended_after_the_resolved_base(self):
        with patch.object(settings_service, "load_settings", return_value={
            "prompt_overrides": {
                summaries.PROMPT_IDS[summaries.CORE_MEMORY_SUMMARY]: {
                    "__builtin__": "基础核心记忆提示词",
                },
            },
        }):
            text = summaries.summary_system_prompt(
                summaries.CORE_MEMORY_SUMMARY, stored_prompt="补充输出格式",
            )
        self.assertEqual(text, "基础核心记忆提示词\n\n补充输出格式")


class MainStartupTests(unittest.TestCase):
    def test_no_pydantic_protected_namespace_warnings_from_settings_routes(self):
        import warnings

        from routers import settings as settings_router

        for model in (
            settings_router.SettingsUpdate,
            settings_router.ModelThinkingSettings,
            settings_router.SummaryConfigUpdate,
        ):
            with self.subTest(model=model.__name__):
                with warnings.catch_warnings(record=True) as caught:
                    warnings.simplefilter("always")
                    model.model_rebuild(force=True)
                self.assertFalse(
                    [item for item in caught if "protected namespace" in str(item.message)],
                )

    def test_summary_update_model_forbids_unknown_fields(self):
        from pydantic import ValidationError

        from routers import settings as settings_router

        with self.assertRaises(ValidationError):
            settings_router.SummaryConfigUpdate(nope=True)


class SettingsDefaultsTests(unittest.TestCase):
    def test_default_settings_expose_the_new_keys(self):
        defaults = settings_service.get_default_settings()
        for key in (
            "context_summary_config",
            "core_memory_summary_config",
            "prompt_overrides",
            "model_prompt_overrides",
        ):
            with self.subTest(key=key):
                self.assertIn(key, defaults)
        self.assertEqual(
            defaults["context_summary_config"],
            settings_service.default_summary_config(),
        )

    def test_example_settings_file_is_valid_json(self):
        import json

        path = Path(__file__).resolve().parent.parent / "config" / "settings.example.json"
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
        self.assertIn("context_summary_config", data)
        self.assertIn("core_memory_summary_config", data)
        self.assertIn("prompt_overrides", data)


if __name__ == "__main__":
    unittest.main()

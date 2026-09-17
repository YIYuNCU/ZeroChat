"""Tests for the configurable system-prompt registry."""
import unittest
from unittest.mock import patch

from services import prompt_config_service as prompts


class PromptRegistryTests(unittest.TestCase):
    def test_resolve_matches_legacy_constants_without_overrides(self):
        # The chat protocol/no-reply blocks carry `{NO_REPLY_DIRECTIVE}` and the onebot
        # directive carries `{MAIN_QQ_HINT}`; with the defaults (empty) the resolved text
        # must reproduce the legacy constants.
        def _legacy(text: str) -> str:
            return text.replace("{NO_REPLY_DIRECTIVE}", "").replace("{MAIN_QQ_HINT}", "")

        for prompt_id, expected in [
            (prompts.CHAT_FORMAT_PROTOCOL_ID, prompts.CHAT_FORMAT_PROTOCOL),
            (prompts.CHAT_SOUND_DEDUP_ID, prompts.CHAT_SOUND_DEDUP),
            (prompts.CHAT_NO_REPLY_ID, prompts.CHAT_NO_REPLY),
            (prompts.ONEBOT_SYSTEM_DIRECTIVE_ID, prompts.ONEBOT_SYSTEM_DIRECTIVE),
            (prompts.SUMMARY_CONTEXT_EVENTS_ID, prompts.SUMMARY_CONTEXT_EVENTS),
            (prompts.SUMMARY_CORE_MEMORY_ID, prompts.SUMMARY_CORE_MEMORY),
        ]:
            with self.subTest(prompt_id=prompt_id):
                self.assertEqual(
                    prompts.resolve(prompt_id, settings={}, render={}),
                    _legacy(expected),
                )

    def test_tool_rules_expand_placeholders(self):
        text = prompts.resolve(
            prompts.CHAT_TOOL_RULES_ID,
            settings={},
            render={
                prompts.EMOJI_TOOL_RULE_PLACEHOLDER: "EMOJI",
                "TOOL_POLICY_CONSERVATIVE": "POLICY",
            },
        )
        self.assertIn("POLICY", text)
        self.assertIn("EMOJI", text)
        self.assertNotIn("{EMOJI_TOOL_RULE}", text)
        self.assertNotIn("{TOOL_POLICY_CONSERVATIVE}", text)

    def test_cloud_emoji_variant_swaps_the_tool_branch(self):
        default_text = prompts.resolve(prompts.CHAT_TOOL_RULES_ID, settings={})
        cloud_text = prompts.resolve(
            prompts.CHAT_TOOL_RULES_ID, settings={}, variant="cloud_emoji",
        )
        self.assertIn("send_emotion_emoji", default_text)
        self.assertIn("send_emoji", cloud_text)
        self.assertNotIn("send_emotion_emoji", cloud_text)

    def test_model_profile_override_beats_global_override(self):
        settings = {
            "prompt_overrides": {prompts.CHAT_NO_REPLY_ID: {"zerochat": "全局"}},
            "model_prompt_overrides": {
                prompts.model_target_key("https://api.example.com", "GPT-4O"): {
                    prompts.CHAT_NO_REPLY_ID: {"zerochat": "档案"},
                },
            },
        }
        self.assertEqual(
            prompts.resolve(
                prompts.CHAT_NO_REPLY_ID,
                settings=settings,
                api_url="https://api.example.com",
                model="gpt-4o",
            ),
            "档案",
        )
        self.assertEqual(
            prompts.resolve(
                prompts.CHAT_NO_REPLY_ID,
                settings=settings,
                api_url="https://other.example.com",
                model="gpt-4o",
            ),
            "全局",
        )

    def test_role_metadata_override_wins_over_everything(self):
        settings = {
            "prompt_overrides": {prompts.CHAT_NO_REPLY_ID: {"zerochat": "全局"}},
        }
        role_data = {"metadata": {"prompt_overrides": {
            prompts.CHAT_NO_REPLY_ID: {"zerochat": "角色"},
        }}}
        self.assertEqual(
            prompts.resolve(
                prompts.CHAT_NO_REPLY_ID, settings=settings, role_data=role_data,
            ),
            "角色",
        )

    def test_builtin_override_key_replaces_whole_template(self):
        settings = {
            "prompt_overrides": {
                prompts.CHAT_USER_MESSAGE_JSON_HINT_ID: {
                    prompts.BUILTIN_OVERRIDE_KEY: "自定义用户消息说明",
                },
            },
        }
        self.assertEqual(
            prompts.resolve(prompts.CHAT_USER_MESSAGE_JSON_HINT_ID, settings=settings),
            "自定义用户消息说明",
        )

    def test_model_profile_override_replaces_the_template_too(self):
        with patch.object(
            prompts.settings_service, "load_settings",
            return_value={
                "model_prompt_overrides": {
                    "https://api.example.com|m": {
                        prompts.CHAT_NO_REPLY_ID: {"__builtin__": "档案级"},
                    },
                },
            },
        ):
            self.assertEqual(
                prompts.resolve(
                    prompts.CHAT_NO_REPLY_ID,
                    api_url="https://api.example.com",
                    model="m",
                ),
                "档案级",
            )

    def test_tool_prompts_are_not_editable(self):
        """工具调用提示词完全由代码维护：不进列表、不受覆盖影响、写不进设置。"""
        for prompt_id in (
            prompts.CHAT_TOOL_RULES_ID,
            prompts.CHAT_TOOL_POLICY_CONSERVATIVE_ID,
        ):
            with self.subTest(prompt_id=prompt_id):
                self.assertFalse(prompts.PROMPT_REGISTRY[prompt_id].editable)
                self.assertNotIn(prompt_id, prompts.registry_snapshot())
                self.assertNotIn(prompt_id, prompts.registry_snapshot(applies_to="chat"))

                builtin = prompts.PROMPT_REGISTRY[prompt_id].builtin
                settings = {
                    "prompt_overrides": {prompt_id: {"__builtin__": "被篡改"}},
                    "model_prompt_overrides": {
                        "https://api.example.com|m": {prompt_id: {"__builtin__": "被篡改"}},
                    },
                }
                text = prompts.resolve(
                    prompt_id,
                    settings=settings,
                    api_url="https://api.example.com",
                    model="m",
                    role_data={"metadata": {"prompt_overrides": {prompt_id: {"__builtin__": "被篡改"}}}},
                )
                self.assertNotIn("被篡改", text)
                # 覆盖被完全忽略：输出与代码自渲染逐字一致。
                expected = (
                    builtin
                    .replace(
                        "{" + prompts.EMOJI_TOOL_RULE_PLACEHOLDER + "}",
                        prompts.EMOJI_TOOL_RULE_DEFAULT,
                    )
                    .replace("{TOOL_POLICY_CONSERVATIVE}", "")
                )
                self.assertEqual(text, expected)

                self.assertEqual(
                    prompts.sanitize_overrides({prompt_id: {"__builtin__": "x"}}), {},
                )

    def test_tool_rule_emoji_branch_still_follows_the_model_variant(self):
        default_text = prompts.resolve(prompts.CHAT_TOOL_RULES_ID, settings={})
        cloud_text = prompts.resolve(
            prompts.CHAT_TOOL_RULES_ID, settings={}, variant="cloud_emoji",
        )
        self.assertIn("send_emotion_emoji", default_text)
        self.assertNotIn("send_emoji（表情包）", default_text)
        self.assertIn("send_emoji（表情包）", cloud_text)
        self.assertNotIn("{EMOJI_TOOL_RULE}", default_text)
        self.assertNotIn("{EMOJI_TOOL_RULE}", cloud_text)

    def test_blank_override_falls_back_to_builtin(self):
        settings = {"prompt_overrides": {prompts.CHAT_NO_REPLY_ID: {"zerochat": "   "}}}
        self.assertEqual(
            prompts.resolve(prompts.CHAT_NO_REPLY_ID, settings=settings),
            prompts.resolve(prompts.CHAT_NO_REPLY_ID, settings={}),
        )

    def test_sanitize_drops_unknown_shapes_and_truncates(self):
        cleaned = prompts.sanitize_overrides({
            prompts.CHAT_NO_REPLY_ID: {"zerochat": "x" * (prompts.MAX_PROMPT_OVERRIDE_CHARS + 5)},
            "": {"zerochat": "no id"},
            "chat.unknown_prompt": "not a map",
        })
        self.assertEqual(list(cleaned), [prompts.CHAT_NO_REPLY_ID])
        self.assertEqual(
            len(cleaned[prompts.CHAT_NO_REPLY_ID]["zerochat"]),
            prompts.MAX_PROMPT_OVERRIDE_CHARS,
        )

    def test_prompt_ids_are_stable_ascii_keys(self):
        """id 会落进 settings.json 的覆盖表，必须是与标题无关的稳定 ASCII 键。"""
        for prompt_id, definition in prompts.PROMPT_REGISTRY.items():
            with self.subTest(prompt_id=prompt_id):
                self.assertEqual(prompt_id, definition.id)
                self.assertRegex(prompt_id, r"^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$")
                self.assertTrue(prompt_id.isascii())
                # 标题可以改，id 不受影响。
                self.assertNotIn(definition.title, prompt_id)

    def test_sanitize_model_overrides_requires_a_profile_key(self):
        cleaned = prompts.sanitize_model_overrides({
            "https://API.example.com|gpt-4o": {prompts.CHAT_NO_REPLY_ID: {"default": "值"}},
            "no-separator": {prompts.CHAT_NO_REPLY_ID: {"default": "值"}},
        })
        self.assertEqual(list(cleaned), ["https://api.example.com|gpt-4o"])

    def test_unknown_prompt_id_logs_and_returns_empty(self):
        with self.assertLogs("services.prompt_config_service", level="WARNING"):
            self.assertEqual(prompts.resolve("nope.nope", settings={}), "")

    def test_registry_snapshot_can_filter_by_consumer(self):
        summary_only = prompts.registry_snapshot("summary")
        self.assertTrue(summary_only)
        self.assertTrue(all("summary" in item["applies_to"] for item in summary_only.values()))
        chat_only = prompts.registry_snapshot("chat")
        self.assertIn(prompts.CHAT_FORMAT_PROTOCOL_ID, chat_only)

    def test_reset_override_entry_removes_only_that_prompt(self):
        saved: dict = {}

        def _capture(updates):
            saved.update(updates)
            return True

        with patch.object(
            prompts.settings_service,
            "load_settings",
            return_value={
                "prompt_overrides": {
                    prompts.CHAT_NO_REPLY_ID: {"default": "a"},
                    prompts.CHAT_SOUND_DEDUP_ID: {"default": "b"},
                },
            },
        ), patch.object(prompts.settings_service, "save_settings", side_effect=_capture):
            self.assertTrue(prompts.reset_override_entry(prompts.CHAT_NO_REPLY_ID))

        self.assertEqual(
            list(saved["prompt_overrides"]), [prompts.CHAT_SOUND_DEDUP_ID],
        )

    def test_reset_override_entry_keeps_other_phases(self):
        saved: dict = {}

        with patch.object(
            prompts.settings_service,
            "load_settings",
            return_value={
                "prompt_overrides": {
                    prompts.CHAT_NO_REPLY_ID: {"zerochat": "a", "default": "b"},
                },
            },
        ), patch.object(
            prompts.settings_service,
            "save_settings",
            side_effect=lambda updates: saved.update(updates) or True,
        ):
            self.assertTrue(
                prompts.reset_override_entry(prompts.CHAT_NO_REPLY_ID, phase="zerochat")
            )

        self.assertEqual(saved["prompt_overrides"][prompts.CHAT_NO_REPLY_ID], {"default": "b"})


class AiServicePromptIntegrationTests(unittest.TestCase):
    def test_model_overrides_use_configured_url_before_http_normalization(self):
        from services import ai_service

        for url in ('https://api.example.com', 'https://api.example.com/v1',
                    'https://generativelanguage.googleapis.com/v1beta'):
            for source in ('role', 'metadata', 'global'):
                with self.subTest(url=url, source=source):
                    role = {'id': 'role-1', 'ai_model': 'test-model', 'stats_config': _STATS}
                    config = {'model_prompt_overrides': {
                        prompts.model_target_key(url, 'test-model'): {
                            prompts.CHAT_FORMAT_PROTOCOL_ID: {'zerochat': 'CUSTOM-PROTOCOL'},
                            prompts.CHAT_STATS_BLOCK_ID: {'__builtin__': 'CUSTOM-STATS'},
                        }}}
                    if source == 'role':
                        role['ai_api_url'] = url
                    elif source == 'metadata':
                        role['metadata'] = {'ai_api_url': url}
                    else:
                        config['ai_api_url'] = url
                    with patch.object(ai_service.settings_service, 'load_settings', return_value=config):
                        rendered = ai_service._build_system_prompt(role)
                    self.assertIn('CUSTOM-PROTOCOL', rendered)
                    self.assertIn('CUSTOM-STATS', rendered)

    def test_settings_overrides_reach_the_chat_system_prompt(self):
        from services import ai_service

        with patch.object(
            ai_service.settings_service,
            "load_settings",
            return_value={
                "prompt_overrides": {
                    prompts.CHAT_FORMAT_PROTOCOL_ID: {"zerochat": "覆盖后的协议"},
                },
            },
        ):
            text = ai_service._build_system_prompt({"id": "role-1", "ai_model": "gpt-4o"})
        self.assertIn("覆盖后的协议", text)
        self.assertNotIn(prompts.CHAT_FORMAT_PROTOCOL[:12], text)


class _FakeEmojiPlugin:
    TOOLS = [{"type": "function", "function": {"name": "send_emoji"}}]
    PROMPT = "【表情包使用指引】插件自带指引文本"


_STATS = {"enabled": True, "stats": [{"name": "好感", "min": 0, "max": 100, "initial": 50}]}

# SHA-256 of the default system prompt rendered by the pre-refactor code (git 3f9d4a9),
# captured by rendering both trees with an identical role matrix and diffing byte for
# byte. These pin the whole assembled prompt: part order, blank lines, placeholder
# substitution and both emoji branches. Regenerate only when the text is *meant* to change.
_GOLDEN = {
    ("chat_minimal", False): (
        2404, "38823834273727f01134f08358c003982a6fc7216313ba25c67d549bc6241fd8"
    ),
    ("chat_minimal", True): (
        2300, "e8827d500d2cedcefadc99681f628f95d40b8affbe25c9d8c6a8dfc0ddd8e511"
    ),
    ("chat_full", False): (
        2440, "d6dd284bdd20515a3e91c1508716a94aab159919ebf47811d93220e7751e3486"
    ),
    ("chat_stats", False): (
        3032, "7118203514e4b1543f37d6f4e384810a00e2a76e6510fd43fff1fbbe0dfad613"
    ),
    ("chat_stats_sound_off", True): (
        2739, "9db8e8462f4d0f9da497118e356c2768a00f458cc75228ce429704bcdecc4700"
    ),
    ("grok_stats", False): (
        3436, "eba86ddb70a4bfb72b0a01f495f11ed6f063ede8c331485f6474226c2524bb80"
    ),
    ("onebot_main_qq", False): (
        3665, "6a86409d644d62856df3735bc208b966bc14c118d94085e979a325424d460006"
    ),
}

_CASES = {
    "chat_minimal": ({"id": "1", "name": "R", "ai_model": "deepseek-chat"}, {}, False),
    "chat_full": (
        {
            "id": "1",
            "name": "R",
            "ai_model": "deepseek-chat",
            "persona": "人设文本",
            "system_prompt": "角色自定义提示词",
        },
        {"extra_context": "额外上下文文本"},
        False,
    ),
    "chat_stats": (
        {"id": "1", "name": "R", "ai_model": "deepseek-chat", "stats_config": _STATS},
        {},
        False,
    ),
    "chat_stats_sound_off": (
        {
            "id": "1",
            "name": "R",
            "ai_model": "deepseek-chat",
            "stats_config": _STATS,
            "show_sound": False,
        },
        {},
        False,
    ),
    "grok_stats": (
        {"id": "1", "name": "R", "ai_model": "grok-3", "stats_config": _STATS},
        {},
        False,
    ),
    "onebot_main_qq": (
        {
            "id": "1",
            "name": "R",
            "ai_model": "deepseek-chat",
            "onebot_config": {"main_user_id": "123456"},
        },
        {},
        True,
    ),
}


class DefaultPromptIsUnchangedTests(unittest.TestCase):
    """The default prompt must stay byte-identical to the pre-refactor render."""

    def _render(self, case, cloud_emoji):
        import hashlib

        from services import ai_service

        role, kwargs, is_onebot = _CASES[case]
        with patch.object(
            ai_service.settings_service, "load_settings", return_value={}
        ), patch.object(
            ai_service, "_emoji_plugin", _FakeEmojiPlugin() if cloud_emoji else None
        ):
            text = ai_service._build_system_prompt(
                role,
                extra_context=kwargs.get("extra_context"),
                is_onebot=is_onebot,
                settings={},
            )
        return len(text), hashlib.sha256(text.encode("utf-8")).hexdigest()

    def test_renders_match_the_pre_refactor_bytes(self):
        for (case, cloud_emoji), (want_len, want_hash) in _GOLDEN.items():
            with self.subTest(case=case, cloud_emoji=cloud_emoji):
                length, digest = self._render(case, cloud_emoji)
                self.assertEqual(want_len, length)
                self.assertEqual(want_hash, digest)

    def test_emoji_rule_branch_is_present_and_never_left_blank(self):
        for cloud_emoji, expected, unexpected in (
            (False, "send_emotion_emoji（情绪表情）", "send_emoji（表情包）"),
            (True, "send_emoji（表情包）", "send_emotion_emoji（情绪表情）"),
        ):
            with self.subTest(cloud_emoji=cloud_emoji):
                from services import ai_service

                with patch.object(
                    ai_service.settings_service, "load_settings", return_value={}
                ), patch.object(
                    ai_service,
                    "_emoji_plugin",
                    _FakeEmojiPlugin() if cloud_emoji else None,
                ):
                    text = ai_service._build_system_prompt(
                        {"id": "1", "ai_model": "deepseek-chat"}, settings={}
                    )
                self.assertIn(expected, text)
                self.assertNotIn(unexpected, text)

    def test_no_placeholder_residue_or_collapsed_blank_lines(self):
        from services import ai_service

        with patch.object(
            ai_service.settings_service, "load_settings", return_value={}
        ), patch.object(ai_service, "_emoji_plugin", None):
            text = ai_service._build_system_prompt(
                {"id": "1", "ai_model": "grok-3", "stats_config": _STATS}, settings={}
            )
        self.assertNotIn("{", text)
        self.assertNotIn("\n\n\n\n", text)


if __name__ == "__main__":
    unittest.main()

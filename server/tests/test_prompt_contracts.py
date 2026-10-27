"""Cross-checks between the prompt text and the code that depends on it."""
import json
import re
import unittest
from unittest.mock import patch

from services import ai_tools, prompt_config_service as prompts
from services.ai_service import NO_REPLY_DIRECTIVE, is_no_reply_directive
from services.stats_service import parse_stats_block


def _tool_description(tool_list) -> str:
    return tool_list[0]["function"]["description"]


class ToolDescriptionCoverageTests(unittest.TestCase):
    """Per-tool usage rules moved out of chat.tool_rules and into the tool descriptions."""

    EXPECTED = {
        "_SEARCH_MEMORY_TOOL": ("记忆窗口里没有不代表不存在",),
        "_WEB_SEARCH_TOOL": ("优先查证", "纯角色扮演"),
        "_WRITE_MEMORY_TOOL": ("首次确认后写入一次", "不要逐句保存"),
        "_SCHEDULE_TASK_TOOL": ("set_alarm",),
        "_SET_ALARM_TOOL": ("schedule_task",),
        "_CONTINUE_IF_NO_REPLY_TOOL": ("不受「非必要工具」调用限制",),
        "_SEND_EMOTION_EMOJI_TOOL": ("至多调用一次", "Unicode emoji"),
    }

    def test_each_rule_lives_in_its_tool_description(self):
        for attr, keywords in self.EXPECTED.items():
            description = _tool_description(getattr(ai_tools, attr))
            for keyword in keywords:
                with self.subTest(tool=attr, keyword=keyword):
                    self.assertIn(keyword, description)

    def test_tool_rules_prompt_no_longer_duplicates_per_tool_guidance(self):
        text = prompts.PROMPT_REGISTRY[prompts.CHAT_TOOL_RULES_ID].builtin
        for tool_name in ("search_memory", "web_search", "write_memory", "schedule_task", "set_alarm"):
            with self.subTest(tool=tool_name):
                self.assertNotIn(tool_name, text)


class OutputContractTests(unittest.TestCase):
    """The format examples in the prompts must parse with the real parsers."""

    def test_protocol_example_uses_only_known_tags_and_dollar_separator(self):
        body = prompts.PROMPT_REGISTRY[prompts.CHAT_FORMAT_PROTOCOL_ID].builtin
        example = body.split("格式示例（仅演示格式）：")[1].strip()
        messages = example.split("$")
        self.assertGreaterEqual(len(messages), 2)
        for message in messages:
            self.assertIn("<对话>", message)
            self.assertEqual(message.count("<对话>"), message.count("</对话>"))
        tags = set(re.findall(r"</?([^>/]+)>", example))
        self.assertLessEqual(tags, {"对话", "动作", "声音", "心理", "数值"})

    def test_no_reply_directive_is_rendered_and_recognised(self):
        text = prompts.resolve(
            prompts.CHAT_NO_REPLY_ID, settings={}, render={"NO_REPLY_DIRECTIVE": NO_REPLY_DIRECTIVE},
        )
        self.assertIn(NO_REPLY_DIRECTIVE, text)
        self.assertTrue(is_no_reply_directive(NO_REPLY_DIRECTIVE))

    def test_grok_layout_example_parses_as_a_single_stats_block(self):
        text = prompts.PROMPT_REGISTRY[prompts.CHAT_STATS_LAYOUT_GROK_ID].builtin
        example = re.search(r"示例：(.+)。$", text).group(1)
        self.assertEqual(parse_stats_block(example), {"好感": "80"})


class SummaryPromptContractTests(unittest.TestCase):
    def test_core_memory_example_output_matches_the_parser_schema(self):
        from services.memory_service import _parse_core_memory_facts

        text = prompts.PROMPT_REGISTRY[prompts.SUMMARY_CORE_MEMORY_ID].builtin
        example_output = text.split("输出：")[-1].strip()
        facts = _parse_core_memory_facts(example_output)
        self.assertEqual(len(facts), 1)
        self.assertIn("已戒咖啡", str(facts[0]))

    def test_context_events_example_output_is_valid_json_with_the_documented_keys(self):
        text = prompts.PROMPT_REGISTRY[prompts.SUMMARY_CONTEXT_EVENTS_ID].builtin
        example_output = text.split("输出：")[-1].strip()
        payload = json.loads(example_output)
        self.assertEqual(set(payload), {"summary", "events"})
        self.assertEqual(
            set(payload["events"][0]), {"event", "status", "event_time"},
        )

    def test_summary_prompts_do_not_carry_chat_protocol_text(self):
        for prompt_id in (prompts.SUMMARY_CORE_MEMORY_ID, prompts.SUMMARY_CONTEXT_EVENTS_ID):
            with self.subTest(prompt_id=prompt_id):
                text = prompts.PROMPT_REGISTRY[prompt_id].builtin
                self.assertNotIn("<对话>", text)
                self.assertNotIn("输出协议优先于旧格式要求", text)


class StabilityTests(unittest.TestCase):
    def test_prompt_resolution_is_deterministic(self):
        for prompt_id in prompts.PROMPT_REGISTRY:
            with self.subTest(prompt_id=prompt_id):
                self.assertEqual(
                    prompts.resolve(prompt_id, settings={}),
                    prompts.resolve(prompt_id, settings={}),
                )

    def test_resolve_never_leaks_placeholders_for_chat_prompts(self):
        for prompt_id, definition in prompts.PROMPT_REGISTRY.items():
            if definition.group != "chat" and definition.group != "onebot":
                continue
            with self.subTest(prompt_id=prompt_id):
                text = prompts.resolve(prompt_id, settings={})
                self.assertNotRegex(text, r"\{[A-Z][A-Z0-9_]*\}")


if __name__ == "__main__":
    unittest.main()

"""Tool descriptions live in server/prompts/tools/*.md and are built through tool_registry."""
import re
import unittest
from unittest.mock import patch

from services import ai_tools, prompt_config_service, prompt_store, tool_registry
from services.tool_registry import ToolPromptError, build_tool, parse_tool_text

TOOLS_DIR = prompt_store.PROMPTS_DIR / "tools"


def _all_tool_groups():
    return {
        name: getattr(ai_tools, name)
        for name in dir(ai_tools)
        if re.fullmatch(r"_[A-Z_]+_TOOL", name)
    }


class ParseToolTextTests(unittest.TestCase):
    def test_description_and_parameters(self):
        description, params = parse_tool_text(
            "做一件事。\n第二行。\n\n# 参数\n## a\n甲的说明\n## b_c\n乙的说明\n续行\n"
        )
        self.assertEqual(description, "做一件事。\n第二行。")
        self.assertEqual(params, {"a": "甲的说明", "b_c": "乙的说明\n续行"})

    def test_tool_without_parameters(self):
        self.assertEqual(parse_tool_text("只有描述"), ("只有描述", {}))

    def test_rejects_malformed_bodies(self):
        for body in (
            "# 参数\n## a\n说明",              # 描述为空
            "描述\n# 参数\n## a\n",             # 参数描述为空
            "描述\n# 参数\n## a\nx\n## a\ny",   # 参数重复
            "描述\n# 参数\n游离文字\n## a\nx",   # 参数标题之前有内容
        ):
            with self.subTest(body=body), self.assertRaises(ToolPromptError):
                parse_tool_text(body)


class BuildToolTests(unittest.TestCase):
    def _definition(self, body, editable=False):
        return prompt_store.PromptDefinition(
            id="tool.demo", title="t", group="tools", builtin=body,
            applies_to=("chat",), editable=editable,
        )

    def _build(self, body, properties, editable=False):
        registry = {"tool.demo": self._definition(body, editable)}
        tool_registry.load_tool_text.cache_clear()
        self.addCleanup(tool_registry.load_tool_text.cache_clear)
        with patch.object(prompt_config_service, "PROMPT_REGISTRY", registry):
            return build_tool("demo", properties)

    def test_builds_strict_schema_with_description_last(self):
        tool = self._build(
            "演示工具\n\n# 参数\n## mode\n模式\n## text\n文本",
            {"mode": {"type": "string", "enum": ["a", "b"]}, "text": {"type": "string"}},
        )
        function = tool[0]["function"]
        self.assertEqual(function["name"], "demo")
        self.assertEqual(function["description"], "演示工具")
        self.assertTrue(function["strict"])
        parameters = function["parameters"]
        self.assertFalse(parameters["additionalProperties"])
        self.assertEqual(parameters["required"], ["mode", "text"])
        self.assertEqual(list(parameters["properties"]["mode"]), ["type", "enum", "description"])
        self.assertEqual(parameters["properties"]["text"]["description"], "文本")

    def test_parameter_mismatch_fails_loudly(self):
        with self.assertRaisesRegex(ToolPromptError, "缺少 other"):
            self._build("描述\n# 参数\n## text\n文本", {"text": {"type": "string"}, "other": {"type": "string"}})
        with self.assertRaisesRegex(ToolPromptError, "多出 text"):
            self._build("描述\n# 参数\n## text\n文本", {})

    def test_missing_prompt_and_editable_prompt_are_rejected(self):
        tool_registry.load_tool_text.cache_clear()
        self.addCleanup(tool_registry.load_tool_text.cache_clear)
        with patch.object(prompt_config_service, "PROMPT_REGISTRY", {}):
            with self.assertRaisesRegex(ToolPromptError, "缺少工具提示词"):
                build_tool("demo", {})
        with self.assertRaisesRegex(ToolPromptError, "editable: false"):
            self._build("描述", {}, editable=True)

    def test_inline_description_in_code_is_rejected(self):
        with self.assertRaisesRegex(ToolPromptError, "写在提示词文件里"):
            self._build("描述\n# 参数\n## text\n文本", {"text": {"type": "string", "description": "x"}})


class ShippedToolPromptTests(unittest.TestCase):
    def test_every_tool_in_code_has_a_prompt_file_and_vice_versa(self):
        in_code = {group[0]["function"]["name"] for group in _all_tool_groups().values()}
        on_disk = {path.stem for path in TOOLS_DIR.glob("*.md")}
        self.assertEqual(in_code, on_disk)

    def test_tool_prompts_are_code_owned_and_hidden_from_the_editor(self):
        snapshot = prompt_config_service.registry_snapshot()
        for name in (path.stem for path in TOOLS_DIR.glob("*.md")):
            prompt_id = tool_registry.tool_prompt_id(name)
            with self.subTest(tool=name):
                definition = prompt_config_service.PROMPT_REGISTRY[prompt_id]
                self.assertFalse(definition.editable)
                self.assertEqual(definition.group, "tools")
                self.assertNotIn(prompt_id, snapshot)

    def test_overrides_cannot_change_tool_text(self):
        prompt_id = tool_registry.tool_prompt_id("search_memory")
        self.assertEqual(
            prompt_config_service.sanitize_overrides({prompt_id: {"__builtin__": "篡改"}}), {}
        )

    def test_generated_schemas_are_strict_and_fully_described(self):
        for attr, group in _all_tool_groups().items():
            function = group[0]["function"]
            parameters = function["parameters"]
            with self.subTest(tool=attr):
                self.assertTrue(function["strict"])
                self.assertTrue(function["description"].strip())
                self.assertFalse(parameters["additionalProperties"])
                self.assertEqual(parameters["required"], list(parameters["properties"]))
                for spec in parameters["properties"].values():
                    self.assertTrue(spec["description"].strip())


if __name__ == "__main__":
    unittest.main()

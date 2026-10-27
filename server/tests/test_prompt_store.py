"""Tests for the file-backed built-in prompt store."""
import tempfile
import unittest
from pathlib import Path

from services import prompt_store
from services.prompt_store import PromptStoreError, load_all, parse_prompt_text

_VALID = """---
id: chat.demo
title: 演示
group: chat
origin: zerochat
applies_to: ["chat"]
editable: false
version: 3
placeholders: ["NO_REPLY_DIRECTIVE"]
---
正文 {NO_REPLY_DIRECTIVE}
"""


class ParsePromptTests(unittest.TestCase):
    def test_parses_all_fields(self):
        definition = parse_prompt_text(_VALID)
        self.assertEqual(definition.id, "chat.demo")
        self.assertEqual(definition.title, "演示")
        self.assertEqual(definition.origin, "zerochat")
        self.assertEqual(tuple(definition.applies_to), ("chat",))
        self.assertFalse(definition.editable)
        self.assertEqual(definition.version, 3)
        self.assertEqual(definition.placeholders, ("NO_REPLY_DIRECTIVE",))
        self.assertEqual(definition.builtin, "正文 {NO_REPLY_DIRECTIVE}")

    def test_defaults_and_crlf_and_json_examples_in_body(self):
        text = (
            "---\r\nid: summary.demo\r\ntitle: T\r\ngroup: summary\r\n"
            "origin: shared\r\napplies_to: [\"summary\"]\r\n---\r\n"
            '输出 {"a": 1}\r\n'
        )
        definition = parse_prompt_text(text)
        self.assertTrue(definition.editable)
        self.assertEqual(definition.version, 1)
        self.assertEqual(definition.builtin, '输出 {"a": 1}')

    def test_rejects_malformed_files(self):
        cases = {
            "no front matter": "正文",
            "unterminated": "---\nid: a.b\n正文",
            "unknown key": _VALID.replace("version: 3", "version: 3\nfoo: bar"),
            "duplicate key": _VALID.replace("version: 3", "version: 3\nversion: 4"),
            "missing key": _VALID.replace("title: 演示\n", ""),
            "bad origin": _VALID.replace("origin: zerochat", "origin: nowhere"),
            "bad version": _VALID.replace("version: 3", "version: 0"),
            "bad editable": _VALID.replace("editable: false", "editable: maybe"),
            "empty body": _VALID.replace("正文 {NO_REPLY_DIRECTIVE}", ""),
            "undeclared placeholder": _VALID.replace(
                "正文 {NO_REPLY_DIRECTIVE}", "正文 {NO_REPLY_DIRECTIVE} {STATS_LAYOUT_RULE}"
            ),
            "unused placeholder": _VALID.replace(
                "正文 {NO_REPLY_DIRECTIVE}", "正文"
            ),
            "unregistered placeholder": _VALID.replace(
                'placeholders: ["NO_REPLY_DIRECTIVE"]', 'placeholders: ["MADE_UP"]'
            ).replace("{NO_REPLY_DIRECTIVE}", "{MADE_UP}"),
        }
        for name, text in cases.items():
            with self.subTest(name=name):
                with self.assertRaises(PromptStoreError):
                    parse_prompt_text(text)


class LoadAllTests(unittest.TestCase):
    def test_duplicate_ids_fail_loudly(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "a.md").write_text(_VALID, encoding="utf-8")
            (root / "sub").mkdir()
            (root / "sub" / "b.md").write_text(_VALID, encoding="utf-8")
            with self.assertRaises(PromptStoreError):
                load_all(root)

    def test_missing_or_empty_directory_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(PromptStoreError):
                load_all(Path(tmp) / "nope")
            with self.assertRaises(PromptStoreError):
                load_all(Path(tmp))

    def test_readme_is_skipped(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "README.md").write_text("# not a prompt", encoding="utf-8")
            (root / "a.md").write_text(_VALID, encoding="utf-8")
            self.assertEqual(list(load_all(root)), ["chat.demo"])

    def test_shipped_prompts_load_and_use_only_known_placeholders(self):
        definitions = load_all()
        self.assertIn("chat.format_protocol", definitions)
        for definition in definitions.values():
            with self.subTest(prompt_id=definition.id):
                self.assertTrue(
                    set(definition.placeholders) <= prompt_store.KNOWN_PLACEHOLDERS
                )
                self.assertGreaterEqual(definition.version, 1)


if __name__ == "__main__":
    unittest.main()

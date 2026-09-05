import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

from services.memory_service import (
    _core_memory_result_is_valid,
    _core_memory_vector_facts,
    _format_core_memory_facts,
    _parse_core_memory_facts,
)
from services.vector_memory import VectorMemoryStore, close_all_vector_connections


class CoreMemoryParsingTests(unittest.TestCase):
    def test_legacy_formats_are_split_and_tags_are_preserved_as_metadata(self):
        facts = _parse_core_memory_facts("[preference][high] tea; [goal][low] travel")
        self.assertEqual([item["fact"] for item in facts], ["tea", "travel"])
        self.assertEqual(facts[0]["confidence"], "high")
        self.assertEqual(_core_memory_vector_facts(_format_core_memory_facts(facts)), ["tea", "travel"])

    def test_valid_empty_json_allows_forgetting_everything(self):
        self.assertEqual(_parse_core_memory_facts("[]"), [])
        self.assertTrue(_core_memory_result_is_valid("[]"))
        self.assertFalse(_core_memory_result_is_valid("已有核心记忆"))


class VectorMemoryRegressionTests(unittest.TestCase):
    def test_delete_by_source_removes_only_requested_source(self):
        with TemporaryDirectory() as temp_dir, patch(
            "services.vector_memory.ROLES_DIR", Path(temp_dir)
        ):
            (Path(temp_dir) / "role-1").mkdir()
            store = VectorMemoryStore("role-1")
            store.store("old core", [1.0, 0.0], source="core_summary")
            store.store("chat", [1.0, 0.0], source="chat")
            self.assertEqual(store.delete_by_source("core_summary"), 1)
            self.assertEqual([item["source"] for item in store.list_all()], ["chat"])
            close_all_vector_connections()

    def test_search_tie_break_normalizes_timezones(self):
        with TemporaryDirectory() as temp_dir, patch(
            "services.vector_memory.ROLES_DIR", Path(temp_dir)
        ):
            (Path(temp_dir) / "role-1").mkdir()
            store = VectorMemoryStore("role-1")
            store.store("older", [1.0, 0.0], timestamp="2026-07-01T09:30:00+09:00")
            store.store("newer", [1.0, 0.0], timestamp="2026-07-01T01:00:00Z")
            result = store.search([1.0, 0.0], top_k=2)
            close_all_vector_connections()
        self.assertEqual(result[0]["text"], "newer")

    def test_search_keeps_full_score_precision_before_time_tie_break(self):
        with TemporaryDirectory() as temp_dir, patch(
            "services.vector_memory.ROLES_DIR", Path(temp_dir)
        ):
            (Path(temp_dir) / "role-1").mkdir()
            store = VectorMemoryStore("role-1")
            store.store("higher relevance", [1.0, 0.0], timestamp="2026-07-01T00:00:00Z")
            store.store("newer but lower relevance", [0.99, 0.14], timestamp="2026-07-02T00:00:00Z")
            result = store.search([1.0, 0.0], top_k=2)
            close_all_vector_connections()
        self.assertEqual(result[0]["text"], "higher relevance")


if __name__ == "__main__":
    unittest.main()

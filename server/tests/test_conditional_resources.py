import asyncio
import json
import sqlite3
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

from services.conditional_sync import pack_response
from services.memory_service import _init_db, load_memory_sections
from services.settings_sync import select_settings
from transport.ws_dispatcher import handle_ws_action


class ConditionalResourceTests(unittest.TestCase):
    def test_chat_block_boundaries_and_deletions(self):
        for count in (199, 200, 201):
            with self.subTest(count=count):
                rows = [{"id": str(i)} for i in range(count)]
                first = pack_response("chat_snapshot", {"chats": {"r": rows}}, {})
                rows.append({"id": str(count)})
                changed = pack_response("chat_snapshot", {"chats": {"r": rows}}, first["_sync"])
                self.assertEqual(len(changed["parts"]), 1)
                removed = pack_response("chat_snapshot", {"chats": {}}, changed["_sync"])
                self.assertEqual(removed["parts"], {})
                self.assertEqual(removed["_sync"]["hashes"], {})

    def test_legacy_migration_is_committed_before_paged_read(self):
        from services import memory_service
        memory_service.close_all_connections()
        with TemporaryDirectory() as temp, patch.object(memory_service, "ROLES_DIR", Path(temp)):
            path = memory_service.get_memory_json("legacy")
            path.write_text(json.dumps({"core_memory": "kept", "short_term": [{"role": "user", "content": "hi"}]}), encoding="utf-8")
            try:
                self.assertEqual(load_memory_sections("legacy", ["core_memory"])["core_memory"], ["kept"])
                conn = sqlite3.connect(memory_service.get_memory_db("legacy"), timeout=0.1)
                try:
                    self.assertEqual(conn.execute("SELECT count(*) FROM short_term").fetchone()[0], 1)
                    conn.execute("INSERT INTO memory_meta VALUES ('test_visibility', 'yes')")
                    conn.commit()
                finally:
                    conn.close()
            finally:
                memory_service.close_all_connections()

    def test_vector_page_omits_embeddings_and_detects_delete(self):
        from services.vector_memory import VectorMemoryStore, close_all_vector_connections
        with TemporaryDirectory() as temp, patch("services.vector_memory.ROLES_DIR", Path(temp)):
            (Path(temp) / "r").mkdir()
            try:
                store = VectorMemoryStore("r")
                store.store_batch([{"text": str(i), "embedding": [1.0, 0.0]} for i in range(101)])
                first = store.sync_page(limit=10000)
                self.assertEqual(len(first["items"]), 100)
                self.assertTrue(first["has_more"])
                self.assertNotIn("embedding", first["items"][0])
                store.delete_by_source("chat")
                next_page = store.sync_page(offset=first["next_cursor"], version=first["version"])
                self.assertTrue(next_page["reset_required"])
            finally:
                close_all_vector_connections()

    def test_unchanged_response_contains_no_resource_body(self):
        data = {"settings": {"ai_model": "m", "prompt_overrides": {"a": "x" * 10000}}}
        first = pack_response("settings_get", data, {})
        again = pack_response("settings_get", data, first["_sync"])
        self.assertEqual(set(again), {"_sync"})
        self.assertTrue(again["_sync"]["not_modified"])
        self.assertLess(len(json.dumps(again)), 200)

    def test_one_chat_append_sends_only_last_block(self):
        data = {"chats": {"a": [{"id": str(i), "content": "x" * 300} for i in range(400)],
                          "b": [{"id": "b", "content": "untouched"}]}}
        first = pack_response("chat_snapshot", data, {})
        data["chats"]["a"].append({"id": "400", "content": "new"})
        changed = pack_response("chat_snapshot", data, first["_sync"])
        self.assertEqual(list(changed["parts"].values()), [[{"id": "400", "content": "new"}]])
        self.assertLess(len(json.dumps(changed)), len(json.dumps(first)) // 20)

    def test_list_reorder_and_delete_reuses_item_parts(self):
        data = {"moments": [{"id": "1", "content": "a"}, {"id": "2", "content": "b"}]}
        first = pack_response("moments_list", data, {})
        changed = pack_response("moments_list", {"moments": [data["moments"][1]]}, first["_sync"])
        self.assertEqual(changed["parts"], {})
        self.assertEqual(len(changed["_sync"]["hashes"]), 1)

    def test_hash_is_stable_for_mapping_order_and_empty_is_data(self):
        self.assertEqual(pack_response("settings_get", {"a": 1, "b": 2}, {})["_sync"]["hash"],
                         pack_response("settings_get", {"b": 2, "a": 1}, {})["_sync"]["hash"])
        first = pack_response("chat_snapshot", {"chats": {"a": [{"id": "1"}]}}, {})
        cleared = pack_response("chat_snapshot", {"chats": {"a": []}}, first["_sync"])
        self.assertNotEqual(first["_sync"]["hash"], cleared["_sync"]["hash"])

    def test_settings_groups_exclude_transport_secrets(self):
        self.assertEqual(select_settings({"ai_model": "m", "auth_token": "secret", "vision_model": "v"}, ["chat"]), {"ai_model": "m"})
        with self.assertRaises(ValueError):
            select_settings({}, ["unknown"])

    def test_settings_conflict_does_not_write(self):
        with patch("transport.ws_dispatcher.summary_config_service.load_settings_with_summary_configs", return_value={"ai_model": "new"}), \
             patch("transport.ws_dispatcher._dispatch_ws_action") as dispatch:
            result = asyncio.run(handle_ws_action("settings_update", {"updates": {"ai_model": "old"}, "base_versions": {"ai_model": "stale"}}, None, {}))
            self.assertFalse(result["success"])
            self.assertEqual(result["conflicts"], ["ai_model"])
            dispatch.assert_not_called()


class MemoryPageTests(unittest.TestCase):
    def setUp(self):
        self.conn = sqlite3.connect(":memory:")
        _init_db(self.conn)
        self.conn.executemany("INSERT INTO short_term(id, role, content, timestamp) VALUES (?, 'user', 'hello', '2026-01-01')", [(i,) for i in range(1, 402)])
        self.conn.execute("INSERT INTO memory_meta VALUES ('core_memory', 'one\ntwo')")
        self.conn.commit()
        self.connection = patch("services.memory_service._get_connection", return_value=self.conn)
        self.connection.start()

    def tearDown(self):
        self.connection.stop()
        self.conn.close()

    def test_core_only_does_not_read_short_term(self):
        queries = []
        self.conn.set_trace_callback(queries.append)
        result = load_memory_sections("r", ["core_memory"])
        self.assertEqual(result, {"core_memory": ["one", "two"]})
        self.assertFalse(any("FROM short_term" in query for query in queries))

    def test_pages_are_bounded_and_edit_invalidates_cursor(self):
        first = load_memory_sections("r", ["short_term"])
        self.assertEqual(len(first["short_term"]), 200)
        self.assertTrue(first["has_more"])
        second = load_memory_sections("r", ["short_term"], before_id=first["next_cursor"], version=first["version"])
        self.assertEqual(len(second["short_term"]), 200)
        self.conn.execute("UPDATE short_term SET content='edited' WHERE id=1")
        self.conn.commit()
        stale = load_memory_sections("r", ["short_term"], before_id=first["next_cursor"], version=first["version"])
        self.assertTrue(stale["reset_required"])

    def test_clear_and_rollback_revision(self):
        first = load_memory_sections("r", ["short_term"])
        self.conn.execute("DELETE FROM short_term")
        self.conn.rollback()
        self.assertEqual(load_memory_sections("r", ["short_term"])["version"], first["version"])
        self.conn.execute("DELETE FROM short_term")
        self.conn.commit()
        cleared = load_memory_sections("r", ["short_term"])
        self.assertEqual(cleared["short_term"], [])
        self.assertNotEqual(cleared["version"], first["version"])


if __name__ == "__main__":
    unittest.main()

import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

from services import memory_service
from services.memory_service import append_tool_calls, get_tool_calls


class ToolCallsStorageTests(unittest.TestCase):
    """工具调用历史落库到每角色 memory.sqlite 的 tool_calls 表。"""

    def setUp(self):
        memory_service.close_all_connections()
        self._tempdir = TemporaryDirectory()
        self._patcher = patch.object(
            memory_service, "ROLES_DIR", Path(self._tempdir.name)
        )
        self._patcher.start()

    def tearDown(self):
        memory_service.close_all_connections()
        self._patcher.stop()
        self._tempdir.cleanup()

    def test_append_and_get_round_trip_preserves_order_and_arguments(self):
        calls = [
            {"name": "search_memory", "arguments": {"query": "生日"}, "result": "找到 2 条"},
            {"name": "send_emotion_emoji", "arguments": {"emotion": "happy"}, "result": "已发送"},
        ]
        append_tool_calls("role_a", "req_1", calls)

        fetched = get_tool_calls("role_a", "req_1")
        self.assertEqual(len(fetched), 2)
        self.assertEqual(fetched[0]["name"], "search_memory")
        self.assertEqual(fetched[0]["arguments"], {"query": "生日"})
        self.assertEqual(fetched[0]["result"], "找到 2 条")
        self.assertEqual(fetched[1]["name"], "send_emotion_emoji")

    def test_get_tool_calls_returns_empty_for_unknown_request(self):
        self.assertEqual(get_tool_calls("role_a", "does_not_exist"), [])

    def test_get_tool_calls_requires_role_id_scoping(self):
        append_tool_calls("role_a", "req_shared", [{"name": "x", "arguments": {}, "result": "ok"}])
        # 不同角色各有独立的 memory.sqlite，同名 request_id 不会串到别的角色。
        self.assertEqual(get_tool_calls("role_b", "req_shared"), [])
        self.assertEqual(len(get_tool_calls("role_a", "req_shared")), 1)

    def test_append_tool_calls_is_idempotent_for_same_request_id(self):
        calls = [{"name": "x", "arguments": {}, "result": "first"}]
        append_tool_calls("role_a", "req_dup", calls)
        # 重放同一 request_id 的日志（例如推送补偿重放）不应重复写入。
        append_tool_calls("role_a", "req_dup", calls)
        append_tool_calls("role_a", "req_dup", calls)
        self.assertEqual(len(get_tool_calls("role_a", "req_dup")), 1)

    def test_append_tool_calls_skips_empty_list(self):
        append_tool_calls("role_a", "req_empty", [])
        self.assertEqual(get_tool_calls("role_a", "req_empty"), [])

    def test_append_tool_calls_skips_blank_request_id(self):
        append_tool_calls("role_a", "  ", [{"name": "x", "arguments": {}, "result": "y"}])
        self.assertEqual(get_tool_calls("role_a", "  "), [])

    def test_get_tool_calls_tolerates_non_dict_arguments(self):
        append_tool_calls(
            "role_a",
            "req_bad_args",
            [{"name": "x", "arguments": "not-a-dict", "result": "ok"}],
        )
        fetched = get_tool_calls("role_a", "req_bad_args")
        self.assertEqual(len(fetched), 1)
        self.assertEqual(fetched[0]["arguments"], {})


if __name__ == "__main__":
    unittest.main()

"""record_usage 原子累加回归测试。

验证并发多次记录用量时不会因 last-writer-wins 丢计数（P5）。
"""
import threading
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

import services.memory_service as memory_service


class RecordUsageTests(unittest.TestCase):
    def setUp(self):
        self._orig_roles_dir = memory_service.ROLES_DIR
        self._tmp = TemporaryDirectory()
        memory_service.ROLES_DIR = Path(self._tmp.name)
        (Path(self._tmp.name) / "r1").mkdir(parents=True, exist_ok=True)

    def tearDown(self):
        memory_service.close_all_connections()
        memory_service.ROLES_DIR = self._orig_roles_dir
        self._tmp.cleanup()

    def test_sequential_accumulation(self):
        usage = {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}
        for _ in range(5):
            memory_service.record_usage("r1", usage, "gpt-x", "api.example.com")

        stats = memory_service.get_usage_stats("r1")
        bucket = stats["by_platform_model"][0]
        self.assertEqual(bucket["platform"], "api.example.com")
        self.assertEqual(bucket["prompt_tokens"], 50)
        self.assertEqual(bucket["completion_tokens"], 25)
        self.assertEqual(bucket["total_tokens"], 75)
        self.assertEqual(bucket["request_count"], 5)

    def test_concurrent_accumulation_no_lost_counts(self):
        usage = {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}
        n = 40

        def worker():
            memory_service.record_usage("r1", usage, "gpt-x", "api.example.com")

        threads = [threading.Thread(target=worker) for _ in range(n)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        stats = memory_service.get_usage_stats("r1")
        bucket = stats["by_platform_model"][0]
        self.assertEqual(bucket["request_count"], n)
        self.assertEqual(bucket["prompt_tokens"], n)
        self.assertEqual(bucket["total_tokens"], 2 * n)

    def test_different_platforms_are_separate_buckets(self):
        usage = {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}
        memory_service.record_usage("r1", usage, "gpt-x", "api.first.example")
        memory_service.record_usage("r1", usage, "gpt-x", "api.second.example")

        stats = memory_service.get_usage_stats("r1")
        self.assertEqual(len(stats["by_platform_model"]), 2)
        self.assertEqual(
            {item["platform"] for item in stats["by_platform_model"]},
            {"api.first.example", "api.second.example"},
        )
        self.assertEqual(stats["by_model"][0]["total_tokens"], 30)
        self.assertEqual(stats["by_model"][0]["request_count"], 2)

    def test_legacy_model_buckets_are_retained_as_unlabelled_history(self):
        with memory_service._get_connection("r1") as conn:
            memory_service._set_meta(
                conn,
                "usage_by_model_json",
                '{"gpt-x": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15, "cache_hit_tokens": 0, "cache_miss_tokens": 10, "request_count": 1}}',
            )

        stats = memory_service.get_usage_stats("r1")
        self.assertEqual(stats["by_platform_model"][0]["platform"], "历史未标注平台")
        self.assertEqual(stats["by_platform_model"][0]["model"], "gpt-x")

    def test_reset_clears_current_and_legacy_usage(self):
        usage = {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}
        memory_service.record_usage("r1", usage, "gpt-x", "api.example.com")
        with memory_service._get_connection("r1") as conn:
            memory_service._set_meta(
                conn,
                "usage_by_model_json",
                '{"legacy": {"total_tokens": 1, "request_count": 1}}',
            )

        self.assertTrue(memory_service.reset_usage_stats("r1"))
        self.assertEqual(
            memory_service.get_usage_stats("r1"),
            {"by_platform_model": [], "by_model": [], "last": None},
        )


if __name__ == "__main__":
    unittest.main()

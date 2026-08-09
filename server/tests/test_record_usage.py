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
            memory_service.record_usage("r1", usage, "gpt-x")

        stats = memory_service.get_usage_stats("r1")
        bucket = stats["by_model"][0]
        self.assertEqual(bucket["prompt_tokens"], 50)
        self.assertEqual(bucket["completion_tokens"], 25)
        self.assertEqual(bucket["total_tokens"], 75)
        self.assertEqual(bucket["request_count"], 5)

    def test_concurrent_accumulation_no_lost_counts(self):
        usage = {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}
        n = 40

        def worker():
            memory_service.record_usage("r1", usage, "gpt-x")

        threads = [threading.Thread(target=worker) for _ in range(n)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        stats = memory_service.get_usage_stats("r1")
        bucket = stats["by_model"][0]
        self.assertEqual(bucket["request_count"], n)
        self.assertEqual(bucket["prompt_tokens"], n)
        self.assertEqual(bucket["total_tokens"], 2 * n)


if __name__ == "__main__":
    unittest.main()

import json
import os
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

from core.utils import atomic_write_json, load_moments_posts


class AtomicWriteJsonTests(unittest.TestCase):
    def test_writes_and_reads_back(self):
        with TemporaryDirectory() as d:
            target = Path(d) / "sub" / "data.json"
            payload = {"a": 1, "b": ["x", "中文"]}
            atomic_write_json(target, payload)
            self.assertTrue(target.exists())
            with open(target, "r", encoding="utf-8") as f:
                self.assertEqual(json.load(f), payload)

    def test_creates_parent_dirs(self):
        with TemporaryDirectory() as d:
            target = Path(d) / "a" / "b" / "c.json"
            atomic_write_json(target, [1, 2, 3])
            self.assertTrue(target.exists())

    def test_overwrite_is_atomic_no_temp_leftover(self):
        with TemporaryDirectory() as d:
            target = Path(d) / "data.json"
            atomic_write_json(target, {"v": 1})
            atomic_write_json(target, {"v": 2})
            with open(target, "r", encoding="utf-8") as f:
                self.assertEqual(json.load(f), {"v": 2})
            # 不应残留临时文件
            leftovers = [n for n in os.listdir(d) if n != "data.json"]
            self.assertEqual(leftovers, [])

    def test_non_ascii_preserved(self):
        with TemporaryDirectory() as d:
            target = Path(d) / "cn.json"
            atomic_write_json(target, {"名字": "测试"})
            raw = target.read_text(encoding="utf-8")
            self.assertIn("名字", raw)  # ensure_ascii=False


class LoadMomentsPostsTests(unittest.TestCase):
    def test_missing_file_returns_empty(self):
        with TemporaryDirectory() as d:
            self.assertEqual(load_moments_posts(Path(d) / "nope.json"), [])

    def test_filters_non_dict_items(self):
        with TemporaryDirectory() as d:
            target = Path(d) / "posts.json"
            atomic_write_json(target, [{"id": "1"}, "junk", 42, {"id": "2"}])
            self.assertEqual(
                load_moments_posts(target), [{"id": "1"}, {"id": "2"}]
            )

    def test_corrupt_file_returns_empty(self):
        with TemporaryDirectory() as d:
            target = Path(d) / "posts.json"
            target.write_text("{not valid json", encoding="utf-8")
            self.assertEqual(load_moments_posts(target), [])

    def test_non_list_returns_empty(self):
        with TemporaryDirectory() as d:
            target = Path(d) / "posts.json"
            atomic_write_json(target, {"posts": []})
            self.assertEqual(load_moments_posts(target), [])


if __name__ == "__main__":
    unittest.main()

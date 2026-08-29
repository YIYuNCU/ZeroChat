import asyncio
import unittest
from unittest.mock import patch

from routers import moments, tasks


class ConditionalSyncHashTests(unittest.TestCase):
    def test_task_hash_changes_when_task_payload_changes(self):
        first = [{"id": "t1", "enabled": True, "message": "ping"}]
        second = [{"id": "t1", "enabled": False, "message": "ping"}]
        self.assertNotEqual(tasks.compute_tasks_hash(first), tasks.compute_tasks_hash(second))
        self.assertEqual(tasks.compute_tasks_hash(first), tasks.compute_tasks_hash(list(first)))

    def test_task_list_returns_not_modified_for_matching_hash(self):
        payload = [{"id": "t1", "enabled": True}]
        with patch.object(tasks, "load_tasks", return_value=payload):
            digest = tasks.compute_tasks_hash(payload)
            response = asyncio.run(tasks.list_tasks(client_hash=digest))
        self.assertTrue(response["not_modified"])
        self.assertEqual(response["tasks"], [])
        self.assertEqual(response["count"], 1)

    def test_moment_list_returns_not_modified_for_matching_hash(self):
        payload = [{"id": "m1", "author_id": "me", "content": "hello"}]
        with patch.object(moments, "_build_rendered_moments", return_value=payload), patch.object(
            moments, "_read_cached_moments_hash", return_value=None
        ):
            digest = moments._compute_moments_hash(payload)
            response = asyncio.run(moments.list_moments(client_hash=digest))
        self.assertTrue(response["not_modified"])
        self.assertEqual(response["moments"], [])


if __name__ == "__main__":
    unittest.main()

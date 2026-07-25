import json
import unittest
from datetime import datetime, timedelta
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import AsyncMock, MagicMock, patch

from services import scheduler_service
from transport.ws_dispatcher import _handle_roles_upsert


class _FakeScheduler:
    def __init__(self):
        self.jobs = {}

    def get_job(self, job_id):
        return self.jobs.get(job_id)

    def remove_job(self, job_id):
        self.jobs.pop(job_id, None)

    def add_job(self, func, trigger, id, args, replace_existing):
        self.jobs[id] = {
            "func": func,
            "trigger": trigger,
            "args": args,
            "replace_existing": replace_existing,
        }


class ProactiveSchedulerTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temp_dir = TemporaryDirectory()
        self.roles_dir = Path(self.temp_dir.name)
        self.scheduler = _FakeScheduler()
        self.roles_patch = patch.object(
            scheduler_service,
            "ROLES_DIR",
            self.roles_dir,
        )
        self.scheduler_patch = patch.object(
            scheduler_service,
            "_scheduler",
            self.scheduler,
        )
        self.roles_patch.start()
        self.scheduler_patch.start()

    def tearDown(self):
        self.scheduler_patch.stop()
        self.roles_patch.stop()
        self.temp_dir.cleanup()

    def _write_role(self, proactive_config, *, archived=False):
        role_dir = self.roles_dir / "role-1"
        role_dir.mkdir(parents=True, exist_ok=True)
        profile = role_dir / "profile.json"
        profile.write_text(
            json.dumps(
                {
                    "id": "role-1",
                    "name": "测试角色",
                    "archived": archived,
                    "proactive_config": proactive_config,
                },
                ensure_ascii=False,
            ),
            encoding="utf-8",
        )
        return profile

    def test_schedule_persists_and_restores_next_trigger(self):
        profile = self._write_role(
            {
                "enabled": True,
                "min_interval_minutes": 30,
                "max_interval_minutes": 30,
                "quiet_hours_start": 23,
                "quiet_hours_end": 7,
                "next_trigger_time": None,
            }
        )

        scheduler_service.schedule_proactive_for_role("role-1", reset=True)

        saved = json.loads(profile.read_text(encoding="utf-8"))
        next_run = datetime.fromisoformat(
            saved["proactive_config"]["next_trigger_time"]
        )
        self.assertGreater(next_run, datetime.now())
        self.assertIn("proactive_role-1", self.scheduler.jobs)

        with patch.object(scheduler_service.random, "randint") as randint:
            scheduler_service.schedule_proactive_for_role("role-1")
        randint.assert_not_called()

    def test_disabled_or_archived_role_removes_job_and_trigger_time(self):
        profile = self._write_role(
            {
                "enabled": False,
                "next_trigger_time": (datetime.now() + timedelta(hours=1)).isoformat(),
            }
        )
        self.scheduler.jobs["proactive_role-1"] = object()

        scheduler_service.schedule_proactive_for_role("role-1")

        self.assertNotIn("proactive_role-1", self.scheduler.jobs)
        saved = json.loads(profile.read_text(encoding="utf-8"))
        self.assertIsNone(saved["proactive_config"]["next_trigger_time"])

    async def test_trigger_failure_still_schedules_next_run(self):
        failing_callback = AsyncMock(side_effect=RuntimeError("boom"))
        with patch.object(scheduler_service, "_event_callback", failing_callback), patch.object(
            scheduler_service,
            "schedule_proactive_for_role",
        ) as schedule:
            await scheduler_service._trigger_proactive("role-1")

        schedule.assert_called_once_with("role-1", reset=True)


class ProactiveUpsertTests(unittest.IsolatedAsyncioTestCase):
    async def test_upsert_merges_config_and_refreshes_scheduler(self):
        existing = {
            "id": "role-1",
            "name": "旧名称",
            "description": "保留描述",
            "archived": False,
            "proactive_config": {
                "enabled": False,
                "min_interval_minutes": 30,
                "max_interval_minutes": 120,
                "quiet_hours_start": 22,
                "quiet_hours_end": 8,
                "next_trigger_time": "2026-07-26T10:00:00",
            },
        }
        save_role = MagicMock()
        schedule = MagicMock()

        with patch("transport.ws_dispatcher.roles.load_role", return_value=existing), patch(
            "transport.ws_dispatcher.roles.save_role",
            save_role,
        ), patch(
            "services.scheduler_service.schedule_proactive_for_role",
            schedule,
        ):
            result = await _handle_roles_upsert(
                {
                    "role": {
                        "id": "role-1",
                        "name": "旧名称",
                        "proactive_config": {
                            "enabled": True,
                            "min_interval_minutes": 6,
                            "max_interval_minutes": 90,
                        },
                    }
                },
                "http://localhost:8000",
            )

        config = result["proactive_config"]
        self.assertTrue(config["enabled"])
        self.assertEqual(config["min_interval_minutes"], 6)
        self.assertEqual(config["quiet_hours_start"], 22)
        self.assertEqual(result["description"], "保留描述")
        save_role.assert_called_once()
        schedule.assert_called_once_with("role-1", reset=True)


if __name__ == "__main__":
    unittest.main()

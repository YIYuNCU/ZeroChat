import json
import shutil
import unittest
from datetime import datetime, timedelta
from pathlib import Path
from uuid import uuid4
from unittest.mock import AsyncMock, MagicMock, patch

from pydantic import ValidationError

from services import scheduler_service
from services import settings_service
from transport.ws_dispatcher import _handle_roles_upsert
from routers.roles import ProactiveConfig
from routers.settings import SettingsUpdate


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
        # 使用工作区内的测试运行目录（0o777 默认模式），避免 Windows 上
        # 0o700 临时目录附加的属主 ACL 阻断子目录创建。
        # 注意：放在 server/ 一级（服务端沙箱允许在 server/ 下新建目录）。
        base_dir = Path(__file__).resolve().parents[1] / "test_runtime_tmp"
        base_dir.mkdir(parents=True, exist_ok=True)
        self.roles_dir = base_dir / f"run-{uuid4().hex[:8]}"
        self.roles_dir.mkdir(parents=True)
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
        shutil.rmtree(self.roles_dir, ignore_errors=True)

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

    def test_multiple_minute_quiet_rules_delay_to_the_matching_end(self):
        rules = [
            {
                "start_minute": 12 * 60 + 30,
                "end_minute": 13 * 60 + 45,
                "repeat_type": "daily",
                "weekdays": [],
                "date": None,
            },
            {
                "start_minute": 22 * 60,
                "end_minute": 7 * 60,
                "repeat_type": "daily",
                "weekdays": [],
                "date": None,
            },
        ]

        self.assertEqual(
            scheduler_service.next_allowed_time(
                datetime(2026, 8, 17, 12, 45), rules
            ),
            datetime(2026, 8, 17, 13, 45),
        )
        self.assertEqual(
            scheduler_service.next_allowed_time(
                datetime(2026, 8, 17, 23, 30), rules
            ),
            datetime(2026, 8, 18, 7),
        )

    def test_weekly_rule_defers_only_on_matching_weekdays(self):
        rules = [
            {
                "start_minute": 22 * 60,
                "end_minute": 7 * 60,
                "repeat_type": "weekly",
                "weekdays": [5, 6, 7],
                "date": None,
            }
        ]
        # 2026-08-21 是周五（ISO 5）-> 延迟到周六 07:00
        friday = datetime(2026, 8, 21, 23, 30)
        self.assertEqual(
            scheduler_service.next_allowed_time(friday, rules),
            datetime(2026, 8, 22, 7),
        )
        # 周二不在集合 -> 不延迟
        tuesday = datetime(2026, 8, 18, 23, 30)
        self.assertEqual(scheduler_service.next_allowed_time(tuesday, rules), tuesday)

    def test_weekly_overnight_rule_covers_start_and_end_days(self):
        rules = [
            {
                "start_minute": 23 * 60,
                "end_minute": 7 * 60,
                "repeat_type": "weekly",
                "weekdays": [1],
                "date": None,
            }
        ]
        # 周一 23:30 -> 周二 07:00
        self.assertEqual(
            scheduler_service.next_allowed_time(datetime(2026, 8, 17, 23, 30), rules),
            datetime(2026, 8, 18, 7),
        )
        # 周二 06:00（结束日）-> 周二 07:00
        self.assertEqual(
            scheduler_service.next_allowed_time(datetime(2026, 8, 18, 6, 0), rules),
            datetime(2026, 8, 18, 7),
        )

    def test_once_rule_defers_only_on_matching_date(self):
        rules = [
            {
                "start_minute": 22 * 60,
                "end_minute": 23 * 60,
                "repeat_type": "once",
                "weekdays": [],
                "date": "2026-08-20",
            }
        ]
        self.assertEqual(
            scheduler_service.next_allowed_time(datetime(2026, 8, 20, 22, 30), rules),
            datetime(2026, 8, 20, 23),
        )
        self.assertEqual(
            scheduler_service.next_allowed_time(datetime(2026, 8, 21, 22, 30), rules),
            datetime(2026, 8, 21, 22, 30),
        )

    def test_legacy_hours_remain_a_single_daily_quiet_rule(self):
        self.assertEqual(
            scheduler_service._get_quiet_rules(
                {"quiet_hours_start": 22, "quiet_hours_end": 8}
            ),
            [
                {
                    "start_minute": 22 * 60,
                    "end_minute": 8 * 60,
                    "repeat_type": "daily",
                    "weekdays": [],
                    "date": None,
                }
            ],
        )

    def test_quiet_period_schema_rejects_overlap_and_adjacency(self):
        with self.assertRaises(ValidationError):
            ProactiveConfig(
                quiet_periods=[
                    {"start_minute": 60, "end_minute": 120},
                    {"start_minute": 120, "end_minute": 180},
                ]
            )


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

    async def test_upsert_replaces_legacy_hours_with_quiet_periods(self):
        existing = {
            "id": "role-1",
            "name": "旧名称",
            "proactive_config": {
                "enabled": True,
                "quiet_hours_start": 23,
                "quiet_hours_end": 7,
            },
        }
        save_role = MagicMock()

        with patch("transport.ws_dispatcher.roles.load_role", return_value=existing), patch(
            "transport.ws_dispatcher.roles.save_role", save_role
        ), patch("services.scheduler_service.schedule_proactive_for_role"):
            result = await _handle_roles_upsert(
                {
                    "role": {
                        "id": "role-1",
                        "name": "旧名称",
                        "proactive_config": {
                            "quiet_periods": [
                                {"start_minute": 1320, "end_minute": 420}
                            ],
                        },
                    }
                },
                "http://localhost:8000",
            )

        self.assertEqual(
            result["proactive_config"]["quiet_periods"],
            [{"start_minute": 1320, "end_minute": 420}],
        )
        self.assertNotIn("quiet_hours_start", result["proactive_config"])
        self.assertNotIn("quiet_hours_end", result["proactive_config"])


class ProviderQuietRuleTests(unittest.TestCase):
    """供应商+模型级安静规则：匹配、合并、gating 与设置校验。"""

    def _rule(self, **overrides):
        base = {
            "enabled": True,
            "api_url": "https://api.deepseek.com",
            "model": "deepseek-v4-flash",
            "start_minute": 22 * 60,
            "end_minute": 7 * 60,
            "repeat_type": "daily",
            "weekdays": [],
            "date": None,
        }
        base.update(overrides)
        return base

    def test_provider_rules_match_effective_target(self):
        role = {
            "id": "role-1",
            "ai_api_url": "https://api.deepseek.com",
            "ai_model": "deepseek-v4-flash",
        }
        rules = [
            self._rule(),
            self._rule(api_url="https://api.other.com", model="other-model"),
        ]
        with patch.object(settings_service, "get_quiet_rules", return_value=rules):
            matched = scheduler_service._get_provider_rules_for_role(role)
        self.assertEqual(len(matched), 1)
        self.assertEqual(matched[0]["api_url"], "https://api.deepseek.com")

    def test_disabled_and_non_matching_provider_rules_skipped(self):
        role = {
            "ai_api_url": "https://api.deepseek.com",
            "ai_model": "deepseek-v4-flash",
        }
        rules = [
            self._rule(enabled=False),
            self._rule(api_url="https://API.DEEPSEEK.COM/", model="DEEPSEEK-V4-FLASH"),
        ]
        with patch.object(settings_service, "get_quiet_rules", return_value=rules):
            matched = scheduler_service._get_provider_rules_for_role(role)
        self.assertEqual(matched, [])

    def test_role_fallbacks_to_global_provider(self):
        rules = [self._rule()]
        role = {"id": "role-1"}  # 无 ai_api_url/ai_model -> 全局设置
        with patch.object(settings_service, "get_quiet_rules", return_value=rules), patch.object(
            settings_service,
            "load_settings",
            return_value={
                "ai_api_url": "https://api.deepseek.com",
                "ai_model": "deepseek-v4-flash",
            },
        ):
            matched = scheduler_service._get_provider_rules_for_role(role)
        self.assertEqual(len(matched), 1)

    def test_merged_role_rules_and_provider_rules(self):
        role = {
            "id": "role-1",
            "ai_api_url": "https://api.deepseek.com",
            "ai_model": "deepseek-v4-flash",
            "proactive_config": {
                "quiet_periods": [{"start_minute": 12 * 60, "end_minute": 13 * 60}]
            },
        }
        with patch.object(settings_service, "get_quiet_rules", return_value=[self._rule()]):
            rules = scheduler_service._get_quiet_rules_for_role("role-1", role)
        self.assertEqual(len(rules), 2)
        self.assertEqual(rules[0]["start_minute"], 12 * 60)  # 角色级
        self.assertEqual(rules[1]["start_minute"], 22 * 60)  # 供应商级

    def test_is_role_provider_quiet_gates_now(self):
        role = {
            "ai_api_url": "https://api.deepseek.com",
            "ai_model": "deepseek-v4-flash",
        }
        # 规则覆盖整天 -> 当前时刻必然在静默内
        with patch.object(
            settings_service,
            "get_quiet_rules",
            return_value=[self._rule(start_minute=0, end_minute=23 * 60 + 59)],
        ):
            self.assertTrue(scheduler_service.is_role_provider_quiet("role-1", role))
        other = {"ai_api_url": "https://api.other.com", "ai_model": "x"}
        with patch.object(
            settings_service,
            "get_quiet_rules",
            return_value=[self._rule(start_minute=0, end_minute=23 * 60 + 59)],
        ):
            self.assertFalse(scheduler_service.is_role_provider_quiet("role-1", other))

    def test_settings_update_validates_provider_quiet_rules(self):
        with self.assertRaises(ValidationError):
            SettingsUpdate(quiet_rules=[self._rule(start_minute=60, end_minute=60)])
        with self.assertRaises(ValidationError):
            SettingsUpdate(quiet_rules=[self._rule(repeat_type="weekly", weekdays=[])])
        with self.assertRaises(ValidationError):
            SettingsUpdate(quiet_rules=[self._rule(repeat_type="once")])
        with self.assertRaises(ValidationError):
            SettingsUpdate(quiet_rules=[self._rule(api_url="")])
        ok = SettingsUpdate(quiet_rules=[self._rule(repeat_type="weekly", weekdays=[1, 3])])
        self.assertEqual(ok.quiet_rules[0].weekdays, [1, 3])


if __name__ == "__main__":
    unittest.main()

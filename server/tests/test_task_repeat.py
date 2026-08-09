import unittest
from datetime import datetime, timedelta
from unittest.mock import patch

from apscheduler.triggers.cron import CronTrigger
from apscheduler.triggers.date import DateTrigger

from services import scheduler_service


class _FakeScheduler:
    def __init__(self):
        self.jobs = {}

    def get_job(self, job_id):
        return self.jobs.get(job_id)

    def remove_job(self, job_id):
        self.jobs.pop(job_id, None)

    def add_job(self, func, trigger, id, args, replace_existing):
        self.jobs[id] = {"func": func, "trigger": trigger, "args": args}


class TaskRepeatSchedulingTests(unittest.TestCase):
    def setUp(self):
        self.scheduler = _FakeScheduler()
        self.patch = patch.object(scheduler_service, "_scheduler", self.scheduler)
        self.patch.start()

    def tearDown(self):
        self.patch.stop()

    def _future(self):
        return (datetime.now() + timedelta(days=1)).replace(microsecond=0)

    def test_daily_uses_cron_trigger(self):
        t = self._future()
        scheduler_service.schedule_task(
            {"id": "d1", "trigger_time": t.isoformat(), "repeat": "daily"}
        )
        job = self.scheduler.get_job("task_d1")
        self.assertIsNotNone(job)
        self.assertIsInstance(job["trigger"], CronTrigger)

    def test_weekly_uses_cron_trigger(self):
        t = self._future()
        scheduler_service.schedule_task(
            {"id": "w1", "trigger_time": t.isoformat(), "repeat": "weekly"}
        )
        job = self.scheduler.get_job("task_w1")
        self.assertIsNotNone(job)
        self.assertIsInstance(job["trigger"], CronTrigger)

    def test_none_uses_date_trigger(self):
        t = self._future()
        scheduler_service.schedule_task(
            {"id": "o1", "trigger_time": t.isoformat(), "repeat": "none"}
        )
        job = self.scheduler.get_job("task_o1")
        self.assertIsNotNone(job)
        self.assertIsInstance(job["trigger"], DateTrigger)

    def test_past_one_shot_not_scheduled(self):
        past = (datetime.now() - timedelta(days=1)).isoformat()
        scheduler_service.schedule_task(
            {"id": "p1", "trigger_time": past, "repeat": "none"}
        )
        self.assertIsNone(self.scheduler.get_job("task_p1"))

    def test_daily_with_past_trigger_time_still_scheduled(self):
        # 重复任务的 trigger_time 只用于确定时刻，过去日期也应调度
        past = (datetime.now() - timedelta(days=5)).isoformat()
        scheduler_service.schedule_task(
            {"id": "d2", "trigger_time": past, "repeat": "daily"}
        )
        self.assertIsNotNone(self.scheduler.get_job("task_d2"))


if __name__ == "__main__":
    unittest.main()

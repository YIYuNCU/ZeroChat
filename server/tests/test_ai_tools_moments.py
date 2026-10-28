import unittest
from datetime import datetime, timedelta
from unittest.mock import patch

from services.ai_tools import (
    _VIEW_MOMENT_COMMENTS_TOOL,
    _VIEW_MOMENTS_TOOL,
    execute_view_moment_comments,
    execute_view_moments,
)

ROLE = {"id": "role-1", "name": "小暖"}
TODAY = datetime.now().strftime("%Y-%m-%d")
YESTERDAY = (datetime.now() - timedelta(days=1)).strftime("%Y-%m-%d")


def _posts():
    return [
        {
            "id": "aaaaaaaa-1111",
            "author_id": "role-1",
            "author_name": "小暖",
            "content": "今天天气真好",
            "image_urls": [],
            "liked_by": [{"id": "me", "name": "阿明"}],
            "comments": [
                {"id": "c1", "author_id": "me", "author_name": "阿明", "content": "我也觉得",
                 "reply_to_id": None, "reply_to_name": None, "created_at": f"{TODAY}T10:05:00"},
                {"id": "c2", "author_id": "role-1", "author_name": "小暖", "content": "出去走走吧",
                 "reply_to_id": "me", "reply_to_name": "阿明", "created_at": f"{TODAY}T10:06:00"},
            ],
            "created_at": f"{TODAY}T10:00:00",
        },
        {
            "id": "bbbbbbbb-2222",
            "author_id": "me",
            "author_name": "阿明",
            "content": "加班中",
            "image_urls": ["a.png"],
            "liked_by": [],
            "comments": [],
            "created_at": f"{YESTERDAY}T22:00:00",
        },
        {
            "id": "cccccccc-3333",
            "author_id": "role-2",
            "author_name": "小凉",
            "content": "别的角色的动态",
            "liked_by": [],
            "comments": [],
            "created_at": f"{YESTERDAY}T08:00:00",
        },
        {
            "id": "dddddddd-4444",
            "author_id": "1000000000-tool",
            "author_name": "工具",
            "content": "不应可见",
            "created_at": f"{TODAY}T09:00:00",
        },
    ]


def _patched():
    return patch("routers.moments.load_moments", return_value=_posts())


class ViewMomentsToolTests(unittest.IsolatedAsyncioTestCase):
    def test_schemas_are_strict_and_closed(self):
        for group in (_VIEW_MOMENTS_TOOL, _VIEW_MOMENT_COMMENTS_TOOL):
            function = group[0]["function"]
            parameters = function["parameters"]
            self.assertTrue(function["strict"])
            self.assertFalse(parameters["additionalProperties"])
            self.assertEqual(set(parameters["required"]), set(parameters["properties"]))

    async def test_lists_all_visible_posts_newest_first(self):
        with _patched():
            result = await execute_view_moments(ROLE, "", "", 10)
        self.assertLess(result.index("今天天气真好"), result.index("加班中"))
        self.assertIn("[aaaaaaaa]", result)
        self.assertNotIn("不应可见", result)
        self.assertIn("评论 2 条", result)
        self.assertIn("配图 1 张", result)

    async def test_filters_by_date(self):
        with _patched():
            today = await execute_view_moments(ROLE, TODAY, "", 10)
            yesterday = await execute_view_moments(ROLE, "昨天", "", 10)
        self.assertIn("今天天气真好", today)
        self.assertNotIn("加班中", today)
        self.assertIn("加班中", yesterday)
        self.assertNotIn("今天天气真好", yesterday)

    async def test_filters_by_author_aliases_and_names(self):
        with _patched():
            user = await execute_view_moments(ROLE, "", "user", 10)
            myself = await execute_view_moments(ROLE, "", "self", 10)
            named = await execute_view_moments(ROLE, "", "小凉", 10)
        self.assertIn("加班中", user)
        self.assertNotIn("今天天气真好", user)
        self.assertIn("今天天气真好", myself)
        self.assertIn("（你自己）", myself)
        self.assertIn("别的角色的动态", named)
        self.assertNotIn("加班中", named)

    async def test_invalid_date_and_empty_result(self):
        with _patched():
            bad = await execute_view_moments(ROLE, "上周三", "", 10)
            none = await execute_view_moments(ROLE, "2001-01-01", "", 10)
        self.assertIn("格式无效", bad)
        self.assertIn("没有找到", none)

    async def test_limit_is_clamped_and_reports_remaining(self):
        with _patched():
            result = await execute_view_moments(ROLE, "", "", 1)
            bogus = await execute_view_moments(ROLE, "", "", "abc")
        self.assertIn("还有 2 条更早的动态", result)
        self.assertIn("加班中", bogus)

    async def test_comments_by_full_id_and_prefix(self):
        with _patched():
            full = await execute_view_moment_comments(ROLE, "aaaaaaaa-1111")
            prefix = await execute_view_moment_comments(ROLE, "[aaaaaaaa]")
        for result in (full, prefix):
            self.assertIn("点赞：阿明", result)
            self.assertIn("阿明（用户）：我也觉得", result)
            self.assertIn("小暖（你自己） 回复 阿明：出去走走吧", result)

    async def test_comments_unknown_or_hidden_post(self):
        with _patched():
            unknown = await execute_view_moment_comments(ROLE, "zzzz")
            hidden = await execute_view_moment_comments(ROLE, "dddddddd")
            empty = await execute_view_moment_comments(ROLE, "bbbbbbbb")
            blank = await execute_view_moment_comments(ROLE, "  ")
        self.assertIn("没有找到", unknown)
        self.assertIn("没有找到", hidden)
        self.assertIn("评论：暂无", empty)
        self.assertIn("不能为空", blank)

    async def test_ambiguous_prefix(self):
        posts = _posts()
        posts[1]["id"] = "aaaaaaaa-9999"
        with patch("routers.moments.load_moments", return_value=posts):
            result = await execute_view_moment_comments(ROLE, "aaaa")
        self.assertIn("多条", result)


if __name__ == "__main__":
    unittest.main()

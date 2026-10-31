import json
import tempfile
import unittest
from datetime import datetime, timedelta
from pathlib import Path
from unittest.mock import AsyncMock, patch

from routers import moments
from services.ai_tools import (
    _COMMENT_MOMENT_TOOL,
    _LIKE_MOMENT_TOOL,
    _POST_MOMENT_TOOL,
    execute_comment_moment,
    execute_like_moment,
    execute_post_moment,
)

ROLE = {"id": "role-1", "name": "小暖"}
NOW = datetime.now()


def _seed():
    return [
        {
            "id": "aaaaaaaa-1111", "author_id": "me", "author_name": "阿明", "content": "加班中",
            "image_urls": [], "liked_by": [],
            "comments": [
                {"id": "c1", "author_id": "me", "author_name": "阿明", "content": "好累",
                 "reply_to_id": None, "reply_to_name": None,
                 "created_at": (NOW - timedelta(hours=2)).isoformat()},
                {"id": "c2", "author_id": "role-2", "author_name": "小凉", "content": "加油",
                 "reply_to_id": None, "reply_to_name": None,
                 "created_at": (NOW - timedelta(hours=1)).isoformat()},
            ],
            "created_at": (NOW - timedelta(hours=3)).isoformat(),
        },
        {
            "id": "dddddddd-4444", "author_id": "1000000000-tool", "author_name": "工具",
            "content": "不应可见", "created_at": (NOW - timedelta(hours=4)).isoformat(),
        },
    ]


class MomentActionToolTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        for target, value in (
            ("MOMENTS_FILE", root / "posts.json"), ("MOMENTS_HASH_FILE", root / "posts.hash"),
        ):
            patcher = patch.object(moments, target, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        moments.save_moments(_seed())
        push = patch("transport.push_hub.publish_server_push", new=AsyncMock())
        self.push = push.start()
        self.addCleanup(push.stop)

    def posts(self):
        return {p["id"]: p for p in moments.load_moments()}

    def test_schemas_are_strict_and_closed(self):
        for group in (_POST_MOMENT_TOOL, _COMMENT_MOMENT_TOOL, _LIKE_MOMENT_TOOL):
            function = group[0]["function"]
            parameters = function["parameters"]
            self.assertTrue(function["strict"], function["name"])
            self.assertFalse(parameters["additionalProperties"], function["name"])
            self.assertEqual(set(parameters["required"]), set(parameters["properties"]))

    async def test_post_moment_saves_and_pushes(self):
        result = await execute_post_moment(ROLE, "<对话>今天看到了晚霞</对话>")
        self.assertIn("朋友圈已发布", result)
        mine = [p for p in moments.load_moments() if p["author_id"] == "role-1"]
        self.assertEqual(len(mine), 1)
        self.assertEqual(mine[0]["content"], "今天看到了晚霞")
        self.assertEqual(mine[0]["author_name"], "小暖")
        self.push.assert_awaited_once()
        self.assertEqual(self.push.await_args.args[0], "moment_post")
        self.assertEqual(self.push.await_args.args[1]["post_id"], mine[0]["id"])

    async def test_post_moment_rejects_empty_long_and_rapid_repeat(self):
        self.assertIn("不能为空", await execute_post_moment(ROLE, "  "))
        self.assertIn("超过", await execute_post_moment(ROLE, "字" * 501))
        self.assertIn("已发布", await execute_post_moment(ROLE, "第一条"))
        self.assertIn("间隔", await execute_post_moment(ROLE, "第二条"))
        self.assertEqual(len([p for p in moments.load_moments() if p["author_id"] == "role-1"]), 1)

    async def test_post_moment_refused_for_tool_role(self):
        result = await execute_post_moment({"id": "1000000000-tool", "name": "工具"}, "你好")
        self.assertIn("发布失败", result)
        self.push.assert_not_awaited()

    async def test_comment_on_post_by_prefix(self):
        result = await execute_comment_moment(ROLE, "[aaaaaaaa]", "注意休息", "")
        self.assertIn("已评论", result)
        comments = self.posts()["aaaaaaaa-1111"]["comments"]
        self.assertEqual(comments[-1]["author_id"], "role-1")
        self.assertEqual(comments[-1]["content"], "注意休息")
        self.assertIsNone(comments[-1]["reply_to_id"])
        self.assertEqual(self.push.await_args.args[0], "moment_comment")

    async def test_reply_to_user_and_to_named_commenter(self):
        await execute_comment_moment(ROLE, "aaaaaaaa", "早点睡", "user")
        await execute_comment_moment(ROLE, "aaaaaaaa", "你也是", "小凉")
        comments = self.posts()["aaaaaaaa-1111"]["comments"]
        to_user, to_other = comments[-2], comments[-1]
        self.assertEqual((to_user["reply_to_id"], to_user["reply_to_name"]), ("me", "阿明"))
        self.assertEqual((to_other["reply_to_id"], to_other["reply_to_name"]), ("role-2", "小凉"))

    async def test_reply_to_unknown_person_or_self_fails(self):
        before = len(self.posts()["aaaaaaaa-1111"]["comments"])
        self.assertIn("没有「路人」的评论", await execute_comment_moment(ROLE, "aaaaaaaa", "嗨", "路人"))
        self.assertIn("回复失败", await execute_comment_moment(ROLE, "aaaaaaaa", "嗨", "小暖"))
        self.assertEqual(len(self.posts()["aaaaaaaa-1111"]["comments"]), before)

    async def test_comment_validation_and_unknown_post(self):
        self.assertIn("不能为空", await execute_comment_moment(ROLE, "aaaaaaaa", " ", ""))
        self.assertIn("超过", await execute_comment_moment(ROLE, "aaaaaaaa", "字" * 201, ""))
        self.assertIn("post_id 不能为空", await execute_comment_moment(ROLE, " ", "好", ""))
        self.assertIn("没有找到", await execute_comment_moment(ROLE, "zzzz", "好", ""))
        self.assertIn("没有找到", await execute_comment_moment(ROLE, "dddddddd", "好", ""))
        self.push.assert_not_awaited()

    async def test_like_moment_once(self):
        first = await execute_like_moment(ROLE, "aaaaaaaa")
        second = await execute_like_moment(ROLE, "aaaaaaaa")
        self.assertIn("点赞", first)
        self.assertIn("已经", second)
        likes = self.posts()["aaaaaaaa-1111"]["liked_by"]
        self.assertEqual(likes, [{"id": "role-1", "name": "小暖"}])
        self.push.assert_awaited_once()
        self.assertEqual(self.push.await_args.args[0], "moment_like")

    async def test_like_unknown_or_hidden_post(self):
        self.assertIn("没有找到", await execute_like_moment(ROLE, "zzzz"))
        self.assertIn("没有找到", await execute_like_moment(ROLE, "dddddddd"))
        self.assertIn("post_id 不能为空", await execute_like_moment(ROLE, ""))

    async def test_push_failure_does_not_fail_the_write(self):
        self.push.side_effect = RuntimeError("ws down")
        result = await execute_like_moment(ROLE, "aaaaaaaa")
        self.assertIn("点赞", result)
        self.assertEqual(len(self.posts()["aaaaaaaa-1111"]["liked_by"]), 1)


class MomentActionDispatchTests(unittest.IsolatedAsyncioTestCase):
    async def _tool_names(self, *, origin, sender, context, message="看看朋友圈"):
        from services.ai_service import generate_with_role
        from services.chat_envelope import build_envelope

        envelope = build_envelope({"origin": origin, "sender": sender, **context})
        captured = {}

        async def fake_call(role_data, messages, default_temp=1.0, tools=None, **kwargs):
            captured["tools"] = tools or []
            return {"success": True, "content": "好的"}

        with patch("services.ai_service._call_with_role_config", side_effect=fake_call), patch(
            "services.ai_service.is_recall_onebot_available", return_value=False,
        ), patch("services.ai_service.is_recall_chat_available", return_value=False):
            await generate_with_role(
                ROLE, message, origin=origin, sender=sender, envelope=envelope,
            )
        return {tool["function"]["name"] for tool in captured["tools"]}

    async def test_moment_tools_open_for_app_only(self):
        wanted = {
            "view_moments", "view_moment_comments",
            "post_moment", "comment_moment", "like_moment",
        }
        app = await self._tool_names(origin="zerochat", sender="user", context={})
        owner_qq = await self._tool_names(
            origin="onebot_private", sender="user", context={"sender_id": "10001"},
        )
        third_party = await self._tool_names(
            origin="onebot_private", sender="10003(QQ名:路人)", context={"sender_id": "10003"},
        )
        group = await self._tool_names(
            origin="onebot_group", sender="user",
            context={"onebot_group_id": "g1", "sender_id": "10001"},
        )
        self.assertTrue(wanted <= app)
        self.assertFalse(wanted & owner_qq)
        self.assertFalse(wanted & third_party)
        self.assertFalse(wanted & group)

    async def test_tool_calls_are_dispatched(self):
        from services.ai_service import _handle_tool_calls

        def call(name, arguments):
            return {"id": f"call_{name}", "type": "function",
                    "function": {"name": name, "arguments": arguments}}

        result = {"tool_calls": [
            call("post_moment", {"content": "晚霞"}),
            call("comment_moment", {"post_id": "aaaa", "content": "好看", "reply_to": "user"}),
            call("like_moment", {"post_id": "aaaa"}),
        ]}
        messages = []
        with patch("services.ai_service.execute_post_moment", new=AsyncMock(return_value="P")) as post, patch(
            "services.ai_service.execute_comment_moment", new=AsyncMock(return_value="C"),
        ) as comment, patch(
            "services.ai_service.execute_like_moment", new=AsyncMock(return_value="L"),
        ) as like, patch(
            "services.ai_service._call_with_role_config",
            return_value={"success": True, "content": "好的"},
        ):
            await _handle_tool_calls(result, messages, ROLE, [])
        post.assert_awaited_once_with(ROLE, "晚霞")
        comment.assert_awaited_once_with(ROLE, "aaaa", "好看", "user")
        like.assert_awaited_once_with(ROLE, "aaaa")
        self.assertEqual(
            [m["content"] for m in messages if m.get("role") == "tool"], ["P", "C", "L"],
        )


if __name__ == "__main__":
    unittest.main()

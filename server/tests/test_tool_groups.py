import json
import unittest
from unittest.mock import patch

from services import tool_groups
from services.ai_tools import _RECALL_CHAT_TOOL, _RECALL_ONEBOT_TOOL

ROLE = {"id": "role-1", "name": "小暖"}
MOMENT_TOOLS = {
    "view_moments", "view_moment_comments", "post_moment", "comment_moment", "like_moment",
}


def names(tools):
    return [t["function"]["name"] for t in tools]


class OfferGroupsTests(unittest.TestCase):
    def test_pending_groups_become_a_small_loader_with_hints(self):
        tools = []
        tool_groups.offer_groups(
            tools,
            [tool_groups.moments_group(), tool_groups.recall_group(_RECALL_CHAT_TOOL)],
            "你好",
        )
        self.assertEqual(names(tools), ["load_tools"])
        function = tools[0]["function"]
        self.assertEqual(function["parameters"]["properties"]["group"]["enum"], ["moments", "recall"])
        self.assertIn("- moments：朋友圈", function["description"])
        self.assertIn("- recall：历史回顾", function["description"])
        self.assertTrue(function["strict"])
        full = json.dumps(tool_groups.moments_group().tools, ensure_ascii=False)
        self.assertLess(len(json.dumps(tools, ensure_ascii=False)), len(full) / 2)

    def test_keyword_exposes_group_directly(self):
        tools = []
        tool_groups.offer_groups(tools, [tool_groups.moments_group()], "帮我给他朋友圈点个赞")
        self.assertEqual(set(names(tools)), MOMENT_TOOLS)

    def test_only_unmatched_groups_stay_folded(self):
        tools = []
        tool_groups.offer_groups(
            tools,
            [tool_groups.moments_group(), tool_groups.recall_group(_RECALL_CHAT_TOOL)],
            "看看朋友圈",
        )
        self.assertTrue(MOMENT_TOOLS <= set(names(tools)))
        loader = next(t for t in tools if t["function"]["name"] == "load_tools")
        self.assertEqual(loader["function"]["parameters"]["properties"]["group"]["enum"], ["recall"])
        self.assertNotIn("moments", loader["function"]["description"])

    def test_no_groups_means_no_loader(self):
        tools = []
        tool_groups.offer_groups(tools, [], "你好")
        self.assertEqual(tools, [])

    def test_recall_group_follows_available_tools(self):
        self.assertIsNone(tool_groups.recall_group([]))
        both = tool_groups.recall_group([*_RECALL_CHAT_TOOL, *_RECALL_ONEBOT_TOOL])
        self.assertIn("与用户的历史聊天", both.summary)
        self.assertIn("QQ 会话", both.summary)
        self.assertEqual(both.keywords, tool_groups.RECALL_KEYWORDS)


class ExecuteLoadToolsTests(unittest.TestCase):
    def setUp(self):
        self.tools = [{"type": "function", "function": {"name": "web_search"}}]
        tool_groups.offer_groups(
            self.tools,
            [tool_groups.moments_group(), tool_groups.recall_group(_RECALL_CHAT_TOOL)],
            "你好",
        )

    def test_loading_adds_tools_in_place_and_updates_loader(self):
        result = tool_groups.execute_load_tools(self.tools, "moments")
        self.assertIn("已加载", result)
        self.assertIn("post_moment", result)
        self.assertTrue(MOMENT_TOOLS <= set(names(self.tools)))
        loader = next(t for t in self.tools if t["function"]["name"] == "load_tools")
        self.assertEqual(loader["function"]["parameters"]["properties"]["group"]["enum"], ["recall"])

    def test_loader_removed_after_last_group(self):
        tool_groups.execute_load_tools(self.tools, "moments")
        tool_groups.execute_load_tools(self.tools, "recall")
        self.assertNotIn("load_tools", names(self.tools))
        self.assertIn("recall_chat_history", names(self.tools))

    def test_repeat_and_unknown_group(self):
        tool_groups.execute_load_tools(self.tools, "moments")
        size = len(self.tools)
        self.assertIn("已经可用", tool_groups.execute_load_tools(self.tools, " Moments "))
        self.assertEqual(len(self.tools), size)
        unknown = tool_groups.execute_load_tools(self.tools, "nope")
        self.assertIn("加载失败", unknown)
        self.assertIn("recall", unknown)

    def test_without_tools_or_state(self):
        self.assertIn("加载失败", tool_groups.execute_load_tools(None, "moments"))


class GenerateWithRoleGroupTests(unittest.IsolatedAsyncioTestCase):
    async def _run(self, message="你好", origin="zerochat", sender="user", context=None,
                   recall=False, replies=None):
        from services.ai_service import generate_with_role
        from services.chat_envelope import build_envelope

        envelope = build_envelope({"origin": origin, "sender": sender, **(context or {})})
        seen = []
        queue = list(replies or [{"success": True, "content": "好的"}])

        async def fake_call(role_data, messages, default_temp=1.0, tools=None, **kwargs):
            seen.append(list(names(tools or [])))
            return queue.pop(0) if len(queue) > 1 else queue[0]

        with patch("services.ai_service._call_with_role_config", side_effect=fake_call), patch(
            "services.ai_service.is_recall_onebot_available", return_value=recall,
        ), patch("services.ai_service.is_recall_chat_available", return_value=recall):
            await generate_with_role(
                ROLE, message, origin=origin, sender=sender, envelope=envelope,
            )
        return seen

    async def test_app_chat_folds_moments_by_default(self):
        seen = await self._run("你好")
        self.assertFalse(MOMENT_TOOLS & set(seen[0]))
        self.assertIn("load_tools", seen[0])

    async def test_scheduler_moment_generation_never_gets_moment_tools(self):
        seen = await self._run("现在请发布一条朋友圈动态", origin="moments", sender="system")
        self.assertFalse(MOMENT_TOOLS & set(seen[0]))
        self.assertNotIn("load_tools", seen[0])

    async def test_qq_conversations_have_no_moments_group(self):
        seen = await self._run(
            "看看朋友圈", origin="onebot_private", sender="user", context={"sender_id": "10001"},
        )
        self.assertFalse(MOMENT_TOOLS & set(seen[0]))
        self.assertNotIn("load_tools", seen[0])

    async def test_model_loads_group_and_uses_it_next_round(self):
        load_call = {
            "success": True, "content": "",
            "tool_calls": [{
                "id": "call_load", "type": "function",
                "function": {"name": "load_tools", "arguments": {"group": "moments"}},
            }],
        }
        seen = await self._run(
            "你好", replies=[load_call, {"success": True, "content": "好的"}],
        )
        self.assertNotIn("post_moment", seen[0])
        self.assertTrue(MOMENT_TOOLS <= set(seen[1]))
        self.assertNotIn("load_tools", seen[1])


if __name__ == "__main__":
    unittest.main()

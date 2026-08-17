import unittest
from unittest.mock import AsyncMock, patch

from routers.ai_behavior import (
    AIEvent,
    AIEventType,
    handle_moment_comment,
    handle_moment_post,
)
from services.ai_service import generate_moment_comment


class MomentGenerationContextTests(unittest.IsolatedAsyncioTestCase):
    async def test_post_uses_standard_role_generation_with_memory(self):
        role = {"id": "role-1", "name": "测试角色"}
        event = AIEvent(role_id="role-1", event_type=AIEventType.MOMENT_POST)

        with patch(
            "services.memory_service.get_context_messages",
            new=AsyncMock(
                return_value=[{"role": "user", "content": "最近在准备考试"}]
            ),
        ), patch(
            "services.memory_service._run_db",
            new=AsyncMock(return_value="用户最近在准备考试"),
        ), patch(
            "services.ai_service.generate_with_role",
            new=AsyncMock(return_value={"success": True, "content": "<对话>加油</对话>"}),
        ) as generate:
            result = await handle_moment_post(role, event)

        self.assertEqual(result.content, "加油")
        self.assertEqual(
            generate.call_args.kwargs["core_memory_context"], "用户最近在准备考试"
        )
        self.assertEqual(
            generate.call_args.kwargs["history"][0]["content"], "最近在准备考试"
        )
        self.assertEqual(generate.call_args.kwargs["origin"], "moments")

    async def test_comment_loads_memory_thread_and_reply_author(self):
        role = {"id": "role-1", "name": "测试角色"}
        event = AIEvent(
            role_id="role-1",
            event_type=AIEventType.MOMENT_COMMENT,
            context={
                "post_id": "post-1",
                "post_content": "旧正文",
                "post_author": "旧作者",
                "reply_to": "晚饭吃了吗",
                "reply_to_name": "小明",
            },
        )
        post = {
            "id": "post-1",
            "content": "今天完成了考试复习",
            "author_name": "我",
            "comments": [
                {"author_name": "小明", "content": "晚饭吃了吗"},
                {"author_name": "测试角色", "content": "还没有"},
            ],
        }

        with patch("routers.moments.load_moments", return_value=[post]), patch(
            "services.memory_service.get_context_messages",
            new=AsyncMock(
                return_value=[{"role": "assistant", "content": "我会陪你复习"}]
            ),
        ), patch(
            "services.memory_service._run_db",
            new=AsyncMock(return_value="用户在准备考试"),
        ), patch(
            "services.ai_service.generate_with_role",
            new=AsyncMock(return_value={"success": True, "content": "<对话>记得吃呀</对话>"}),
        ) as generate:
            result = await handle_moment_comment(role, event)

        self.assertEqual(result.content, "记得吃呀")
        prompt = generate.call_args.kwargs["user_message"]
        self.assertIn("小明的这条评论：晚饭吃了吗", prompt)
        self.assertIn("小明：晚饭吃了吗", prompt)
        self.assertIn("测试角色：还没有", prompt)
        self.assertEqual(
            generate.call_args.kwargs["core_memory_context"], "用户在准备考试"
        )
        self.assertEqual(
            generate.call_args.kwargs["history"][0]["content"], "我会陪你复习"
        )

    async def test_comment_generation_uses_standard_role_pipeline(self):
        role = {"id": "role-1", "name": "测试角色"}
        with patch(
            "services.ai_service.generate_with_role",
            new=AsyncMock(return_value={"success": True, "content": "<对话>好呀</对话>"}),
        ) as generate:
            await generate_moment_comment(
                role,
                "周末去公园",
                "小红",
                comment_thread=[{"author_name": "小红", "content": "要一起吗"}],
                core_memory_context="用户喜欢散步",
            )

        self.assertEqual(generate.call_args.kwargs["origin"], "moments")
        self.assertEqual(
            generate.call_args.kwargs["core_memory_context"], "用户喜欢散步"
        )
        self.assertIn("小红：要一起吗", generate.call_args.kwargs["user_message"])


if __name__ == "__main__":
    unittest.main()

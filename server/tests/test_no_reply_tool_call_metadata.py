"""回归测试：无回复（<无回复/>）分支必须保留 content/metadata（尤其 request_id），
否则本轮若发生了工具调用（例如 continue_if_no_reply 自身的链式跟进），
落库的 tool_calls 记录会因为消息从未创建/推送而无法查看。

覆盖 handle_proactive / handle_followup / handle_task 三个入口，
以及 core/lifecycle.py 调度器分支把 request_id/has_tool_calls 转存进 ChatMessage 的行为。
"""
import unittest
from unittest.mock import AsyncMock, patch

from routers.ai_behavior import AIEvent, AIEventType, handle_proactive, handle_followup, handle_task


def _pipeline_result(no_reply: bool, request_id: str = "req_test123", has_tool_calls: bool = True):
    return {
        "success": True,
        "reply": "<无回复/>" if no_reply else "正常回复内容",
        "no_reply": no_reply,
        "request_id": request_id,
        "has_tool_calls": has_tool_calls,
    }


class HandleProactiveNoReplyTests(unittest.IsolatedAsyncioTestCase):
    async def test_no_reply_still_carries_content_and_request_id(self):
        role = {"id": "role-1", "name": "AI", "proactive_config": {"enabled": True}}
        event = AIEvent(role_id="role-1", event_type=AIEventType.PROACTIVE, content="", context={})

        with patch(
            "routers.ai_behavior._run_memory_ai_pipeline",
            new=AsyncMock(return_value=_pipeline_result(no_reply=True)),
        ), patch(
            "routers.ai_behavior._build_shared_extra_parts",
            return_value=[],
        ):
            result = await handle_proactive(role, event)

        self.assertTrue(result.success)
        self.assertEqual(result.action, "ignore")
        # content 不能被丢弃成 None，否则 lifecycle.py 的调度器分支会因为
        # content 为空而完全跳过落库/推送，本轮工具调用记录变得不可达。
        self.assertEqual(result.content, "<无回复/>")
        self.assertEqual(result.metadata.get("request_id"), "req_test123")
        self.assertTrue(result.metadata.get("has_tool_calls"))
        self.assertTrue(result.metadata.get("no_reply"))

    async def test_normal_reply_still_uses_reply_action(self):
        role = {"id": "role-1", "name": "AI", "proactive_config": {"enabled": True}}
        event = AIEvent(role_id="role-1", event_type=AIEventType.PROACTIVE, content="", context={})

        with patch(
            "routers.ai_behavior._run_memory_ai_pipeline",
            new=AsyncMock(return_value=_pipeline_result(no_reply=False)),
        ), patch(
            "routers.ai_behavior._build_shared_extra_parts",
            return_value=[],
        ):
            result = await handle_proactive(role, event)

        self.assertEqual(result.action, "reply")
        self.assertEqual(result.content, "正常回复内容")
        self.assertFalse(result.metadata.get("no_reply"))


class HandleFollowupNoReplyTests(unittest.IsolatedAsyncioTestCase):
    async def test_no_reply_still_carries_content_and_request_id(self):
        role = {"id": "role-1", "name": "AI", "followup_config": {"enabled": True, "max_chain": 3}}
        event = AIEvent(
            role_id="role-1", event_type=AIEventType.FOLLOWUP, content="",
            context={"chain_count": 1},
        )

        with patch(
            "routers.ai_behavior._run_memory_ai_pipeline",
            new=AsyncMock(return_value=_pipeline_result(no_reply=True)),
        ), patch(
            "routers.ai_behavior._build_shared_extra_parts",
            return_value=[],
        ):
            result = await handle_followup(role, event)

        self.assertTrue(result.success)
        self.assertEqual(result.action, "ignore")
        self.assertEqual(result.content, "<无回复/>")
        self.assertEqual(result.metadata.get("request_id"), "req_test123")
        self.assertTrue(result.metadata.get("has_tool_calls"))


class HandleTaskNoReplyTests(unittest.IsolatedAsyncioTestCase):
    async def test_no_reply_still_carries_content_and_request_id(self):
        role = {"id": "role-1", "name": "AI"}
        event = AIEvent(
            role_id="role-1", event_type=AIEventType.TASK, content="任务内容",
            context={"task_id": "task-1"},
        )

        with patch(
            "routers.ai_behavior._run_memory_ai_pipeline",
            new=AsyncMock(return_value=_pipeline_result(no_reply=True)),
        ), patch(
            "routers.ai_behavior._build_moments_chat_context",
            return_value="",
        ), patch(
            "services.memory_service._if_in_menstruation",
            return_value=(None, None),
        ), patch(
            "services.memory_service._get_menstruation_cycle_info",
            return_value={"period_length": 5},
        ):
            result = await handle_task(role, event)

        self.assertTrue(result.success)
        self.assertEqual(result.action, "ignore")
        self.assertEqual(result.content, "<无回复/>")
        self.assertEqual(result.metadata.get("request_id"), "req_test123")
        self.assertTrue(result.metadata.get("has_tool_calls"))


class LifecycleDispatcherThreadsRequestIdTests(unittest.IsolatedAsyncioTestCase):
    """core/lifecycle.py 的调度器分支必须把 AIResponse.metadata 里的
    request_id/has_tool_calls 转存进 ChatMessage，否则即便 handle_* 保留了
    这些字段，落库的消息仍然没有查询工具调用记录的入口。
    """

    async def test_proactive_branch_carries_request_id_into_chat_message(self):
        from core.lifecycle import create_scheduler_event_handler
        from routers.ai_behavior import AIResponse

        fake_result = AIResponse(
            success=True,
            action="ignore",
            content="<无回复/>",
            metadata={
                "type": "proactive",
                "request_id": "req_abc",
                "has_tool_calls": True,
                "no_reply": True,
            },
        )

        captured = {}

        async def fake_save_role_chat_message(chat_id, message):
            captured["message"] = message
            return {"success": True}

        with patch(
            "routers.ai_behavior.handle_ai_event",
            new=AsyncMock(return_value=fake_result),
        ), patch(
            "routers.ai_behavior.load_role",
            return_value={"id": "role-1", "name": "AI"},
        ), patch(
            "routers.roles.save_chat_message",
            new=fake_save_role_chat_message,
        ), patch(
            "transport.push_hub.publish_server_push",
            new=AsyncMock(),
        ):
            handler = create_scheduler_event_handler(__import__("logging").getLogger("test"))
            await handler({
                "role_id": "role-1",
                "event_type": "proactive",
                "content": "",
                "context": {"chat_id": "role-1"},
            })

        message = captured.get("message")
        self.assertIsNotNone(message)
        self.assertEqual(message.request_id, "req_abc")
        self.assertTrue(message.has_tool_calls)


if __name__ == "__main__":
    unittest.main()

"""回归测试：reasoning_content（thinking 思考链）的服务端传播与持久化。

覆盖：
- _handle_tool_calls 累积每一轮工具调用回合的 reasoning_content，并保留
  assistant tool-call 消息的原样 replay（DeepSeek 要求）；
- _run_memory_ai_pipeline / handle_chat / handle_proactive / handle_followup /
  handle_task 把 reasoning_content 放进返回结果与 AIResponse.metadata；
- ChatMessage 序列化/落库/快照携带 reasoning_content，但 canonical md5 不变；
- lifecycle.py 调度器分支把 metadata.reasoning_content 转存进 ChatMessage；
- 角色 show_reasoning 在 REST create/update、WS upsert、角色列表中的往返。
"""
import asyncio
import hashlib
import json
import logging
import shutil
import tempfile
import unittest
import uuid
from pathlib import Path
from unittest.mock import AsyncMock, Mock, patch

from core.lifecycle import create_scheduler_event_handler
from routers import roles
from routers.ai_behavior import (
    AIEvent,
    AIEventType,
    AIResponse,
    _run_memory_ai_pipeline,
    handle_chat,
    handle_followup,
    handle_proactive,
    handle_task,
)
from services import ai_service, memory_service
from services.chat_io_service import canonical_chat_message, close_file_workers, snapshot_cache
from transport import ws_dispatcher


def _make_temp_root() -> Path:
    """Create a per-directory temp root with inherited permissions.

    ``tempfile.mkdtemp`` creates the directory with a restrictive ACL (mode
    0o700) that some sandboxed Windows environments cannot write into, so use a
    plain ``mkdir`` under the system temp root instead and clean it up in
    ``tearDown``.
    """
    root = Path(tempfile.gettempdir()) / f"zerochat_reasoning_{uuid.uuid4().hex}"
    root.mkdir(parents=True, exist_ok=True)
    return root


def _tool_call(call_id: str, emotion: str = "love") -> dict:
    return {
        "id": call_id,
        "type": "function",
        "function": {
            "name": "send_emotion_emoji",
            "arguments": {"emotion": emotion},
        },
    }


def _pipeline_result(reasoning: str = "先分析再回复", no_reply: bool = False) -> dict:
    return {
        "success": True,
        "error": None,
        "request_id": "req_reasoning",
        "reply": "<无回复/>" if no_reply else "正常回复内容",
        "no_reply": no_reply,
        "history": [],
        "extra_context": None,
        "new_core": None,
        "vector_memory_count": 0,
        "emojis_called": [],
        "has_tool_calls": True,
        "reasoning_content": reasoning,
    }


class ToolRoundReasoningTests(unittest.IsolatedAsyncioTestCase):
    """_handle_tool_calls 要把所有工具回合的思考链拼起来，而不是只留最后一轮。"""

    async def test_all_tool_rounds_accumulate_and_replay_is_preserved(self):
        initial = {
            "assistant_content": None,
            "reasoning_content": "第一轮思考",
            "tool_calls": [_tool_call("call_1")],
        }
        second_round = {
            "success": True,
            "content": None,
            "assistant_content": None,
            "reasoning_content": "第二轮思考",
            "tool_calls": [_tool_call("call_2", "happy")],
        }
        final_round = {
            "success": True,
            "content": "最终回复",
            "reasoning_content": "最终思考",
        }

        messages = []
        with patch(
            "services.ai_service.execute_send_emotion_emoji",
            return_value="[love]",
        ), patch(
            "services.ai_service._call_with_role_config",
            new=AsyncMock(side_effect=[second_round, final_round]),
        ):
            result = await ai_service._handle_tool_calls(
                initial, messages, {"id": "role-1"}, []
            )

        self.assertEqual(
            result["reasoning_content"],
            "第一轮思考\n\n第二轮思考\n\n最终思考",
        )
        # 原样 replay：每个 assistant tool-call 消息保留它自己那一轮的 reasoning。
        assistant_messages = [m for m in messages if m["role"] == "assistant"]
        self.assertEqual(
            [m["reasoning_content"] for m in assistant_messages],
            ["第一轮思考", "第二轮思考"],
        )
        self.assertEqual(result["content"], "最终回复")

    async def test_single_tool_round_includes_final_round_reasoning(self):
        initial = {
            "assistant_content": None,
            "reasoning_content": "调用工具前",
            "tool_calls": [_tool_call("call_1")],
        }
        final_round = {
            "success": True,
            "content": "好的",
            "reasoning_content": "调用工具后",
        }

        with patch(
            "services.ai_service.execute_send_emotion_emoji",
            return_value="[love]",
        ), patch(
            "services.ai_service._call_with_role_config",
            new=AsyncMock(return_value=final_round),
        ):
            result = await ai_service._handle_tool_calls(
                initial, [], {"id": "role-1"}, []
            )

        self.assertEqual(result["reasoning_content"], "调用工具前\n\n调用工具后")

    async def test_duplicate_consecutive_segment_is_not_repeated(self):
        initial = {
            "assistant_content": None,
            "reasoning_content": "同一段思考",
            "tool_calls": [_tool_call("call_1")],
        }
        final_round = {
            "success": True,
            "content": "好的",
            "reasoning_content": "同一段思考",
        }

        with patch(
            "services.ai_service.execute_send_emotion_emoji",
            return_value="[love]",
        ), patch(
            "services.ai_service._call_with_role_config",
            new=AsyncMock(return_value=final_round),
        ):
            result = await ai_service._handle_tool_calls(
                initial, [], {"id": "role-1"}, []
            )

        self.assertEqual(result["reasoning_content"], "同一段思考")

    async def test_no_reasoning_does_not_add_the_field(self):
        initial = {
            "assistant_content": None,
            "tool_calls": [_tool_call("call_1")],
        }
        final_round = {"success": True, "content": "好的"}

        with patch(
            "services.ai_service.execute_send_emotion_emoji",
            return_value="[love]",
        ), patch(
            "services.ai_service._call_with_role_config",
            new=AsyncMock(return_value=final_round),
        ):
            result = await ai_service._handle_tool_calls(
                initial, [], {"id": "role-1"}, []
            )

        self.assertNotIn("reasoning_content", result)


class PipelineAndMetadataReasoningTests(unittest.IsolatedAsyncioTestCase):
    """管道结果与四个 AIResponse 入口的 metadata 都要带 reasoning_content。"""

    async def test_pipeline_result_exposes_reasoning_content(self):
        generate_result = {
            "success": True,
            "content": "回复内容",
            "reasoning_content": "先分析再回复",
            "user_content": {"content": "你好"},
        }
        with patch(
            "services.ai_service.generate_with_role",
            new=AsyncMock(return_value=generate_result),
        ), patch(
            "services.memory_service.get_context_messages",
            new=AsyncMock(return_value=[]),
        ), patch(
            "services.memory_service.get_memory_context_string",
            return_value="",
        ), patch(
            "services.memory_service.append_short_term",
        ), patch(
            "services.memory_service._get_memory_length",
            return_value=10,
        ), patch(
            "services.stats_service.get_current_values",
            return_value=None,
        ):
            result = await _run_memory_ai_pipeline(
                role={"id": "role-1", "name": "AI"},
                role_id="role-1",
                user_message="你好",
                trigger_summary_after_reply=False,
            )

        self.assertEqual(result["reasoning_content"], "先分析再回复")

    async def test_handle_chat_metadata_carries_reasoning_content(self):
        event = AIEvent(
            role_id="role-1", event_type=AIEventType.CHAT, content="你好", context={}
        )
        with patch(
            "routers.ai_behavior._run_memory_ai_pipeline",
            new=AsyncMock(return_value=_pipeline_result()),
        ), patch(
            "routers.ai_behavior._build_shared_extra_parts",
            return_value=[],
        ), patch(
            "routers.ai_behavior._build_followup_budget_hint",
            return_value=None,
        ), patch(
            "services.vision_service.load_previous_images",
            return_value=[],
        ), patch(
            "services.scheduler_service.cancel_followup",
        ), patch(
            "services.scheduler_service.schedule_proactive_for_role",
        ), patch(
            "services.memory_service._get_memory_length",
            return_value=10,
        ):
            result = await handle_chat({"id": "role-1", "name": "AI"}, event)

        self.assertTrue(result.success)
        self.assertEqual(result.metadata.get("reasoning_content"), "先分析再回复")

    async def test_proactive_metadata_carries_reasoning_content(self):
        role = {"id": "role-1", "name": "AI", "proactive_config": {"enabled": True}}
        event = AIEvent(
            role_id="role-1", event_type=AIEventType.PROACTIVE, content="", context={}
        )
        with patch(
            "routers.ai_behavior._run_memory_ai_pipeline",
            new=AsyncMock(return_value=_pipeline_result("主动消息思考")),
        ), patch(
            "routers.ai_behavior._build_shared_extra_parts",
            return_value=[],
        ):
            result = await handle_proactive(role, event)

        self.assertEqual(result.metadata.get("reasoning_content"), "主动消息思考")

    async def test_followup_metadata_carries_reasoning_content(self):
        role = {
            "id": "role-1",
            "name": "AI",
            "followup_config": {"enabled": True, "max_chain": 3},
        }
        event = AIEvent(
            role_id="role-1",
            event_type=AIEventType.FOLLOWUP,
            content="",
            context={"chain_count": 1},
        )
        with patch(
            "routers.ai_behavior._run_memory_ai_pipeline",
            new=AsyncMock(return_value=_pipeline_result("续写思考")),
        ), patch(
            "routers.ai_behavior._build_shared_extra_parts",
            return_value=[],
        ):
            result = await handle_followup(role, event)

        self.assertEqual(result.metadata.get("reasoning_content"), "续写思考")

    async def test_task_metadata_carries_reasoning_content(self):
        role = {"id": "role-1", "name": "AI"}
        event = AIEvent(
            role_id="role-1",
            event_type=AIEventType.TASK,
            content="任务内容",
            context={"task_id": "task-1"},
        )
        with patch(
            "routers.ai_behavior._run_memory_ai_pipeline",
            new=AsyncMock(return_value=_pipeline_result("任务思考")),
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

        self.assertEqual(result.metadata.get("reasoning_content"), "任务思考")


class ChatMessageReasoningPersistenceTests(unittest.TestCase):
    """ChatMessage -> messages.json -> snapshot 全链路保留 reasoning_content。"""

    def setUp(self):
        self.root = _make_temp_root()
        self.roles_patch = patch.object(roles, "ROLES_DIR", self.root / "roles")
        self.roles_patch.start()
        snapshot_cache.clear()

    def tearDown(self):
        asyncio.run(close_file_workers())
        self.roles_patch.stop()
        shutil.rmtree(self.root, ignore_errors=True)

    def _message(self, message_id: str, reasoning: str) -> roles.ChatMessage:
        return roles.ChatMessage(
            id=message_id,
            content="你好",
            sender_id="me",
            timestamp="2026-09-05T00:00:00",
            type="text",
            reasoning_content=reasoning,
        )

    def test_chat_message_serializes_persists_and_syncs_reasoning(self):
        message = self._message("m1", "先想一想")
        self.assertEqual(message.model_dump()["reasoning_content"], "先想一想")

        async def run():
            await roles.save_chat_message("r", message)
            snapshot = await roles.get_chat_snapshot("http://backend")
            return snapshot

        snapshot = asyncio.run(run())
        stored = roles._load_role_chat_messages("r")
        self.assertEqual(stored[0]["reasoning_content"], "先想一想")

        synced = snapshot["chats"]["r"][0]
        self.assertEqual(synced["reasoning_content"], "先想一想")
        # 同步/存储都会复制额外字段；reasoning 不参与 canonical 哈希。
        self.assertNotIn("reasoning_content", canonical_chat_message(synced))

    def test_canonical_md5_ignores_reasoning_only_changes(self):
        base = {
            "id": "0",
            "sender_id": "me",
            "content": "中文\nline 0",
            "timestamp": "2026-09-05T00:00:00+00:00",
            "type": "text",
        }
        path = roles.ROLES_DIR / "r" / "chats" / "messages.json"
        path.parent.mkdir(parents=True, exist_ok=True)

        path.write_text(
            json.dumps({"messages": [{**base, "reasoning_content": "第一段思考"}]}),
            encoding="utf-8",
        )
        first = roles._build_chats_snapshot("http://a")

        path.write_text(
            json.dumps({"messages": [{**base, "reasoning_content": "完全不同的思考"}]}),
            encoding="utf-8",
        )
        snapshot_cache.clear()
        second = roles._build_chats_snapshot("http://a")

        self.assertEqual(first["md5"], second["md5"])
        self.assertEqual(
            first["md5"],
            hashlib.md5(
                json.dumps(
                    {"r": [canonical_chat_message(base)]},
                    ensure_ascii=False,
                    separators=(",", ":"),
                    sort_keys=True,
                ).encode()
            ).hexdigest(),
        )
        self.assertEqual(second["chats"]["r"][0]["reasoning_content"], "完全不同的思考")


class LifecycleReasoningDispatchTests(unittest.IsolatedAsyncioTestCase):
    """core/lifecycle.py 调度器分支必须把 metadata.reasoning_content 转存。"""

    async def _dispatch(self, event_type: str, result: AIResponse, context: dict):
        captured = {}

        async def fake_save_role_chat_message(chat_id, message):
            captured["message"] = message
            return {"success": True}

        with patch(
            "routers.ai_behavior.handle_ai_event",
            new=AsyncMock(return_value=result),
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
            handler = create_scheduler_event_handler(logging.getLogger("test"))
            await handler(
                {
                    "role_id": "role-1",
                    "event_type": event_type,
                    "content": "",
                    "context": context,
                }
            )
        return captured.get("message")

    async def test_proactive_branch_carries_reasoning_into_chat_message(self):
        message = await self._dispatch(
            "proactive",
            AIResponse(
                success=True,
                action="reply",
                content="主动问候",
                metadata={
                    "type": "proactive",
                    "request_id": "req_proactive",
                    "has_tool_calls": False,
                    "reasoning_content": "主动消息思考",
                },
            ),
            {"chat_id": "role-1"},
        )

        self.assertIsNotNone(message)
        self.assertEqual(message.reasoning_content, "主动消息思考")

    async def test_followup_branch_carries_reasoning_into_chat_message(self):
        message = await self._dispatch(
            "followup",
            AIResponse(
                success=True,
                action="reply",
                content="继续追问",
                metadata={
                    "type": "followup",
                    "request_id": "req_followup",
                    "reasoning_content": "续写思考",
                },
            ),
            {"chat_id": "role-1"},
        )

        self.assertIsNotNone(message)
        self.assertEqual(message.reasoning_content, "续写思考")

    async def test_task_branch_carries_reasoning_into_chat_message(self):
        message = await self._dispatch(
            "task",
            AIResponse(
                success=True,
                action="reply",
                content="任务回复",
                metadata={
                    "type": "task",
                    "task_id": "task-1",
                    "request_id": "req_task",
                    "reasoning_content": "任务思考",
                },
            ),
            {"chat_id": "role-1", "task_id": "task-1"},
        )

        self.assertIsNotNone(message)
        self.assertEqual(message.reasoning_content, "任务思考")


class RoleShowReasoningTests(unittest.IsolatedAsyncioTestCase):
    """show_reasoning 在角色创建/更新/列表/WS upsert 中的往返。"""

    def setUp(self):
        memory_service.close_all_connections()
        self.root = _make_temp_root()
        self._patchers = [
            patch.object(roles, "ROLES_DIR", self.root / "roles"),
            patch.object(memory_service, "load_memory", return_value={"core_memory": ""}),
            patch.object(memory_service, "save_memory"),
            patch.object(memory_service, "mirror_stored_cycle_state"),
            patch.object(memory_service, "sync_menstruation_cycle_state"),
            patch.object(memory_service, "_get_menstruation_status", return_value=None),
            patch.object(memory_service, "ROLES_DIR", self.root / "roles"),
        ]
        for patcher in self._patchers:
            patcher.start()

    def tearDown(self):
        for patcher in reversed(self._patchers):
            patcher.stop()
        memory_service.close_all_connections()
        shutil.rmtree(self.root, ignore_errors=True)

    async def test_create_role_defaults_show_reasoning_to_false(self):
        created = await roles.create_role(
            roles.RoleCreate(id="role-1", name="测试角色"), Mock()
        )

        self.assertIs(created["show_reasoning"], False)
        stored = roles.load_role("role-1")
        self.assertIs(stored["show_reasoning"], False)

        items = roles.build_role_items("http://backend")
        self.assertEqual(items[0]["show_reasoning"], False)

    async def test_create_role_persists_explicit_show_reasoning(self):
        await roles.create_role(
            roles.RoleCreate(
                id="role-1", name="测试角色", show_reasoning=True
            ),
            Mock(),
        )
        self.assertIs(roles.load_role("role-1")["show_reasoning"], True)

    async def test_update_role_persists_show_reasoning(self):
        await roles.create_role(
            roles.RoleCreate(id="role-1", name="测试角色"), Mock()
        )
        updated = await roles.update_role(
            "role-1", roles.RoleUpdate(show_reasoning=True), Mock()
        )

        self.assertIs(updated["show_reasoning"], True)
        self.assertIs(roles.load_role("role-1")["show_reasoning"], True)

    async def test_websocket_upsert_returns_and_persists_show_reasoning(self):
        with patch("services.scheduler_service.schedule_proactive_for_role"):
            created = await ws_dispatcher._handle_roles_upsert(
                {"role": {"id": "role-ws", "name": "WS 角色"}},
                "http://backend",
            )
            self.assertIs(created["show_reasoning"], False)

            updated = await ws_dispatcher._handle_roles_upsert(
                {
                    "role": {
                        "id": "role-ws",
                        "name": "WS 角色",
                        "show_reasoning": True,
                    }
                },
                "http://backend",
            )
            self.assertIs(updated["show_reasoning"], True)

        self.assertIs(roles.load_role("role-ws")["show_reasoning"], True)

    async def test_role_list_defaults_show_reasoning_for_legacy_profile(self):
        role_dir = roles.ROLES_DIR / "role-old"
        role_dir.mkdir(parents=True, exist_ok=True)
        (role_dir / "profile.json").write_text(
            json.dumps({"id": "role-old", "name": "旧角色"}),
            encoding="utf-8",
        )

        items = roles.build_role_items("http://backend")

        self.assertEqual(items[0]["show_reasoning"], False)


if __name__ == "__main__":
    unittest.main()

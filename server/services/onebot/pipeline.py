"""OneBot 入站编排：解析 → 去重 → 放行 → 指令 → 聚合 → AI → 出站 → 同步 App。"""
from __future__ import annotations

import logging
import uuid
from dataclasses import dataclass
from typing import Any, Dict, List, Optional

from services.onebot import commands, config as cfg_mod, media, message_log, mirror, policy
from services.onebot.aggregator import MessageAggregator, MessageDeduper
from services.onebot.models import Inbound, OneBotEvent
from services.onebot.parser import transform_event
from services.onebot.reply_plan import ReplyPlan, build_plan
from services.onebot.sender import deliver_plan, send_plain

logger = logging.getLogger(__name__)


@dataclass
class IngestResult:
    status: str  # "ok" | "ignored" | "queued" | "command"
    reason: str = ""
    reply: str = ""


def merge_batch(batch: List[Inbound]) -> Dict[str, Any]:
    """同一发送者的一批消息合并为一次 AI 输入（与 App 一样用换行连接）。"""
    texts = [item.content for item in batch if item.content.strip()]
    urls: List[str] = []
    for item in batch:
        for url in item.image_urls:
            if url not in urls:
                urls.append(url)
    return {"content": "\n".join(texts), "image_urls": urls}


class OneBotPipeline:
    def __init__(self) -> None:
        self.deduper = MessageDeduper()
        self.aggregator = MessageAggregator(self._process_batch)

    async def shutdown(self) -> None:
        await self.aggregator.shutdown()

    async def ingest(
        self,
        role_id: str,
        config: Dict[str, Any],
        event: OneBotEvent,
        conn,
        *,
        server_url: str = "",
        sync: bool = False,
    ) -> IngestResult:
        """处理一个事件。sync=True（HTTP）跳过聚合，直接处理并返回回复文本。"""
        inbound = transform_event(
            event, role_id=role_id, config=config, server_url=config.get("server_url") or server_url
        )
        if inbound is None:
            return IngestResult("ignored", "非消息事件或内容为空")
        if self.deduper.seen(role_id, inbound.message_id):
            return IngestResult("ignored", "重复消息")

        # 先记入额外消息库（只保留 3 天），再走放行：群里没 @ 机器人的发言也要留给 QQ 消息回顾。
        await message_log.arun(message_log.record_inbound, inbound, config, event.time)

        reject = policy.gate(inbound, config)
        if reject:
            logger.debug("OneBot 忽略: role=%s %s", role_id, reject)
            return IngestResult("ignored", reject)

        reply = commands.run_command(role_id, inbound)
        if reply is not None:
            if conn is not None:
                await send_plain(conn, role_id, inbound.target, reply, quote_id=inbound.message_id)
            return IngestResult("command", reply=reply)

        reject = policy.check_disabled_or_blocked(inbound, config)
        if reject:
            return IngestResult("ignored", reject)

        logger.info(
            "OneBot 消息接收: role=%s origin=%s user=%s sender=%s content=%s",
            role_id, inbound.origin, inbound.user_id, inbound.sender, inbound.content[:80],
        )

        if sync or conn is None:
            plan = await self._process_batch([inbound], conn)
            return IngestResult("ok", reply=plan.text())

        self.aggregator.submit(inbound, conn, cfg_mod.wait_seconds(config))
        return IngestResult("queued")

    async def _process_batch(self, batch: List[Inbound], conn) -> ReplyPlan:
        from routers.ai_behavior import AIEvent, AIEventType, handle_ai_event

        first, last = batch[0], batch[-1]
        role_id = first.role_id
        # 聚合等待期间可能刚好进入静默时间：此时丢弃这批消息，不调用模型也不回复
        quiet = policy.check_provider_quiet(role_id)
        if quiet:
            logger.info("OneBot 丢弃 %d 条消息: role=%s %s", len(batch), role_id, quiet)
            return ReplyPlan()
        merged = merge_batch(batch)
        mirrored = mirror.should_mirror(first)

        upload_ids = await media.stage_images(merged["image_urls"])
        if mirrored:
            await mirror.mirror_user(role_id, merged["content"])

        request_id = (
            f"qq_{last.message_id}_{last.user_id}" if last.message_id is not None
            else f"qq_{uuid.uuid4().hex}"
        )
        context: Dict[str, Any] = {
            "origin": first.origin,
            "sender": first.sender,
            "sender_id": str(first.user_id or ""),
            "sender_name": first.sender_name,
            "chat_name": first.chat_name,
            "request_id": request_id,
            "onebot_user_id": first.user_id,
            "onebot_group_id": first.group_id,
        }
        if upload_ids:
            context["vision_upload_ids"] = upload_ids

        result = await handle_ai_event(
            AIEvent(role_id=role_id, event_type=AIEventType.CHAT, content=merged["content"], context=context)
        )
        data = result.model_dump() if hasattr(result, "model_dump") else (result if isinstance(result, dict) else {})
        if not data.get("success"):
            logger.warning("OneBot AI 处理未成功: role=%s error=%s", role_id, data.get("error"))
            return ReplyPlan()

        metadata = data.get("metadata") or {}
        plan = build_plan(data.get("content") or "", metadata)
        if plan.empty:
            return plan
        if conn is None:
            # HTTP 无反向 WS：只返回文本，不做延迟发送；主用户私聊仍把回复同步进 App 历史
            for item in plan.items:
                await message_log.arun(message_log.record_outgoing, role_id, last.target, item)
            if mirrored:
                for item in plan.items:
                    if item.kind == "text":
                        await mirror.mirror_item(role_id, item, None, metadata)
            return plan

        async def _on_delivered(item, path):
            await message_log.arun(message_log.record_outgoing, role_id, last.target, item)
            if mirrored:
                await mirror.mirror_item(role_id, item, path, metadata)

        await deliver_plan(
            conn, role_id, last.target, plan,
            quote_id=last.message_id if last.is_group else None,
            server_url=first.server_url,
            on_delivered=_on_delivered,
        )
        return plan


pipeline = OneBotPipeline()

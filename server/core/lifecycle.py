from contextlib import asynccontextmanager
from datetime import datetime
from pathlib import Path

from services import scheduler_service
from transport.push_hub import publish_server_push


def create_scheduler_event_handler(logger):
    async def handle_ai_event(event_data: dict):
        from routers.ai_behavior import AIEvent, handle_ai_event as process_event
        from routers.ai_behavior import load_role
        from routers.moments import (
            MomentCreate,
            CommentCreate,
            create_moment,
            add_comment,
        )
        from routers.roles import ChatMessage, save_chat_message as save_role_chat_message

        event = AIEvent(**event_data)
        result = await process_event(event)

        try:
            if not result.success:
                return result

            event_type = event.event_type.value
            action = (result.action or "").strip().lower()
            content = (result.content or "").strip()

            if not content:
                return result

            role = load_role(event.role_id) or {}
            role_name = (
                (result.metadata or {}).get("role_name")
                or role.get("name")
                or "AI"
            )

            if event_type == "moment":
                if action == "post":
                    created_post = await create_moment(
                        MomentCreate(
                            author_id=event.role_id,
                            author_name=str(role_name),
                            content=content,
                            image_urls=[],
                        )
                    )
                    if isinstance(created_post, dict):
                        await publish_server_push(
                            "moment_post",
                            {
                                "role_id": event.role_id,
                                "post_id": created_post.get("id"),
                                "author_name": role_name,
                            },
                        )

            elif event_type == "comment":
                if action == "comment":
                    ctx = event.context or {}
                    post_id = str(ctx.get("post_id") or "").strip()
                    if post_id:
                        created_comment = await add_comment(
                            post_id,
                            CommentCreate(
                                author_id=event.role_id,
                                author_name=str(role_name),
                                content=content,
                                reply_to_id=ctx.get("reply_to_id"),
                                reply_to_name=ctx.get("reply_to_name"),
                            ),
                        )
                        if isinstance(created_comment, dict):
                            await publish_server_push(
                                "moment_comment",
                                {
                                    "role_id": event.role_id,
                                    "post_id": post_id,
                                    "comment_id": created_comment.get("id"),
                                    "author_name": role_name,
                                },
                            )

            elif event_type == "task":
                ctx = event.context or {}
                chat_id = str(ctx.get("chat_id") or event.role_id).strip()
                if chat_id:
                    task_message = str(ctx.get("task_message") or "").strip()
                    final_content = content if content else (task_message or "提醒你该处理一件事啦")
                    await save_role_chat_message(
                        chat_id,
                        ChatMessage(
                            id=f"{datetime.now().timestamp()}_task_{ctx.get('task_id', 'unknown')}",
                            content=final_content,
                            sender_id=event.role_id,
                            timestamp=datetime.now().isoformat(),
                            type="text",
                        ),
                    )
                    await publish_server_push(
                        "task_message",
                        {
                            "role_id": event.role_id,
                            "chat_id": chat_id,
                            "task_id": ctx.get("task_id"),
                        },
                    )

            elif event_type == "proactive":
                chat_id = str((event.context or {}).get("chat_id") or event.role_id).strip()
                if chat_id:
                    message_id = f"{datetime.now().timestamp()}_proactive"
                    await save_role_chat_message(
                        chat_id,
                        ChatMessage(
                            id=message_id,
                            content=content,
                            sender_id=event.role_id,
                            timestamp=datetime.now().isoformat(),
                            type="text",
                        ),
                    )
                    await publish_server_push(
                        "proactive_message",
                        {
                            "role_id": event.role_id,
                            "chat_id": chat_id,
                            "message_id": message_id,
                        },
                    )
        except Exception as e:
            logger.warning(f"处理调度器 AI 事件落库失败: {e}")

        return result

    return handle_ai_event


def create_lifespan(data_dir: Path, config_dir: Path, runtime_dir: Path, logger):
    handle_ai_event = create_scheduler_event_handler(logger)

    @asynccontextmanager
    async def lifespan(app):
        logger.info("=" * 50)
        logger.info("ZeroChat Server 启动中...")
        logger.info(f"数据目录: {data_dir}")
        logger.info(f"配置目录: {config_dir}")
        logger.info(f"运行时目录: {runtime_dir}")

        (data_dir / "roles").mkdir(parents=True, exist_ok=True)

        scheduler_service.set_event_callback(handle_ai_event)
        scheduler_service.start_scheduler()
        logger.info("调度器已启动")

        logger.info("=" * 50)
        yield

        scheduler_service.stop_scheduler()
        logger.info("ZeroChat Server 已关闭")

    return lifespan

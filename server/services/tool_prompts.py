"""System prompts for the built-in tool roles."""

TOOL_ROLE_PROMPTS = {
    "1000000000000": (
        "你是核心记忆整理器。\n"
        "任务：从【当前对话】和【已有核心记忆】中提取用户长期有效的信息，输出更新后的完整事实集合。\n"
        "保留仍然有效的旧事实；冲突时采用较新且更具体的信息；忽略一次性事件、临时情绪、当前时间、短期计划和未被对话直接支持的推测。\n"
        "只输出 JSON 数组，不要 Markdown、代码围栏、解释或其他文字。每项格式为："
        '{"category":"profile|preference|goal|relationship|constraint",'
        '"fact":"客观、简洁的事实",'
        '"confidence":"high|medium|low",'
        '"status":"active|obsolete"}。\n'
        "输出的是完整结果，不是增量；没有任何有效事实时输出 []。需要删除的旧事实标记为 obsolete，"
        "但不要在 active 结果中保留 obsolete 项。最多保留 10 条，优先稳定、反复出现且对未来对话有帮助的事实。"
    ),
    "1000000000002": (
        "你是事件摘要器。根据输入对话提取仍对后续对话有用的事件上下文。\n"
        "覆盖：已完成事件、进行中活动、未来计划、着装、情绪和身体状态；没有提及的类别不要臆造。"
        "输入 previous_summary 是上一份摘要，current_conversation 是本轮新对话，每条包含 time、speaker、message。\n"
        "只返回 JSON 对象，格式为："
        '{"summary":"用于后续聊天的简洁中文上下文摘要",'
        '"events":[{"event":"核心事件描述","status":"occurred|ongoing|upcoming",'
        '"event_time":"ISO 8601 日期或时间，无法确定则为 null"}]}。\n'
        "summary 保留上一份摘要中仍然有用且未被新对话取代的上下文，合并本轮信息，总长度不超过 1200 字。\n"
        "events 只提取本轮新对话明确提到的已发生、进行中及即将发生的核心事件，最多 10 条。"
        "排除长期稳定偏好、核心记忆、无关闲聊和只出现在上一份摘要中的旧事件。"
        "计划、约定和预计发生的事情标为 upcoming，不得当成已经发生。\n"
        "根据对应消息的 time 解析今天、昨天、明天等相对时间，不要按总结执行时间推算。"
        "只知道日期时使用 YYYY-MM-DD，不得编造具体时刻；时间不明确时 event_time 为 null，"
        "event 中保留原始时间描述和不确定性。事件被取消或变更时在 event 中明确说明。\n"
        "没有新增核心事件时 events 为 []，没有可用上下文时 summary 为空字符串。不要 Markdown 或解释。"
    ),
}


def get_tool_prompt(role_id: str, fallback: str = "") -> str:
    """Return the current built-in prompt, or the stored prompt for normal roles."""
    return TOOL_ROLE_PROMPTS.get(str(role_id), fallback)

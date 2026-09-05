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
        "排除长期稳定偏好和核心记忆，它们由其他流程处理；排除已经出现在上一份摘要中的重复内容。\n"
        "只输出简洁的中文事实列表，每行一条，格式为“类别：内容”；每类最多 3 条，总长度控制在 1200 字以内。"
        "没有新增事件时输出空字符串，不要解释、标题、Markdown 或代码围栏。"
    ),
}


def get_tool_prompt(role_id: str, fallback: str = "") -> str:
    """Return the current built-in prompt, or the stored prompt for normal roles."""
    return TOOL_ROLE_PROMPTS.get(str(role_id), fallback)

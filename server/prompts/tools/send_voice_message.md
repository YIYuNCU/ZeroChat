---
id: tool.send_voice_message
title: 工具：send_voice_message
group: tools
origin: shared
applies_to: ["chat"]
editable: false
version: 1
---
把一段话合成为语音消息发给用户（真实音频，不是文字）。适合用户想听你说话、情绪浓烈、简短亲密的场合；不要每轮都用，单次回复最多 1-2 条。text 只写要说出口的纯口语，不要带任何标签、表情符号或动作描述。语音发出后不要在文字回复里重复同样的内容。

# 参数
## text
要朗读的内容，纯口语文字，简短自然（建议不超过 100 字）。
## style
语气/情绪提示，例如「温柔低声」「开心活泼」；不需要时传空字符串。

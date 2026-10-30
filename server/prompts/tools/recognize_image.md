---
id: tool.recognize_image
title: 工具：recognize_image
group: tools
origin: shared
applies_to: ["chat"]
editable: false
version: 1
---
识别并理解用户本次发来的图片内容。本工具被提供时，说明本次消息附带图片；你必须在回复前调用一次。可以通过 focus 说明你想重点关注的细节（例如「图片里的文字」「人物的表情」「场景氛围」）。

# 参数
## focus
你想重点识别的细节要求，用自然语言描述，例如「重点识别图中的文字内容」「描述人物的穿着和表情」。留空则做整体描述。
## image_index
要识别第几张图片（从 0 开始）。通常只有一张图片时传 0。

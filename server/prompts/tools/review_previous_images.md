---
id: tool.review_previous_images
title: 工具：review_previous_images
group: tools
origin: shared
applies_to: ["chat"]
editable: false
version: 1
---
重新获取用户在同一会话上一批发送的原始图片，并使用本次提供的新提示词重新进行视觉识别。用户提及刚才、上一张、之前那几张图片，且需要重新确认或以不同问题识别图片时调用。不能用于查看其他会话或更早批次的图片。

# 参数
## prompt
用于本次重新识图的完整提示词，明确说明需要从图片中识别什么；不使用之前的识图结果。
## image_index
上一批图片中的索引，从 0 开始。

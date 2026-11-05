---
id: tool.block_user
title: 工具：block_user
group: tools
origin: shared
applies_to: ["chat"]
editable: false
version: 2
---
屏蔽某个 QQ 用户：此后在所有群聊和私聊里都不再处理 ta 的消息（主人可用 /unblock 解除）。亲密对象（sender 为 "user"）和你自己不能被屏蔽。当你觉得某个用户的行为令人不适、骚扰、刷屏、恶意攻击或伪装亲密对象时，需要调用此函数屏蔽该用户。不要因为正常的聊天分歧而屏蔽用户。

# 参数
## user_id
要屏蔽的用户 QQ 号，纯数字，取自消息里的 sender_id 或 sender 开头的数字
## reason
屏蔽原因（简短说明）

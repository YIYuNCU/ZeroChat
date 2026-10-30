---
id: tool.set_alarm
title: 工具：set_alarm
group: tools
origin: shared
applies_to: ["chat"]
editable: false
version: 1
---
在用户的设备上设置系统闹钟或写入日历事件。当用户明确要求「定个闹钟」「加到日历」「提醒我到点响铃」等需要落到手机系统的场景时调用。与 schedule_task（应用内提醒消息）不同，此工具作用于系统闹钟/日历；只有需要手机系统响铃或日历时才用它，普通聊天内提醒仍用 schedule_task。触发时间使用 ISO 8601 格式（24 小时制）。注意：这是向设备发起请求，用户可能拒绝权限，不保证一定成功。

# 参数
## title
闹钟或日历事件的标题，例如「吃药」「开会」「起床」
## trigger_time
触发时间，ISO 8601 格式（例如 2026-05-08T14:30:00），24 小时制。基于当前时间推算。
## kind
类型：alarm（系统闹钟，到点响铃）、calendar_event（日历事件）
## note
备注/说明，可留空字符串

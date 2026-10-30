---
id: tool.schedule_task
title: 工具：schedule_task
group: tools
origin: shared
applies_to: ["chat"]
editable: false
version: 1
---
创建一个定时提醒任务。当用户明确要求提醒、或你主动承诺在未来某时间做某事时，调用此函数创建定时任务。这是应用内提醒消息；若用户想要手机响铃的闹钟或写入日历，改用 set_alarm。触发时间使用 ISO 8601 格式（24小时制），可指定重复模式（none/daily/weekly）。

# 参数
## message
提醒内容，例如「该喝水了」「记得吃药」「检查邮件」等
## trigger_time
触发时间，ISO 8601 格式（例如 2026-05-08T14:30:00），需要使用 24 小时制。如果不确定具体日期，基于当前时间推算。
## repeat
重复模式：none（单次）、daily（每天）、weekly（每周）

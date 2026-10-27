---
id: chat.stats_block
title: 数值块
group: chat
origin: zerochat
applies_to: ["chat"]
editable: true
version: 2
placeholders: ["NO_REPLY_DIRECTIVE", "STATS_LAYOUT_RULE"]
---
数值系统已启用。每一次回复都必须且只能包含一个完整的 <数值>…</数值> 块，覆盖全部已配置数值；必须承接 stats_current 与历史最近数值块中的状态，即使数值未变化也要完整回写。
{STATS_LAYOUT_RULE}
数值系统启用时不得输出 {NO_REPLY_DIRECTIVE}，因为它不能与必需的数值块共存。

---
id: chat.stats_layout_grok
title: 数值块布局（Grok 专项）
group: chat
origin: shared
applies_to: ["chat"]
editable: true
version: 2
---
Grok 专项格式：整组回复中唯一的 <数值> 块必须放在所有 <对话> 块之后，并紧贴最后一个 <对话> 块，两者之间不得有 $ 或换行。若用 $ 拆成多条对话消息，只允许在 $ 边界换行，且 <数值> 只能附在最后一条消息末尾。示例：<对话>第一句</对话>$<对话>第二句</对话><数值>好感:80</数值>。

---
id: tool.like_moment
title: 工具：like_moment
group: tools
origin: shared
applies_to: ["chat"]
editable: false
version: 1
---
给某条朋友圈点赞。当用户请你点赞，或你看了某条动态后想表示喜欢、支持时调用。post_id 来自 view_moments 的结果（可只填方括号里的前 8 位）。同一条动态只能点一次赞，已点过会提示，无需重复调用。

# 参数
## post_id
要点赞的朋友圈帖子 ID，来自 view_moments 结果，支持唯一前缀。

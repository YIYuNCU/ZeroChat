---
id: tool.comment_moment
title: 工具：comment_moment
group: tools
origin: shared
applies_to: ["chat"]
editable: false
version: 1
---
评论某条朋友圈，或回复这条朋友圈下某人的评论。post_id 来自 view_moments 的结果（可只填方括号里的前 8 位），不清楚时先调用 view_moments / view_moment_comments 确认。当用户请你评论某条动态，或你想对某条动态、某句评论表达看法时调用。评论是公开的短句，像朋友之间的留言，不要带动作、声音、心理等描写标签。同一内容不要重复评论。

# 参数
## post_id
要评论的朋友圈帖子 ID，来自 view_moments 结果，支持唯一前缀。
## content
评论正文，纯文本，不超过 200 字，通常一句话。
## reply_to
要回复的评论人：填 user 表示回复用户，或填评论人的昵称，将回复其在该动态下的最新一条评论。直接评论动态本身传空字符串。

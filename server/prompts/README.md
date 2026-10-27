# server/prompts

内置系统提示词的唯一来源。每条提示词一个 `.md` 文件，由 `services/prompt_store.py` 在启动时加载并校验，
`services/prompt_config_service.py` 再叠加用户覆盖层（settings.json）后供业务使用。

## 文件格式

```
---
id: chat.format_protocol        # 全局唯一，覆盖层按它索引
title: 消息格式协议              # 设置页显示名
group: chat                     # chat | onebot | summary
origin: zerochat                # zerochat | onebot | shared
applies_to: ["chat"]            # JSON 数组：chat / summary
editable: true                  # false = 由代码维护，忽略所有覆盖
version: 2                      # 内置文案修改时递增；覆盖据此判断是否“基于旧版”
placeholders: ["NO_REPLY_DIRECTIVE"]   # 正文用到的 {NAME} 占位符，必须全部声明
---
正文模板
```

- front-matter 每行 `key: value`，value 先按 JSON 解析（数组、布尔、数字、带引号字符串），失败则当作原始字符串；
  `#` 之后的行内注释仅在不带引号的值中生效。未知键、缺少必填键、重复 id 都会导致启动失败。
- 正文不包含分段外层标签（如 `<output_protocol>`），外层标签由 `ai_service._build_system_prompt` 统一添加。
- 正文首尾的空行会被去掉。
- `{NAME}`（全大写）为占位符，由代码在渲染时替换；JSON 示例里的 `{"a": 1}` 不受影响。

## 升级内置文案

修改正文后必须把 `version` 加 1。已有的用户覆盖会因 `__base_version__` 落后而在设置页提示“基于旧版”。

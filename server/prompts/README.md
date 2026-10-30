# server/prompts

内置系统提示词的唯一来源。每条提示词一个 `.md` 文件，由 `services/prompt_store.py` 在启动时加载并校验，
`services/prompt_config_service.py` 再叠加用户覆盖层（settings.json）后供业务使用。

## 文件格式

```
---
id: chat.format_protocol        # 全局唯一，覆盖层按它索引
title: 消息格式协议              # 设置页显示名
group: chat                     # chat | onebot | summary | tools
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

## 工具提示词（`tools/`）

每个 function-calling 工具一个文件 `tools/<工具名>.md`，`id: tool.<工具名>`，`group: tools`，必须 `editable: false`
（随代码发布，不进入覆盖层和设置页）。正文分两段：第一段是工具 description；`# 参数` 之后每个参数一个 `## 参数名`
小节，写该参数的 description：

```
工具描述……

# 参数
## query
参数描述……
```

`ai_tools.py` 里只保留 schema 骨架（参数名、类型、枚举），通过 `tool_registry.build_tool("<工具名>", {...})` 合成完整定义
（strict、全部参数必填、description 排在最后）。提示词文件缺失、参数与骨架不一致或被声明为可编辑，都会在导入时直接报错。
修改工具文案后把该文件的 `version` 加 1。新增工具时同时新增 md 与 `build_tool` 调用（`tests/test_tool_registry.py`
会检查两边一一对应）。可选的表情包插件 `emoji_ivs_plugin.py` 自带工具定义，不走这里。

## 用户覆盖

设置页直接编辑对应 md 的全文，保存即整篇替换，没有追加或局部修改。覆盖只有两层（后者覆盖前者）：

1. 全局：`settings.json` 的 `prompt_overrides`；
2. 角色：`role.metadata.prompt_overrides`（仅 `applies_to` 含 `chat` 的提示词）。

形态为 `{id: {"__builtin__": 全文, "__base_version__": "N"}}`。旧的 `__append__`、相位键会在保存或启动迁移时折叠为 `__builtin__`；
按模型的 `model_prompt_overrides` 已停用，数据保留但不再生效。

## 升级内置文案

修改正文后必须把 `version` 加 1。已有的用户覆盖会因 `__base_version__` 落后而在设置页提示“基于旧版”。

### 不兼容升级：`onebot.system_directive` v3

v3 起 QQ 与 App 共用 `chat.format_protocol` 输出协议，指令里的 `<format_markers>`（旧式 `<>`/`//`/`[]`/`**` 标记）改为 `<delivery_rules>`
（只有 `<对话>` 会送达 QQ，`$` 分条）。旧版覆盖会让模型输出旧标记，因此 `__base_version__` 低于 3（或缺失）的覆盖在渲染时被忽略并记录警告
（`prompt_config_service.MIN_COMPATIBLE_BASE_VERSION`），需要在设置页基于新版重新编辑。

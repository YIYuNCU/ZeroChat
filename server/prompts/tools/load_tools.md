---
id: tool.load_tools
title: 工具：load_tools
group: tools
origin: shared
applies_to: ["chat"]
editable: false
version: 1
---
加载一组当前没有提供的工具。下面列出的工具组确实存在，只是暂未加载；当用户的需求需要其中的能力时，先调用本工具加载对应的组，加载成功后就能直接调用组内的工具，不必再询问用户。用不到时不要加载。当前可加载的工具组：

# 参数
## group
要加载的工具组名称，必须是上面列表中的一个。

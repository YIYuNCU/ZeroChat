import 'package:flutter/material.dart';

import '../models/summary_config.dart';

/// 直接编辑提示词（md）全文；空映射表示恢复默认，null 表示取消。
///
/// 初始文本为当前覆盖的 `__builtin__`，没有覆盖时为 `prompt.builtin`。保存时：
/// - 文本 trim 后为空，或与内置提示词（trim 后）相同 => 返回 `{}`（无覆盖）；
/// - 否则返回 `{__builtin__: 全文, __base_version__: 内置版本号}`。
Future<Map<String, String>?> showPromptEditor(
  BuildContext context, {
  required ConfigurablePrompt prompt,
  required Map<String, String> current,
  required String scopeLabel,
}) async {
  final text = TextEditingController(
    text: current[promptOverrideBuiltinKey] ?? prompt.builtin,
  );
  final stale = prompt.isOverrideStale(current);
  final route = DialogRoute<Map<String, String>>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('${prompt.title}（$scopeLabel）'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (stale)
                Container(
                  key: const ValueKey('prompt-editor-stale'),
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF4E5),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '内置提示词已更新，当前覆盖基于旧版',
                          style: TextStyle(
                            fontSize: 13,
                            color: Color(0xFFB26A00),
                          ),
                        ),
                      ),
                      TextButton(
                        key: const ValueKey('prompt-editor-load-latest'),
                        onPressed: () {
                          // 只替换文本框内容，不立即保存。
                          text.value = TextEditingValue(
                            text: prompt.builtin,
                            selection: TextSelection.collapsed(
                              offset: prompt.builtin.length,
                            ),
                          );
                        },
                        child: const Text('载入最新内置'),
                      ),
                    ],
                  ),
                ),
              TextField(
                key: const ValueKey('prompt-editor-text'),
                controller: text,
                maxLines: 16,
                minLines: 8,
                decoration: const InputDecoration(
                  labelText: '提示词全文',
                  alignLabelWithHint: true,
                  border: OutlineInputBorder(),
                  helperText:
                      '占位符（如 {NO_REPLY_DIRECTIVE}）由程序在运行时替换，请原样保留。',
                  helperMaxLines: 3,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, <String, String>{}),
          child: const Text('恢复默认'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.pop(context, buildPromptOverride(prompt, text.text)),
          child: const Text('保存'),
        ),
      ],
    ),
  );
  final result = await Navigator.of(context, rootNavigator: true).push(route);
  await route.completed;
  text.dispose();
  return result;
}

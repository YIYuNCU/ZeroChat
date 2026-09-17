import 'package:flutter/material.dart';

import '../models/summary_config.dart';

/// 编辑提示词；空映射表示恢复默认，null 表示取消。
Future<Map<String, String>?> showPromptEditor(
  BuildContext context, {
  required ConfigurablePrompt prompt,
  required Map<String, String> current,
  required String scopeLabel,
}) async {
  const builtinKey = '__builtin__';
  final template = TextEditingController(
    text: current[builtinKey] ?? prompt.builtin,
  );
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
              TextField(
                controller: template,
                maxLines: 16,
                minLines: 8,
                decoration: const InputDecoration(
                  labelText: '正文模板',
                  alignLabelWithHint: true,
                  border: OutlineInputBorder(),
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
          onPressed: () {
            final overrides = <String, String>{};
            final templateText = template.text;
            if (templateText != prompt.builtin) {
              overrides[builtinKey] = templateText;
            }
            Navigator.pop(context, overrides);
          },
          child: const Text('保存'),
        ),
      ],
    ),
  );
  final result = await Navigator.of(context, rootNavigator: true).push(route);
  await route.completed;
  template.dispose();
  return result;
}

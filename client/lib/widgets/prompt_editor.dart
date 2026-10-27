import 'package:flutter/material.dart';

import '../models/summary_config.dart';

enum _PromptEditMode { replace, append }

/// 编辑提示词；空映射表示恢复默认，null 表示取消。
///
/// 覆盖层内层只使用三个保留键：
/// - `__builtin__`：整体替换内置提示词；
/// - `__append__`：在生效文本后追加（可继续获得内置更新）；
/// - `__base_version__`：覆盖创建时基于的内置版本号（字符串形式的整数）。
Future<Map<String, String>?> showPromptEditor(
  BuildContext context, {
  required ConfigurablePrompt prompt,
  required Map<String, String> current,
  required String scopeLabel,
}) async {
  final template = TextEditingController(
    text: current[promptOverrideBuiltinKey] ?? prompt.builtin,
  );
  final append = TextEditingController(
    text: current[promptOverrideAppendKey] ?? '',
  );
  final stale = prompt.isOverrideStale(current);
  var mode = current.containsKey(promptOverrideAppendKey)
      ? _PromptEditMode.append
      : _PromptEditMode.replace;
  final route = DialogRoute<Map<String, String>>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
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
                    width: double.infinity,
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF4E5),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text(
                      '内置提示词已更新，当前覆盖基于旧版',
                      style: TextStyle(fontSize: 13, color: Color(0xFFB26A00)),
                    ),
                  ),
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<_PromptEditMode>(
                    segments: const [
                      ButtonSegment(
                        value: _PromptEditMode.replace,
                        label: Text('替换'),
                      ),
                      ButtonSegment(
                        value: _PromptEditMode.append,
                        label: Text('追加'),
                      ),
                    ],
                    selected: {mode},
                    showSelectedIcon: false,
                    onSelectionChanged: (selection) =>
                        setState(() => mode = selection.first),
                  ),
                ),
                const SizedBox(height: 12),
                if (mode == _PromptEditMode.replace)
                  TextField(
                    key: const ValueKey('prompt-editor-replace'),
                    controller: template,
                    maxLines: 16,
                    minLines: 8,
                    decoration: const InputDecoration(
                      labelText: '正文模板',
                      alignLabelWithHint: true,
                      border: OutlineInputBorder(),
                    ),
                  )
                else ...[
                  TextField(
                    key: const ValueKey('prompt-editor-append'),
                    controller: append,
                    maxLines: 16,
                    minLines: 8,
                    decoration: const InputDecoration(
                      labelText: '追加内容',
                      alignLabelWithHint: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '追加在内置提示词之后，可继续获得内置更新',
                    style: TextStyle(fontSize: 12, color: Color(0xFF888888)),
                  ),
                ],
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
              if (mode == _PromptEditMode.replace) {
                final templateText = template.text;
                if (templateText != prompt.builtin) {
                  overrides[promptOverrideBuiltinKey] = templateText;
                }
              } else {
                final appendText = append.text;
                if (appendText.trim().isNotEmpty) {
                  overrides[promptOverrideAppendKey] = appendText;
                }
              }
              if (overrides.isNotEmpty) {
                overrides[promptOverrideBaseVersionKey] = prompt.version
                    .toString();
              }
              Navigator.pop(context, overrides);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    ),
  );
  final result = await Navigator.of(context, rootNavigator: true).push(route);
  await route.completed;
  template.dispose();
  append.dispose();
  return result;
}

import 'package:flutter/material.dart';

import '../models/proactive_config.dart';

/// 打开安静时间编辑器（支持每天 / 每周自选星期 / 指定日期一次）。
/// 返回 null 表示取消；返回非 null 为编辑后的规则列表。
Future<List<QuietRule>?> showQuietRuleEditor(
  BuildContext context, {
  required List<QuietRule> initialRules,
}) async {
  var rules = List<QuietRule>.from(initialRules);

  return showDialog<List<QuietRule>>(
    context: context,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (dialogContext, setState) {
          void removeRule(int index) {
            setState(() => rules = [...rules]..removeAt(index));
          }

          Future<void> addRule() async {
            final edited = await _showRuleEditorDialog(
              dialogContext,
              draft: const QuietRule(startMinute: 23 * 60, endMinute: 7 * 60),
            );
            if (edited == null) return;
            setState(() => rules = [...rules, edited]);
          }

          Future<void> editRule(int index) async {
            final edited = await _showRuleEditorDialog(
              dialogContext,
              draft: rules[index],
            );
            if (edited == null) return;
            setState(() => rules = [...rules]..[index] = edited);
          }

          return AlertDialog(
            title: const Text('安静时间'),
            content: SizedBox(
              width: double.maxFinite,
              child: rules.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Text(
                        '暂无规则，点击“新增规则”添加',
                        textAlign: TextAlign.center,
                      ),
                    )
                  : ListView.separated(
                      shrinkWrap: true,
                      itemCount: rules.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final rule = rules[index];
                        return ListTile(
                          dense: true,
                          title: Text(rule.label),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.edit_outlined),
                                tooltip: '编辑',
                                onPressed: () => editRule(index),
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete_outline),
                                tooltip: '删除',
                                onPressed: () => removeRule(index),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(null),
                child: const Text('取消'),
              ),
              TextButton.icon(
                onPressed: addRule,
                icon: const Icon(Icons.add),
                label: const Text('新增规则'),
              ),
              FilledButton(
                onPressed: () {
                  final error = validateQuietRules(rules);
                  if (error != null) {
                    ScaffoldMessenger.of(dialogContext).showSnackBar(
                      SnackBar(content: Text(error)),
                    );
                    return;
                  }
                  Navigator.of(dialogContext).pop(rules);
                },
                child: const Text('确定'),
              ),
            ],
          );
        },
      );
    },
  );
}

/// 单条规则的编辑对话框。
/// 返回 null 表示放弃修改；返回非 null 为保存后的规则。
Future<QuietRule?> _showRuleEditorDialog(
  BuildContext context, {
  required QuietRule draft,
}) async {
  var startMinute = draft.startMinute;
  var endMinute = draft.endMinute;
  var repeatType = draft.repeatType;
  var weekdays = List<int>.from(draft.weekdays);
  var date = draft.date;

  return showDialog<QuietRule>(
    context: context,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (dialogContext, setState) {
          String? error;

          Future<void> pickStart() async {
            final picked = await showTimePicker(
              context: dialogContext,
              initialTime: TimeOfDay(
                hour: startMinute ~/ 60,
                minute: startMinute % 60,
              ),
            );
            if (picked != null) {
              setState(() => startMinute = picked.hour * 60 + picked.minute);
            }
          }

          Future<void> pickEnd() async {
            final picked = await showTimePicker(
              context: dialogContext,
              initialTime: TimeOfDay(
                hour: endMinute ~/ 60,
                minute: endMinute % 60,
              ),
            );
            if (picked != null) {
              setState(() => endMinute = picked.hour * 60 + picked.minute);
            }
          }

          Future<void> pickDate() async {
            final parsed = DateTime.tryParse(date ?? '');
            final initial =
                parsed ?? DateTime.now().add(const Duration(days: 1));
            final picked = await showDatePicker(
              context: dialogContext,
              initialDate: initial,
              firstDate: DateTime.now().subtract(const Duration(days: 3650)),
              lastDate: DateTime.now().add(const Duration(days: 3650)),
            );
            if (picked != null) {
              setState(() {
                date = '${picked.year.toString().padLeft(4, '0')}-'
                    '${picked.month.toString().padLeft(2, '0')}-'
                    '${picked.day.toString().padLeft(2, '0')}';
              });
            }
          }

          final candidate = QuietRule(
            startMinute: startMinute,
            endMinute: endMinute,
            repeatType: repeatType,
            weekdays: weekdays,
            date: date,
          );

          return AlertDialog(
            title: const Text('编辑安静时间'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(
                        value: QuietRule.repeatDaily,
                        label: Text('每天'),
                      ),
                      ButtonSegment(
                        value: QuietRule.repeatWeekly,
                        label: Text('每周'),
                      ),
                      ButtonSegment(
                        value: QuietRule.repeatOnce,
                        label: Text('指定日期'),
                      ),
                    ],
                    selected: {repeatType},
                    onSelectionChanged: (selection) {
                      setState(() {
                        repeatType = selection.first;
                        if (repeatType != QuietRule.repeatWeekly) {
                          weekdays = [];
                        }
                        if (repeatType != QuietRule.repeatOnce) {
                          date = null;
                        }
                      });
                    },
                  ),
                  const SizedBox(height: 12),
                  if (repeatType == QuietRule.repeatWeekly) ...[
                    Wrap(
                      spacing: 4,
                      children: [
                        for (var day = 1; day <= 7; day++)
                          FilterChip(
                            label: Text(kWeekdayNames[day - 1]),
                            selected: weekdays.contains(day),
                            onSelected: (selected) {
                              setState(() {
                                if (selected) {
                                  if (!weekdays.contains(day)) {
                                    weekdays.add(day);
                                  }
                                } else {
                                  weekdays.remove(day);
                                }
                              });
                            },
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (repeatType == QuietRule.repeatOnce) ...[
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(date ?? '未选择日期'),
                      trailing: const Icon(Icons.calendar_today),
                      onTap: pickDate,
                    ),
                    const SizedBox(height: 4),
                  ],
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title:
                        Text('开始：${QuietRule.formatMinute(startMinute)}'),
                    trailing: const Icon(Icons.schedule),
                    onTap: pickStart,
                  ),
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text('结束：${QuietRule.formatMinute(endMinute)}'),
                    trailing: const Icon(Icons.schedule),
                    onTap: pickEnd,
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(dialogContext).colorScheme.error,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () {
                  final validation = validateQuietRules([candidate]);
                  if (validation != null) {
                    setState(() => error = validation);
                    return;
                  }
                  Navigator.of(dialogContext).pop(candidate);
                },
                child: const Text('保存'),
              ),
            ],
          );
        },
      );
    },
  );
}
import 'package:flutter/material.dart';

/// 设置页里的可折叠分组：一行标题（可带图标和折叠时的摘要），点击展开 / 收起内容。
///
/// 用来把很长的设置列表按主题收拢，页面默认只露出各组标题。设计约定：
/// - 组内的 [children] 沿用页面原有的行控件（ListTile / 自定义行 / Divider），
///   本组件只负责标题行、分隔线和折叠动画；
/// - 收起时内容仍保留在 widget 树里（`maintainState`），不会丢失输入框里
///   尚未保存的内容，也不会重置组内控件的局部状态；
/// - [subtitle] 适合放“当前值摘要”，让用户不展开也能看到关键状态；
/// - 同一页面里标题应唯一，展开状态按标题记在 [PageStorage] 里，重建页面不会丢。
class SettingsGroup extends StatelessWidget {
  final String title;

  /// 标题下方的一行摘要（收起时也可见），例如“已启用 · 每 30 分钟”。
  final String? subtitle;
  final IconData? icon;
  final bool initiallyExpanded;
  final ValueChanged<bool>? onExpansionChanged;
  final List<Widget> children;

  const SettingsGroup({
    super.key,
    required this.title,
    required this.children,
    this.subtitle,
    this.icon,
    this.initiallyExpanded = false,
    this.onExpansionChanged,
  });

  @override
  Widget build(BuildContext context) {
    final summary = subtitle?.trim() ?? '';
    return Material(
      color: Colors.white,
      child: Theme(
        // 去掉 ExpansionTile 自带的上下分割线，样式与页面其余分组保持一致。
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          key: PageStorageKey<String>('settings-group-$title'),
          initiallyExpanded: initiallyExpanded,
          maintainState: true,
          onExpansionChanged: onExpansionChanged,
          shape: const Border(),
          collapsedShape: const Border(),
          tilePadding: const EdgeInsets.symmetric(horizontal: 16),
          childrenPadding: EdgeInsets.zero,
          expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
          leading: icon == null
              ? null
              : Icon(icon, size: 22, color: const Color(0xFF555555)),
          title: Text(title, style: const TextStyle(fontSize: 16)),
          subtitle: summary.isEmpty
              ? null
              : Text(
                  summary,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF888888),
                  ),
                ),
          children: [
            const Divider(height: 1, indent: 16),
            // ExpansionTile 用自己的 PageStorageKey 保存“是否展开”(bool)，组内 TextField
            // 的内部 Scrollable 会按祖先 PageStorageKey 保存滚动位置(double)。两者标识
            // 相同会在“展开后才新出现输入框”时触发类型转换异常，所以给内容再套一层
            // 不同的 PageStorageKey，让两边的标识错开。
            KeyedSubtree(
              key: PageStorageKey<String>('settings-group-body-$title'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

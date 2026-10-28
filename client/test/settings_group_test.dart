import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zerochat/widgets/settings_group.dart';

Widget _host(Widget child) =>
    MaterialApp(home: Scaffold(body: ListView(children: [child])));

void main() {
  testWidgets('starts collapsed and expands on tap', (tester) async {
    await tester.pumpWidget(
      _host(
        const SettingsGroup(
          title: '高级',
          subtitle: '已启用',
          icon: Icons.tune,
          children: [ListTile(title: Text('内容行'))],
        ),
      ),
    );

    expect(find.text('高级'), findsOneWidget);
    expect(find.text('已启用'), findsOneWidget);
    expect(find.text('内容行'), findsNothing);

    await tester.tap(find.text('高级'));
    await tester.pumpAndSettle();
    expect(find.text('内容行'), findsOneWidget);

    await tester.tap(find.text('高级'));
    await tester.pumpAndSettle();
    expect(find.text('内容行'), findsNothing);
  });

  testWidgets('initiallyExpanded shows content right away', (tester) async {
    await tester.pumpWidget(
      _host(
        const SettingsGroup(
          title: '基本',
          initiallyExpanded: true,
          children: [ListTile(title: Text('名称'))],
        ),
      ),
    );
    expect(find.text('名称'), findsOneWidget);
  });

  testWidgets('keeps collapsed text input state', (tester) async {
    final controller = TextEditingController(text: '草稿');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _host(
        SettingsGroup(
          title: '输入',
          initiallyExpanded: true,
          children: [TextField(controller: controller)],
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), '修改后');

    await tester.tap(find.text('输入'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('输入'));
    await tester.pumpAndSettle();

    expect(controller.text, '修改后');
    expect(find.text('修改后'), findsOneWidget);
  });

  testWidgets('text field appearing after the group was toggled does not crash', (
    tester,
  ) async {
    final showField = ValueNotifier<bool>(false);
    addTearDown(showField.dispose);
    await tester.pumpWidget(
      _host(
        ValueListenableBuilder<bool>(
          valueListenable: showField,
          builder: (context, show, _) => SettingsGroup(
            title: '条件输入',
            children: [
              const ListTile(title: Text('固定行')),
              if (show) const TextField(key: ValueKey('late-field')),
            ],
          ),
        ),
      ),
    );

    // 先展开一次，让展开状态写入 PageStorage，再让输入框晚一步挂载。
    await tester.tap(find.text('条件输入'));
    await tester.pumpAndSettle();
    showField.value = true;
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('late-field')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reports expansion changes', (tester) async {
    final events = <bool>[];
    await tester.pumpWidget(
      _host(
        SettingsGroup(
          title: '回调',
          onExpansionChanged: events.add,
          children: const [SizedBox(height: 10)],
        ),
      ),
    );
    await tester.tap(find.text('回调'));
    await tester.pumpAndSettle();
    expect(events, [true]);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zerochat/models/group_chat.dart';
import 'package:zerochat/pages/group_settings_page.dart';
import 'package:zerochat/services/group_chat_service.dart';
import 'package:zerochat/services/storage_service.dart';

late GroupChat _group;

Future<void> _pumpPage(WidgetTester tester) async {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(home: GroupSettingsPage(groupId: _group.id)),
  );
  await tester.pumpAndSettle();
}

Future<void> _toggle(WidgetTester tester, String title) async {
  await tester.tap(find.text(title));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await StorageService.init();
    await GroupChatService.init();
    _group = await GroupChatService.createGroup(
      name: '测试群',
      memberIds: const [],
    );
  });

  testWidgets('keeps member, name and dissolve rows flat', (tester) async {
    await _pumpPage(tester);

    expect(find.text('群成员'), findsOneWidget);
    expect(find.text('群聊名称'), findsOneWidget);
    expect(find.text('测试群'), findsOneWidget);
    expect(find.text('解散群聊'), findsOneWidget);
  });

  testWidgets('shows collapsed group titles with summaries', (tester) async {
    await _pumpPage(tester);

    expect(find.text('聊天记录与记忆'), findsOneWidget);
    expect(find.text('防刷屏'), findsOneWidget);
    expect(find.text('AI 行为'), findsOneWidget);
    expect(find.text('0 条记录 · 0 条记忆'), findsOneWidget);
    expect(find.text('冷却 5 秒 · 每分钟最多 10 条'), findsOneWidget);
    expect(find.text('回复概率 60% · 互相回复开'), findsOneWidget);

    // 分组内的行默认不可见。
    expect(find.text('聊天记录'), findsNothing);
    expect(find.text('核心记忆总结轮数'), findsNothing);
    expect(find.text('核心记忆'), findsNothing);
    expect(find.text('AI 回复冷却'), findsNothing);
    expect(find.text('每分钟最大回复'), findsNothing);
    expect(find.text('AI 回复概率'), findsNothing);
    expect(find.text('AI 互相回复'), findsNothing);
    expect(find.text('连续发言上限'), findsNothing);
  });

  testWidgets('expanding 聊天记录与记忆 reveals its rows', (tester) async {
    await _pumpPage(tester);

    await _toggle(tester, '聊天记录与记忆');

    expect(find.text('聊天记录'), findsOneWidget);
    expect(find.text('核心记忆总结轮数'), findsOneWidget);
    expect(find.text('核心记忆'), findsOneWidget);
  });

  testWidgets('expanding 防刷屏 reveals its rows and dialog still works', (
    tester,
  ) async {
    await _pumpPage(tester);

    await _toggle(tester, '防刷屏');

    expect(find.text('AI 回复冷却'), findsOneWidget);
    expect(find.text('每分钟最大回复'), findsOneWidget);

    await tester.tap(find.text('AI 回复冷却'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.add_circle_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(GroupChatService.getGroup(_group.id)!.cooldownSeconds, 6);
    expect(find.text('冷却 6 秒 · 每分钟最多 10 条'), findsOneWidget);
  });

  testWidgets('expanding AI 行为 reveals its rows and toggle saves', (
    tester,
  ) async {
    await _pumpPage(tester);

    await _toggle(tester, 'AI 行为');

    expect(find.text('AI 回复概率'), findsOneWidget);
    expect(find.text('AI 互相回复'), findsOneWidget);
    expect(find.text('连续发言上限'), findsOneWidget);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(
      GroupChatService.getGroup(_group.id)!.allowAiToAiInteraction,
      isFalse,
    );
    expect(find.text('回复概率 60% · 互相回复关'), findsOneWidget);
  });
}

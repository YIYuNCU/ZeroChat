import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zerochat/pages/settings_page.dart';
import 'package:zerochat/services/settings_service.dart';
import 'package:zerochat/services/storage_service.dart';

Future<void> _pumpPage(WidgetTester tester) async {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
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
    final settings = SettingsService.instance;
    await settings.updateDisplaySettings(
      coverImageUrl: '',
      chatBackgroundUrl: '',
    );
    await settings.updateMessageWaitSeconds(0);
    await settings.updateBackgroundRuntimeEnabled(true);
    await settings.updateBackgroundPollIntervalSeconds(120);
  });

  testWidgets('shows group titles, only the first group is expanded', (
    tester,
  ) async {
    await _pumpPage(tester);

    expect(find.text('背景'), findsOneWidget);
    expect(find.text('消息发送'), findsOneWidget);
    expect(find.text('后台与保活'), findsOneWidget);

    // 背景组默认展开，其余收起。
    expect(find.text('朋友圈封面'), findsOneWidget);
    expect(find.text('聊天背景'), findsOneWidget);
    expect(find.text('输入停顿'), findsNothing);
    expect(find.text('后台轮询间隔'), findsNothing);
    expect(find.text('保活自检间隔'), findsNothing);
  });

  testWidgets('collapsed groups show a summary of current values', (
    tester,
  ) async {
    await _pumpPage(tester);

    expect(find.text('封面未设置 · 聊天背景未设置'), findsOneWidget);
    expect(find.text('输入停顿：立即发送'), findsOneWidget);
    expect(find.text('已开启 · 轮询 120 秒'), findsOneWidget);
  });

  testWidgets('expanding 消息发送 reveals the wait slider', (tester) async {
    await _pumpPage(tester);

    await _toggle(tester, '消息发送');

    expect(find.text('输入停顿'), findsOneWidget);
    expect(find.byType(Slider), findsOneWidget);
    expect(find.textContaining('输入停顿时间：发送消息后'), findsOneWidget);
  });

  testWidgets('expanding 后台与保活 reveals the runtime items', (tester) async {
    await _pumpPage(tester);

    await _toggle(tester, '后台与保活');

    expect(find.text('后台运行'), findsOneWidget);
    expect(find.text('后台轮询间隔'), findsOneWidget);
    expect(find.text('保活自检间隔'), findsOneWidget);
    expect(find.textContaining('开启后应用切到后台仍会保持运行'), findsOneWidget);
  });

  testWidgets('toggling background runtime still saves and updates summary', (
    tester,
  ) async {
    await _pumpPage(tester);
    await _toggle(tester, '后台与保活');

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(SettingsService.instance.backgroundRuntimeEnabled, isFalse);
    expect(find.text('已关闭'), findsOneWidget);
  });
}

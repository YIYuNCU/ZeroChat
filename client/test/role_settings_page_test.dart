import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zerochat/models/onebot_config.dart';
import 'package:zerochat/models/role.dart';
import 'package:zerochat/pages/role_settings_page.dart';
import 'package:zerochat/services/storage_service.dart';

/// 角色设置页按主题分组、默认只露出分组标题；收起的分组里的字段仍要参与保存。
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await StorageService.init();
  });

  Role buildRole() => Role(
    id: 'r1',
    name: '小明',
    systemPrompt: '补充设定原文',
    personaCard: const PersonaCard(identity: '一名程序员'),
    maxContextRounds: 42,
    maxContextLength: 8000,
    onebotConfig: const OneBotConfig(
      enabled: true,
      secret: 'secret-1',
      selfId: 10001,
      mainUserId: 20002,
    ),
  );

  /// 通过真实路由打开页面，这样点击「保存」返回的 Role 可以被读取。
  Future<Future<Role?> Function()> openPage(
    WidgetTester tester,
    Role role,
  ) async {
    tester.view.physicalSize = const Size(400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Future<Role?>? pending;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () {
                  pending = Navigator.push<Role>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => RoleSettingsPage(role: role),
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return () => pending!;
  }

  /// 展开 / 收起后页面可能很长，先把分组标题滚到可见再点击。
  Future<void> tapGroup(WidgetTester tester, String title) async {
    await tester.scrollUntilVisible(
      find.text(title),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.text(title));
    await tester.pumpAndSettle();
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
  }

  Finder textFieldLabeled(String label) => find.byWidgetPredicate(
    (widget) => widget is TextField && widget.decoration?.labelText == label,
  );

  const groupTitles = [
    '基本信息',
    '人设',
    '提示词',
    '语音',
    'AI 模型',
    '性别与周期',
    '上下文与搜索',
    'OneBot 接口',
    '消息显示',
    '数值系统',
    '状态管理',
  ];

  testWidgets('shows every group title but only the basic info content', (
    tester,
  ) async {
    await openPage(tester, buildRole());

    for (final title in groupTitles) {
      expect(find.text(title), findsOneWidget, reason: title);
    }
    // 基本信息默认展开。
    expect(find.text('角色名称'), findsOneWidget);
    // 其余分组的内容默认收起。
    expect(find.text('身份与背景'), findsNothing);
    expect(find.text('允许联网搜索'), findsNothing);
    expect(find.text('启用 OneBot 接口'), findsNothing);
    expect(find.text('显示动作'), findsNothing);
    expect(find.text('归档角色'), findsNothing);
    expect(find.byKey(const ValueKey('role-voice-enabled')), findsNothing);
    // 页面底部的重置按钮不属于任何分组。
    expect(find.text('重置为默认值'), findsOneWidget);
  });

  testWidgets('collapsed groups show a summary of their current values', (
    tester,
  ) async {
    await openPage(tester, buildRole());

    expect(find.text('已填 1/6 项 · 含补充设定'), findsOneWidget);
    expect(find.text('42 轮 · 8000 字符 · 联网搜索开'), findsOneWidget);
    expect(find.text('已启用'), findsOneWidget); // OneBot
    expect(find.text('已显示 4/7 项'), findsOneWidget);
    expect(find.text('未启用'), findsOneWidget); // 数值系统
    expect(find.text('正常'), findsOneWidget);
    expect(find.text('允许发送语音'), findsOneWidget); // 语音摘要
  });

  testWidgets('tapping a group title expands and collapses its content', (
    tester,
  ) async {
    await openPage(tester, buildRole());

    await tapGroup(tester, '消息显示');
    expect(find.text('显示动作'), findsOneWidget);
    expect(find.text('显示思维链'), findsOneWidget);

    await tapGroup(tester, '消息显示');
    expect(find.text('显示动作'), findsNothing);

    await tapGroup(tester, '人设');
    expect(textFieldLabeled('身份与背景'), findsOneWidget);
    expect(find.text('补充设定（自由文本）'), findsOneWidget);

    await tapGroup(tester, 'OneBot 接口');
    expect(find.text('启用 OneBot 接口'), findsOneWidget);
    expect(find.text('Secret'), findsOneWidget);
  });

  testWidgets('saving includes fields from groups that were never opened', (
    tester,
  ) async {
    final result = await openPage(tester, buildRole());

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    final saved = (await result())!;

    expect(saved.name, '小明');
    expect(saved.systemPrompt, '补充设定原文');
    expect(saved.personaCard.identity, '一名程序员');
    expect(saved.maxContextRounds, 42);
    expect(saved.maxContextLength, 8000);
    expect(saved.onebotConfig.enabled, isTrue);
    expect(saved.onebotConfig.secret, 'secret-1');
    expect(saved.onebotConfig.selfId, 10001);
    expect(saved.onebotConfig.mainUserId, 20002);
  });

  testWidgets('edits made in a group survive collapsing it before save', (
    tester,
  ) async {
    final result = await openPage(tester, buildRole());

    await tapGroup(tester, '人设');
    await tester.enterText(textFieldLabeled('身份与背景'), '改过的身份');
    await tester.pump();
    // 摘要随输入更新。
    expect(find.text('已填 1/6 项 · 含补充设定'), findsOneWidget);
    await tester.enterText(textFieldLabeled('说话方式'), '慢条斯理');
    await tester.pump();
    expect(find.text('已填 2/6 项 · 含补充设定'), findsOneWidget);

    await tapGroup(tester, '消息显示');
    // 展开的只有「消息显示」，第一个可见的开关就是「显示动作」。
    await tester.tap(find.byType(Switch).first);
    await tester.pump();

    // 收起两个分组后再保存。
    await tapGroup(tester, '人设');
    await tapGroup(tester, '消息显示');
    expect(textFieldLabeled('身份与背景'), findsNothing);
    expect(find.text('已显示 3/7 项'), findsOneWidget);

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    final saved = (await result())!;

    expect(saved.personaCard.identity, '改过的身份');
    expect(saved.personaCard.speakingStyle, '慢条斯理');
    expect(saved.showAction, isFalse);
    expect(saved.showPsychology, isTrue);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zerochat/models/summary_config.dart';
import 'package:zerochat/pages/api_settings_page.dart';
import 'package:zerochat/services/storage_service.dart';

/// 模型 / 总结 / 提示词设置页的折叠分组：默认只露出核心字段和分组标题，
/// 展开后才能看到次要字段。
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await StorageService.init();
  });

  Future<void> pumpModel(
    WidgetTester tester,
    ModelSettingsKind kind, {
    Size size = const Size(400, 1600),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(home: ModelSettingsPage(kind: kind)));
    await tester.pumpAndSettle();
  }

  Future<void> toggle(WidgetTester tester, String title) async {
    final finder = find.text(title);
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Finder effortDropdown() => find.byWidgetPredicate(
    (widget) =>
        widget is DropdownButtonFormField<String> &&
        widget.decoration.labelText == '思考强度',
  );

  group('ModelSettingsPage', () {
    testWidgets('chat keeps core fields flat and collapses the rest', (
      tester,
    ) async {
      await pumpModel(tester, ModelSettingsKind.chat);

      for (final label in ['API 地址', 'API Key', '模型', '获取模型列表', '测试当前配置']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      for (final title in ['思考与推理', '高级', '模型档案']) {
        expect(find.text(title), findsOneWidget, reason: title);
      }
      expect(find.text('协议格式'), findsNothing);
      expect(find.text('超时时间（秒）'), findsNothing);
      expect(find.text('使用流式传输'), findsNothing);
      expect(find.text('启用模型思考'), findsNothing);
      expect(effortDropdown(), findsNothing);
      expect(find.text('保存为模型档案'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('expanding a group reveals its fields', (tester) async {
      await pumpModel(tester, ModelSettingsKind.chat);

      await toggle(tester, '高级');
      expect(find.text('协议格式'), findsOneWidget);
      expect(find.text('超时时间（秒）'), findsOneWidget);
      expect(find.text('使用流式传输'), findsOneWidget);
      expect(effortDropdown(), findsNothing);

      await toggle(tester, '思考与推理');
      expect(find.text('启用模型思考'), findsOneWidget);
      expect(effortDropdown(), findsOneWidget);

      await toggle(tester, '模型档案');
      expect(find.text('保存为模型档案'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('budget field appearing after expansion does not throw', (
      tester,
    ) async {
      await pumpModel(tester, ModelSettingsKind.chat);

      await toggle(tester, '思考与推理');
      expect(find.widgetWithText(TextFormField, '思考预算（tokens）'), findsNothing);
      await tester.enterText(
        find.byType(TextField).first,
        'https://api.siliconflow.cn/v1',
      );
      await tester.pumpAndSettle();
      expect(
        find.widgetWithText(TextFormField, '思考预算（tokens）'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('typed values survive collapsing the group', (tester) async {
      await pumpModel(tester, ModelSettingsKind.chat);

      await toggle(tester, '高级');
      final timeout = find.widgetWithText(TextField, '60');
      expect(timeout, findsOneWidget);
      await tester.enterText(timeout, '123');
      await toggle(tester, '高级');
      expect(find.text('超时时间（秒）'), findsNothing);

      await toggle(tester, '高级');
      expect(find.widgetWithText(TextField, '123'), findsOneWidget);
    });

    testWidgets('embedding has no advanced or thinking groups', (tester) async {
      await pumpModel(tester, ModelSettingsKind.embedding);

      expect(find.text('高级'), findsNothing);
      expect(find.text('思考与推理'), findsNothing);
      expect(find.text('模型档案'), findsOneWidget);
      expect(find.text('获取模型列表'), findsOneWidget);
    });

    testWidgets('vision mode lives in the advanced group', (tester) async {
      await pumpModel(tester, ModelSettingsKind.vision);

      expect(find.text('启用视觉识别模型'), findsOneWidget);
      expect(find.text('运行模式'), findsNothing);
      await toggle(tester, '高级');
      expect(find.text('运行模式'), findsOneWidget);
      expect(find.text('协议格式'), findsOneWidget);
    });
  });

  group('SummaryModelSettingsPage', () {
    Future<void> pumpSummary(
      WidgetTester tester, {
      SummaryFeature feature = SummaryFeature.context,
    }) async {
      tester.view.physicalSize = const Size(600, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(home: SummaryModelSettingsPage(feature: feature)),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('chat recall page shows its title, hint and groups', (
      tester,
    ) async {
      await pumpSummary(tester, feature: SummaryFeature.chatRecall);

      expect(find.text('聊天回顾总结'), findsOneWidget);
      expect(
        find.textContaining('AI 按指定时间/事件查阅历史聊天时，用此模型总结相关内容'),
        findsOneWidget,
      );
      for (final title in ['模型档案', '高级参数', '系统提示词']) {
        expect(find.text(title), findsOneWidget, reason: title);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('shows core fields and collapsed groups', (tester) async {
      await pumpSummary(tester);

      expect(find.text('启用'), findsOneWidget);
      for (final label in ['API 地址', 'API Key', '模型']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      for (final title in ['模型档案', '高级参数', '系统提示词']) {
        expect(find.text(title), findsOneWidget, reason: title);
      }
      expect(find.text('温度'), findsNothing);
      expect(find.text('推理强度'), findsNothing);
      expect(find.text('附加系统提示词（可选）'), findsNothing);
      expect(find.text('把当前配置保存为模型档案'), findsNothing);

      await toggle(tester, '高级参数');
      expect(find.text('协议格式'), findsOneWidget);
      expect(find.text('温度'), findsOneWidget);
      expect(find.text('超时时间（秒）'), findsOneWidget);
      expect(find.text('推理强度'), findsOneWidget);
      expect(find.text('思考预算'), findsOneWidget);

      await toggle(tester, '系统提示词');
      expect(find.text('附加系统提示词（可选）'), findsOneWidget);

      await toggle(tester, '模型档案');
      expect(find.text('把当前配置保存为模型档案'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('PromptsPage', () {
    ConfigurablePrompt prompt(
      String id,
      String title, {
      String group = 'chat',
      List<String> appliesTo = const ['chat'],
    }) => ConfigurablePrompt(
      id: id,
      title: title,
      group: group,
      origin: group,
      appliesTo: appliesTo,
      builtin: 'builtin',
    );

    Future<void> pumpPrompts(WidgetTester tester) async {
      tester.view.physicalSize = const Size(600, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final registry = {
        for (final p in [
          prompt('chat.format_protocol', '消息格式协议'),
          prompt('chat.no_reply', '无回复指令'),
          prompt('chat.tool_rules', '工具调用规则'),
          prompt('chat.voice_rules', '语音消息工具规则'),
          prompt('chat.emoji_rule_default', '表情工具规则（内置）'),
          prompt('chat.stats_block', '数值块'),
          prompt('onebot.system_directive', 'QQ 系统级指令', group: 'onebot'),
          prompt(
            'summary.core_memory',
            '核心记忆总结提示词',
            group: 'summary',
            appliesTo: const ['summary'],
          ),
        ])
          p.id: p,
      };
      await tester.pumpWidget(
        MaterialApp(
          home: PromptsPage(
            loadRegistry: ({bool force = false}) async => registry,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('prompts are grouped by purpose and collapsed', (tester) async {
      await pumpPrompts(tester);

      for (final title in ['通用规则', '工具、语音与表情', '数值系统', 'QQ / OneBot']) {
        expect(find.text(title), findsOneWidget, reason: title);
      }
      expect(find.text('其他'), findsNothing);
      expect(find.text('3 项'), findsOneWidget);
      // 条目收在分组里；总结类提示词不属于此页。
      expect(find.text('消息格式协议'), findsNothing);
      expect(find.text('工具调用规则'), findsNothing);

      await toggle(tester, '工具、语音与表情');
      expect(find.text('工具调用规则'), findsOneWidget);
      expect(find.text('语音消息工具规则'), findsOneWidget);
      expect(find.text('表情工具规则（内置）'), findsOneWidget);
      expect(find.text('消息格式协议'), findsNothing);

      await toggle(tester, '通用规则');
      expect(find.text('消息格式协议'), findsOneWidget);
      expect(find.text('无回复指令'), findsOneWidget);
      expect(find.text('核心记忆总结提示词'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}

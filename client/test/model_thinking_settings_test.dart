import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zerochat/models/ai_model_profile.dart';
import 'package:zerochat/pages/api_settings_page.dart';
import 'package:zerochat/services/settings_service.dart';
import 'package:zerochat/services/storage_service.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await StorageService.init();
  });

  testWidgets('profile editor persists thinking switch, dropdown and budget', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await SettingsService.instance.saveApiProfile(
      const ModelApiProfile(
        id: 'thinking-ui',
        name: 'Thinking profile',
        apiUrl: 'https://api.siliconflow.cn/v1',
        model: 'Qwen/Qwen3',
        apiKey: '',
        capabilities: {ModelProfileCapability.chat},
        thinkingEnabled: true,
        thinkingBudget: 4096,
        reasoningEffort: 'low',
      ),
    );
    await tester.pumpWidget(const MaterialApp(home: ModelProfilesPage()));
    await tester.tap(find.byTooltip('编辑档案'));
    await tester.pumpAndSettle();
    final effort = find.byWidgetPredicate(
      (widget) =>
          widget is DropdownButtonFormField<String> &&
          widget.decoration.labelText == '思考强度',
    );
    await tester.ensureVisible(effort);
    await tester.tap(effort);
    await tester.pumpAndSettle();
    await tester.tap(find.text('高（high）').last);
    await tester.pumpAndSettle();
    final budget = find.widgetWithText(TextFormField, '思考预算（tokens）');
    await tester.ensureVisible(budget);
    await tester.enterText(budget, '8192');
    final toggle = find.widgetWithText(CheckboxListTile, '启用模型思考');
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(tester.widget<CheckboxListTile>(toggle).value, isFalse);
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    final saved = SettingsService.instance
        .modelProfilesFor(ModelProfileCapability.chat)
        .firstWhere((profile) => profile.id == 'thinking-ui');
    expect(saved.thinkingEnabled, isFalse);
    expect(saved.reasoningEffort, 'high');
    expect(saved.thinkingBudget, 8192);
    expect(tester.takeException(), isNull);
  });

  testWidgets('main model settings use dropdown and show budget by provider', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: ModelSettingsPage(kind: ModelSettingsKind.chat)),
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is DropdownButtonFormField<String> &&
            widget.decoration.labelText == '思考强度',
      ),
      findsOneWidget,
    );
    expect(find.widgetWithText(TextFormField, '思考预算（tokens）'), findsNothing);
    await tester.enterText(
      find.byType(TextField).first,
      'https://api.siliconflow.cn/v1',
    );
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextFormField, '思考预算（tokens）'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zerochat/models/ai_model_profile.dart';
import 'package:zerochat/pages/api_settings_page.dart';
import 'package:zerochat/services/settings_service.dart';
import 'package:zerochat/services/storage_service.dart';

/// 模型行必须在选择后立刻反映当前模型：
/// 修复前下拉框只在其它操作触发重建后才更新。
///
/// 模型列表由 `http.runWithClient` 注入的 MockClient 提供，
/// 生产代码里没有任何测试专用开关。
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await StorageService.init();
  });

  /// 在 MockClient 的 Zone 内执行 [body]，让页面内部的 http 请求拿到桩数据。
  Future<void> withModelList(Future<void> Function() body) {
    return http.runWithClient(
      body,
      () => MockClient(
        (request) async => http.Response(
          jsonEncode({
            'data': [
              {'id': 'model-a'},
              {'id': 'model-b'},
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );
  }

  Finder dropdownContaining(String value) => find.byWidgetPredicate(
    (widget) =>
        widget is DropdownButton<String> &&
        (widget.items ?? const <DropdownMenuItem<String>>[]).any(
          (item) => item.value == value,
        ),
  );

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const MaterialApp(home: ModelSettingsPage(kind: ModelSettingsKind.chat)),
    );
  }

  Future<void> loadModels(WidgetTester tester) async {
    await tester.enterText(
      find.byType(TextField).at(0),
      'https://api.siliconflow.cn/v1',
    );
    await tester.enterText(find.byType(TextField).at(1), 'sk-test');
    await tester.pump();
    final fetch = find.text('获取模型列表');
    await tester.ensureVisible(fetch);
    await tester.tap(fetch);
    await tester.pumpAndSettle();
  }

  testWidgets('选择模型后模型行立即显示新模型', (tester) async {
    await withModelList(() async {
      await pumpPage(tester);
      await loadModels(tester);

      final modelRow = dropdownContaining('model-a');
      expect(tester.widget<DropdownButton<String>>(modelRow).value, 'model-a');

      await tester.ensureVisible(modelRow);
      await tester.tap(modelRow);
      await tester.pumpAndSettle();
      await tester.tap(find.text('model-b').last);
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<DropdownButton<String>>(dropdownContaining('model-a'))
            .value,
        'model-b',
      );
      // 让“获取到 N 个模型”的 SnackBar 计时器结束。
      await tester.pump(const Duration(seconds: 5));
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('套用模型档案后模型行显示档案中的模型', (tester) async {
    await withModelList(() async {
      const profileId = 'dropdown-profile';
      await SettingsService.instance.saveApiProfile(
        const ModelApiProfile(
          id: profileId,
          name: 'Profile A',
          apiUrl: 'https://api.siliconflow.cn/v1',
          model: 'profile-model',
          apiKey: 'sk-test',
          capabilities: {ModelProfileCapability.chat},
        ),
      );
      await pumpPage(tester);
      await loadModels(tester);

      final profileRow = dropdownContaining(profileId);
      await tester.ensureVisible(profileRow);
      await tester.tap(profileRow);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Profile A').last);
      await tester.pumpAndSettle();

      // 档案模型不在拉取列表里，也必须显示为当前模型而不是提示文案。
      expect(
        tester
            .widget<DropdownButton<String>>(dropdownContaining('model-a'))
            .value,
        'profile-model',
      );
      await tester.pump(const Duration(seconds: 5));
      expect(tester.takeException(), isNull);
    });
  });
}

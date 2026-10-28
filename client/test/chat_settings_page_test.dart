import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zerochat/models/role.dart';
import 'package:zerochat/pages/chat_settings_page.dart';
import 'package:zerochat/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _host() {
  return MaterialApp(
    home: ChatSettingsPage(
      chatId: 'chat-settings-test',
      chatName: '测试聊天',
      currentRole: Role.defaultRole(),
    ),
  );
}

Future<void> _pumpPage(WidgetTester tester) async {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(_host());
  await tester.pump();
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await StorageService.init();
  });

  testWidgets('默认只显示分组标题，组内条目收起', (tester) async {
    await _pumpPage(tester);

    // 顶部 / 底部平铺的高频入口与危险操作
    expect(find.text('测试聊天'), findsOneWidget);
    expect(find.text('角色设置'), findsOneWidget);
    expect(find.text('表情管理'), findsOneWidget);
    expect(find.text('清空聊天记录'), findsOneWidget);

    // 分组标题
    for (final title in ['外观', '记忆', '主动消息与续写', '记录与数据']) {
      expect(find.text(title), findsOneWidget, reason: '缺少分组 $title');
    }

    // 组内条目默认不可见
    for (final item in [
      '聊天背景',
      '核心记忆',
      '短期记忆',
      '向量记忆',
      '主动消息',
      '安静时间',
      '无回复续写',
      '聊天记录',
      '外挂记录',
      '定时任务',
      'Token 用量',
    ]) {
      expect(find.text(item), findsNothing, reason: '$item 不应默认可见');
    }
  });

  testWidgets('展开分组后可见组内条目', (tester) async {
    await _pumpPage(tester);

    Future<void> expand(String title, List<String> items) async {
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
      for (final item in items) {
        expect(find.text(item), findsOneWidget, reason: '$title 展开后应显示 $item');
      }
    }

    await expand('外观', ['聊天背景']);
    await expand('记忆', ['核心记忆', '短期记忆', '向量记忆']);
    await expand('主动消息与续写', ['主动消息', '安静时间', '无回复续写']);
    await expand('记录与数据', ['聊天记录', '外挂记录', '定时任务', 'Token 用量']);
  });

  testWidgets('分组 subtitle 显示当前关键值', (tester) async {
    await _pumpPage(tester);

    expect(find.text('聊天背景：跟随全局'), findsOneWidget);
    expect(find.text('核心 0 条 · 向量 0 条'), findsOneWidget);
    expect(find.text('聊天记录 0 条 · 定时任务 0 个'), findsOneWidget);
    expect(find.textContaining('主动消息'), findsWidgets);
  });
}

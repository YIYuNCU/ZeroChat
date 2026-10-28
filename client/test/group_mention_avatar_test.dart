import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zerochat/core/group_mentions.dart';
import 'package:zerochat/core/group_scheduler.dart';
import 'package:zerochat/models/message.dart';
import 'package:zerochat/models/role.dart';
import 'package:zerochat/pages/group_settings_page.dart';
import 'package:zerochat/services/group_chat_service.dart';
import 'package:zerochat/services/role_service.dart';
import 'package:zerochat/services/storage_service.dart';
import 'package:zerochat/widgets/chat_bubble.dart';
import 'package:zerochat/widgets/input_bar.dart';
import 'package:zerochat/widgets/member_avatars.dart';

List<Role> _roles() => [
  Role(id: 'r1', name: '小明', systemPrompt: 't'),
  Role(id: 'r2', name: '小明明', systemPrompt: 't'),
  Role(id: 'r3', name: 'Alice', systemPrompt: 't'),
];

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await StorageService.init();
    await StorageService.setJsonList(
      StorageService.keyRoles,
      _roles().map((r) => r.toJson()).toList(),
    );
    await StorageService.setString(StorageService.keyCurrentRoleId, 'r1');
    await RoleService.init();
    await GroupChatService.init();
  });

  group('GroupMentions.resolve', () {
    test('prefers the longest member name', () {
      final result = GroupMentions.resolve('@小明明 你好', _roles());
      expect(result.roleIds, ['r2']);
      expect(result.mentionAll, isFalse);
    });

    test('keeps first-appearance order and dedupes', () {
      final result = GroupMentions.resolve('@alice @小明 再 @Alice', _roles());
      expect(result.roleIds, ['r3', 'r1']);
    });

    test('detects @所有人 and ignores emails', () {
      expect(GroupMentions.resolve('@所有人 开会', _roles()).mentionAll, isTrue);
      expect(
        GroupMentions.resolve('mail me a@Alice.com', _roles()).isEmpty,
        isTrue,
      );
    });

    test('excludes the speaker itself', () {
      final result = GroupMentions.resolve(
        '@小明 @Alice',
        _roles(),
        excludeRoleId: 'r1',
      );
      expect(result.roleIds, ['r3']);
    });

    test('a bare @ or unknown name mentions nobody', () {
      expect(GroupMentions.resolve('@ 你好 @路人', _roles()).isEmpty, isTrue);
    });
  });

  group('GroupScheduler mentions', () {
    test('mentioned roles always answer and others stay silent', () {
      for (var i = 0; i < 30; i++) {
        final result = GroupScheduler.selectRespondingRoles(
          memberIds: const ['r1', 'r2', 'r3'],
          userMessage: '@Alice 在吗',
          replyProbability: 0,
          mentionedRoleIds: const ['r3'],
        );
        expect(result.speakOrder, ['r3']);
      }
    });

    test('user mention overrides the consecutive speak limit', () {
      final result = GroupScheduler.selectRespondingRoles(
        memberIds: const ['r1', 'r3'],
        userMessage: '@Alice',
        lastSpeakerRoleId: 'r3',
        consecutiveCounts: const {'r3': 5},
        maxConsecutiveSpeaks: 2,
        mentionedRoleIds: const ['r3'],
        mentionOverridesLimit: true,
      );
      expect(result.speakOrder, ['r3']);
    });

    test('@所有人 selects everyone except the sender', () {
      final result = GroupScheduler.selectRespondingRoles(
        memberIds: const ['r1', 'r2', 'r3'],
        userMessage: '@所有人',
        mentionAll: true,
        excludeRoleId: 'r2',
      );
      expect(result.speakOrder.toSet(), {'r1', 'r3'});
    });
  });

  group('InputBar @ panel', () {
    Future<EditableText> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: InputBar(mentionRoles: _roles())),
        ),
      );
      await tester.tap(find.byType(TextField));
      await tester.pump();
      return tester.widget<EditableText>(find.byType(EditableText));
    }

    testWidgets('typing @ lists members plus 所有人 and filters by query', (
      tester,
    ) async {
      await pump(tester);

      await tester.enterText(find.byType(TextField), '@');
      await tester.pump();
      expect(find.byKey(const ValueKey('mention_panel')), findsOneWidget);
      expect(find.byKey(const ValueKey('mention_all')), findsOneWidget);
      expect(find.byKey(const ValueKey('mention_r3')), findsOneWidget);

      await tester.enterText(find.byType(TextField), '@ali');
      await tester.pump();
      expect(find.byKey(const ValueKey('mention_r3')), findsOneWidget);
      expect(find.byKey(const ValueKey('mention_r1')), findsNothing);
      expect(find.byKey(const ValueKey('mention_all')), findsNothing);
    });

    testWidgets('picking a member replaces the @query and closes the panel', (
      tester,
    ) async {
      final editable = await pump(tester);

      await tester.enterText(find.byType(TextField), '你好 @小');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('mention_r1')));
      await tester.pump();

      expect(editable.controller.text, '你好 @小明 ');
      expect(editable.controller.selection.baseOffset, 7);
      expect(find.byKey(const ValueKey('mention_panel')), findsNothing);
    });

    testWidgets('no panel after whitespace or without mentionRoles', (
      tester,
    ) async {
      await pump(tester);
      await tester.enterText(find.byType(TextField), '@小明 ');
      await tester.pump();
      expect(find.byKey(const ValueKey('mention_panel')), findsNothing);

      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: InputBar())),
      );
      await tester.enterText(find.byType(TextField), '@');
      await tester.pump();
      expect(find.byKey(const ValueKey('mention_panel')), findsNothing);
      expect(find.byKey(const ValueKey('format_mention')), findsNothing);
    });

    testWidgets('toolbar @ button inserts a trigger', (tester) async {
      final editable = await pump(tester);

      await tester.tap(find.byKey(const ValueKey('format_mention')));
      await tester.pump();

      expect(editable.controller.text, '@');
      expect(find.byKey(const ValueKey('mention_panel')), findsOneWidget);
    });
  });

  group('ChatBubble mention highlight', () {
    Widget bubble(List<String> names) => MaterialApp(
      home: Scaffold(
        body: ChatBubble(
          message: Message(
            id: 'm',
            senderId: 'me',
            receiverId: 'ai',
            content: '<对话>@小明 你好 @路人</对话>',
            timestamp: DateTime(2026, 7, 14),
          ),
          isSender: true,
          mentionNames: names,
        ),
      ),
    );

    testWidgets('colors known mentions only', (tester) async {
      await tester.pumpWidget(bubble(['小明']));

      final rich = tester
          .widgetList<RichText>(find.byType(RichText))
          .firstWhere((w) => w.text.toPlainText().contains('@小明'));
      final colors = <String, Color?>{};
      rich.text.visitChildren((span) {
        if (span is TextSpan && span.text != null) {
          colors[span.text!] = span.style?.color;
        }
        return true;
      });
      expect(colors['@小明'], const Color(0xFF576B95));
      expect(colors.keys.any((k) => k.contains('@路人')), isTrue);
      expect(
        colors.entries.firstWhere((e) => e.key.contains('@路人')).value,
        isNull,
      );
    });
  });

  group('custom group avatar', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('group_avatar_test');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('set, replace and clear copies files into the target dir', () async {
      final group = await GroupChatService.createGroup(
        name: '群',
        memberIds: const ['r1', 'r2'],
      );
      final src = File('${tmp.path}/src.png')..writeAsBytesSync([1, 2, 3]);
      final out = Directory('${tmp.path}/out');

      final first = await GroupChatService.setCustomAvatar(
        group.id,
        src.path,
        targetDir: out,
      );
      expect(first!.avatarUrl, startsWith(out.path));
      expect(File(first.avatarUrl!).existsSync(), isTrue);
      expect(GroupChatService.getGroup(group.id)!.avatarUrl, first.avatarUrl);

      await Future<void>.delayed(const Duration(milliseconds: 2));
      final second = await GroupChatService.setCustomAvatar(
        group.id,
        src.path,
        targetDir: out,
      );
      expect(second!.avatarUrl, isNot(first.avatarUrl));
      expect(File(first.avatarUrl!).existsSync(), isFalse);
      expect(File(second.avatarUrl!).existsSync(), isTrue);

      await GroupChatService.clearCustomAvatar(group.id);
      expect(GroupChatService.getGroup(group.id)!.avatarUrl, isNull);
      expect(File(second.avatarUrl!).existsSync(), isFalse);
    });

    test('dissolving the group removes its avatar file', () async {
      final group = await GroupChatService.createGroup(
        name: '群',
        memberIds: const ['r1', 'r2'],
      );
      final src = File('${tmp.path}/src.png')..writeAsBytesSync([1]);
      final updated = await GroupChatService.setCustomAvatar(
        group.id,
        src.path,
        targetDir: Directory('${tmp.path}/out'),
      );

      await GroupChatService.deleteGroup(group.id);

      expect(File(updated!.avatarUrl!).existsSync(), isFalse);
    });

    testWidgets('missing avatar file falls back to the member grid', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: GroupAvatar(
              memberIds: ['r1', 'r2'],
              customAvatarPath: '/definitely/not/here.png',
            ),
          ),
        ),
      );
      // 文件读取走真实 IO，需要放出事件循环才能触发 errorBuilder。
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();

      expect(find.byType(RoleAvatar), findsNWidgets(2));
    });

    testWidgets('settings page shows the avatar row', (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final group = await GroupChatService.createGroup(
        name: '测试群',
        memberIds: const ['r1', 'r2'],
      );

      await tester.pumpWidget(
        MaterialApp(home: GroupSettingsPage(groupId: group.id)),
      );

      expect(find.text('群头像'), findsOneWidget);
      // 默认头像：设置页头部的成员宫格 + 成员列表里的头像
      expect(find.byType(GroupAvatar), findsOneWidget);
    });
  });
}

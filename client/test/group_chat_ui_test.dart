import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zerochat/models/message.dart';
import 'package:zerochat/models/role.dart';
import 'package:zerochat/pages/create_group_page.dart';
import 'package:zerochat/pages/group_settings_page.dart';
import 'package:zerochat/services/group_chat_service.dart';
import 'package:zerochat/services/role_service.dart';
import 'package:zerochat/services/storage_service.dart';
import 'package:zerochat/widgets/chat_bubble.dart';
import 'package:zerochat/widgets/member_avatars.dart';

Message _message(String content, {String senderId = 'role-1'}) {
  return Message(
    id: 'message-1',
    senderId: senderId,
    receiverId: 'me',
    content: content,
    timestamp: DateTime(2026, 7, 14),
  );
}

Widget _bubble({required bool isSender, required bool showSenderName}) {
  return MaterialApp(
    home: Scaffold(
      body: ChatBubble(
        message: _message('你好', senderId: isSender ? 'me' : 'role-1'),
        isSender: isSender,
        senderName: isSender ? '我' : '小明',
        showSenderName: showSenderName,
      ),
    ),
  );
}

void _bigView(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await StorageService.init();
    await StorageService.setJsonList(StorageService.keyRoles, [
      Role(id: 'role-1', name: '小明', systemPrompt: 'test').toJson(),
      Role(id: 'role-2', name: '小红', systemPrompt: 'test').toJson(),
      Role(id: 'role-3', name: '小刚', systemPrompt: 'test').toJson(),
      Role(
        id: 'role-4',
        name: '已归档',
        systemPrompt: 'test',
        archived: true,
      ).toJson(),
    ]);
    await StorageService.setString(StorageService.keyCurrentRoleId, 'role-1');
    await RoleService.init();
    await GroupChatService.init();
  });

  group('ChatBubble sender name', () {
    testWidgets('shows the speaker name above received group bubbles', (
      tester,
    ) async {
      await tester.pumpWidget(_bubble(isSender: false, showSenderName: true));

      expect(find.text('小明'), findsOneWidget);
    });

    testWidgets('hides the name by default and for own messages', (
      tester,
    ) async {
      await tester.pumpWidget(_bubble(isSender: false, showSenderName: false));
      expect(find.text('小明'), findsNothing);

      await tester.pumpWidget(_bubble(isSender: true, showSenderName: true));
      expect(find.text('我'), findsNothing);
    });
  });

  group('GroupAvatar', () {
    testWidgets('falls back to a group icon when no member resolves', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: GroupAvatar(memberIds: ['missing'])),
        ),
      );

      expect(find.byIcon(Icons.group), findsOneWidget);
    });

    testWidgets('renders one tile per resolved member', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: GroupAvatar(memberIds: ['role-1', 'role-2', 'role-3']),
          ),
        ),
      );

      expect(find.byType(RoleAvatar), findsNWidgets(3));
    });
  });

  group('CreateGroupPage', () {
    testWidgets('lists selectable roles only and gates the confirm button', (
      tester,
    ) async {
      _bigView(tester);
      await tester.pumpWidget(const MaterialApp(home: CreateGroupPage()));

      expect(find.text('小明'), findsOneWidget);
      expect(find.text('小红'), findsOneWidget);
      expect(find.text('已归档'), findsNothing);
      expect(find.text('完成(0)'), findsOneWidget);

      await tester.tap(find.text('小明'));
      await tester.pump();
      // 只选 1 个时不能创建。
      await tester.tap(find.text('完成(1)'));
      await tester.pump();
      expect(GroupChatService.getAllGroups(), isEmpty);

      await tester.tap(find.text('小红'));
      await tester.pump();
      expect(find.text('完成(2)'), findsOneWidget);
    });

    testWidgets('search filters the role list', (tester) async {
      _bigView(tester);
      await tester.pumpWidget(const MaterialApp(home: CreateGroupPage()));

      await tester.enterText(find.widgetWithText(TextField, '搜索角色'), '小红');
      await tester.pump();

      // 搜索框自身也含「小红」，所以按头像行数断言。
      expect(find.byType(RoleAvatar), findsOneWidget);
      expect(find.text('小明'), findsNothing);

      await tester.enterText(find.widgetWithText(TextField, '搜索角色'), 'zzz');
      await tester.pump();
      expect(find.text('没有匹配的角色'), findsOneWidget);
    });

    testWidgets('creates the group with the default member-name title', (
      tester,
    ) async {
      _bigView(tester);
      await tester.pumpWidget(const MaterialApp(home: CreateGroupPage()));

      await tester.tap(find.text('小明'));
      await tester.tap(find.text('小红'));
      await tester.pump();
      await tester.tap(find.text('完成(2)'));
      await tester.pumpAndSettle();

      final groups = GroupChatService.getAllGroups();
      expect(groups, hasLength(1));
      expect(groups.single.name, '小明、小红');
      expect(groups.single.memberIds, ['role-1', 'role-2']);
    });
  });

  group('GroupSettingsPage members', () {
    late String groupId;

    setUp(() async {
      final group = await GroupChatService.createGroup(
        name: '测试群',
        memberIds: const ['role-1', 'role-2'],
      );
      groupId = group.id;
    });

    testWidgets('shows member names and remove mode badges', (tester) async {
      _bigView(tester);
      await tester.pumpWidget(
        MaterialApp(home: GroupSettingsPage(groupId: groupId)),
      );

      expect(find.text('小明'), findsOneWidget);
      expect(find.text('小红'), findsOneWidget);
      expect(find.byIcon(Icons.remove), findsOneWidget); // 移除入口

      await tester.tap(find.text('移除'));
      await tester.pump();
      expect(find.text('完成'), findsOneWidget);
      // 入口图标 + 两个成员角标
      expect(find.byIcon(Icons.remove), findsNWidgets(3));
    });

    testWidgets('removing a member in remove mode updates the group', (
      tester,
    ) async {
      _bigView(tester);
      await tester.pumpWidget(
        MaterialApp(home: GroupSettingsPage(groupId: groupId)),
      );

      await tester.tap(find.text('移除'));
      await tester.pump();
      await tester.tap(find.text('小红'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '移除'));
      await tester.pumpAndSettle();

      expect(GroupChatService.getGroup(groupId)!.memberIds, ['role-1']);
      expect(find.text('小红'), findsNothing);
    });

    testWidgets('add member sheet supports multi select', (tester) async {
      _bigView(tester);
      await tester.pumpWidget(
        MaterialApp(home: GroupSettingsPage(groupId: groupId)),
      );

      await tester.tap(find.text('添加'));
      await tester.pumpAndSettle();

      // 已在群里的和归档角色不可选。
      expect(find.text('添加成员'), findsOneWidget);
      expect(find.text('小刚'), findsOneWidget);
      expect(find.text('已归档'), findsNothing);

      await tester.tap(find.text('小刚'));
      await tester.pump();
      await tester.tap(find.text('添加(1)'));
      await tester.pumpAndSettle();

      expect(GroupChatService.getGroup(groupId)!.memberIds, [
        'role-1',
        'role-2',
        'role-3',
      ]);
    });
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zerochat/core/message_parts.dart';
import 'package:zerochat/models/message.dart';
import 'package:zerochat/models/role.dart';
import 'package:zerochat/services/role_service.dart';
import 'package:zerochat/services/storage_service.dart';
import 'package:zerochat/widgets/chat_bubble.dart';

Message _message(
  String content, {
  String senderId = 'role-1',
  String? reasoning,
}) {
  return Message(
    id: 'message-1',
    senderId: senderId,
    receiverId: 'me',
    content: content,
    timestamp: DateTime(2026, 7, 14),
    reasoningContent: reasoning,
  );
}

Widget _bubble(Message message, {required bool isSender}) {
  return MaterialApp(
    home: Scaffold(
      body: ChatBubble(
        message: message,
        isSender: isSender,
        senderName: isSender ? '我' : 'AI',
      ),
    ),
  );
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await StorageService.init();
    await StorageService.setJsonList(StorageService.keyRoles, [
      Role(
        id: 'role-1',
        name: 'AI',
        systemPrompt: 'test',
        showNoReply: true,
      ).toJson(),
      Role(
        id: 'role-2',
        name: 'AI-reasoning',
        systemPrompt: 'test',
        showNoReply: true,
        showReasoning: true,
      ).toJson(),
    ]);
    await StorageService.setString(StorageService.keyCurrentRoleId, 'role-1');
    await RoleService.init();
  });

  testWidgets('renders repeated mixed parts in source order', (tester) async {
    await tester.pumpWidget(
      _bubble(
        _message(
          '<对话>第一句</对话>'
          '<动作>抬手</动作>'
          '<对话>第二句</对话>'
          '<声音>裙摆沙沙作响</声音>'
          '<心理>有些犹豫</心理>'
          '<动作>放下手</动作>',
        ),
        isSender: false,
      ),
    );

    final labels = ['第一句', '抬手', '第二句', '裙摆沙沙作响', '有些犹豫', '放下手'];
    final positions = labels
        .map((label) => tester.getTopLeft(find.text(label)).dy)
        .toList();

    expect(positions, orderedEquals([...positions]..sort()));
    for (var index = 1; index < positions.length; index++) {
      expect(positions[index], greaterThan(positions[index - 1]));
    }
  });

  testWidgets('renders sound blocks with a distinct icon', (tester) async {
    await tester.pumpWidget(
      _bubble(_message('<对话>我在这里</对话><声音>衣料轻响</声音>'), isSender: false),
    );

    expect(find.text('衣料轻响'), findsOneWidget);
    expect(find.byIcon(Icons.volume_up_outlined), findsOneWidget);
  });

  testWidgets('only user facts receive fact styling', (tester) async {
    await tester.pumpWidget(
      _bubble(_message('<事实>会议已经结束</事实>'), isSender: false),
    );

    expect(find.text('会议已经结束'), findsOneWidget);
    expect(find.byIcon(Icons.fact_check_outlined), findsNothing);
    expect(find.text('<事实>会议已经结束</事实>'), findsNothing);

    await tester.pumpWidget(
      _bubble(_message('<事实>会议已经结束</事实>', senderId: 'me'), isSender: true),
    );
    await tester.pump();

    expect(find.text('会议已经结束'), findsOneWidget);
    expect(find.byIcon(Icons.fact_check_outlined), findsOneWidget);
  });

  testWidgets('renders a visible no-reply directive as a quiet hint', (
    tester,
  ) async {
    await tester.pumpWidget(
      _bubble(_message(MessageParts.noReplyDirective), isSender: false),
    );

    expect(find.text('无回复'), findsOneWidget);
    expect(find.byIcon(Icons.notifications_off_outlined), findsOneWidget);
    expect(find.text(MessageParts.noReplyDirective), findsNothing);

    await tester.pumpWidget(
      _bubble(
        _message(MessageParts.noReplyDirective, senderId: 'me'),
        isSender: true,
      ),
    );
    await tester.pump();

    expect(find.text(MessageParts.noReplyDirective), findsOneWidget);
    expect(find.byIcon(Icons.notifications_off_outlined), findsNothing);
  });

  testWidgets('hides no-reply directives when the role setting is disabled', (
    tester,
  ) async {
    final role = RoleService.getRoleById('role-1')!;
    await RoleService.updateRoleLocal(role.copyWith(showNoReply: false));

    await tester.pumpWidget(
      _bubble(_message(MessageParts.noReplyDirective), isSender: false),
    );

    expect(find.text('无回复'), findsNothing);
    expect(find.byIcon(Icons.notifications_off_outlined), findsNothing);
  });

  testWidgets('thinking chain is hidden when the role setting is disabled', (
    tester,
  ) async {
    await tester.pumpWidget(
      _bubble(_message('回复内容', reasoning: '先分析再回答'), isSender: false),
    );

    expect(find.text('思考过程'), findsNothing);
    expect(find.text('先分析再回答'), findsNothing);
    expect(find.text('回复内容'), findsOneWidget);
  });

  testWidgets('thinking chain expands for roles that enable it', (
    tester,
  ) async {
    await tester.pumpWidget(
      _bubble(
        _message('回复内容', senderId: 'role-2', reasoning: '先分析再回答'),
        isSender: false,
      ),
    );

    expect(find.text('思考过程'), findsOneWidget);
    expect(find.text('先分析再回答'), findsNothing);

    await tester.tap(find.text('思考过程'));
    await tester.pump();

    expect(find.text('先分析再回答'), findsOneWidget);
    expect(find.text('收起思考过程'), findsOneWidget);

    await tester.tap(find.text('收起思考过程'));
    await tester.pump();
    expect(find.text('先分析再回答'), findsNothing);
  });

  testWidgets('no-reply message with reasoning is not fully hidden', (
    tester,
  ) async {
    final role = RoleService.getRoleById('role-2')!;
    await RoleService.updateRoleLocal(role.copyWith(showNoReply: false));

    await tester.pumpWidget(
      _bubble(
        _message(
          MessageParts.noReplyDirective,
          senderId: 'role-2',
          reasoning: '判断后决定不回复',
        ),
        isSender: false,
      ),
    );

    expect(find.text('思考过程'), findsOneWidget);
    expect(find.text('无回复'), findsNothing);
  });
}

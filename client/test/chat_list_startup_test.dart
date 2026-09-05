import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zerochat/models/chat_info.dart';
import 'package:zerochat/services/chat_list_service.dart';
import 'package:zerochat/services/storage_service.dart';

void main() {
  testWidgets('mounted UI refreshes when local chat cache finishes loading', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await StorageService.init();
    await tester.pumpWidget(
      ListenableBuilder(
        listenable: ChatListService.instance,
        builder: (context, child) => Text(
          ChatListService.instance.chatList.map((chat) => chat.name).join(', '),
          textDirection: TextDirection.ltr,
        ),
      ),
    );
    expect(find.text('Cached conversation'), findsNothing);

    await StorageService.setJsonList('chat_list', [
      ChatInfo(id: 'cached', name: 'Cached conversation').toJson(),
    ]);
    await ChatListService.init();
    await tester.pump();

    expect(find.text('Cached conversation'), findsOneWidget);
  });
}

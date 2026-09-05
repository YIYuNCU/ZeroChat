import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zerochat/core/message_store.dart';
import 'package:zerochat/models/message.dart';
import 'package:zerochat/services/message_archive_service.dart';
import 'package:zerochat/services/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  final store = MessageStore.instance;
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('zerochat-store-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => directory.path,
        );
    SharedPreferences.setMockInitialValues({});
    await StorageService.init();
    await StorageService.setStringList('message_store_chat_ids', ['r']);
    await StorageService.setStringList(
      'messages_v2_r',
      List.generate(
        251,
        (i) => Message(
          id: '$i',
          senderId: 'me',
          receiverId: 'r',
          content: 'message $i',
          timestamp: DateTime(2026).add(Duration(seconds: i)),
          sendStatus: i == 0
              ? MessageSendStatus.sending
              : MessageSendStatus.sent,
        ).toStorageString(),
      ),
    );
    await MessageStore.init();
    await store.ensureLoaded('r');
  });
  tearDownAll(() async {
    store.releaseChatWindow('r');
    await store.clearAllLocalChatData();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await directory.delete(recursive: true);
  });

  test(
    'offline initialization migrates legacy history and recovers old pending sends',
    () async {
      expect(StorageService.getStringList('messages_v2_r'), isNull);
      expect(store.getMessageCount('r'), 251);
      expect(store.getMessages('r').length, 200);
      final name = base64UrlEncode(utf8.encode('r')).replaceAll('=', '');
      final pending = await MessageArchiveService.read(
        '${directory.path}/message_archives/$name.jsonl',
        pendingOnly: true,
      );
      expect(pending.messages.single.id, '0');
      expect(pending.messages.single.sendStatus, MessageSendStatus.failed);
    },
  );

  test('closing the window during queued pagination is harmless', () async {
    store.activateChatWindow('r');
    await store.ensureLoaded('r');
    final loading = store.loadOlderMessages('r');
    store.releaseChatWindow('r');
    expect(await loading, 0);
    store.activateChatWindow('r');
    await store.ensureLoaded('r');
    expect(await store.loadOlderMessages('r'), 50);
    expect(store.getMessages('r').first.id, '1');
    store.releaseChatWindow('r');
  });
}

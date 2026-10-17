import 'dart:convert';
import 'dart:async';
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
    expect(await store.loadOlderMessages('r'), 51);
    expect(store.getMessages('r').first.id, '0');
    store.releaseChatWindow('r');
  });

  test('history window slides between 200 and 400 messages', () async {
    const chatId = 'slide';
    await StorageService.setStringList(
      'messages_v2_$chatId',
      List.generate(
        1000,
        (i) => Message(
          id: '$i',
          senderId: i.isEven ? 'me' : 'ai',
          receiverId: chatId,
          content: 'message $i',
          timestamp: DateTime(2026).add(Duration(seconds: i)),
        ).toStorageString(),
      ),
    );

    store.activateChatWindow(chatId);
    await store.ensureLoaded(chatId);
    expect(store.getMessageCount(chatId), 1000);
    expect(store.getMessages(chatId).length, 200);
    expect(store.getMessages(chatId).first.id, '800');
    expect(store.olderMessageCount(chatId), 800);
    expect(store.hasNewerMessages(chatId), isFalse);

    expect(await store.loadOlderMessages(chatId), 200);
    expect(store.getMessages(chatId).length, 400);
    expect(store.getMessages(chatId).first.id, '600');
    expect(store.newerMessageCount(chatId), 0);

    expect(await store.loadOlderMessages(chatId), 200);
    expect(store.getMessages(chatId).length, 400);
    expect(store.getMessages(chatId).first.id, '400');
    expect(store.olderMessageCount(chatId), 400);
    expect(store.newerMessageCount(chatId), 200);
    expect(store.getLastMessage(chatId)?.id, '999');

    expect(await store.loadNewerMessages(chatId), 200);
    expect(store.getMessages(chatId).length, 400);
    expect(store.getMessages(chatId).first.id, '600');
    expect(store.newerMessageCount(chatId), 0);

    // 停留在历史窗口时收到 AI 新消息：只写入归档，不把用户拽回最新端。
    expect(await store.loadOlderMessages(chatId), 200);
    expect(store.getMessages(chatId).first.id, '400');
    expect(store.newerMessageCount(chatId), 200);
    await store.addMessage(
      chatId,
      Message(
        id: 'ai-new',
        senderId: 'ai',
        receiverId: chatId,
        content: 'proactive message',
        timestamp: DateTime(2026).add(const Duration(seconds: 1001)),
      ),
    );
    expect(store.getMessageCount(chatId), 1001);
    expect(store.getMessages(chatId).length, 400);
    expect(store.getMessages(chatId).first.id, '400');
    expect(store.newerMessageCount(chatId), 201);
    expect(store.getLastMessage(chatId)?.id, 'ai-new');

    // 用户自己发消息时必须贴回最新端，确保刚发出的内容可见。
    await store.addMessage(
      chatId,
      Message(
        id: 'new',
        senderId: 'me',
        receiverId: chatId,
        content: 'new message',
        timestamp: DateTime(2026).add(const Duration(seconds: 1002)),
      ),
    );
    expect(store.getMessageCount(chatId), 1002);
    expect(store.getMessages(chatId).length, 400);
    expect(store.getMessages(chatId).last.id, 'new');
    expect(store.newerMessageCount(chatId), 0);
    store.releaseChatWindow(chatId);
  });

  test(
    'backend switch drains archive writes before moving namespace',
    () async {
      await StorageService.configureNamespace('server-a');
      await store.ensureLoaded('r');
      final writing = store.updateMessageSendStatus(
        'r',
        '250',
        MessageSendStatus.failed,
      );
      await Future<void>.delayed(Duration.zero);
      final entered = Completer<void>();
      final release = Completer<void>();
      final switching = store.switchBackend(
        changeNamespace: () async {
          entered.complete();
          await release.future;
          await StorageService.configureNamespace('server-b');
        },
      );
      await entered.future;
      expect(await writing, isTrue);
      expect(StorageService.namespace, 'server-a');
      await expectLater(store.clearAllLocalChatData(), throwsStateError);
      release.complete();
      await switching;
      expect(store.getMessageCount('r'), 0);
      await store.switchBackend(
        changeNamespace: () => StorageService.configureNamespace('server-a'),
      );
      await store.ensureLoaded('r');
      expect(store.getMessageCount('r'), 251);
      expect(store.getMessages('r').last.sendStatus, MessageSendStatus.failed);
    },
  );
}

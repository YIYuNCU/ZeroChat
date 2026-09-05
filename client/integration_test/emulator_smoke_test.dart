import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:zerochat/core/chat_controller.dart';
import 'package:zerochat/core/message_store.dart';
import 'package:zerochat/main.dart' as app;
import 'package:zerochat/models/chat_info.dart';
import 'package:zerochat/models/message.dart';
import 'package:zerochat/models/role.dart';
import 'package:zerochat/pages/chat_detail_page.dart';
import 'package:zerochat/services/avatar_cache_service.dart';
import 'package:zerochat/services/chat_list_service.dart';
import 'package:zerochat/services/media_cache_service.dart';
import 'package:zerochat/services/message_archive_service.dart';
import 'package:zerochat/services/role_service.dart';
import 'package:zerochat/services/secure_storage_service.dart';
import 'package:zerochat/services/settings_service.dart';
import 'package:zerochat/services/storage_service.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Android storage, caches, chat navigation and history', (
    tester,
  ) async {
    if (const bool.fromEnvironment('ZEROCHAT_DEVICE_TEST')) {
      final package = await PackageInfo.fromPlatform();
      expect(
        package.packageName,
        'com.zerochat.zerochat.devicetest',
        reason: 'Phone fixtures must run in the isolated test application.',
      );
    } else if (!const bool.fromEnvironment('ZEROCHAT_EMULATOR_TEST')) {
      fail(
        'Use --dart-define=ZEROCHAT_EMULATOR_TEST=true on a disposable emulator.',
      );
    }
    await StorageService.init();
    await StorageService.prefs.clear();
    await SecureStorageService.init();
    for (final key in SecureStorageService.sensitiveKeys) {
      await SecureStorageService.remove(key);
    }
    await SecureStorageService.init();
    for (final key in SecureStorageService.sensitiveKeys) {
      expect(SecureStorageService.getString(key), isEmpty);
    }
    await StorageService.setBool('background_runtime_enabled', false);
    await SettingsService.init();
    final docs = await getApplicationDocumentsDirectory();
    const chatId = 'emulator_performance';
    final filename = base64UrlEncode(utf8.encode(chatId)).replaceAll('=', '');
    final archive = '${docs.path}/message_archives/$filename.jsonl';
    final messages = List.generate(
      10000,
      (i) => Message(
        id: 'fixture_$i',
        senderId: i.isEven ? 'me' : chatId,
        receiverId: i.isEven ? chatId : 'me',
        content:
            'History message $i: Android cache and scrolling verification.',
        timestamp: DateTime(2026, 9, 1).add(Duration(seconds: i)),
      ),
    );
    await MessageArchiveService.write(archive, messages);
    await StorageService.setStringList('message_store_archive_chat_ids_v1', [
      chatId,
    ]);
    await StorageService.setJson('message_store_archive_counts_v1', {
      chatId: messages.length,
    });
    final roles = List.generate(
      100,
      (i) => Role(
        id: i == 0 ? chatId : 'emulator_role_$i',
        name: i == 0 ? 'Performance Test' : 'Test Contact $i',
        systemPrompt: 'Test fixture',
      ),
    );
    await StorageService.setJsonList(
      StorageService.keyRoles,
      roles.map((r) => r.toJson()).toList(),
    );
    await StorageService.setString(StorageService.keyCurrentRoleId, chatId);
    await StorageService.setJsonList(
      'chat_list',
      roles
          .map(
            (r) => ChatInfo(
              id: r.id,
              name: r.name,
              lastMessage: 'Local cached conversation',
              lastMessageTime: r.id == chatId
                  ? DateTime(2026, 9, 5)
                  : DateTime(2026),
            ).toJson(),
          )
          .toList(),
    );
    await RoleService.init();
    await ChatListService.init();
    await ChatController.init();
    MediaCacheService.configureImageCache();

    final measurements = <String, Object>{};
    var watch = Stopwatch()..start();
    for (var i = 0; i < 10; i++) {
      final page = await MessageArchiveService.read(
        archive,
        start: 4900,
        count: 50,
      );
      expect(page.messages.length, 50);
      expect(page.messages.first.id, 'fixture_4900');
    }
    measurements['indexed_page_mean_ms'] = watch.elapsedMicroseconds / 10000;

    final pixel = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLFCwAAAABJRU5ErkJggg==',
    );
    var downloads = 0;
    Future<http.Response> download(String _) async {
      downloads++;
      return http.Response.bytes(pixel, 200);
    }

    await AvatarCacheService.clearAll();
    final paths = await Future.wait(
      List.generate(
        10,
        (_) => AvatarCacheService.resolveAvatarPath(
          cacheKey: 'emulator_avatar',
          remoteUrl: 'http://test.invalid/avatar.png',
          backendHash: 'fixture',
          download: download,
        ),
      ),
    );
    expect(paths.first, isNotNull);
    expect(paths.toSet().length, 1);
    expect(downloads, 1);
    await AvatarCacheService.resolveAvatarPath(
      cacheKey: 'emulator_avatar',
      remoteUrl: 'http://test.invalid/avatar.png',
      backendHash: 'fixture',
      download: download,
    );
    expect(downloads, 1);
    await AvatarCacheService.clearAll();
    expect(await File(paths.first!).exists(), isFalse);
    measurements['coalesced_avatar_requests'] = downloads;

    watch = Stopwatch()..start();
    await tester.pumpWidget(const app.ZeroChatApp());
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    measurements['cached_ui_ready_ms'] = watch.elapsedMilliseconds;
    expect(find.text('Performance Test'), findsOneWidget);
    await tester.tap(find.text('Performance Test'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.byType(ChatDetailPage), findsOneWidget);
    expect(MessageStore.instance.getMessageCount(chatId), 10000);
    expect(MessageStore.instance.getMessages(chatId).length, 200);

    await binding.watchPerformance(() async {
      final list = find
          .descendant(
            of: find.byType(ChatDetailPage),
            matching: find.byType(ListView),
          )
          .first;
      for (var i = 0; i < 4; i++) {
        await tester.fling(list, const Offset(0, 350), 900);
        await tester.pumpAndSettle();
      }
    }, reportKey: 'chat_scroll');
    final added = await MessageStore.instance.loadOlderMessages(chatId);
    expect(added, 50);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byIcon(Icons.arrow_back_ios));
    await tester.pumpAndSettle();
    expect(find.text('Performance Test'), findsOneWidget);

    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('Performance Test'), findsOneWidget);
    expect(tester.takeException(), isNull);

    binding.reportData ??= {};
    binding.reportData!['storage_metrics'] = measurements;
    final report = File('${docs.path}/emulator_test_results.json');
    await report.writeAsString(jsonEncode(binding.reportData));
    // Printed for automated host collection; no private user data is included.
    debugPrint('ZEROCHAT_EMULATOR_METRICS ${jsonEncode(measurements)}');
    await tester.pumpWidget(const SizedBox.shrink());
    await AvatarCacheService.clearAll();
  });
}

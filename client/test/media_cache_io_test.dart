import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zerochat/services/avatar_cache_service.dart';
import 'package:zerochat/services/emoji_transfer_service.dart';
import 'package:zerochat/services/settings_service.dart';
import 'package:zerochat/services/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  const reference = 'ws-emoji://test/1';
  final bytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==',
  );
  late int requests;
  Future<Map<String, dynamic>> request(
    String action,
    Map<String, dynamic> payload,
  ) async {
    requests++;
    if (action == 'emoji_file_init') {
      return {
        'transfer_id': 'test',
        'total_chunks': 1,
        'size': bytes.length,
        'filename': 'a.png',
        'sha256': sha256.convert(bytes).toString(),
      };
    }
    return {'chunk_index': 0, 'chunk_base64': base64Encode(bytes)};
  }

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('zerochat-media-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => directory.path,
        );
    SharedPreferences.setMockInitialValues({});
    await StorageService.init();
  });
  setUp(() async {
    requests = 0;
    await AvatarCacheService.clearAll();
    await EmojiTransferService.clearCache();
    await SettingsService.instance.updateBackendUrl('http://first');
  });
  tearDown(() async {
    await AvatarCacheService.clearAll();
    await EmojiTransferService.clearCache();
  });
  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await directory.delete(recursive: true);
  });

  test(
    'avatar requests coalesce, hit disk, and isolate backend identities',
    () async {
      var downloads = 0;
      Future<http.Response> download(String _) async {
        downloads++;
        return http.Response.bytes(bytes, 200);
      }

      Future<String?> resolve(String url) =>
          AvatarCacheService.resolveAvatarPath(
            cacheKey: 'role_r_avatar',
            remoteUrl: url,
            backendHash: 'same',
            download: download,
          );
      final paths = await Future.wait(
        List.generate(10, (_) => resolve('http://first/avatar')),
      );
      expect(paths.first, isNotNull);
      expect(paths.toSet().length, 1);
      expect(downloads, 1);
      expect(await resolve('http://first/avatar'), paths.first);
      expect(downloads, 1);
      expect(await resolve('http://second/avatar'), isNot(paths.first));
      expect(downloads, 2);
    },
  );

  test('clearing avatars prevents an old download from committing', () async {
    final started = Completer<void>();
    final response = Completer<http.Response>();
    final result = AvatarCacheService.resolveAvatarPath(
      cacheKey: 'role_r_avatar',
      remoteUrl: 'http://first/avatar',
      backendHash: 'v1',
      download: (_) {
        started.complete();
        return response.future;
      },
    );
    await started.future;
    await AvatarCacheService.clearAll();
    response.complete(http.Response.bytes(bytes, 200));
    expect(await result, isNull);
    expect(
      AvatarCacheService.peekResolvedPath(
        cacheKey: 'role_r_avatar',
        remoteUrl: 'http://first/avatar',
        backendHash: 'v1',
      ),
      isNull,
    );
  });

  test('emoji requests coalesce and a deleted file downloads again', () async {
    final paths = await Future.wait(
      List.generate(
        10,
        (_) =>
            EmojiTransferService.resolveLocalPath(reference, request: request),
      ),
    );
    expect(paths.first, isNotNull);
    expect(requests, 2);
    expect(
      await EmojiTransferService.resolveLocalPath(reference, request: request),
      paths.first,
    );
    expect(requests, 2);
    await File(paths.first!).delete();
    expect(
      await EmojiTransferService.resolveLocalPath(reference, request: request),
      isNotNull,
    );
    expect(requests, 4);
    await SettingsService.instance.updateBackendUrl('http://second');
    expect(
      await EmojiTransferService.resolveLocalPath(reference, request: request),
      isNot(paths.first),
    );
    expect(requests, 6);
  });

  test('invalidated emoji content is fetched again', () async {
    final path = await EmojiTransferService.resolveLocalPath(
      reference,
      request: request,
    );
    await EmojiTransferService.invalidate(reference);
    expect(await File(path!).exists(), isFalse);
    expect(
      await EmojiTransferService.resolveLocalPath(reference, request: request),
      isNotNull,
    );
    expect(requests, 4);
  });

  test(
    'eviction cannot be undone by a same-identity in-flight avatar',
    () async {
      final started = Completer<void>();
      final gate = Completer<http.Response>();
      final old = AvatarCacheService.resolveAvatarPath(
        cacheKey: 'avatar',
        remoteUrl: 'http://first/a',
        download: (_) {
          started.complete();
          return gate.future;
        },
      );
      await started.future;
      await AvatarCacheService.evict('avatar');
      final replacement = await AvatarCacheService.resolveAvatarPath(
        cacheKey: 'avatar',
        remoteUrl: 'http://first/a',
        download: (_) async => http.Response.bytes(bytes, 200),
      );
      gate.complete(http.Response.bytes(bytes, 200));
      expect(await old, isNull);
      expect(await File(replacement!).exists(), isTrue);
    },
  );

  test(
    'clear and trim do not allow a partial download to repopulate cache',
    () async {
      final started = Completer<void>();
      final chunk = Completer<Map<String, dynamic>>();
      final result = EmojiTransferService.resolveLocalPath(
        reference,
        request: (action, payload) async {
          if (action == 'emoji_file_chunk') {
            started.complete();
            return chunk.future;
          }
          return request(action, payload);
        },
      );
      await started.future;
      await EmojiTransferService.trimToBudget();
      await EmojiTransferService.clearCache();
      chunk.complete({'chunk_index': 0, 'chunk_base64': base64Encode(bytes)});
      expect(await result, isNull);
      final files = await Directory(
        '${directory.path}/emoji_cache',
      ).list().toList();
      expect(files, isEmpty);
    },
  );

  test(
    'emoji budget removes oldest files and keeps active cache usable',
    () async {
      final cache = Directory('${directory.path}/emoji_cache');
      await cache.create(recursive: true);
      for (var i = 0; i < 505; i++) {
        await File('${cache.path}/$i.png').writeAsBytes(bytes);
      }
      await EmojiTransferService.trimToBudget();
      expect(await cache.list().length, 500);
    },
  );
}

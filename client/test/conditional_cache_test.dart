import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:zerochat/services/conditional_cache_service.dart';

Map<String, dynamic> snapshot(String hash, String text, {bool reuse = false}) =>
    {
      '_sync': {
        'version': 1,
        'hash': hash,
        'hashes': {'p': hash},
        'layout': {
          'map': {
            'value': {'part': 'p'},
          },
        },
      },
      'parts': {if (!reuse) 'p': text},
    };

void main() {
  late Directory dir;
  late ConditionalCacheService cache;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('zerochat-conditional-');
    cache = ConditionalCacheService(directory: () async => dir);
  });
  tearDown(() async => dir.delete(recursive: true));
  Future<Map<String, dynamic>> read(
    ResourceRequest send, {
    bool force = false,
    String scope = 'a',
  }) => cache.request(
    scope: scope,
    action: 'test',
    payload: {},
    send: send,
    force: force,
  );

  test(
    'persists data and validators together and reuses unchanged response',
    () async {
      await read((_) async => snapshot('one', 'first'));
      cache = ConditionalCacheService(directory: () async => dir);
      final result = await read((query) async {
        expect((query['_sync'] as Map)['hash'], 'one');
        return {
          '_sync': {'hash': 'one', 'not_modified': true},
        };
      });
      expect(result['value'], 'first');
      result['value'] = 'caller mutation';
      expect(
        (await read((_) async => throw StateError('must use cache')))['value'],
        'first',
      );
    },
  );

  test(
    'scopes and corrupt data never send someone else\'s validator',
    () async {
      await read((_) async => snapshot('one', 'first'));
      await read((query) async {
        expect((query['_sync'] as Map).containsKey('hash'), false);
        return snapshot('two', 'second');
      }, scope: 'b');
      final files = await Directory(
        '${dir.path}/resource_cache_v1',
      ).list().toList();
      for (final file in files.whereType<File>()) {
        await file.writeAsString('broken');
      }
      cache = ConditionalCacheService(directory: () async => dir);
      await read((query) async {
        expect((query['_sync'] as Map).containsKey('hash'), false);
        return snapshot('new', 'repaired');
      });
    },
  );

  test(
    'coalesces concurrent reads and retries invalidated in-flight data',
    () async {
      final gate = Completer<Map<String, dynamic>>();
      var calls = 0;
      Future<Map<String, dynamic>> send(Map<String, dynamic> _) async {
        calls++;
        return calls == 1 ? gate.future : snapshot('new', 'fresh');
      }

      final first = read(send);
      final second = read(send);
      while (calls == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      cache.invalidate();
      gate.complete(snapshot('old', 'stale'));
      expect((await first)['value'], 'fresh');
      expect((await second)['value'], 'fresh');
      expect(calls, 2);
    },
  );

  test(
    'missing parts are rejected without acknowledging a new version',
    () async {
      await read((_) async => snapshot('one', 'first'));
      await expectLater(
        read((_) async => snapshot('two', 'missing', reuse: true), force: true),
        throwsFormatException,
      );
      expect(
        (await read((_) async => throw StateError('must use cache')))['value'],
        'first',
      );
    },
  );

  test(
    'invalidation during disk persistence retries before exposing the response',
    () async {
      var directories = 0;
      var calls = 0;
      cache = ConditionalCacheService(
        directory: () async {
          directories++;
          if (directories == 2) cache.invalidate();
          return dir;
        },
      );
      final result = await read((_) async {
        calls++;
        return snapshot('$calls', calls == 1 ? 'stale' : 'fresh');
      });
      expect(result['value'], 'fresh');
      expect(calls, 2);
    },
  );

  test('concurrent forced reads share one network validation', () async {
    final gate = Completer<Map<String, dynamic>>();
    var calls = 0;
    Future<Map<String, dynamic>> send(Map<String, dynamic> _) {
      calls++;
      return gate.future;
    }

    final first = read(send, force: true);
    final second = read(send, force: true);
    while (calls == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    gate.complete(snapshot('new', 'fresh'));
    await Future.wait([first, second]);
    expect(calls, 1);
  });
}

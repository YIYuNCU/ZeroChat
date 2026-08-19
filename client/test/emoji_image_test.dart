import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zerochat/widgets/emoji_image.dart';

const _pngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLFCwAAAABJRU5ErkJggg==';

Future<File> _createEmojiFile() async {
  final directory = await Directory.systemTemp.createTemp(
    'zerochat_emoji_test_',
  );
  addTearDown(() => directory.delete(recursive: true));
  final file = File('${directory.path}${Platform.pathSeparator}emoji.png');
  await file.writeAsBytes(base64Decode(_pngBase64));
  return file;
}

Widget _subject({
  required String source,
  required Future<String?> Function(String) resolveLocalPath,
  Stream<void>? reconnectStream,
}) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 80,
        height: 80,
        child: EmojiImage(
          source: source,
          error: const Icon(Icons.broken_image),
          resolveLocalPath: resolveLocalPath,
          reconnectStream: reconnectStream,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('renders ws emoji references from a resolved local file', (
    tester,
  ) async {
    final imageFile = await _createEmojiFile();
    final resolvedReferences = <String>[];

    await tester.pumpWidget(
      _subject(
        source: 'ws-emoji://role/role-1/happy/wave.png',
        resolveLocalPath: (reference) async {
          resolvedReferences.add(reference);
          return imageFile.path;
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(resolvedReferences, ['ws-emoji://role/role-1/happy/wave.png']);
    expect(tester.widget<Image>(find.byType(Image)).image, isA<FileImage>());
  });

  testWidgets('retries a failed transfer after exponential backoff', (
    tester,
  ) async {
    final imageFile = await _createEmojiFile();
    var attempts = 0;

    await tester.pumpWidget(
      _subject(
        source: 'ws-emoji://user/emoji-1',
        resolveLocalPath: (_) async {
          attempts += 1;
          return attempts == 1 ? null : imageFile.path;
        },
      ),
    );
    await tester.pump();
    expect(attempts, 1);

    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(attempts, 2);
    expect(tester.widget<Image>(find.byType(Image)).image, isA<FileImage>());
  });

  testWidgets('retries a failed transfer immediately after reconnect', (
    tester,
  ) async {
    final reconnects = StreamController<void>();
    addTearDown(reconnects.close);
    var attempts = 0;

    await tester.pumpWidget(
      _subject(
        source: 'ws-emoji://user/emoji-2',
        resolveLocalPath: (_) async {
          attempts += 1;
          return null;
        },
        reconnectStream: reconnects.stream,
      ),
    );
    await tester.pump();
    expect(attempts, 1);

    reconnects.add(null);
    await tester.pump();

    expect(attempts, 2);
  });

  testWidgets('keeps HTTP sources on the authenticated network image path', (
    tester,
  ) async {
    var resolverCalled = false;

    await tester.pumpWidget(
      _subject(
        source: 'https://example.com/emoji.png',
        resolveLocalPath: (_) async {
          resolverCalled = true;
          return null;
        },
      ),
    );
    await tester.pump();

    expect(resolverCalled, isFalse);
    expect(
      tester.widget<Image>(find.byType(Image)).image,
      isA<NetworkImage>(),
    );
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'package:zerochat/models/message.dart';
import 'package:zerochat/services/message_archive_service.dart';

Message message(int i, {bool pending = false}) => Message(
  id: '$i',
  senderId: 'me',
  receiverId: 'r',
  content: '中文\nline $i',
  timestamp: DateTime.utc(2026, 9, 5).add(Duration(seconds: i)),
  sendStatus: pending ? MessageSendStatus.sending : MessageSendStatus.sent,
);

void main() {
  late Directory directory;
  late String path;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('zerochat-archive-');
    path = '${directory.path}/messages.jsonl';
  });
  tearDown(() => directory.delete(recursive: true));

  test(
    'tail and boundary pages preserve UTF-8 and multiline content',
    () async {
      await MessageArchiveService.write(path, List.generate(231, message));
      final tail = await MessageArchiveService.read(path, count: 50);
      expect(tail.total, 231);
      expect(
        tail.messages.map((m) => m.id),
        List.generate(50, (i) => '${181 + i}'),
      );
      final page = await MessageArchiveService.read(path, start: 49, count: 53);
      expect(page.messages.first.content, '中文\nline 49');
      expect(page.messages.last.id, '101');
      expect(page.messages.length, 53);
    },
  );

  test('append, edit, delete and pending lookup update the index', () async {
    await MessageArchiveService.write(path, List.generate(201, message));
    await MessageArchiveService.append(path, [message(201, pending: true)]);
    await MessageArchiveService.replaceMessage(path, message(0, pending: true));
    final pending = await MessageArchiveService.read(path, pendingOnly: true);
    expect(pending.messages.map((m) => m.id), ['0', '201']);
    await MessageArchiveService.removeMessage(path, '49');
    final page = await MessageArchiveService.read(path, start: 49, count: 2);
    expect(page.total, 201);
    expect(page.messages.map((m) => m.id), ['50', '51']);
  });

  test(
    'legacy archive and corrupt but valid JSON index rebuild safely',
    () async {
      await File(path).writeAsString(
        '${message(0).toStorageString()}\r\ninvalid\n${message(1).toStorageString()}',
      );
      expect((await MessageArchiveService.read(path)).total, 2);
      final index = File('$path.idx');
      final data =
          jsonDecode(await index.readAsString()) as Map<String, dynamic>;
      data['offsets'] = [10];
      await index.writeAsString(jsonEncode(data));
      expect((await MessageArchiveService.read(path)).messages.first.id, '0');
      await MessageArchiveService.append(path, [message(2)]);
      expect(
        (await MessageArchiveService.read(path)).messages.map((m) => m.id),
        ['0', '1', '2'],
      );
    },
  );

  test('external edits invalidate a previously valid index', () async {
    await MessageArchiveService.write(path, [message(0)]);
    await File(
      path,
    ).writeAsString('${message(1).toStorageString()}\n', mode: FileMode.append);
    expect(
      (await MessageArchiveService.read(path, count: 1)).messages.single.id,
      '1',
    );
  });

  test(
    'batch status recovery preserves all history and updates pending index',
    () async {
      await MessageArchiveService.write(
        path,
        List.generate(201, (i) => message(i, pending: true)),
      );
      await MessageArchiveService.replaceMessages(path, [
        message(0),
        message(50),
        message(200),
      ]);
      final page = await MessageArchiveService.read(path, pendingOnly: true);
      expect(page.total, 201);
      expect(page.messages.length, 198);
      expect(
        page.messages.any((m) => ['0', '50', '200'].contains(m.id)),
        isFalse,
      );
    },
  );

  test('canonical hash matches the server wire fixture', () async {
    await MessageArchiveService.write(path, [message(0)]);
    const canonical =
        '{"r":[{"content":"中文\\nline 0","id":"0","quote_content":null,"quote_id":null,"sender_id":"me","timestamp":"2026-09-05T00:00:00.000Z","type":"text"}]}';
    expect(
      await MessageArchiveService.hash({'r': path}),
      md5.convert(utf8.encode(canonical)).toString(),
    );
  });

  test('10k history warm pagination benchmark', () async {
    final messages = List.generate(10000, message);
    await MessageArchiveService.write(path, messages);
    final baseline = Stopwatch()..start();
    final all = (await File(
      path,
    ).readAsLines()).map(Message.fromStorageString).toList();
    expect(all.length, 10000);
    baseline.stop();
    final watch = Stopwatch()..start();
    for (var i = 0; i < 5; i++) {
      final page = await MessageArchiveService.read(
        path,
        start: 4900,
        count: 50,
      );
      expect(page.messages.length, 50);
    }
    watch.stop();
    // Timing is reported, not asserted: device and filesystem speed vary.
    // ignore: avoid_print
    print(
      'archive benchmark: full parse ${baseline.elapsedMilliseconds}ms; '
      'indexed page mean ${watch.elapsedMicroseconds / 5000}ms',
    );
  });
}

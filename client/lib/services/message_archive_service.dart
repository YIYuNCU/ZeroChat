import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:crypto/crypto.dart';

import '../models/message.dart';

/// Callers serialize mutations. All parsing and file work runs off the UI isolate.
class MessageArchiveService {
  static const stride = 50;

  static Future<String> hash(Map<String, String> paths) => Isolate.run(() {
    final chats = <String, List<Map<String, dynamic>>>{};
    for (final id in paths.keys.toList()..sort()) {
      final messages = _read(paths[id]!, null, null, false).messages;
      chats[id] =
          messages
              .where((m) => m.sendStatus == MessageSendStatus.sent)
              .map(
                (m) => <String, dynamic>{
                  'content': m.content,
                  'id': m.id,
                  'quote_content': m.quotedPreviewText,
                  'quote_id': m.quotedMessageId,
                  'sender_id': m.senderId,
                  'timestamp': m.timestamp.toIso8601String(),
                  'type': m.type.name,
                },
              )
              .toList()
            ..sort((a, b) {
              final time = (a['timestamp'] as String).compareTo(
                b['timestamp'] as String,
              );
              return time != 0
                  ? time
                  : (a['id'] as String).compareTo(b['id'] as String);
            });
    }
    return md5.convert(utf8.encode(jsonEncode(chats))).toString();
  });

  static Future<({List<Message> messages, int total})> read(
    String path, {
    int? start,
    int? count,
    bool pendingOnly = false,
  }) => Isolate.run(() => _read(path, start, count, pendingOnly));

  static Future<void> write(String path, List<Message> messages) =>
      Isolate.run(() {
        final file = File(path);
        file.parent.createSync(recursive: true);
        final temp = File('$path.tmp');
        final sink = temp.openSync(mode: FileMode.write);
        try {
          for (final message in messages) {
            sink.writeStringSync('${message.toStorageString()}\n');
          }
          sink.flushSync();
        } finally {
          sink.closeSync();
        }
        _replace(temp, file);
        _buildIndex(file);
      });

  static Future<void> append(String path, List<Message> messages) =>
      Isolate.run(() {
        final file = File(path);
        file.parent.createSync(recursive: true);
        final index = _index(file);
        var total = index['total'] as int;
        final offsets = List<int>.from(index['offsets'] as List);
        final pending = List<int>.from(index['pending'] as List);
        final sink = file.openSync(mode: FileMode.append);
        try {
          // A legacy final record may have no newline.
          if (file.lengthSync() > 0) {
            final reader = file.openSync();
            try {
              reader.setPositionSync(file.lengthSync() - 1);
              if (reader.readByteSync() != 10) sink.writeByteSync(10);
            } finally {
              reader.closeSync();
            }
          }
          for (final message in messages) {
            if (total % stride == 0) offsets.add(sink.positionSync());
            if (message.sendStatus != MessageSendStatus.sent) {
              pending.add(total);
            }
            sink.writeStringSync('${message.toStorageString()}\n');
            total++;
          }
          sink.flushSync();
        } finally {
          sink.closeSync();
        }
        _saveIndex(file, total, offsets, pending);
      });

  static Future<bool> replaceMessage(String path, Message message) =>
      _edit(path, {message.id: message});

  static Future<bool> replaceMessages(String path, List<Message> messages) =>
      _edit(path, {for (final message in messages) message.id: message});

  static Future<bool> removeMessage(String path, String id) =>
      _edit(path, {id: null});

  static Future<bool> _edit(
    String path,
    Map<String, Message?> replacements,
  ) async {
    // Keep the entire read/modify/write in one isolate, without copying history
    // back to the UI thread.
    return Isolate.run(() {
      final messages = _read(path, null, null, false).messages;
      var changed = false;
      for (var i = 0; i < messages.length; i++) {
        final id = messages[i].id;
        if (replacements.containsKey(id)) {
          changed = true;
          messages[i] = replacements[id] ?? messages[i];
        }
      }
      if (!changed) return false;
      messages.removeWhere(
        (m) => replacements.containsKey(m.id) && replacements[m.id] == null,
      );
      final file = File(path);
      final temp = File('$path.tmp');
      final sink = temp.openSync(mode: FileMode.write);
      try {
        for (final message in messages) {
          sink.writeStringSync('${message.toStorageString()}\n');
        }
        sink.flushSync();
      } finally {
        sink.closeSync();
      }
      _replace(temp, file);
      _buildIndex(file);
      return true;
    });
  }

  static ({List<Message> messages, int total}) _read(
    String path,
    int? start,
    int? count,
    bool pendingOnly,
  ) {
    final file = File(path);
    if (!file.existsSync()) return (messages: <Message>[], total: 0);
    final index = _index(file);
    final total = index['total'] as int;
    final offsets = List<int>.from(index['offsets'] as List);
    final pending = List<int>.from(index['pending'] as List);
    final first = (start ?? (count == null ? 0 : total - count)).clamp(
      0,
      total,
    );
    final end = count == null ? total : (first + count).clamp(first, total);
    final messages = <Message>[];
    if (first == end) return (messages: messages, total: total);
    final blocks = pendingOnly
        ? pending.map((i) => i ~/ stride).toSet().toList()
        : [first ~/ stride];
    final reader = file.openSync();
    try {
      for (final block in blocks) {
        var ordinal = block * stride;
        final stop = pendingOnly ? (ordinal + stride).clamp(0, total) : end;
        for (final record in _records(reader, offsets[block])) {
          Message message;
          try {
            message = Message.fromStorageString(record.line);
          } catch (_) {
            continue;
          }
          if (ordinal >= first &&
              ordinal < end &&
              (!pendingOnly || message.sendStatus != MessageSendStatus.sent)) {
            messages.add(message);
          }
          ordinal++;
          if (ordinal >= stop) break;
        }
      }
    } finally {
      reader.closeSync();
    }
    return (messages: messages, total: total);
  }

  static Map<String, dynamic> _index(File file) {
    if (!file.existsSync()) {
      return {'total': 0, 'offsets': <int>[], 'pending': <int>[]};
    }
    try {
      final index =
          jsonDecode(File('${file.path}.idx').readAsStringSync())
              as Map<String, dynamic>;
      final stat = file.statSync();
      final total = index['total'] as int;
      final offsets = List<int>.from(index['offsets'] as List);
      final pending = List<int>.from(index['pending'] as List);
      final checksum = index.remove('checksum');
      if (checksum ==
              sha256.convert(utf8.encode(jsonEncode(index))).toString() &&
          index['version'] == 1 &&
          index['size'] == stat.size &&
          index['modified'] == stat.modified.microsecondsSinceEpoch &&
          total >= 0 &&
          offsets.length == (total + stride - 1) ~/ stride &&
          offsets.every((n) => n >= 0 && n < stat.size) &&
          pending.every((n) => n >= 0 && n < total) &&
          _increasing(offsets) &&
          _increasing(pending)) {
        return index;
      }
    } catch (_) {}
    return _buildIndex(file);
  }

  static bool _increasing(List<int> values) {
    for (var i = 1; i < values.length; i++) {
      if (values[i] <= values[i - 1]) return false;
    }
    return true;
  }

  static Map<String, dynamic> _buildIndex(File file) {
    final offsets = <int>[];
    final pending = <int>[];
    var total = 0;
    final reader = file.openSync();
    try {
      for (final record in _records(reader, 0)) {
        try {
          final message = Message.fromStorageString(record.line);
          if (total % stride == 0) offsets.add(record.offset);
          if (message.sendStatus != MessageSendStatus.sent) pending.add(total);
          total++;
        } catch (_) {}
      }
    } finally {
      reader.closeSync();
    }
    return _saveIndex(file, total, offsets, pending);
  }

  static Map<String, dynamic> _saveIndex(
    File file,
    int total,
    List<int> offsets,
    List<int> pending,
  ) {
    final stat = file.statSync();
    final index = <String, dynamic>{
      'version': 1,
      'size': stat.size,
      'modified': stat.modified.microsecondsSinceEpoch,
      'total': total,
      'offsets': offsets,
      'pending': pending,
    };
    final target = File('${file.path}.idx');
    index['checksum'] = sha256
        .convert(utf8.encode(jsonEncode(index)))
        .toString();
    final temp = File('${target.path}.tmp');
    temp.writeAsStringSync(jsonEncode(index), flush: true);
    _replace(temp, target);
    return index;
  }

  static void _replace(File temp, File target) {
    try {
      temp.renameSync(target.path);
    } on FileSystemException {
      if (!Platform.isWindows) rethrow;
      if (target.existsSync()) target.deleteSync();
      temp.renameSync(target.path);
    }
  }

  static Iterable<({String line, int offset})> _records(
    RandomAccessFile reader,
    int start,
  ) sync* {
    reader.setPositionSync(start);
    var offset = start;
    var position = start;
    var line = <int>[];
    while (true) {
      final chunk = reader.readSync(16 * 1024);
      if (chunk.isEmpty) break;
      for (final byte in chunk) {
        position++;
        if (byte == 10) {
          yield (line: utf8.decode(line, allowMalformed: true), offset: offset);
          line = <int>[];
          offset = position;
        } else {
          line.add(byte);
        }
      }
    }
    if (line.isNotEmpty) {
      yield (line: utf8.decode(line, allowMalformed: true), offset: offset);
    }
  }
}

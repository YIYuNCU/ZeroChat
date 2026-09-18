import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'transfer_metrics.dart';

typedef ResourceRequest =
    Future<Map<String, dynamic>> Function(Map<String, dynamic> payload);

/// Stores a response and its validators together. Callers receive detached data.
/// No transport retry, UI state, or user-owned archives live in this cache.
class ConditionalCacheService {
  static const actions = {
    'settings_get',
    'settings_prompts_get',
    'settings_summary_get',
    'roles_list',
    'roles_detail',
    'roles_memory_get',
    'vector_memory_list',
    'usage_stats_get',
    'chat_snapshot',
    'moments_list',
    'tasks_list',
    'user_emojis_list',
    'role_emoji_categories_list',
    'role_emojis_list',
    'user_emoji_categories_list',
  };
  static final instance = ConditionalCacheService();
  ConditionalCacheService({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationCacheDirectory;
  final Future<Directory> Function() _directory;
  final _memory = <String, Map<String, dynamic>>{};
  static const maximumMemoryBytes = 64 * 1024 * 1024;
  static const maximumDiskBytes = 128 * 1024 * 1024;
  final _sizes = <String, int>{};
  final _pending = <String, Future<Map<String, dynamic>>>{};
  final _checked = <String, DateTime>{};
  final _keyActions = <String, String>{};
  final _generations = <String, int>{};
  final _lastNetworkGeneration = <String, int>{};
  int _epoch = 0;
  final _actionEpochs = <String, int>{};

  static String digest(String value) =>
      sha256.convert(utf8.encode(value)).toString();
  static dynamic _canonical(dynamic value) => value is Map
      ? {
          for (final k
              in (value.keys.map((k) => k.toString()).toList()..sort()))
            k: _canonical(value[k]),
        }
      : value is List
      ? value.map(_canonical).toList()
      : value;
  String _key(String scope, String action, Map<String, dynamic> query) =>
      digest(jsonEncode([scope, action, _canonical(query)]));

  /// Invalidation also prevents an older in-flight response from being committed.
  void invalidate({Iterable<String>? actions}) {
    if (actions == null) {
      _epoch++;
    } else {
      for (final action in actions) {
        _actionEpochs[action] = (_actionEpochs[action] ?? 0) + 1;
      }
    }
    if (actions == null) {
      _checked.clear();
    } else {
      _checked.removeWhere((key, _) => actions.contains(_keyActions[key]));
    }
  }

  void invalidateMutation(String action) {
    if (action == 'settings_update') {
      invalidate(
        actions: [
          'settings_get',
          'settings_prompts_get',
          'settings_summary_get',
        ],
      );
    } else if (action.startsWith('moments_') &&
        !action.endsWith('_list') &&
        !action.endsWith('_hash')) {
      invalidate(actions: ['moments_list']);
    } else if (action.startsWith('tasks_') &&
        !action.contains('list') &&
        !action.endsWith('_hash')) {
      invalidate(actions: ['tasks_list']);
    } else if (action.contains('chat_message') || action == 'ai_event') {
      invalidate(
        actions: [
          'chat_snapshot',
          'roles_memory_get',
          'usage_stats_get',
          'vector_memory_list',
        ],
      );
    } else if ((action.startsWith('short_term_') ||
            action.startsWith('vector_memory_') ||
            action == 'roles_memory_update') &&
        !action.endsWith('_list')) {
      invalidate(actions: ['roles_memory_get', 'vector_memory_list']);
    } else if (action.startsWith('roles_') &&
        !action.endsWith('_get') &&
        !action.endsWith('_list') &&
        !action.endsWith('_hash')) {
      invalidate(
        actions: [
          'roles_list',
          'roles_detail',
          'roles_memory_get',
          'chat_snapshot',
        ],
      );
    } else if (action.contains('emoji') &&
        !action.startsWith('emoji_file_') &&
        (action.endsWith('_upload') ||
            action.endsWith('_delete') ||
            action.endsWith('_create'))) {
      invalidate(
        actions: [
          'role_emoji_categories_list',
          'role_emojis_list',
          'user_emoji_categories_list',
          'user_emojis_list',
        ],
      );
    }
  }

  Future<Map<String, dynamic>> request({
    required String scope,
    required String action,
    required Map<String, dynamic> payload,
    required ResourceRequest send,
    bool force = false,
    bool persist = true,
    void Function(Map<String, dynamic>)? onCached,
  }) async {
    final query = Map<String, dynamic>.from(payload)
      ..remove('client_hash')
      ..remove('client_md5');
    final key = _key(scope, action, query);
    _keyActions[key] = action;
    if (onCached != null) {
      final local = await _load(key, persist);
      if (local != null) onCached(_result(local, action, true));
    }
    final existing = _pending[key];
    if (existing != null) {
      final existingGeneration = _generations[key];
      await existing;
      // A forced invalidation received during a read must not be swallowed.
      if ((!force || _lastNetworkGeneration[key] == existingGeneration) &&
          _checked.containsKey(key) &&
          _memory.containsKey(key)) {
        return _result(_memory[key]!, action, true);
      }
      if (_pending[key] != null && !identical(_pending[key], existing)) {
        return request(
          scope: scope,
          action: action,
          payload: payload,
          send: send,
          force: force,
          persist: persist,
        );
      }
    }
    final generation = (_generations[key] ?? 0) + 1;
    _generations[key] = generation;
    final future = _fetch(key, action, query, send, force, persist, generation);
    _pending[key] = future;
    try {
      return await future;
    } finally {
      if (identical(_pending[key], future)) _pending.remove(key);
    }
  }

  Future<File> _file(String key) async =>
      File('${(await _directory()).path}/resource_cache_v1/$key.json');

  Future<Map<String, dynamic>?> _load(String key, bool persist) async {
    final resident = _memory.remove(key);
    if (resident != null) {
      _memory[key] = resident;
      return resident;
    }
    if (!persist) return null;
    try {
      final envelope =
          jsonDecode(await (await _file(key)).readAsString()) as Map;
      final body = envelope['body'] as String;
      if (digest(body) != envelope['checksum']) return null;
      final value = Map<String, dynamic>.from(jsonDecode(body) as Map);
      _materialize(value['layout'] as Map, value['parts'] as Map);
      _remember(key, value);
      return value;
    } catch (_) {
      return null;
    }
  }

  void _remember(String key, Map<String, dynamic> value) {
    _memory.remove(key);
    _memory[key] = value;
    _sizes[key] = utf8.encode(jsonEncode(value)).length;
    while (_memory.length > 32 ||
        _sizes.values.fold<int>(0, (a, b) => a + b) > maximumMemoryBytes) {
      final oldest = _memory.keys.first;
      _memory.remove(oldest);
      _sizes.remove(oldest);
      _checked.remove(oldest);
      _keyActions.remove(oldest);
      if (!_pending.containsKey(oldest)) {
        _generations.remove(oldest);
        _lastNetworkGeneration.remove(oldest);
      }
    }
  }

  Future<void> trimDisk() async {
    final root = Directory('${(await _directory()).path}/resource_cache_v1');
    if (!await root.exists()) return;
    final files = <({File file, FileStat stat})>[];
    await for (final entry in root.list(followLinks: false)) {
      if (entry is File && entry.path.endsWith('.json')) {
        files.add((file: entry, stat: await entry.stat()));
      }
    }
    files.sort((a, b) => a.stat.modified.compareTo(b.stat.modified));
    var bytes = files.fold<int>(0, (sum, item) => sum + item.stat.size);
    for (final item in files) {
      if (bytes <= maximumDiskBytes) break;
      if (_pending.keys.any((key) => item.file.path.endsWith('$key.json'))) {
        continue;
      }
      try {
        await item.file.delete();
        bytes -= item.stat.size;
      } on FileSystemException {
        /* Active reader. */
      }
    }
  }

  Future<Map<String, dynamic>> _fetch(
    String key,
    String action,
    Map<String, dynamic> query,
    ResourceRequest send,
    bool force,
    bool persist,
    int generation, [
    int retries = 0,
  ]) async {
    final cached = await _load(key, persist);
    final checked = _checked[key];
    if (!force &&
        cached != null &&
        checked != null &&
        DateTime.now().difference(checked) < const Duration(seconds: 30)) {
      TransferMetrics.cacheHit(action);
      return _result(cached, action, true);
    }
    final epoch = _epoch + (_actionEpochs[action] ?? 0);
    _lastNetworkGeneration[key] = generation;
    final response = await send({
      ...query,
      '_sync': {
        'version': 1,
        if (cached != null) 'hash': cached['hash'],
        if (cached != null) 'hashes': cached['hashes'],
      },
    });
    final sync = response['_sync'];
    if (epoch != _epoch + (_actionEpochs[action] ?? 0)) {
      if (retries >= 3) {
        throw StateError(
          'Resource changed during synchronization; retry later',
        );
      }
      return _fetch(
        key,
        action,
        query,
        send,
        true,
        persist,
        generation,
        retries + 1,
      );
    }
    if (sync is! Map) return response;
    if (sync['not_modified'] == true) {
      TransferMetrics.cacheHit(action, conditional: true);
      if (cached == null) {
        throw const FormatException('Validator without cached data');
      }
      _checked[key] = DateTime.now();
      return _result(cached, action, true);
    }
    final hashes = Map<String, dynamic>.from(sync['hashes'] as Map);
    final received = response['parts'] as Map;
    final oldParts = cached?['parts'] as Map? ?? {};
    final parts = <String, dynamic>{};
    for (final key in hashes.keys) {
      if (received.containsKey(key)) {
        parts[key] = received[key];
      } else if (oldParts.containsKey(key) &&
          (cached?['hashes'] as Map? ?? {})[key] == hashes[key]) {
        parts[key] = oldParts[key];
      } else {
        throw const FormatException('Incomplete conditional response');
      }
    }
    final next = <String, dynamic>{
      'hash': sync['hash'],
      'hashes': hashes,
      'layout': sync['layout'],
      'parts': parts,
    };
    final result = _result(next, action, false);
    if (generation != _generations[key]) {
      throw StateError('Superseded resource request');
    }
    _remember(key, next);
    _checked[key] = DateTime.now();
    if (persist) {
      try {
        final file = await _file(key);
        await file.parent.create(recursive: true);
        final body = jsonEncode(next);
        final temp = File('${file.path}.$generation.part');
        await temp.writeAsString(
          jsonEncode({'body': body, 'checksum': digest(body)}),
          flush: true,
        );
        await temp.rename(file.path);
        unawaited(trimDisk().catchError((Object _) {}));
      } on FileSystemException {
        /* A cache write failure must not discard valid data. */
      }
    }
    if (epoch != _epoch + (_actionEpochs[action] ?? 0)) {
      _checked.remove(key);
      if (retries >= 3) {
        throw StateError(
          'Resource changed during synchronization; retry later',
        );
      }
      return _fetch(
        key,
        action,
        query,
        send,
        true,
        persist,
        generation,
        retries + 1,
      );
    }
    return result;
  }

  static dynamic _materialize(Map node, Map parts) {
    if (node.containsKey('part')) {
      if (!parts.containsKey(node['part'])) {
        throw const FormatException('Missing cache part');
      }
      return parts[node['part']];
    }
    if (node['map'] is Map) {
      return <String, dynamic>{
        for (final entry in (node['map'] as Map).entries)
          entry.key.toString(): _materialize(entry.value as Map, parts),
      };
    }
    return [
      for (final child in node['list'] as List)
        ...(_materialize(child as Map, parts) as List),
    ];
  }

  static Map<String, dynamic> _result(
    Map cache,
    String action,
    bool unchanged,
  ) {
    final result = Map<String, dynamic>.from(
      jsonDecode(
            jsonEncode(
              _materialize(cache['layout'] as Map, cache['parts'] as Map),
            ),
          )
          as Map,
    );
    result['_cache_unchanged'] = unchanged;
    return result;
  }
}

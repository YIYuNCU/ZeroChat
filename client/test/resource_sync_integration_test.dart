import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zerochat/models/ai_model_profile.dart';
import 'package:zerochat/models/summary_config.dart';
import 'package:zerochat/services/conditional_cache_service.dart';
import 'package:zerochat/services/memory_service.dart';
import 'package:zerochat/services/role_service.dart';
import 'package:zerochat/services/secure_backend_client.dart';
import 'package:zerochat/services/secure_storage_service.dart';
import 'package:zerochat/services/secure_websocket_client.dart';
import 'package:zerochat/services/settings_service.dart';
import 'package:zerochat/services/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final settings = SettingsService.instance;
  late Directory directory;
  late HttpServer server;
  final sockets = <WebSocket>[];
  final requests = <Map<String, dynamic>>[];
  final secrets = <String, String>{};
  var remote = <String, dynamic>{};
  var roles = <Map<String, dynamic>>[];
  var rejectUpdate = false;

  setUp(() async {
    requests.clear();
    sockets.clear();
    rejectUpdate = false;
    remote = {
      'ai_model': 'server-model',
      'ai_api_key': 'chat-secret',
      'context_summary_config': {
        'model': 'summary-model',
        'api_key': 'summary-secret',
      },
    };
    roles = [
      {
        'id': 'r',
        'name': 'Role',
        'system_prompt': 'server prompt',
        'onebot_config': {'secret': 'onebot-secret'},
      },
    ];
    directory = await Directory.systemTemp.createTemp('zerochat-sync-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      socket.listen((frame) {
        final data = jsonDecode(frame as String) as Map;
        final action = data['action'];
        final payload = Map<String, dynamic>.from(
          SecureBackendClient.decryptPayloadFromTransfer(data['payload'])
              as Map,
        );
        requests.add({'action': action, 'payload': payload});
        Map<String, dynamic> response;
        if (action == 'settings_get') {
          final summaryOnly =
              (payload['groups'] as List?)?.contains('context_summary') == true;
          final values = summaryOnly
              ? {'context_summary_config': remote['context_summary_config']}
              : remote;
          response = {
            'settings': values,
            'field_versions': {for (final key in values.keys) key: 'version-1'},
          };
        } else if (action == 'settings_update') {
          response = rejectUpdate
              ? {
                  'success': false,
                  'conflicts': ['ai_model'],
                }
              : {'success': true};
        } else if (action == 'roles_list') {
          response = {
            'roles': roles
                .map(
                  (r) => {...r}
                    ..remove('system_prompt')
                    ..remove('onebot_config'),
                )
                .toList(),
            'hash': 'remote',
          };
        } else if (action == 'roles_detail') {
          response = {'role': roles.first};
        } else {
          response = {'success': true};
        }
        socket.add(
          jsonEncode({
            'request_id': data['request_id'],
            'ok': true,
            'data': SecureBackendClient.encryptPayloadForTransfer(response),
          }),
        );
      });
    });
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => directory.path,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity_status'),
      (_) async => null,
    );
    secrets
      ..clear()
      ..addAll({
        'backend_auth_token': 'test-token',
        'backend_encryption_secret': 'test-secret',
      });
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async {
        final args = Map<String, dynamic>.from(call.arguments as Map);
        final key = args['key'];
        switch (call.method) {
          case 'readAll':
            return Map<String, String>.of(secrets);
          case 'read':
            return secrets[key];
          case 'write':
            secrets[key as String] = args['value'] as String;
            return null;
          case 'delete':
            secrets.remove(key);
            return null;
          case 'containsKey':
            return secrets.containsKey(key);
        }
        return null;
      },
    );
    SharedPreferences.setMockInitialValues({
      'backend_url': 'http://127.0.0.1:${server.port}',
    });
    StorageService.archiveNamespace = '';
    await StorageService.init();
    await SecureStorageService.init();
    await SettingsService.init();
    await RoleService.reloadLocalCache();
    ConditionalCacheService.instance.invalidate();
  });
  tearDown(() async {
    await SecureWebSocketClient.instance.close();
    for (final socket in sockets) {
      await socket.close();
    }
    await server.close(force: true);
    await directory.delete(recursive: true);
  });

  test('one setting edit sends one field and no unrelated API keys', () async {
    expect(await settings.syncAllSettingsFromBackend(), isTrue);
    await settings.updateChatApi(
      url: settings.chatApiUrl,
      key: settings.chatApiKey,
      model: 'edited',
    );
    expect(await settings.syncApiSettingsToBackend(), isTrue);
    final update = requests.last['payload'] as Map;
    expect(update['updates'], {'ai_model': 'edited'});
    expect(update['base_versions'], {'ai_model': 'version-1'});
    final count = requests.length;
    expect(await settings.syncApiSettingsToBackend(), isTrue);
    expect(requests.length, count);
  });

  test('summary model patch omits unchanged summary and chat keys', () async {
    expect(await settings.syncAllSettingsFromBackend(), isTrue);
    final config = settings.contextSummaryConfig.copy()..model = 'new-summary';
    await settings.updateContextSummaryConfig(config);
    expect(
      await settings.syncSummaryConfigToBackend(SummaryFeature.context),
      isTrue,
    );
    expect((requests.last['payload'] as Map)['updates'], {
      'context_summary_config': {'model': 'new-summary'},
    });
  });

  test('conflict preserves local edits across a background read', () async {
    await settings.syncAllSettingsFromBackend();
    await settings.updateChatApi(
      url: settings.chatApiUrl,
      key: settings.chatApiKey,
      model: 'local-draft',
    );
    rejectUpdate = true;
    expect(await settings.syncApiSettingsToBackend(), isFalse);
    expect(settings.hasSettingsConflict, isTrue);
    remote['ai_model'] = 'other-device';
    await settings.syncAllSettingsFromBackend();
    expect(settings.chatModel, 'local-draft');
  });

  test(
    'summary profile binding and secrets are isolated across backends',
    () async {
      const profile = ModelApiProfile(
        id: 'p',
        name: 'Local',
        apiUrl: 'https://provider.test',
        model: 'p-model',
        apiKey: 'profile-secret',
        capabilities: {ModelProfileCapability.chat},
      );
      await settings.saveApiProfile(profile);
      await settings.updateContextSummaryConfig(
        SummaryApiConfig(profileId: 'p', apiKey: 'profile-secret'),
      );
      final originalUrl = settings.backendUrl;
      await settings.updateBackendUrl('http://127.0.0.1:1');
      expect(settings.contextSummaryConfig.profileId, isNull);
      expect(settings.contextSummaryConfig.apiKey, isEmpty);
      await settings.updateBackendUrl(originalUrl);
      expect(settings.contextSummaryConfig.profileId, 'p');
      expect(settings.contextSummaryConfig.apiKey, 'profile-secret');
    },
  );

  test(
    'role detail can clear a secret and local drafts survive reload and refresh',
    () async {
      await RoleService.fetchFromBackend(force: true);
      final role = await RoleService.ensureRoleDetails('r');
      final cleared = role.copyWith(
        onebotConfig: role.onebotConfig.copyWith(secret: ''),
      );
      await RoleService.syncRoleToBackend(cleared);
      final patch = (requests.last['payload'] as Map)['role'] as Map;
      expect((patch['onebot_config'] as Map)['secret'], '');
      await RoleService.updateRoleLocal(
        cleared.copyWith(name: 'Offline draft'),
      );
      await RoleService.reloadLocalCache();
      await RoleService.fetchFromBackend(force: true);
      expect(RoleService.getRoleById('r')!.name, 'Offline draft');
    },
  );

  test('core memory updates target the requested role', () async {
    await MemoryService.setCoreMemoryLocal(['first'], roleId: 'r1');
    await MemoryService.setCoreMemoryLocal(['second'], roleId: 'r2');
    expect(MemoryService.getCoreMemory(roleId: 'r1'), ['first']);
    expect(MemoryService.getCoreMemory(roleId: 'r2'), ['second']);
  });
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'settings_service.dart';
import 'secure_backend_client.dart';

class SecureWebSocketClient {
  SecureWebSocketClient._();

  static final SecureWebSocketClient instance = SecureWebSocketClient._();

  static const Duration _defaultRequestTimeout = Duration(seconds: 8);
  static const Duration _heartbeatInterval = Duration(minutes: 15);

  WebSocket? _socket;
  StreamSubscription<dynamic>? _subscription;
  Timer? _heartbeatTimer;

  final Map<String, Completer<Map<String, dynamic>>> _pending =
      <String, Completer<Map<String, dynamic>>>{};
    final StreamController<Map<String, dynamic>> _serverPushController =
      StreamController<Map<String, dynamic>>.broadcast();

  Completer<void>? _connectingCompleter;
  int _requestSeq = 0;

  bool get isConnected => _socket != null;
  Stream<Map<String, dynamic>> get serverPushStream => _serverPushController.stream;

  Future<void> ensureConnected() async {
    if (_socket != null) {
      return;
    }

    if (_connectingCompleter != null) {
      await _connectingCompleter!.future;
      return;
    }

    final completer = Completer<void>();
    _connectingCompleter = completer;

    try {
      final wsUri = _buildWsUri(
        backendUrl: SettingsService.instance.backendUrl,
      );

      final socket = await WebSocket.connect(
        wsUri.toString(),
        headers: {'X-Auth-Token': SettingsService.instance.backendAuthToken},
      ).timeout(_defaultRequestTimeout);

      _socket = socket;
      _subscription = socket.listen(
        _handleIncoming,
        onError: (Object error, StackTrace stackTrace) {
          debugPrint('SecureWebSocketClient: stream error: $error');
          _handleDisconnect(error.toString());
        },
        onDone: () {
          _handleDisconnect('socket closed');
        },
      );

      _startHeartbeat();
      completer.complete();
    } catch (e) {
      _handleDisconnect('connect failed: $e');
      completer.completeError(e);
      rethrow;
    } finally {
      _connectingCompleter = null;
    }
  }

  Future<Map<String, dynamic>> request(
    String action,
    Map<String, dynamic> payload, {
    Duration timeout = _defaultRequestTimeout,
  }) async {
    await ensureConnected();

    final requestId = _nextRequestId();
    final completer = Completer<Map<String, dynamic>>();
    _pending[requestId] = completer;

    final encryptedPayload = SecureBackendClient.encryptPayloadForTransfer(
      payload,
    );

    final frame = <String, dynamic>{
      'request_id': requestId,
      'action': action,
      'payload': encryptedPayload,
    };

    try {
      _socket?.add(jsonEncode(frame));
    } catch (e) {
      _pending.remove(requestId);
      rethrow;
    }

    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(requestId);
        throw TimeoutException(
          'WebSocket request timeout: $action',
          timeout,
        );
      },
    );
  }

  Future<void> close() async {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;

    await _subscription?.cancel();
    _subscription = null;

    await _socket?.close();
    _socket = null;

    _failAllPending('socket closed');
  }

  Uri _buildWsUri({required String backendUrl}) {
    final uri = Uri.parse(backendUrl);
    final wsScheme = uri.scheme == 'https' ? 'wss' : 'ws';

    return Uri(
      scheme: wsScheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: '/ws/secure',
    );
  }

  String _nextRequestId() {
    _requestSeq += 1;
    return '${DateTime.now().microsecondsSinceEpoch}_$_requestSeq';
  }

  void _handleIncoming(dynamic raw) {
    try {
      final map = jsonDecode(raw.toString());
      if (map is! Map) {
        return;
      }
      final data = Map<String, dynamic>.from(map);
      final event = data['event']?.toString() ?? '';
      if (event == 'heartbeat_ack') {
        return;
      }

      if (event == 'server_push') {
        try {
          final encryptedPayload = data['data'];
          final decrypted = SecureBackendClient.decryptPayloadFromTransfer(
            encryptedPayload,
          );
          final payloadMap = decrypted is Map
              ? Map<String, dynamic>.from(decrypted)
              : <String, dynamic>{'value': decrypted};

          _serverPushController.add({
            'event': event,
            'type': data['type']?.toString(),
            ...payloadMap,
          });
        } catch (e) {
          debugPrint('SecureWebSocketClient: decode server push failed: $e');
        }
        return;
      }

      final requestId = data['request_id']?.toString() ?? '';
      if (requestId.isEmpty) {
        return;
      }

      final completer = _pending.remove(requestId);
      if (completer == null || completer.isCompleted) {
        return;
      }

      final ok = data['ok'] == true;
      if (!ok) {
        String errorText = data['error']?.toString() ?? 'unknown websocket error';
        try {
          final encryptedError = data['data'];
          if (encryptedError != null) {
            final decryptedError = SecureBackendClient.decryptPayloadFromTransfer(
              encryptedError,
            );
            if (decryptedError is Map) {
              final map = Map<String, dynamic>.from(decryptedError);
              final maybeError = map['error']?.toString();
              if (maybeError != null && maybeError.isNotEmpty) {
                errorText = maybeError;
              }
            }
          }
        } catch (_) {
          // Ignore decrypt failure and keep fallback error text.
        }
        completer.completeError(Exception(errorText));
        return;
      }

      final encryptedResult = data['data'];
      final decrypted = SecureBackendClient.decryptPayloadFromTransfer(
        encryptedResult,
      );
      if (decrypted is Map<String, dynamic>) {
        completer.complete(decrypted);
      } else if (decrypted is Map) {
        completer.complete(Map<String, dynamic>.from(decrypted));
      } else {
        completer.complete({'value': decrypted});
      }
    } catch (e) {
      debugPrint('SecureWebSocketClient: decode incoming failed: $e');
    }
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (Timer timer) {
      final socket = _socket;
      if (socket == null) {
        return;
      }
      try {
        socket.add(
          jsonEncode({
            'event': 'heartbeat',
            'timestamp': DateTime.now().toIso8601String(),
          }),
        );
      } catch (e) {
        _handleDisconnect('heartbeat failed: $e');
      }
    });
  }

  void _handleDisconnect(String reason) {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;

    _subscription?.cancel();
    _subscription = null;

    _socket = null;
    _failAllPending(reason);
  }

  void _failAllPending(String reason) {
    final entries = List<MapEntry<String, Completer<Map<String, dynamic>>>>.from(
      _pending.entries,
    );
    _pending.clear();

    for (final entry in entries) {
      if (!entry.value.isCompleted) {
        entry.value.completeError(Exception(reason));
      }
    }
  }
}

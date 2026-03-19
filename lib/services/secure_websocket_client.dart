import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import 'settings_service.dart';
import 'secure_backend_client.dart';
import 'wake_lock_service.dart';

class SecureWebSocketClient {
  SecureWebSocketClient._() {
    _startConnectivityMonitor();
  }

  static final SecureWebSocketClient instance = SecureWebSocketClient._();

  static const Duration _defaultRequestTimeout = Duration(seconds: 8);
  static const Duration _heartbeatInterval = Duration(minutes: 2);
  static const Duration _connectivityReconnectDebounce = Duration(seconds: 2);

  WebSocket? _socket;
  StreamSubscription<dynamic>? _subscription;
  Timer? _heartbeatTimer;
  StreamSubscription<dynamic>? _connectivitySubscription;
  Timer? _connectivityReconnectTimer;

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
      await WakeLockService.acquireShort(
        duration: _resolveRequestWakeLockDuration(timeout),
        reason: 'request_$action',
      );
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

  Duration _resolveRequestWakeLockDuration(Duration timeout) {
    final bounded = timeout.inSeconds.clamp(8, 90);
    return Duration(seconds: bounded + 6);
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
      unawaited(_sendHeartbeatFrame());
    });
  }

  Future<void> _sendHeartbeatFrame() async {
    final socket = _socket;
    if (socket == null) {
      return;
    }
    try {
      await WakeLockService.acquireShort(
        duration: const Duration(seconds: 10),
        reason: 'heartbeat',
      );
      socket.add(
        jsonEncode({
          'event': 'heartbeat',
          'timestamp': DateTime.now().toIso8601String(),
        }),
      );
    } catch (e) {
      _handleDisconnect('heartbeat failed: $e');
    }
  }

  void _startConnectivityMonitor() {
    if (!Platform.isAndroid) {
      return;
    }

    _connectivitySubscription?.cancel();
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen(
      (dynamic result) {
        if (!_hasNetwork(result)) {
          return;
        }
        _scheduleConnectivityConnectionCheck();
      },
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('SecureWebSocketClient: connectivity stream error: $error');
      },
    );
  }

  bool _hasNetwork(dynamic result) {
    if (result is ConnectivityResult) {
      return result != ConnectivityResult.none;
    }
    if (result is List<ConnectivityResult>) {
      return result.any((ConnectivityResult item) => item != ConnectivityResult.none);
    }
    if (result is Iterable) {
      return result.any((dynamic item) => item != ConnectivityResult.none);
    }
    return true;
  }

  void _scheduleConnectivityConnectionCheck() {
    _connectivityReconnectTimer?.cancel();
    _connectivityReconnectTimer = Timer(
      _connectivityReconnectDebounce,
      () {
        unawaited(_checkConnectionAfterNetworkChange());
      },
    );
  }

  Future<void> _checkConnectionAfterNetworkChange() async {
    if (_socket == null) {
      try {
        await ensureConnected();
      } catch (e) {
        debugPrint(
          'SecureWebSocketClient: reconnect failed after connectivity change: $e',
        );
      }
      return;
    }

    try {
      await request(
        'health',
        const <String, dynamic>{},
        timeout: const Duration(seconds: 4),
      );
    } catch (e) {
      debugPrint(
        'SecureWebSocketClient: connection check failed after connectivity change, reconnecting: $e',
      );
      try {
        await close();
        await ensureConnected();
      } catch (e2) {
        debugPrint(
          'SecureWebSocketClient: reconnect failed after connection check: $e2',
        );
      }
    }
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

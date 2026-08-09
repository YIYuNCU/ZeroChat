import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class SecureBackendResponse {
  final int statusCode;
  final dynamic data;

  const SecureBackendResponse({required this.statusCode, required this.data});

  bool get isSuccess => statusCode >= 200 && statusCode < 300;
}

class SecureBackendClient {
  static String _authToken = '';
  static String _encryptionSecret = '';

  /// 是否已配置鉴权 token 与加密 secret。未配置时应阻止连接并提示用户填写。
  static bool get isSecurityConfigured =>
      _authToken.isNotEmpty && _encryptionSecret.isNotEmpty;

  /// 常规请求（get/post/put/delete/getRaw/postRawJson）的读写超时。
  static const Duration _connectReadTimeout = Duration(seconds: 15);

  /// multipart 上传的超时（作用于 request.send()）。
  static const Duration _multipartTimeout = Duration(seconds: 60);

  /// 幂等请求的最大重试次数（首发之外）。
  static const int _idempotentMaxRetries = 2;

  static final Random _retryJitter = Random();

  /// 仅在连接级异常时重试；HTTP 4xx/5xx 会返回响应而非抛异常，不在此列。
  static bool _isRetryableError(Object error) {
    return error is TimeoutException ||
        error is SocketException ||
        error is http.ClientException ||
        error is HandshakeException;
  }

  /// 有界指数退避重试。仅用于幂等操作；非幂等调用不要传 maxRetries>0。
  static Future<T> _withRetry<T>(
    Future<T> Function() op, {
    int maxRetries = 0,
    String label = 'http',
  }) async {
    Object? lastError;
    for (int attempt = 0; attempt <= maxRetries; attempt += 1) {
      try {
        return await op();
      } catch (e) {
        lastError = e;
        final shouldRetry = attempt < maxRetries && _isRetryableError(e);
        if (!shouldRetry) {
          rethrow;
        }
        final base = 300 * (1 << attempt); // 300ms, 600ms, ...
        final jitter = _retryJitter.nextInt(150);
        final delay = Duration(milliseconds: base + jitter);
        debugPrint(
          'SecureBackendClient: retry $label (attempt ${attempt + 2}/${maxRetries + 1}) after ${delay.inMilliseconds}ms, error: $e',
        );
        await Future<void>.delayed(delay);
      }
    }
    throw lastError ?? Exception('SecureBackendClient request failed: $label');
  }

  static void configureSecurity({
    required String authToken,
    required String encryptionSecret,
  }) {
    // 不再回退到内置默认值：未配置即为空，由调用方在连接前校验并提示用户填写。
    _authToken = authToken.trim();
    _encryptionSecret = encryptionSecret.trim();
  }

  static Map<String, String> get authHeaders => {'X-Auth-Token': _authToken};

  static Map<String, String> _buildHeaders({
    Map<String, String>? headers,
    bool includeAuth = true,
  }) {
    final merged = <String, String>{};
    if (includeAuth) {
      merged['X-Auth-Token'] = _authToken;
    }
    if (headers != null) {
      merged.addAll(headers);
    }
    return merged;
  }

  static Future<SecureBackendResponse> get(String url) async {
    return _withRetry(
      () async {
        final response = await http
            .get(
              Uri.parse(url),
              headers: _buildHeaders(headers: {'Accept': 'application/json'}),
            )
            .timeout(_connectReadTimeout);
        return _decodeResponse(response);
      },
      maxRetries: _idempotentMaxRetries,
      label: 'GET $url',
    );
  }

  static Future<SecureBackendResponse> post(
    String url,
    Map<String, dynamic> body,
  ) async {
    // 非幂等：单发，仅加超时，不自动重试。
    final response = await http
        .post(
          Uri.parse(url),
          headers: _buildHeaders(headers: {'Content-Type': 'application/json'}),
          body: jsonEncode({'payload': _encryptPayload(body)}),
        )
        .timeout(_connectReadTimeout);

    return _decodeResponse(response);
  }

  static Future<SecureBackendResponse> put(
    String url,
    Map<String, dynamic> body,
  ) async {
    // PUT 为整资源替换，幂等，可重试。
    return _withRetry(
      () async {
        final response = await http
            .put(
              Uri.parse(url),
              headers:
                  _buildHeaders(headers: {'Content-Type': 'application/json'}),
              body: jsonEncode({'payload': _encryptPayload(body)}),
            )
            .timeout(_connectReadTimeout);
        return _decodeResponse(response);
      },
      maxRetries: _idempotentMaxRetries,
      label: 'PUT $url',
    );
  }

  static Future<SecureBackendResponse> delete(String url) async {
    return _withRetry(
      () async {
        final response = await http
            .delete(
              Uri.parse(url),
              headers: _buildHeaders(headers: {'Accept': 'application/json'}),
            )
            .timeout(_connectReadTimeout);
        return _decodeResponse(response);
      },
      maxRetries: _idempotentMaxRetries,
      label: 'DELETE $url',
    );
  }

  static SecureBackendResponse _decodeResponse(http.Response response) {
    if (response.body.isEmpty) {
      return SecureBackendResponse(statusCode: response.statusCode, data: null);
    }

    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic> && decoded['payload'] != null) {
        final decrypted = _decryptPayload(decoded['payload']);
        return SecureBackendResponse(
          statusCode: response.statusCode,
          data: decrypted,
        );
      }
      return SecureBackendResponse(
        statusCode: response.statusCode,
        data: decoded,
      );
    } catch (_) {
      return SecureBackendResponse(
        statusCode: response.statusCode,
        data: response.body,
      );
    }
  }

  static dynamic decodeResponseBodyString(String body) {
    if (body.isEmpty) return null;
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic> && decoded['payload'] != null) {
      return _decryptPayload(decoded['payload']);
    }
    return decoded;
  }

  static Map<String, String> encryptPayloadForTransfer(
    Map<String, dynamic> data,
  ) {
    return _encryptPayload(data);
  }

  static dynamic decryptPayloadFromTransfer(dynamic encrypted) {
    return _decryptPayload(encrypted);
  }

  // Raw requests for non-encrypted endpoints or binary content.
  static Future<http.Response> getRaw(
    String url, {
    Map<String, String>? headers,
    bool includeAuth = true,
    Duration? timeout,
  }) async {
    return _withRetry(
      () => http
          .get(
            Uri.parse(url),
            headers: _buildHeaders(headers: headers, includeAuth: includeAuth),
          )
          .timeout(timeout ?? _connectReadTimeout),
      maxRetries: _idempotentMaxRetries,
      label: 'GET(raw) $url',
    );
  }

  /// 原始 JSON POST。非幂等，默认单发不重试。
  /// [timeout] 允许调用方为 LLM 等长耗时请求放宽超时。
  static Future<http.Response> postRawJson(
    String url, {
    required Map<String, dynamic> body,
    Map<String, String>? headers,
    bool includeAuth = true,
    Duration? timeout,
  }) async {
    final merged = <String, String>{'Content-Type': 'application/json'};
    if (headers != null) {
      merged.addAll(headers);
    }
    return http
        .post(
          Uri.parse(url),
          headers: _buildHeaders(headers: merged, includeAuth: includeAuth),
          body: jsonEncode(body),
        )
        .timeout(timeout ?? _connectReadTimeout);
  }

  static Future<http.StreamedResponse> multipartPost(
    String url, {
    List<http.MultipartFile>? files,
    Map<String, String>? fields,
    Map<String, String>? headers,
    bool includeAuth = true,
  }) async {
    final request = http.MultipartRequest('POST', Uri.parse(url));
    request.headers.addAll(
      _buildHeaders(headers: headers, includeAuth: includeAuth),
    );
    if (fields != null) {
      request.fields.addAll(fields);
    }
    if (files != null) {
      request.files.addAll(files);
    }
    // 非幂等：单发，仅加超时。
    return request.send().timeout(_multipartTimeout);
  }

  static Map<String, String> _encryptPayload(Map<String, dynamic> data) {
    final plain = utf8.encode(jsonEncode(data));
    final nonce = _randomBytes(16);
    final secretBytes = utf8.encode(_encryptionSecret);
    final keyStream = _buildKeystream(secretBytes, nonce, plain.length);
    final cipher = _xorBytes(plain, keyStream);

    final hmacSha256 = Hmac(sha256, secretBytes);
    final sign = hmacSha256.convert([...nonce, ...cipher]).toString();

    return {
      'nonce': base64Encode(nonce),
      'ciphertext': base64Encode(cipher),
      'hmac': sign,
    };
  }

  static dynamic _decryptPayload(dynamic encrypted) {
    if (encrypted is! Map) {
      throw const FormatException('invalid encrypted payload');
    }

    final nonceB64 = encrypted['nonce']?.toString() ?? '';
    final cipherB64 = encrypted['ciphertext']?.toString() ?? '';
    final sign = encrypted['hmac']?.toString() ?? '';

    if (nonceB64.isEmpty || cipherB64.isEmpty || sign.isEmpty) {
      throw const FormatException('encrypted payload missing fields');
    }

    final nonce = base64Decode(nonceB64);
    final cipher = base64Decode(cipherB64);
    final secretBytes = utf8.encode(_encryptionSecret);

    final hmacSha256 = Hmac(sha256, secretBytes);
    final expected = hmacSha256.convert([...nonce, ...cipher]).toString();
    if (expected != sign) {
      throw const FormatException('payload hmac verify failed');
    }

    final keyStream = _buildKeystream(secretBytes, nonce, cipher.length);
    final plain = _xorBytes(cipher, keyStream);
    return jsonDecode(utf8.decode(plain));
  }

  static List<int> _buildKeystream(
    List<int> secretBytes,
    List<int> nonce,
    int length,
  ) {
    final stream = <int>[];
    var counter = 0;

    while (stream.length < length) {
      final counterBytes = ByteData(4)..setUint32(0, counter, Endian.big);
      final digest = sha256.convert([
        ...secretBytes,
        ...nonce,
        ...counterBytes.buffer.asUint8List(),
      ]);
      stream.addAll(digest.bytes);
      counter += 1;
    }

    return stream.sublist(0, length);
  }

  static List<int> _xorBytes(List<int> input, List<int> keyStream) {
    return List<int>.generate(input.length, (i) => input[i] ^ keyStream[i]);
  }

  static List<int> _randomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
  }
}

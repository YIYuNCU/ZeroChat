import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

class SecureBackendResponse {
  final int statusCode;
  final dynamic data;

  const SecureBackendResponse({required this.statusCode, required this.data});

  bool get isSuccess => statusCode >= 200 && statusCode < 300;
}

class SecureBackendClient {
  static const String _authToken = 'ZEROCHAT_FIXED_TOKEN_2026';
  static const String _encryptionSecret = 'ZEROCHAT_TRANSFER_SECRET_2026';

  static Map<String, String> get authHeaders => {'X-Auth-Token': _authToken};

  static Future<SecureBackendResponse> get(String url) async {
    final response = await http.get(
      Uri.parse(url),
      headers: {'X-Auth-Token': _authToken, 'Accept': 'application/json'},
    );

    return _decodeResponse(response);
  }

  static Future<SecureBackendResponse> post(
    String url,
    Map<String, dynamic> body,
  ) async {
    final response = await http.post(
      Uri.parse(url),
      headers: {'Content-Type': 'application/json', 'X-Auth-Token': _authToken},
      body: jsonEncode({'payload': _encryptPayload(body)}),
    );

    return _decodeResponse(response);
  }

  static Future<SecureBackendResponse> put(
    String url,
    Map<String, dynamic> body,
  ) async {
    final response = await http.put(
      Uri.parse(url),
      headers: {'Content-Type': 'application/json', 'X-Auth-Token': _authToken},
      body: jsonEncode({'payload': _encryptPayload(body)}),
    );

    return _decodeResponse(response);
  }

  static Future<SecureBackendResponse> delete(String url) async {
    final response = await http.delete(
      Uri.parse(url),
      headers: {'X-Auth-Token': _authToken, 'Accept': 'application/json'},
    );

    return _decodeResponse(response);
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

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'config.dart';

class ApiException implements Exception {
  ApiException(this.statusCode, this.message);

  final int? statusCode;
  final String message;

  bool get isUnauthorized => statusCode == 401;

  @override
  String toString() => message;
}

/// Client HTTP minimal : JSON + Bearer token lu à chaque requête
/// (le token vit dans le secure storage, pas en mémoire).
class ApiClient {
  ApiClient({required this.tokenReader, http.Client? client})
      : _client = client ?? http.Client();

  final Future<String?> Function() tokenReader;
  final http.Client _client;

  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body, {
    bool authenticated = true,
  }) async {
    final decoded = await _send('POST', path, body: body, authenticated: authenticated);
    return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
  }

  /// Réponse objet JSON.
  Future<Map<String, dynamic>> get(String path) async {
    final decoded = await _send('GET', path);
    return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
  }

  /// Réponse tableau JSON (listes : vacations, pénalités...).
  Future<List<dynamic>> getList(String path) async {
    final decoded = await _send('GET', path);
    return decoded is List ? decoded : <dynamic>[];
  }

  Future<dynamic> _send(
    String method,
    String path, {
    Map<String, dynamic>? body,
    bool authenticated = true,
  }) async {
    final headers = <String, String>{'Content-Type': 'application/json'};
    if (authenticated) {
      final token = await tokenReader();
      if (token == null) {
        throw ApiException(401, 'Session expirée, reconnectez-vous.');
      }
      headers['Authorization'] = 'Bearer $token';
    }

    final uri = Uri.parse('${AppConfig.apiBaseUrl}$path');
    final http.Response response;
    try {
      response = await (method == 'GET'
              ? _client.get(uri, headers: headers)
              : _client.post(uri, headers: headers, body: jsonEncode(body)))
          .timeout(const Duration(seconds: 20));
    } on SocketException {
      throw ApiException(null, 'Pas de connexion au serveur.');
    } on TimeoutException {
      throw ApiException(null, 'Le serveur ne répond pas (délai dépassé).');
    } on HttpException {
      throw ApiException(null, 'Erreur réseau.');
    }

    final dynamic decoded =
        response.body.isEmpty ? <String, dynamic>{} : jsonDecode(response.body);

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return decoded;
    }
    final json =
        decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    final message = (json['message'] ?? json['error'] ?? 'Erreur serveur')
        .toString();
    throw ApiException(response.statusCode, message);
  }
}

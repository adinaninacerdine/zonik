import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'config.dart';

class ApiException implements Exception {
  ApiException(this.statusCode, this.message);

  /// Code HTTP, ou null si la requête n'a pas atteint le serveur.
  final int? statusCode;
  final String message;

  bool get isUnauthorized => statusCode == 401;

  /// Pas de réponse du serveur (pas de réseau, délai, DNS…).
  bool get isNetwork => statusCode == null;

  /// Le serveur refuse la requête elle-même : la renvoyer telle quelle ne
  /// changera rien. 401 (session), 408 (délai) et 429 (trop de requêtes)
  /// sont des cas à part, temporaires.
  bool get isPermanent =>
      statusCode != null &&
      statusCode! >= 400 &&
      statusCode! < 500 &&
      statusCode != 401 &&
      statusCode != 408 &&
      statusCode != 429;

  @override
  String toString() => message;
}

/// Réponse brute : corps JSON décodé + heure du serveur (en-tête Date),
/// qui sert à mesurer le décalage de l'horloge du téléphone.
class ApiResponse {
  const ApiResponse({
    required this.statusCode,
    required this.body,
    this.serverDate,
  });

  final int statusCode;
  final dynamic body;
  final DateTime? serverDate;

  Map<String, dynamic> get json =>
      body is Map<String, dynamic> ? body as Map<String, dynamic> : const {};
}

/// Client HTTP minimal : JSON + Bearer token lu à chaque requête
/// (le token vit dans le secure storage, pas en mémoire).
class ApiClient {
  ApiClient({required this.tokenReader, http.Client? client})
      : _client = client ?? http.Client();

  static const Duration defaultTimeout = Duration(seconds: 20);

  final Future<String?> Function() tokenReader;
  final http.Client _client;

  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body, {
    bool authenticated = true,
    Duration timeout = defaultTimeout,
  }) async {
    final res = await send('POST', path,
        body: body, authenticated: authenticated, timeout: timeout);
    return res.json;
  }

  /// Réponse objet JSON.
  Future<Map<String, dynamic>> get(
    String path, {
    Duration timeout = defaultTimeout,
  }) async {
    final res = await send('GET', path, timeout: timeout);
    return res.json;
  }

  /// Réponse tableau JSON (listes : vacations, pénalités...).
  Future<List<dynamic>> getList(
    String path, {
    Duration timeout = defaultTimeout,
  }) async {
    final res = await send('GET', path, timeout: timeout);
    return res.body is List ? res.body as List<dynamic> : <dynamic>[];
  }

  /// Requête complète : lève [ApiException] hors 2xx, renvoie sinon le
  /// corps décodé et l'heure du serveur.
  Future<ApiResponse> send(
    String method,
    String path, {
    Map<String, dynamic>? body,
    bool authenticated = true,
    Duration timeout = defaultTimeout,
  }) async {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };
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
          .timeout(timeout);
    } on SocketException {
      throw ApiException(null, 'Pas de connexion au serveur.');
    } on TimeoutException {
      throw ApiException(null, 'Le serveur ne répond pas (délai dépassé).');
    } on HttpException {
      throw ApiException(null, 'Erreur réseau.');
    } on http.ClientException {
      throw ApiException(null, 'Erreur réseau.');
    } on HandshakeException {
      throw ApiException(null, 'Connexion sécurisée impossible (réseau ou heure du téléphone).');
    }

    dynamic decoded;
    try {
      decoded = response.body.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(response.body);
    } on FormatException {
      // Page HTML d'un portail captif, d'un proxy opérateur ou d'une erreur
      // Caddy : ce n'est pas notre API qui a répondu.
      if (response.statusCode >= 200 && response.statusCode < 300) {
        throw ApiException(null, 'Réponse inattendue (réseau filtré ?).');
      }
      decoded = <String, dynamic>{};
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return ApiResponse(
        statusCode: response.statusCode,
        body: decoded,
        serverDate: _parseDate(response.headers['date']),
      );
    }
    final json =
        decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    final message = (json['message'] ?? json['error'] ?? _defaultMessage(response.statusCode))
        .toString();
    throw ApiException(response.statusCode, message);
  }

  static String _defaultMessage(int status) {
    if (status == 413) return 'Données trop volumineuses pour le serveur.';
    if (status >= 500) return 'Erreur serveur ($status).';
    return 'Erreur $status.';
  }

  static DateTime? _parseDate(String? header) {
    if (header == null) return null;
    try {
      return HttpDate.parse(header);
    } catch (_) {
      return null;
    }
  }
}

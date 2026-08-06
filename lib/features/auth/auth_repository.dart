import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/api_client.dart';

class Session {
  const Session({
    required this.tenantSlug,
    required this.matricule,
  });

  final String tenantSlug;
  final String matricule;
}

class AuthRepository {
  AuthRepository({required this.api, required this.storage});

  static const _kToken = 'token';
  static const _kTenantSlug = 'tenantSlug';
  static const _kMatricule = 'matricule';

  final ApiClient api;
  final FlutterSecureStorage storage;

  /// Session existante (token présent) au démarrage, sinon null.
  Future<Session?> loadSession() async {
    final token = await storage.read(key: _kToken);
    if (token == null) return null;
    return Session(
      tenantSlug: await storage.read(key: _kTenantSlug) ?? '',
      matricule: await storage.read(key: _kMatricule) ?? '',
    );
  }

  Future<Session> login({
    required String tenantSlug,
    required String matricule,
    required String pin,
  }) async {
    final json = await api.post(
      '/api/auth/employee/login',
      {'tenantSlug': tenantSlug, 'matricule': matricule, 'pin': pin},
      authenticated: false,
    );
    final token = json['token'] as String?;
    if (token == null) {
      throw ApiException(null, 'Réponse du serveur invalide (token absent).');
    }
    await storage.write(key: _kToken, value: token);
    await storage.write(key: _kTenantSlug, value: tenantSlug);
    await storage.write(key: _kMatricule, value: matricule);
    return Session(tenantSlug: tenantSlug, matricule: matricule);
  }

  /// Supprime uniquement le token : les pointages locaux non synchronisés
  /// restent en base et partiront à la prochaine session.
  Future<void> logout() async {
    await storage.delete(key: _kToken);
  }
}

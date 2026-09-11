import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/api_client.dart';

class Session {
  const Session({
    required this.tenantSlug,
    required this.matricule,
    this.fullName = '',
    this.mustChangePin = false,
  });

  final String tenantSlug;
  final String matricule;
  final String fullName;

  /// PIN d'amorçage (import, réinitialisation par un admin) : l'agent doit
  /// en choisir un avant d'accéder au pointage.
  final bool mustChangePin;

  Session copyWith({bool? mustChangePin}) => Session(
        tenantSlug: tenantSlug,
        matricule: matricule,
        fullName: fullName,
        mustChangePin: mustChangePin ?? this.mustChangePin,
      );
}

class AuthRepository {
  AuthRepository({required this.api, required this.storage});

  static const _kToken = 'token';
  static const _kTenantSlug = 'tenantSlug';
  static const _kMatricule = 'matricule';
  static const _kFullName = 'fullName';
  static const _kMustChangePin = 'mustChangePin';

  final ApiClient api;
  final FlutterSecureStorage storage;

  /// Session existante (token présent) au démarrage, sinon null.
  Future<Session?> loadSession() async {
    final token = await storage.read(key: _kToken);
    if (token == null) return null;
    return Session(
      tenantSlug: await storage.read(key: _kTenantSlug) ?? '',
      matricule: await storage.read(key: _kMatricule) ?? '',
      fullName: await storage.read(key: _kFullName) ?? '',
      mustChangePin: (await storage.read(key: _kMustChangePin)) == 'true',
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
    final fullName = (json['fullName'] as String?) ?? '';
    final mustChangePin = json['mustChangePin'] == true;
    await storage.write(key: _kToken, value: token);
    await storage.write(key: _kTenantSlug, value: tenantSlug);
    await storage.write(key: _kMatricule, value: matricule);
    await storage.write(key: _kFullName, value: fullName);
    await storage.write(key: _kMustChangePin, value: mustChangePin.toString());
    return Session(
      tenantSlug: tenantSlug,
      matricule: matricule,
      fullName: fullName,
      mustChangePin: mustChangePin,
    );
  }

  /// L'agent choisit son PIN. Le serveur vérifie l'actuel et refuse les PIN triviaux.
  Future<void> changePin({
    required String currentPin,
    required String newPin,
  }) async {
    await api.post(
      '/api/auth/employee/pin',
      {'currentPin': currentPin, 'newPin': newPin},
    );
    await storage.write(key: _kMustChangePin, value: 'false');
  }

  /// Supprime uniquement le token : les pointages locaux non synchronisés
  /// restent en base et partiront à la prochaine session.
  Future<void> logout() async {
    await storage.delete(key: _kToken);
  }
}

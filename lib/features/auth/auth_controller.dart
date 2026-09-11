import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';
import 'auth_repository.dart';

/// État d'authentification : Session si connecté, null sinon.
class AuthController extends AsyncNotifier<Session?> {
  @override
  Future<Session?> build() {
    return ref.watch(authRepositoryProvider).loadSession();
  }

  Future<void> login({
    required String tenantSlug,
    required String matricule,
    required String pin,
  }) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() {
      return ref.read(authRepositoryProvider).login(
            tenantSlug: tenantSlug.trim(),
            matricule: matricule.trim(),
            pin: pin.trim(),
          );
    });
  }

  /// Changement de PIN par l'agent. En cas de succès, la session sort du
  /// mode "PIN à changer" et l'écran d'accueil s'affiche.
  Future<void> changePin({
    required String currentPin,
    required String newPin,
  }) async {
    final current = state.value;
    if (current == null) return;
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      await ref.read(authRepositoryProvider).changePin(
            currentPin: currentPin.trim(),
            newPin: newPin.trim(),
          );
      return current.copyWith(mustChangePin: false);
    });
  }

  Future<void> logout() async {
    await ref.read(authRepositoryProvider).logout();
    state = const AsyncData(null);
  }
}

final authControllerProvider =
    AsyncNotifierProvider<AuthController, Session?>(AuthController.new);

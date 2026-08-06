import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'core/api_client.dart';
import 'data/database.dart';
import 'features/attendance/punch_repository.dart';
import 'features/attendance/sync_service.dart';
import 'features/auth/auth_repository.dart';
import 'features/face/face_repository.dart';
import 'features/face/face_service.dart';

final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

final secureStorageProvider = Provider<FlutterSecureStorage>(
  (ref) => const FlutterSecureStorage(),
);

final apiClientProvider = Provider<ApiClient>((ref) {
  final storage = ref.watch(secureStorageProvider);
  return ApiClient(tokenReader: () => storage.read(key: 'token'));
});

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  return AuthRepository(
    api: ref.watch(apiClientProvider),
    storage: ref.watch(secureStorageProvider),
  );
});

final punchRepositoryProvider = Provider<PunchRepository>((ref) {
  return PunchRepository(
    db: ref.watch(databaseProvider),
    api: ref.watch(apiClientProvider),
  );
});

final syncServiceProvider = Provider<SyncService>((ref) {
  final service = SyncService(repository: ref.watch(punchRepositoryProvider));
  ref.onDispose(service.dispose);
  return service;
});

/// Modèle de reconnaissance faciale (chargé une fois, ~5 Mo en mémoire).
final faceServiceProvider = FutureProvider<FaceService>((ref) async {
  final service = await FaceService.load();
  ref.onDispose(service.dispose);
  return service;
});

final faceRepositoryProvider = Provider<FaceRepository>((ref) {
  return FaceRepository(
    api: ref.watch(apiClientProvider),
    storage: ref.watch(secureStorageProvider),
  );
});

/// Nombre de pointages en attente de synchronisation.
final pendingCountProvider = StreamProvider<int>((ref) {
  return ref.watch(databaseProvider).watchPendingCount();
});

/// Derniers pointages (pour l'historique de l'écran d'accueil).
final recentPunchesProvider = StreamProvider<List<Punch>>((ref) {
  return ref.watch(databaseProvider).watchRecent();
});

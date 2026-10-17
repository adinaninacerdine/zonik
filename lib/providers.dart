import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'core/api_client.dart';
import 'data/database.dart';
import 'features/attendance/punch_repository.dart';
import 'features/attendance/sync_service.dart';
import 'features/auth/auth_controller.dart';
import 'features/auth/auth_repository.dart';
import 'features/face/face_repository.dart';
import 'features/face/face_service.dart';
import 'features/planning/planning_repository.dart';

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
  return PunchRepository(db: ref.watch(databaseProvider));
});

final planningRepositoryProvider = Provider<PlanningRepository>((ref) {
  final auth = ref.watch(authRepositoryProvider);
  return PlanningRepository(
    db: ref.watch(databaseProvider),
    api: ref.watch(apiClientProvider),
    ownerReader: auth.currentOwner,
  );
});

/// Moteur d'envoi des pointages (un seul pour toute l'app).
final syncEngineProvider = Provider<SyncEngine>((ref) {
  final auth = ref.watch(authRepositoryProvider);
  final engine = SyncEngine(
    db: ref.watch(databaseProvider),
    api: ref.watch(apiClientProvider),
    sessionReader: auth.currentSyncSession,
  );
  ref.onDispose(engine.dispose);
  return engine;
});

/// Déclencheurs de sync (réseau, minuterie). Démarré par l'écran d'accueil.
final syncServiceProvider = Provider<SyncService>((ref) {
  final service = SyncService(
    engine: ref.watch(syncEngineProvider),
    planning: ref.watch(planningRepositoryProvider),
  );
  ref.onDispose(service.dispose);
  return service;
});

/// État de la sync pour l'interface (en cours, dernière réussite, erreur,
/// reconnexion nécessaire, décalage d'horloge).
final syncStateProvider = StreamProvider<SyncState>((ref) async* {
  final engine = ref.watch(syncEngineProvider);
  yield engine.state;
  yield* engine.states;
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

/// Agent connecté (null hors session).
final ownerProvider = Provider<Owner?>((ref) {
  return ref.watch(authControllerProvider).value?.owner;
});

/// Jour courant (minuit local). Change à minuit : la carte « Aujourd'hui »
/// passe au lendemain même si l'app reste ouverte toute la nuit.
final currentDayProvider = StreamProvider<DateTime>((ref) async* {
  DateTime today() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  var day = today();
  yield day;
  await for (final _ in Stream<void>.periodic(const Duration(minutes: 1))) {
    final d = today();
    if (d != day) {
      day = d;
      yield day;
    }
  }
});

/// Vacations du jour de l'agent connecté, lues dans le cache local :
/// disponibles hors ligne.
final todayShiftsProvider = StreamProvider<List<MyShift>>((ref) {
  final owner = ref.watch(ownerProvider);
  final day = ref.watch(currentDayProvider).value;
  if (owner == null || day == null) return Stream.value(const <MyShift>[]);
  return ref.watch(planningRepositoryProvider).watchDay(owner, day);
});

/// Date du dernier téléchargement du planning de l'agent connecté.
final planningFetchedAtProvider = StreamProvider<DateTime?>((ref) {
  final owner = ref.watch(ownerProvider);
  if (owner == null) return Stream.value(null);
  return ref.watch(planningRepositoryProvider).watchFetchedAt(owner);
});

/// Nombre de pointages de l'agent connecté en attente de synchronisation.
final pendingCountProvider = StreamProvider<int>((ref) {
  final owner = ref.watch(ownerProvider);
  if (owner == null) return Stream.value(0);
  return ref.watch(databaseProvider).watchPendingCount(owner);
});

/// Pointages d'autres agents de ce téléphone encore en attente.
final othersPendingCountProvider = StreamProvider<int>((ref) {
  final owner = ref.watch(ownerProvider);
  if (owner == null) return Stream.value(0);
  return ref.watch(databaseProvider).watchOthersPendingCount(owner);
});

/// Derniers pointages de l'agent connecté (historique de l'écran d'accueil).
final recentPunchesProvider = StreamProvider<List<Punch>>((ref) {
  final owner = ref.watch(ownerProvider);
  if (owner == null) return Stream.value(const <Punch>[]);
  return ref.watch(databaseProvider).watchRecent(owner);
});

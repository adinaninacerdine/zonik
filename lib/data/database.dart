import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'database.g.dart';

/// Pointages écrits localement en premier (offline-first), puis
/// synchronisés vers le backend. Dédup côté serveur via [clientUuid].
@DataClassName('Punch')
class Punches extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get clientUuid => text().unique()();

  /// 'in' (arrivée) ou 'out' (départ).
  TextColumn get type => text()();
  RealColumn get lat => real()();
  RealColumn get lng => real()();
  RealColumn get accuracy => real().nullable()();

  /// Heure locale du pointage (celle qui fait foi, pas celle de la sync).
  DateTimeColumn get punchedAt => dateTime()();
  BoolColumn get synced => boolean().withDefault(const Constant(false))();
  DateTimeColumn get syncedAt => dateTime().nullable()();

  /// Dernière erreur de sync rencontrée (diagnostic).
  TextColumn get lastError => text().nullable()();

  /// Vérification d'identité : similarité cosinus avec l'empreinte enrôlée
  /// (null si vérification indisponible), correspondance au seuil, et photo
  /// témoin JPEG jointe pour l'audit superviseur.
  RealColumn get faceScore => real().nullable()();
  BoolColumn get faceMatch => boolean().nullable()();
  BlobColumn get photo => blob().nullable()();
}

@DriftDatabase(tables: [Punches])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(driftDatabase(name: 'zonik'));

  AppDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await m.addColumn(punches, punches.faceScore);
            await m.addColumn(punches, punches.faceMatch);
            await m.addColumn(punches, punches.photo);
          }
        },
      );

  Future<int> insertPunch(PunchesCompanion punch) =>
      into(punches).insert(punch);

  Future<List<Punch>> pendingPunches() => (select(punches)
        ..where((t) => t.synced.equals(false))
        ..orderBy([(t) => OrderingTerm.asc(t.punchedAt)]))
      .get();

  Stream<int> watchPendingCount() {
    final count = punches.id.count();
    final query = selectOnly(punches)
      ..addColumns([count])
      ..where(punches.synced.equals(false));
    return query.map((row) => row.read(count) ?? 0).watchSingle();
  }

  Stream<List<Punch>> watchRecent({int limit = 30}) => (select(punches)
        ..orderBy([(t) => OrderingTerm.desc(t.punchedAt)])
        ..limit(limit))
      .watch();

  Future<Punch?> lastPunch() => (select(punches)
        ..orderBy([(t) => OrderingTerm.desc(t.punchedAt)])
        ..limit(1))
      .getSingleOrNull();

  Future<void> markSynced(List<String> clientUuids) async {
    if (clientUuids.isEmpty) return;
    await (update(punches)..where((t) => t.clientUuid.isIn(clientUuids)))
        .write(PunchesCompanion(
      synced: const Value(true),
      syncedAt: Value(DateTime.now()),
      lastError: const Value(null),
    ));
  }

  Future<void> markSyncError(List<String> clientUuids, String error) async {
    if (clientUuids.isEmpty) return;
    await (update(punches)..where((t) => t.clientUuid.isIn(clientUuids)))
        .write(PunchesCompanion(lastError: Value(error)));
  }
}

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'database.g.dart';

/// Propriétaire d'une donnée locale : un agent d'une entreprise.
/// Plusieurs agents peuvent se succéder sur un même téléphone : chaque
/// pointage reste attaché à celui qui l'a fait, et ne part qu'avec SON token.
class Owner {
  const Owner(this.tenantSlug, this.matricule);

  final String tenantSlug;
  final String matricule;

  @override
  bool operator ==(Object other) =>
      other is Owner &&
      other.tenantSlug == tenantSlug &&
      other.matricule == matricule;

  @override
  int get hashCode => Object.hash(tenantSlug, matricule);
}

/// Pointages écrits localement en premier (offline-first), puis
/// synchronisés vers le backend. Dédup côté serveur via [clientUuid].
@DataClassName('Punch')
class Punches extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get clientUuid => text().unique()();

  /// Agent propriétaire (null uniquement pour les lignes héritées de la v2,
  /// rattachées à la session courante au premier lancement).
  TextColumn get tenantSlug => text().nullable()();
  TextColumn get matricule => text().nullable()();

  /// 'in' (arrivée) ou 'out' (départ).
  TextColumn get type => text()();
  RealColumn get lat => real()();
  RealColumn get lng => real()();
  RealColumn get accuracy => real().nullable()();

  /// Heure de l'horloge du téléphone au moment du pointage. Elle peut être
  /// fausse (réglée à la main) : le serveur la recoupe avec [elapsedMs].
  DateTimeColumn get punchedAt => dateTime()();

  /// Horloge monotone Android (ms depuis le démarrage, non modifiable par
  /// l'utilisateur) et compteur de démarrages. Avec les mêmes valeurs
  /// relevées à l'envoi, le serveur recalcule l'heure réelle du pointage.
  IntColumn get elapsedMs => integer().nullable()();
  IntColumn get bootCount => integer().nullable()();

  /// Écart horloge serveur − horloge téléphone connu au moment du pointage
  /// (mesuré à la dernière sync réussie), en ms.
  IntColumn get clockOffsetMs => integer().nullable()();

  /// Heure du fix GPS (horloge satellite) et position simulée détectée.
  DateTimeColumn get fixAt => dateTime().nullable()();
  BoolColumn get isMocked => boolean().nullable()();

  /// Contrôle de zone fait sur le téléphone (sites en cache). Indicatif :
  /// le serveur refait le calcul avec PostGIS, qui fait foi.
  TextColumn get siteId => text().nullable()();
  TextColumn get siteName => text().nullable()();
  RealColumn get distanceM => real().nullable()();
  BoolColumn get inZone => boolean().nullable()();

  BoolColumn get synced => boolean().withDefault(const Constant(false))();
  DateTimeColumn get syncedAt => dateTime().nullable()();

  /// Refus définitif du serveur (donnée invalide) : on n'insiste plus, le
  /// motif reste affiché à l'agent et visible au diagnostic.
  BoolColumn get rejected => boolean().withDefault(const Constant(false))();

  /// File de retry : nombre d'échecs temporaires et prochaine tentative.
  IntColumn get attempts => integer().withDefault(const Constant(0))();
  DateTimeColumn get nextAttemptAt => dateTime().nullable()();

  /// Dernière erreur de sync rencontrée (diagnostic).
  TextColumn get lastError => text().nullable()();

  /// Vérification d'identité : similarité cosinus avec l'empreinte enrôlée
  /// (null si vérification indisponible), correspondance au seuil, et photo
  /// témoin JPEG jointe pour l'audit superviseur (effacée après sync).
  RealColumn get faceScore => real().nullable()();
  BoolColumn get faceMatch => boolean().nullable()();
  BlobColumn get photo => blob().nullable()();
}

/// Sites (zones de pointage) de l'entreprise, pour le contrôle hors ligne.
@DataClassName('CachedSite')
class CachedSites extends Table {
  TextColumn get id => text()();
  TextColumn get tenantSlug => text()();
  TextColumn get name => text()();
  RealColumn get lat => real()();
  RealColumn get lng => real()();
  RealColumn get radiusM => real()();

  @override
  Set<Column> get primaryKey => {tenantSlug, id};
}

/// Vacations planifiées de l'agent (fenêtre hier → J+7).
@DataClassName('CachedShift')
class CachedShifts extends Table {
  TextColumn get assignmentId => text()();
  TextColumn get tenantSlug => text()();
  TextColumn get matricule => text()();
  TextColumn get shiftId => text()();
  DateTimeColumn get startsAt => dateTime()();
  DateTimeColumn get endsAt => dateTime()();
  TextColumn get siteId => text().nullable()();
  TextColumn get siteName => text().withDefault(const Constant(''))();
  TextColumn get postName => text().withDefault(const Constant(''))();

  /// titulaire | remplacant | renfort
  TextColumn get role => text().withDefault(const Constant('titulaire'))();

  /// planned | confirmed
  TextColumn get status => text().withDefault(const Constant('planned'))();

  @override
  Set<Column> get primaryKey => {tenantSlug, matricule, assignmentId};
}

/// Petites valeurs persistantes (dates de dernière sync, écart d'horloge…).
@DataClassName('MetaEntry')
class AppMeta extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

@DriftDatabase(tables: [Punches, CachedSites, CachedShifts, AppMeta])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(driftDatabase(name: 'zonik'));

  AppDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 3;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => m.createAll(),
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await m.addColumn(punches, punches.faceScore);
            await m.addColumn(punches, punches.faceMatch);
            await m.addColumn(punches, punches.photo);
          }
          if (from < 3) {
            // Aucune donnée existante n'est touchée : les pointages en
            // attente de la v1.1 restent en attente et partent normalement.
            await m.addColumn(punches, punches.tenantSlug);
            await m.addColumn(punches, punches.matricule);
            await m.addColumn(punches, punches.elapsedMs);
            await m.addColumn(punches, punches.bootCount);
            await m.addColumn(punches, punches.clockOffsetMs);
            await m.addColumn(punches, punches.fixAt);
            await m.addColumn(punches, punches.isMocked);
            await m.addColumn(punches, punches.siteId);
            await m.addColumn(punches, punches.siteName);
            await m.addColumn(punches, punches.distanceM);
            await m.addColumn(punches, punches.inZone);
            await m.addColumn(punches, punches.rejected);
            await m.addColumn(punches, punches.attempts);
            await m.addColumn(punches, punches.nextAttemptAt);
            await m.createTable(cachedSites);
            await m.createTable(cachedShifts);
            await m.createTable(appMeta);
          }
        },
        beforeOpen: (details) async {
          // Deux accès concurrents (UI + sync) : on attend le verrou au lieu
          // d'échouer immédiatement en « database is locked ».
          await customStatement('PRAGMA busy_timeout = 5000');
        },
      );

  // ---------------------------------------------------------------------------
  // Pointages
  // ---------------------------------------------------------------------------

  Future<int> insertPunch(PunchesCompanion punch) =>
      into(punches).insert(punch);

  Expression<bool> _ownedBy(Punches t, Owner o) =>
      t.tenantSlug.equals(o.tenantSlug) & t.matricule.equals(o.matricule);

  Expression<bool> _isPending(Punches t) =>
      t.synced.equals(false) & t.rejected.equals(false);

  /// Rattache les pointages hérités de la v2 (sans propriétaire) à l'agent
  /// connecté. Jusqu'à la v1.1 une seule session existait par téléphone.
  Future<int> adoptOrphans(Owner owner) {
    return (update(punches)..where((t) => t.tenantSlug.isNull())).write(
      PunchesCompanion(
        tenantSlug: Value(owner.tenantSlug),
        matricule: Value(owner.matricule),
      ),
    );
  }

  /// Pointages à envoyer pour [owner], du plus ancien au plus récent.
  /// Sans [ignoreBackoff], ceux dont la prochaine tentative n'est pas encore
  /// due sont exclus.
  Future<List<Punch>> pendingPunches(
    Owner owner, {
    bool ignoreBackoff = false,
  }) {
    final now = DateTime.now();
    final query = select(punches)
      ..where((t) {
        var cond = _isPending(t) & _ownedBy(t, owner);
        if (!ignoreBackoff) {
          cond = cond &
              (t.nextAttemptAt.isNull() |
                  t.nextAttemptAt.isSmallerOrEqualValue(now));
        }
        return cond;
      })
      ..orderBy([(t) => OrderingTerm.asc(t.punchedAt)]);
    return query.get();
  }

  Stream<int> watchPendingCount(Owner owner) {
    final count = punches.id.count();
    final query = selectOnly(punches)
      ..addColumns([count])
      ..where(_isPending(punches) & _ownedBy(punches, owner));
    return query.map((row) => row.read(count) ?? 0).watchSingle();
  }

  /// Nombre de pointages en attente appartenant à D'AUTRES agents sur ce
  /// téléphone (ils partiront à leur prochaine connexion).
  Stream<int> watchOthersPendingCount(Owner owner) {
    final count = punches.id.count();
    final query = selectOnly(punches)
      ..addColumns([count])
      ..where(_isPending(punches) & _ownedBy(punches, owner).not());
    return query.map((row) => row.read(count) ?? 0).watchSingle();
  }

  Stream<List<Punch>> watchRecent(Owner owner, {int limit = 30}) =>
      (select(punches)
            ..where((t) => _ownedBy(t, owner))
            ..orderBy([(t) => OrderingTerm.desc(t.punchedAt)])
            ..limit(limit))
          .watch();

  Future<Punch?> lastPunch(Owner owner) => (select(punches)
        ..where((t) => _ownedBy(t, owner))
        ..orderBy([(t) => OrderingTerm.desc(t.punchedAt)])
        ..limit(1))
      .getSingleOrNull();

  /// Accepté par le serveur (ou déjà connu) : on libère la photo, qui est
  /// désormais sur le serveur, pour ne pas remplir le téléphone.
  Future<void> markSynced(List<String> clientUuids) async {
    if (clientUuids.isEmpty) return;
    await (update(punches)..where((t) => t.clientUuid.isIn(clientUuids)))
        .write(PunchesCompanion(
      synced: const Value(true),
      syncedAt: Value(DateTime.now()),
      lastError: const Value(null),
      nextAttemptAt: const Value(null),
      photo: const Value(null),
    ));
  }

  Future<void> markRejected(String clientUuid, String reason) async {
    await (update(punches)..where((t) => t.clientUuid.equals(clientUuid)))
        .write(PunchesCompanion(
      rejected: const Value(true),
      lastError: Value(reason),
      nextAttemptAt: const Value(null),
    ));
  }

  /// Remet un pointage refusé dans la file (après correction côté serveur,
  /// par exemple un agent ou un site recréé dans le dashboard).
  Future<void> retryRejected(String clientUuid) async {
    await (update(punches)..where((t) => t.clientUuid.equals(clientUuid)))
        .write(const PunchesCompanion(
      rejected: Value(false),
      attempts: Value(0),
      nextAttemptAt: Value(null),
    ));
  }

  /// Échec temporaire (réseau, serveur) : +1 tentative et report.
  Future<void> markRetry(
    List<String> clientUuids,
    String error,
    DateTime nextAttemptAt,
  ) async {
    if (clientUuids.isEmpty) return;
    await (update(punches)..where((t) => t.clientUuid.isIn(clientUuids)))
        .write(PunchesCompanion.custom(
      attempts: punches.attempts + const Constant(1),
      lastError: Variable<String>(error),
      nextAttemptAt: Variable<DateTime>(nextAttemptAt),
    ));
  }

  /// Retire la photo d'un pointage (refusée par le serveur car trop lourde) :
  /// mieux vaut un pointage sans photo qu'un pointage perdu.
  Future<void> dropPhoto(String clientUuid) async {
    await (update(punches)..where((t) => t.clientUuid.equals(clientUuid)))
        .write(const PunchesCompanion(photo: Value(null)));
  }

  /// Ménage : historique synchronisé au-delà de la rétention, et photos
  /// encore présentes sur des pointages déjà synchronisés.
  Future<void> housekeeping(Duration retention) async {
    final limit = DateTime.now().subtract(retention);
    await (delete(punches)
          ..where((t) =>
              t.synced.equals(true) & t.punchedAt.isSmallerThanValue(limit)))
        .go();
    await (update(punches)
          ..where((t) => t.synced.equals(true) & t.photo.isNotNull()))
        .write(const PunchesCompanion(photo: Value(null)));
  }

  // ---------------------------------------------------------------------------
  // Sites
  // ---------------------------------------------------------------------------

  Future<void> replaceSites(String tenantSlug, List<CachedSitesCompanion> rows) {
    return transaction(() async {
      await (delete(cachedSites)..where((t) => t.tenantSlug.equals(tenantSlug)))
          .go();
      await batch((b) =>
          b.insertAll(cachedSites, rows, mode: InsertMode.insertOrReplace));
    });
  }

  /// Ajoute ou met à jour des sites sans effacer les autres (sites déduits
  /// des vacations, quand le serveur ne fournit pas la liste complète).
  Future<void> upsertSites(List<CachedSitesCompanion> rows) {
    if (rows.isEmpty) return Future.value();
    return batch((b) =>
        b.insertAll(cachedSites, rows, mode: InsertMode.insertOrReplace));
  }

  Future<List<CachedSite>> sitesFor(String tenantSlug) =>
      (select(cachedSites)..where((t) => t.tenantSlug.equals(tenantSlug)))
          .get();

  // ---------------------------------------------------------------------------
  // Vacations
  // ---------------------------------------------------------------------------

  /// Remplace les vacations de [owner] qui commencent dans [from, to[ par
  /// celles reçues du serveur (annulations comprises).
  Future<void> replaceShifts(
    Owner owner,
    DateTime from,
    DateTime to,
    List<CachedShiftsCompanion> rows,
  ) {
    return transaction(() async {
      await (delete(cachedShifts)
            ..where((t) =>
                t.tenantSlug.equals(owner.tenantSlug) &
                t.matricule.equals(owner.matricule) &
                t.endsAt.isBiggerThanValue(from) &
                t.startsAt.isSmallerThanValue(to)))
          .go();
      await batch(
          (b) => b.insertAll(cachedShifts, rows, mode: InsertMode.insertOrReplace));
    });
  }

  /// Vacations de [owner] qui chevauchent [from, to[.
  Stream<List<CachedShift>> watchShifts(
    Owner owner,
    DateTime from,
    DateTime to,
  ) {
    return (select(cachedShifts)
          ..where((t) =>
              t.tenantSlug.equals(owner.tenantSlug) &
              t.matricule.equals(owner.matricule) &
              t.endsAt.isBiggerThanValue(from) &
              t.startsAt.isSmallerThanValue(to))
          ..orderBy([(t) => OrderingTerm.asc(t.startsAt)]))
        .watch();
  }

  /// Vacation de [owner] en cours à l'instant [at], s'il y en a une.
  Future<CachedShift?> currentShift(Owner owner, DateTime at) {
    return (select(cachedShifts)
          ..where((t) =>
              t.tenantSlug.equals(owner.tenantSlug) &
              t.matricule.equals(owner.matricule) &
              t.startsAt.isSmallerOrEqualValue(at) &
              t.endsAt.isBiggerThanValue(at))
          ..orderBy([(t) => OrderingTerm.asc(t.startsAt)])
          ..limit(1))
        .getSingleOrNull();
  }

  /// Purge des vacations terminées depuis plus de [keep].
  Future<void> pruneShifts(Duration keep) {
    final limit = DateTime.now().subtract(keep);
    return (delete(cachedShifts)..where((t) => t.endsAt.isSmallerThanValue(limit)))
        .go();
  }

  // ---------------------------------------------------------------------------
  // Méta
  // ---------------------------------------------------------------------------

  Future<String?> getMeta(String key) async {
    final row = await (select(appMeta)..where((t) => t.key.equals(key)))
        .getSingleOrNull();
    return row?.value;
  }

  Stream<String?> watchMeta(String key) =>
      (select(appMeta)..where((t) => t.key.equals(key)))
          .watchSingleOrNull()
          .map((row) => row?.value);

  Future<void> setMeta(String key, String value) => into(appMeta)
      .insertOnConflictUpdate(AppMetaCompanion.insert(key: key, value: value));
}

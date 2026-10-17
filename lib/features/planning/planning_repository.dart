import 'package:drift/drift.dart' show Value;

import '../../core/api_client.dart';
import '../../core/config.dart';
import '../../data/database.dart';

/// Une vacation de l'agent (lue depuis le cache local).
class MyShift {
  const MyShift({
    required this.assignmentId,
    required this.shiftId,
    required this.startsAt,
    required this.endsAt,
    required this.siteName,
    required this.postName,
    required this.role,
    required this.status,
    this.siteId,
  });

  final String assignmentId;
  final String shiftId;
  final DateTime startsAt;
  final DateTime endsAt;
  final String? siteId;
  final String siteName;
  final String postName;

  /// titulaire | remplacant | renfort
  final String role;

  /// planned | confirmed
  final String status;

  bool get isNow {
    final now = DateTime.now();
    return !now.isBefore(startsAt) && now.isBefore(endsAt);
  }

  static MyShift fromRow(CachedShift r) => MyShift(
        assignmentId: r.assignmentId,
        shiftId: r.shiftId,
        startsAt: r.startsAt.toLocal(),
        endsAt: r.endsAt.toLocal(),
        siteId: r.siteId,
        siteName: r.siteName,
        postName: r.postName,
        role: r.role,
        status: r.status,
      );
}

/// Données de référence de l'agent (vacations, sites) téléchargées quand le
/// réseau est là et lues EXCLUSIVEMENT depuis le cache local par l'écran :
/// une semaine sans réseau, l'agent voit toujours où et quand il travaille,
/// et le pointage peut contrôler la zone.
///
/// Source : `GET /api/mobile/context` (vacations + sites en un appel). Tant
/// que le backend ne l'expose pas (404), repli sur
/// `GET /api/scheduling/me/shifts`, et les sites sont déduits des vacations
/// si elles contiennent leurs coordonnées.
class PlanningRepository {
  PlanningRepository({
    required this.db,
    required this.api,
    required this.ownerReader,
  });

  static const kContextFetchedAt = 'contextFetchedAt';

  final AppDatabase db;
  final ApiClient api;
  final Future<Owner?> Function() ownerReader;

  bool _refreshing = false;

  static String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// Vacations de [owner] qui chevauchent le jour [day] (minuit local).
  Stream<List<MyShift>> watchDay(Owner owner, DateTime day) {
    final from = DateTime(day.year, day.month, day.day);
    final to = from.add(const Duration(days: 1));
    return db
        .watchShifts(owner, from, to)
        .map((rows) => rows.map(MyShift.fromRow).toList());
  }

  /// Date du dernier téléchargement réussi pour [owner] (affichée hors ligne).
  Stream<DateTime?> watchFetchedAt(Owner owner) => db
      .watchMeta(_fetchedKey(owner))
      .map((v) => v == null ? null : DateTime.tryParse(v)?.toLocal());

  /// Télécharge vacations et sites si le cache a plus de
  /// [AppConfig.contextRefreshInterval] (ou toujours avec [force]).
  /// Retourne true si le cache a été mis à jour. Lève [ApiException] en cas
  /// d'échec — l'appelant l'ignore : le cache existant reste valable.
  Future<bool> refresh({bool force = false}) async {
    if (_refreshing) return false;
    // Posé AVANT tout await : deux déclenchements simultanés (connexion +
    // démarrage de l'écran) ne téléchargent qu'une fois.
    _refreshing = true;
    try {
      final owner = await ownerReader();
      if (owner == null) return false;

      if (!force) {
        final last =
            DateTime.tryParse(await db.getMeta(_fetchedKey(owner)) ?? '');
        if (last != null &&
            DateTime.now().difference(last) <
                AppConfig.contextRefreshInterval) {
          return false;
        }
      }

      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final from = today.subtract(const Duration(days: AppConfig.shiftsDaysBack));
      final to = today.add(const Duration(days: AppConfig.shiftsDaysAhead + 1));
      final range = 'from=${_ymd(from)}&to=${_ymd(to)}';

      List<dynamic> shiftsJson;
      List<dynamic>? sitesJson;
      try {
        final ctx = await api.get('/api/mobile/context?$range');
        shiftsJson = (ctx['shifts'] as List?) ?? const [];
        sitesJson = ctx['sites'] as List?;
      } on ApiException catch (e) {
        if (e.statusCode != 404) rethrow;
        // Backend sans /api/mobile/context : ancien endpoint.
        shiftsJson = await api.getList('/api/scheduling/me/shifts?$range');
      }

      final shifts = <CachedShiftsCompanion>[];
      final derivedSites = <String, CachedSitesCompanion>{};
      for (final j in shiftsJson.whereType<Map<String, dynamic>>()) {
        final row = _shiftFromJson(owner, j);
        if (row == null) continue;
        shifts.add(row);
        final site = _siteFromJson(owner.tenantSlug, {
          'id': j['site_id'] ?? j['siteId'],
          'name': j['site_name'] ?? j['siteName'],
          'lat': j['site_lat'] ?? j['siteLat'],
          'lng': j['site_lng'] ?? j['siteLng'],
          'radius_m': j['site_radius_m'] ?? j['siteRadiusM'],
        });
        if (site != null) derivedSites[site.id.value] = site;
      }

      await db.replaceShifts(owner, from, to, shifts);

      if (sitesJson != null) {
        // Liste complète fournie : elle remplace le cache (sites supprimés
        // ou rayons modifiés dans le dashboard pris en compte).
        final sites = sitesJson
            .whereType<Map<String, dynamic>>()
            .map((j) => _siteFromJson(owner.tenantSlug, j))
            .whereType<CachedSitesCompanion>()
            .toList();
        await db.replaceSites(owner.tenantSlug, sites);
      } else {
        await db.upsertSites(derivedSites.values.toList());
      }

      await db.setMeta(
          _fetchedKey(owner), DateTime.now().toUtc().toIso8601String());
      return true;
    } finally {
      _refreshing = false;
    }
  }

  /// Fraîcheur suivie par agent : un changement d'agent sur le téléphone
  /// déclenche un téléchargement immédiat.
  static String _fetchedKey(Owner o) =>
      '$kContextFetchedAt:${o.tenantSlug}:${o.matricule}';

  static CachedShiftsCompanion? _shiftFromJson(
    Owner owner,
    Map<String, dynamic> j,
  ) {
    final assignmentId = (j['assignment_id'] ?? j['assignmentId'])?.toString();
    final shiftId = (j['shift_id'] ?? j['shiftId'])?.toString();
    final startsAt =
        DateTime.tryParse((j['starts_at'] ?? j['startsAt'] ?? '').toString());
    final endsAt =
        DateTime.tryParse((j['ends_at'] ?? j['endsAt'] ?? '').toString());
    if (assignmentId == null || startsAt == null || endsAt == null) {
      return null;
    }
    final siteId = (j['site_id'] ?? j['siteId'])?.toString();
    return CachedShiftsCompanion.insert(
      assignmentId: assignmentId,
      tenantSlug: owner.tenantSlug,
      matricule: owner.matricule,
      shiftId: shiftId ?? assignmentId,
      startsAt: startsAt,
      endsAt: endsAt,
      siteId: Value(siteId),
      siteName: Value((j['site_name'] ?? j['siteName'] ?? '').toString()),
      postName: Value((j['post_name'] ?? j['postName'] ?? '').toString()),
      role: Value((j['role'] ?? 'titulaire').toString()),
      status: Value((j['status'] ?? 'planned').toString()),
    );
  }

  static CachedSitesCompanion? _siteFromJson(
    String tenantSlug,
    Map<String, dynamic> j,
  ) {
    final id = j['id']?.toString();
    final lat = _num(j['lat'] ?? j['latitude']);
    final lng = _num(j['lng'] ?? j['longitude'] ?? j['lon']);
    final radius = _num(j['radius_m'] ?? j['radiusM'] ?? j['radius']);
    if (id == null || lat == null || lng == null) return null;
    return CachedSitesCompanion.insert(
      id: id,
      tenantSlug: tenantSlug,
      name: (j['name'] ?? '').toString(),
      lat: lat,
      lng: lng,
      radiusM: radius ?? 150,
    );
  }

  /// PostgreSQL renvoie souvent les numeric en chaînes : on accepte les deux.
  static double? _num(Object? v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }
}

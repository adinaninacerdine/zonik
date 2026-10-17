import 'package:drift/drift.dart';
import 'package:geolocator/geolocator.dart';
import 'package:uuid/uuid.dart';

import '../../core/device_clock.dart';
import '../../data/database.dart';
import 'geofence.dart';

/// Ce que l'écran affiche après un pointage.
class PunchReceipt {
  const PunchReceipt({required this.clientUuid, required this.zone});

  final String clientUuid;
  final ZoneCheck zone;
}

/// Création des pointages. Écrit TOUJOURS en local, sans jamais attendre le
/// réseau : l'envoi est l'affaire du moteur de synchronisation.
class PunchRepository {
  PunchRepository({required this.db});

  /// Clé méta : écart (ms) horloge serveur − horloge téléphone mesuré à la
  /// dernière synchronisation réussie.
  static const kServerOffsetMs = 'serverOffsetMs';

  final AppDatabase db;
  final _uuid = const Uuid();

  Future<PunchReceipt> punch({
    required Owner owner,
    required String type, // 'in' | 'out'
    required Position position,
    double? faceScore,
    bool? faceMatch,
    Uint8List? photoJpeg,
  }) async {
    final clock = await DeviceClock.sample();
    final offset = int.tryParse(await db.getMeta(kServerOffsetMs) ?? '');

    // Contrôle de zone local, sur le site de la vacation en cours s'il y en a
    // une, sinon sur le site le plus proche. Indicatif : le serveur tranche.
    final sites = await db.sitesFor(owner.tenantSlug);
    final shift = await db.currentShift(owner, clock.wallClock);
    final zone = checkZone(
      sites: sites,
      lat: position.latitude,
      lng: position.longitude,
      accuracy: position.accuracy,
      expectedSiteId: shift?.siteId,
    );

    final clientUuid = _uuid.v4();
    await db.insertPunch(PunchesCompanion.insert(
      clientUuid: clientUuid,
      tenantSlug: Value(owner.tenantSlug),
      matricule: Value(owner.matricule),
      type: type,
      lat: position.latitude,
      lng: position.longitude,
      accuracy: Value(position.accuracy),
      punchedAt: clock.wallClock,
      elapsedMs: Value(clock.elapsedMs),
      bootCount: Value(clock.bootCount),
      clockOffsetMs: Value(offset),
      fixAt: Value(position.timestamp),
      isMocked: Value(position.isMocked),
      siteId: Value(zone.site?.id),
      siteName: Value(zone.site?.name),
      distanceM: Value(zone.distanceM),
      inZone: Value(zone.inZone),
      faceScore: Value(faceScore),
      faceMatch: Value(faceMatch),
      photo: Value(photoJpeg),
    ));

    return PunchReceipt(clientUuid: clientUuid, zone: zone);
  }
}

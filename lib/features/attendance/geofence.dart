import 'dart:math' as math;

import '../../core/config.dart';
import '../../data/database.dart';

/// Résultat du contrôle de zone fait sur le téléphone.
class ZoneCheck {
  const ZoneCheck({this.site, this.distanceM, this.inZone});

  /// Aucun site en cache : contrôle impossible hors ligne.
  static const unknown = ZoneCheck();

  /// Site retenu (celui de la vacation en cours, sinon le plus proche).
  final CachedSite? site;
  final double? distanceM;
  final bool? inZone;

  bool get isKnown => inZone != null;
}

/// Distance en mètres entre deux points (haversine) — précision largement
/// suffisante pour des rayons de 50 à 500 m.
double distanceMeters(double lat1, double lng1, double lat2, double lng2) {
  const earthRadius = 6371000.0;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(lat2 - lat1);
  final dLng = rad(lng2 - lng1);
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(rad(lat1)) *
          math.cos(rad(lat2)) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  return 2 * earthRadius * math.asin(math.min(1, math.sqrt(a)));
}

/// Contrôle de zone. Si [expectedSiteId] (site de la vacation en cours) est
/// en cache, c'est lui qui est jugé ; sinon le site le plus proche.
/// L'imprécision GPS est tolérée jusqu'à
/// [AppConfig.geofenceMaxAccuracyAllowance] mètres.
ZoneCheck checkZone({
  required List<CachedSite> sites,
  required double lat,
  required double lng,
  double? accuracy,
  String? expectedSiteId,
}) {
  if (sites.isEmpty) return ZoneCheck.unknown;

  CachedSite? target;
  double? targetDistance;

  if (expectedSiteId != null) {
    for (final s in sites) {
      if (s.id == expectedSiteId) {
        target = s;
        targetDistance = distanceMeters(lat, lng, s.lat, s.lng);
        break;
      }
    }
  }

  if (target == null) {
    for (final s in sites) {
      final d = distanceMeters(lat, lng, s.lat, s.lng);
      if (targetDistance == null || d < targetDistance) {
        target = s;
        targetDistance = d;
      }
    }
  }

  final allowance = math.min(
    accuracy ?? 0,
    AppConfig.geofenceMaxAccuracyAllowance,
  );
  return ZoneCheck(
    site: target,
    distanceM: targetDistance,
    inZone: targetDistance! <= target!.radiusM + allowance,
  );
}

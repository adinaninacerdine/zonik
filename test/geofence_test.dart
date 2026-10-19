import 'package:flutter_test/flutter_test.dart';
import 'package:zonik/data/database.dart';
import 'package:zonik/features/attendance/geofence.dart';

const siege = CachedSite(
  id: 's1',
  tenantSlug: 'demo',
  name: 'Siège Moroni',
  lat: -11.7022,
  lng: 43.2551,
  radiusM: 150,
);

const port = CachedSite(
  id: 's2',
  tenantSlug: 'demo',
  name: 'Port de Moroni',
  lat: -11.7046,
  lng: 43.2465,
  radiusM: 100,
);

void main() {
  test('distance haversine cohérente (~1 km)', () {
    final d = distanceMeters(-11.7022, 43.2551, -11.7112, 43.2551);
    expect(d, closeTo(1000, 5));
  });

  test('sans site en cache, la zone est inconnue', () {
    final z = checkZone(sites: const [], lat: -11.7, lng: 43.25);
    expect(z.isKnown, isFalse);
  });

  test('dans le rayon du site le plus proche', () {
    final z = checkZone(
      sites: const [siege, port],
      lat: -11.7030,
      lng: 43.2555,
      accuracy: 10,
    );
    expect(z.site!.id, 's1');
    expect(z.inZone, isTrue);
  });

  test('hors zone au-delà du rayon + tolérance GPS plafonnée', () {
    // ~300 m du siège, précision annoncée 400 m : tolérance plafonnée à 50 m.
    final z = checkZone(
      sites: const [siege],
      lat: -11.7049,
      lng: 43.2551,
      accuracy: 400,
    );
    expect(z.inZone, isFalse);
    expect(z.distanceM, closeTo(300, 10));
  });

  test('le site de la vacation en cours prime sur le plus proche', () {
    final z = checkZone(
      sites: const [siege, port],
      lat: -11.7030,
      lng: 43.2555,
      expectedSiteId: 's2',
    );
    expect(z.site!.id, 's2');
    expect(z.inZone, isFalse);
  });

  test('site de la vacation non localisé : pas de verdict', () {
    final z = checkZone(
      sites: const [siege, port],
      lat: -11.7200,
      lng: 43.2700,
      expectedSiteId: 'site-sans-position',
    );
    expect(z.isKnown, isFalse);
  });

  test('site de la vacation non localisé mais agent dans un site connu', () {
    final z = checkZone(
      sites: const [siege, port],
      lat: -11.7030,
      lng: 43.2555,
      expectedSiteId: 'site-sans-position',
    );
    expect(z.site!.id, 's1');
    expect(z.inZone, isTrue);
  });
}

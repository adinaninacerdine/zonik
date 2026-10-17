import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zonik/core/api_client.dart';
import 'package:zonik/data/database.dart';
import 'package:zonik/features/attendance/sync_service.dart';

const agent = Owner('demo', 'EMP001');
const otherAgent = Owner('demo', 'EMP002');

/// Requêtes /sync reçues par le faux serveur (liste des clientUuid par lot).
final batches = <List<String>>[];

List<String> _uuidsOf(http.Request r) {
  final body = jsonDecode(r.body) as Map<String, dynamic>;
  return [
    for (final p in body['punches'] as List)
      (p as Map<String, dynamic>)['clientUuid'] as String,
  ];
}

http.Response _json(Object body, [int status = 200, Map<String, String>? headers]) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json', ...?headers});

Future<void> _addPunch(
  AppDatabase db,
  String uuid, {
  Owner owner = agent,
  int minute = 0,
  int photoBytes = 0,
}) {
  return db.insertPunch(PunchesCompanion.insert(
    clientUuid: uuid,
    tenantSlug: Value(owner.tenantSlug),
    matricule: Value(owner.matricule),
    type: 'in',
    lat: -11.7022,
    lng: 43.2551,
    punchedAt: DateTime(2026, 10, 17, 8).add(Duration(minutes: minute)),
    photo: Value(photoBytes > 0 ? Uint8List(photoBytes) : null),
  ));
}

SyncEngine _engine(AppDatabase db, MockClient client) => SyncEngine(
      db: db,
      api: ApiClient(tokenReader: () async => 'token', client: client),
      ownerReader: () async => agent,
    );

Future<Punch> _get(AppDatabase db, String uuid) =>
    (db.select(db.punches)..where((t) => t.clientUuid.equals(uuid)))
        .getSingle();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    batches.clear();
  });

  tearDown(() => db.close());

  test('envoie par lots de 10, uniquement les pointages de l\'agent connecté',
      () async {
    for (var i = 0; i < 25; i++) {
      await _addPunch(db, 'a$i', minute: i);
    }
    await _addPunch(db, 'autre', owner: otherAgent);

    final engine = _engine(db, MockClient((r) async {
      batches.add(_uuidsOf(r));
      return _json({'ok': true});
    }));
    await engine.sync();

    expect(batches.map((b) => b.length), [10, 10, 5]);
    expect(batches.expand((b) => b), isNot(contains('autre')));
    expect(await db.pendingPunches(agent), isEmpty);
    expect((await _get(db, 'autre')).synced, isFalse);
  });

  test('un lot refusé est coupé en deux : seul le pointage fautif est refusé',
      () async {
    for (var i = 0; i < 6; i++) {
      await _addPunch(db, i == 3 ? 'poison' : 'p$i', minute: i);
    }
    final engine = _engine(db, MockClient((r) async {
      final ids = _uuidsOf(r);
      batches.add(ids);
      if (ids.contains('poison')) {
        return _json({'message': 'Type de pointage invalide'}, 400);
      }
      return _json({'ok': true});
    }));
    await engine.sync();

    final poison = await _get(db, 'poison');
    expect(poison.rejected, isTrue);
    expect(poison.lastError, 'Type de pointage invalide');
    for (final id in ['p0', 'p1', 'p2', 'p4', 'p5']) {
      expect((await _get(db, id)).synced, isTrue, reason: id);
    }
  });

  test('panne réseau : backoff, puis renvoi forcé par le bouton', () async {
    await _addPunch(db, 'x');
    var online = false;
    final engine = _engine(db, MockClient((r) async {
      batches.add(_uuidsOf(r));
      if (!online) throw const SocketException('pas de réseau');
      return _json({'ok': true});
    }));

    await engine.sync();
    var p = await _get(db, 'x');
    expect(p.synced, isFalse);
    expect(p.attempts, 1);
    expect(p.nextAttemptAt!.isAfter(DateTime.now()), isTrue);
    expect(engine.state.lastError, isNotNull);

    // Réveil périodique : le backoff n'est pas écoulé, rien n'est envoyé.
    online = true;
    await engine.sync();
    expect(batches.length, 1);

    // Bouton « Envoyer » : on ignore le backoff.
    await engine.sync(force: true);
    p = await _get(db, 'x');
    expect(p.synced, isTrue);
    expect(engine.state.lastError, isNull);
  });

  test('401 : sync suspendue, pointages intacts', () async {
    await _addPunch(db, 'y');
    final engine = _engine(db, MockClient((r) async {
      batches.add(_uuidsOf(r));
      return _json({'message': 'Token expiré'}, 401);
    }));

    await engine.sync();
    expect(engine.state.needsReauth, isTrue);
    final p = await _get(db, 'y');
    expect(p.synced, isFalse);
    expect(p.rejected, isFalse);
    expect(p.attempts, 0);

    // Tant que l'agent ne s'est pas reconnecté, la minuterie n'insiste pas.
    await engine.sync();
    expect(batches.length, 1);
  });

  test('résultats par pointage renvoyés par le serveur', () async {
    await _addPunch(db, 'ok1', minute: 0);
    await _addPunch(db, 'ko', minute: 1);
    await _addPunch(db, 'dup', minute: 2);
    final engine = _engine(db, MockClient((r) async => _json({
          'results': [
            {'clientUuid': 'ok1', 'status': 'accepted'},
            {'clientUuid': 'ko', 'status': 'rejected', 'reason': 'Agent inconnu'},
            {'clientUuid': 'dup', 'status': 'duplicate'},
          ],
        })));
    await engine.sync();

    expect((await _get(db, 'ok1')).synced, isTrue);
    expect((await _get(db, 'dup')).synced, isTrue);
    final ko = await _get(db, 'ko');
    expect(ko.rejected, isTrue);
    expect(ko.lastError, 'Agent inconnu');
  });

  test('413 : la photo est retirée, le pointage passe quand même', () async {
    await _addPunch(db, 'lourd', photoBytes: 4000);
    final engine = _engine(db, MockClient((r) async {
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      final payload = ((body['punches'] as List).single
          as Map<String, dynamic>)['payload'] as Map<String, dynamic>;
      if (payload.containsKey('photo')) return _json({}, 413);
      return _json({'ok': true});
    }));
    await engine.sync();

    final p = await _get(db, 'lourd');
    expect(p.synced, isTrue);
    expect(p.photo, isNull);
  });

  test('la photo est effacée du téléphone après envoi', () async {
    await _addPunch(db, 'photo', photoBytes: 2000);
    final engine = _engine(db, MockClient((r) async => _json({'ok': true})));
    await engine.sync();
    expect((await _get(db, 'photo')).photo, isNull);
  });

  test('l\'en-tête Date mesure le décalage d\'horloge du téléphone', () async {
    await _addPunch(db, 'z');
    final serverNow = DateTime.now().add(const Duration(minutes: 42));
    final engine = _engine(
      db,
      MockClient((r) async =>
          _json({'ok': true}, 200, {'date': HttpDate.format(serverNow)})),
    );
    await engine.sync();
    expect(engine.state.clockOffset!.inMinutes, inInclusiveRange(41, 42));
  });

  test('les pointages de la v1.1 sans propriétaire sont rattachés à l\'agent',
      () async {
    await db.insertPunch(PunchesCompanion.insert(
      clientUuid: 'ancien',
      type: 'out',
      lat: -11.7,
      lng: 43.2,
      punchedAt: DateTime(2026, 10, 1),
    ));
    final engine = _engine(db, MockClient((r) async {
      batches.add(_uuidsOf(r));
      return _json({'ok': true});
    }));
    await engine.sync();
    expect(batches.single, ['ancien']);
    expect((await _get(db, 'ancien')).matricule, 'EMP001');
  });
}

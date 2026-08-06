import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../core/api_client.dart';
import '../../data/database.dart';

enum PunchOutcome {
  /// Enregistré localement ET synchronisé avec le serveur.
  synced,

  /// Enregistré localement, la sync se fera plus tard (offline).
  savedLocally,
}

class PunchRepository {
  PunchRepository({required this.db, required this.api});

  final AppDatabase db;
  final ApiClient api;
  final _uuid = const Uuid();

  bool _syncing = false;

  /// Écrit TOUJOURS en local d'abord — le pointage ne dépend jamais du réseau.
  Future<PunchOutcome> punch({
    required String type, // 'in' | 'out'
    required double lat,
    required double lng,
    double? accuracy,
    double? faceScore,
    bool? faceMatch,
    Uint8List? photoJpeg,
  }) async {
    await db.insertPunch(PunchesCompanion.insert(
      clientUuid: _uuid.v4(),
      type: type,
      lat: lat,
      lng: lng,
      accuracy: Value(accuracy),
      punchedAt: DateTime.now(),
      faceScore: Value(faceScore),
      faceMatch: Value(faceMatch),
      photo: Value(photoJpeg),
    ));

    final synced = await trySync();
    return synced ? PunchOutcome.synced : PunchOutcome.savedLocally;
  }

  /// Envoie tous les pointages en attente via /api/attendance/sync
  /// (dédup serveur par clientUuid — un renvoi n'est jamais un doublon).
  /// Retourne true si plus rien n'est en attente.
  Future<bool> trySync() async {
    if (_syncing) return false;
    _syncing = true;
    try {
      final pending = await db.pendingPunches();
      if (pending.isEmpty) return true;

      final uuids = pending.map((p) => p.clientUuid).toList();
      try {
        await api.post('/api/attendance/sync', {
          'punches': [
            for (final p in pending)
              {
                'clientUuid': p.clientUuid,
                'type': p.type,
                'method': 'gps',
                'punchedAt': p.punchedAt.toUtc().toIso8601String(),
                'payload': {
                  'lat': p.lat,
                  'lng': p.lng,
                  if (p.accuracy != null) 'accuracy': p.accuracy,
                  if (p.faceScore != null) 'faceScore': p.faceScore,
                  if (p.faceMatch != null) 'faceMatch': p.faceMatch,
                  if (p.photo != null) 'photo': base64Encode(p.photo!),
                },
              },
          ],
        });
        await db.markSynced(uuids);
        return true;
      } on ApiException catch (e) {
        await db.markSyncError(uuids, e.message);
        return false;
      } catch (e) {
        await db.markSyncError(uuids, e.toString());
        return false;
      }
    } finally {
      _syncing = false;
    }
  }
}

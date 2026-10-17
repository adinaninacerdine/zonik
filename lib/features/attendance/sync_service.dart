import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:drift/drift.dart' show Value;

import '../../core/api_client.dart';
import '../../core/config.dart';
import '../../core/device_clock.dart';
import '../../data/database.dart';
import '../planning/planning_repository.dart';
import 'punch_repository.dart';

/// État visible de la synchronisation (bandeau de l'écran d'accueil).
class SyncState {
  const SyncState({
    this.running = false,
    this.lastSuccessAt,
    this.lastError,
    this.needsReauth = false,
    this.clockOffset,
  });

  final bool running;

  /// Dernier échange réussi avec le serveur.
  final DateTime? lastSuccessAt;

  /// Dernière erreur temporaire (réseau, serveur), effacée au succès suivant.
  final String? lastError;

  /// Le serveur a refusé le token (401) : l'agent doit se reconnecter pour
  /// que ses pointages partent. Ils restent en sécurité sur le téléphone.
  final bool needsReauth;

  /// Horloge serveur − horloge téléphone (mesurée à la dernière sync).
  final Duration? clockOffset;

  SyncState copyWith({
    bool? running,
    DateTime? lastSuccessAt,
    String? lastError,
    bool clearError = false,
    bool? needsReauth,
    Duration? clockOffset,
  }) =>
      SyncState(
        running: running ?? this.running,
        lastSuccessAt: lastSuccessAt ?? this.lastSuccessAt,
        lastError: clearError ? null : (lastError ?? this.lastError),
        needsReauth: needsReauth ?? this.needsReauth,
        clockOffset: clockOffset ?? this.clockOffset,
      );
}

enum _Outcome {
  /// Tous les pointages du lot sont réglés (acceptés ou refusés).
  progress,

  /// Échec temporaire ou session expirée : on arrête là pour cette fois.
  stop,
}

/// Moteur d'envoi des pointages.
///
/// - n'envoie que les pointages de l'agent connecté, avec SON token ;
/// - par petits lots (nombre et poids des photos plafonnés), avec un délai
///   adapté au nombre de photos ;
/// - échec réseau/serveur → backoff exponentiel par pointage ;
/// - refus serveur (4xx) d'un lot → lot coupé en deux jusqu'à isoler le
///   pointage fautif, seul celui-ci est marqué refusé ;
/// - 413 sur un pointage seul → renvoi sans la photo plutôt que de le perdre ;
/// - 401 → sync suspendue jusqu'à reconnexion, rien n'est perdu ;
/// - chaque réponse mesure le décalage d'horloge du téléphone.
class SyncEngine {
  SyncEngine({
    required this.db,
    required this.api,
    required this.ownerReader,
  });

  static const kLastSuccessAt = 'lastSyncAt';

  final AppDatabase db;
  final ApiClient api;

  /// Agent connecté (token présent), null sinon.
  final Future<Owner?> Function() ownerReader;

  final _states = StreamController<SyncState>.broadcast();
  final _random = math.Random();
  SyncState _state = const SyncState();

  bool _running = false;
  bool _again = false;
  bool _againForced = false;

  SyncState get state => _state;
  Stream<SyncState> get states => _states.stream;

  void _emit(SyncState s) {
    _state = s;
    if (!_states.isClosed) _states.add(s);
  }

  /// Recharge l'état persistant (dernière sync, écart d'horloge).
  Future<void> init() async {
    final last = DateTime.tryParse(await db.getMeta(kLastSuccessAt) ?? '');
    final offset =
        int.tryParse(await db.getMeta(PunchRepository.kServerOffsetMs) ?? '');
    _emit(_state.copyWith(
      lastSuccessAt: last?.toLocal(),
      clockOffset: offset == null ? null : Duration(milliseconds: offset),
    ));
  }

  /// Après une reconnexion réussie : la sync reprend.
  void onReauthenticated() {
    _emit(_state.copyWith(needsReauth: false, clearError: true));
  }

  /// Lance une synchronisation. [force] (bouton « Synchroniser ») ignore le
  /// backoff. Un appel pendant une sync en cours est mémorisé et rejoué
  /// juste après : un pointage fait pendant l'envoi part sans attendre.
  Future<void> sync({bool force = false}) async {
    if (_running) {
      _again = true;
      _againForced = _againForced || force;
      return;
    }
    if (_state.needsReauth && !force) return;

    _running = true;
    _emit(_state.copyWith(running: true));
    try {
      var forced = force;
      do {
        _again = false;
        await _drain(forced: forced);
        forced = _againForced;
        _againForced = false;
      } while (_again && !_state.needsReauth);
    } finally {
      _running = false;
      _emit(_state.copyWith(running: false));
    }
  }

  Future<void> _drain({required bool forced}) async {
    final owner = await ownerReader();
    if (owner == null) return;

    // Lignes de la v1.1 sans propriétaire : elles appartiennent à l'agent
    // qui utilisait le téléphone, donc à la session courante.
    await db.adoptOrphans(owner);

    // Garde-fou : un pointage n'est tenté qu'une fois par passe, quoi qu'il
    // arrive (évite toute boucle si le serveur répond de façon inattendue).
    final tried = <String>{};
    while (true) {
      final pending = (await db.pendingPunches(owner, ignoreBackoff: forced))
          .where((p) => !tried.contains(p.clientUuid))
          .toList();
      if (pending.isEmpty) return;

      final batch = _takeBatch(pending);
      tried.addAll(batch.map((p) => p.clientUuid));
      final outcome = await _send(batch);
      if (outcome == _Outcome.stop) return;
    }
  }

  /// Premier lot : au plus N pointages et un poids de photos plafonné
  /// (toujours au moins un pointage, même avec une grosse photo).
  List<Punch> _takeBatch(List<Punch> pending) {
    final batch = <Punch>[];
    var bytes = 0;
    for (final p in pending) {
      final size = p.photo?.length ?? 0;
      if (batch.isNotEmpty &&
          (batch.length >= AppConfig.syncBatchMaxItems ||
              bytes + size > AppConfig.syncBatchMaxPhotoBytes)) {
        break;
      }
      batch.add(p);
      bytes += size;
    }
    return batch;
  }

  Duration _timeoutFor(List<Punch> batch) {
    final photos = batch.where((p) => p.photo != null).length;
    final t = AppConfig.syncBaseTimeout + AppConfig.syncTimeoutPerPhoto * photos;
    return t > AppConfig.syncMaxTimeout ? AppConfig.syncMaxTimeout : t;
  }

  Future<_Outcome> _send(List<Punch> batch) async {
    final clock = await DeviceClock.sample();
    final sentAt = DateTime.now();

    try {
      final res = await api.send(
        'POST',
        '/api/attendance/sync',
        body: {'punches': [for (final p in batch) _toJson(p, clock)]},
        timeout: _timeoutFor(batch),
      );
      await _recordServerTime(res.serverDate, sentAt, DateTime.now());
      await _applyResults(batch, res.json);
      final now = DateTime.now();
      await db.setMeta(kLastSuccessAt, now.toUtc().toIso8601String());
      _emit(_state.copyWith(
        lastSuccessAt: now,
        clearError: true,
        needsReauth: false,
      ));
      return _Outcome.progress;
    } on ApiException catch (e) {
      if (e.isUnauthorized) {
        _emit(_state.copyWith(needsReauth: true, lastError: e.message));
        return _Outcome.stop;
      }

      if (e.isPermanent) {
        // Lot refusé : on le coupe en deux pour isoler le pointage fautif.
        if (batch.length > 1) {
          final mid = batch.length ~/ 2;
          for (final half in [batch.sublist(0, mid), batch.sublist(mid)]) {
            if (await _send(half) == _Outcome.stop) return _Outcome.stop;
          }
          return _Outcome.progress;
        }

        final p = batch.single;
        if (e.statusCode == 413 && p.photo != null) {
          // Photo trop lourde pour le serveur : le pointage passe sans.
          await db.dropPhoto(p.clientUuid);
          return _send([p.copyWith(photo: const Value(null))]);
        }
        await db.markRejected(p.clientUuid, e.message);
        return _Outcome.progress;
      }

      await _scheduleRetry(batch, e.message);
      _emit(_state.copyWith(lastError: e.message));
      return _Outcome.stop;
    } catch (e) {
      await _scheduleRetry(batch, e.toString());
      _emit(_state.copyWith(lastError: 'Erreur inattendue : $e'));
      return _Outcome.stop;
    }
  }

  /// Corps d'un pointage. Les champs historiques (clientUuid, type, method,
  /// punchedAt, payload.lat/lng…) sont inchangés ; tout ce qui est nouveau
  /// est rangé dans le payload, que le backend accepte déjà librement.
  Map<String, dynamic> _toJson(Punch p, ClockSample sent) => {
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
          'device': {
            if (p.elapsedMs != null) 'elapsedMs': p.elapsedMs,
            if (p.bootCount != null) 'bootCount': p.bootCount,
            if (p.clockOffsetMs != null) 'clockOffsetMs': p.clockOffsetMs,
            'sentAt': sent.wallClock.toUtc().toIso8601String(),
            if (sent.elapsedMs != null) 'sentElapsedMs': sent.elapsedMs,
            if (sent.bootCount != null) 'sentBootCount': sent.bootCount,
            if (sent.autoTime != null) 'autoTime': sent.autoTime,
            'attempt': p.attempts + 1,
          },
          'gps': {
            if (p.fixAt != null) 'fixAt': p.fixAt!.toUtc().toIso8601String(),
            if (p.isMocked != null) 'isMocked': p.isMocked,
          },
          if (p.inZone != null)
            'zone': {
              'siteId': p.siteId,
              'distanceM': p.distanceM?.round(),
              'inZone': p.inZone,
            },
        },
      };

  /// Réponse par pointage si le serveur la fournit
  /// (`results: [{clientUuid, status, reason}]`), sinon tout le lot est
  /// considéré accepté (comportement du backend actuel).
  Future<void> _applyResults(List<Punch> batch, Map<String, dynamic> json) async {
    final results = json['results'];
    if (results is! List) {
      await db.markSynced(batch.map((p) => p.clientUuid).toList());
      return;
    }

    final byUuid = <String, Map>{};
    for (final r in results.whereType<Map>()) {
      final id = (r['clientUuid'] ?? r['client_uuid'])?.toString();
      if (id != null) byUuid[id] = r;
    }

    const refused = {'rejected', 'refused', 'invalid', 'error'};
    final accepted = <String>[];
    for (final p in batch) {
      final r = byUuid[p.clientUuid];
      final status = (r?['status'] ?? '').toString().toLowerCase();
      if (r != null && refused.contains(status)) {
        final reason =
            (r['reason'] ?? r['message'] ?? r['error'] ?? 'Refusé par le serveur')
                .toString();
        await db.markRejected(p.clientUuid, reason);
      } else {
        accepted.add(p.clientUuid);
      }
    }
    await db.markSynced(accepted);
  }

  Future<void> _scheduleRetry(List<Punch> batch, String error) async {
    final attempts = batch.map((p) => p.attempts).reduce(math.min);
    final base = AppConfig.syncBackoffBase.inMilliseconds;
    final max = AppConfig.syncBackoffMax.inMilliseconds;
    final delay = math.min(max, base * math.pow(2, math.min(attempts, 12)).toInt());
    // ±20 % d'aléa : 80 agents qui retrouvent le réseau en même temps ne
    // frappent pas le serveur à la même seconde.
    final jitter = (delay * 0.2 * (_random.nextDouble() * 2 - 1)).round();
    await db.markRetry(
      batch.map((p) => p.clientUuid).toList(),
      error,
      DateTime.now().add(Duration(milliseconds: delay + jitter)),
    );
  }

  Future<void> _recordServerTime(
    DateTime? serverDate,
    DateTime sentAt,
    DateTime receivedAt,
  ) async {
    if (serverDate == null) return;
    final midpoint = sentAt.add(receivedAt.difference(sentAt) ~/ 2);
    final offset = serverDate.difference(midpoint);
    await db.setMeta(
      PunchRepository.kServerOffsetMs,
      offset.inMilliseconds.toString(),
    );
    _emit(_state.copyWith(clockOffset: offset));
  }

  void dispose() => _states.close();
}

/// Déclencheurs : retour du réseau, réveil périodique, retour au premier
/// plan (appelé par l'écran), et ménage au démarrage. Le pointage lui-même
/// n'attend jamais ce service.
class SyncService {
  SyncService({required this.engine, required this.planning}) {
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      final online = results.any((r) => r != ConnectivityResult.none);
      if (online) kick();
    });
    _timer = Timer.periodic(AppConfig.syncInterval, (_) => kick());
  }

  final SyncEngine engine;
  final PlanningRepository planning;
  late final StreamSubscription<List<ConnectivityResult>> _connectivitySub;
  late final Timer _timer;

  /// Au lancement : état persistant, ménage, puis première sync.
  Future<void> start() async {
    await engine.init();
    await engine.db.housekeeping(AppConfig.punchRetention);
    await engine.db.pruneShifts(const Duration(days: 2));
    kick();
  }

  /// Envoi des pointages + rafraîchissement du cache si nécessaire.
  /// Ne lève jamais d'exception.
  void kick({bool force = false}) {
    unawaited(engine.sync(force: force));
    unawaited(planning.refresh(force: force).then((_) {}, onError: (_) {}));
  }

  void dispose() {
    _connectivitySub.cancel();
    _timer.cancel();
  }
}

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

import '../../core/config.dart';
import 'punch_repository.dart';

/// Relance la synchronisation quand le réseau revient, et périodiquement
/// en filet de sécurité. Le pointage lui-même n'attend jamais ce service.
class SyncService {
  SyncService({required this.repository}) {
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      final online = results.any((r) => r != ConnectivityResult.none);
      if (online) repository.trySync();
    });
    _timer = Timer.periodic(AppConfig.syncInterval, (_) {
      repository.trySync();
    });
  }

  final PunchRepository repository;
  late final StreamSubscription<List<ConnectivityResult>> _connectivitySub;
  late final Timer _timer;

  void dispose() {
    _connectivitySub.cancel();
    _timer.cancel();
  }
}

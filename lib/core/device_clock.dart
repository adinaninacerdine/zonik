import 'package:flutter/services.dart';

/// Relevé de l'horloge du téléphone à un instant donné.
class ClockSample {
  const ClockSample({
    required this.wallClock,
    this.elapsedMs,
    this.bootCount,
    this.autoTime,
  });

  /// Heure système (modifiable par l'utilisateur).
  final DateTime wallClock;

  /// ms depuis le démarrage du téléphone (monotone, non modifiable).
  final int? elapsedMs;

  /// Numéro de démarrage : deux relevés ne sont comparables que s'ils
  /// partagent le même [bootCount].
  final int? bootCount;

  /// Heure automatique activée dans les réglages (null si inconnu).
  final bool? autoTime;
}

/// Accès à l'horloge monotone Android via le canal natif de MainActivity.
/// Ne lève jamais d'exception : sans canal (tests, autre plateforme), seuls
/// les champs fiables manquent et le pointage se fait quand même.
class DeviceClock {
  DeviceClock._();

  static const _channel = MethodChannel('com.zonik.pointage/clock');

  static Future<ClockSample> sample() async {
    final now = DateTime.now();
    try {
      final map = await _channel.invokeMapMethod<String, dynamic>('sample');
      if (map == null) return ClockSample(wallClock: now);
      final boot = (map['bootCount'] as num?)?.toInt();
      final auto = (map['autoTime'] as num?)?.toInt();
      return ClockSample(
        wallClock: now,
        elapsedMs: (map['elapsedRealtimeMs'] as num?)?.toInt(),
        bootCount: (boot == null || boot < 0) ? null : boot,
        autoTime: (auto == null || auto < 0) ? null : auto == 1,
      );
    } catch (_) {
      return ClockSample(wallClock: now);
    }
  }
}

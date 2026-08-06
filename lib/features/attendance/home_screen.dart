import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';

import '../../core/config.dart';
import '../../data/database.dart';
import '../../providers.dart';
import '../auth/auth_controller.dart';
import '../face/enroll_screen.dart';
import '../liveness/liveness_screen.dart';
import 'punch_repository.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Démarre l'écoute réseau + sync périodique, et tente une sync au lancement.
    Future.microtask(() {
      final repo = ref.read(punchRepositoryProvider);
      ref.read(syncServiceProvider);
      repo.trySync();
      _ensureEnrolled();
    });
  }

  /// Premier lancement sur cet appareil : sans empreinte faciale locale,
  /// on tente de récupérer le profil serveur (réinstallation), sinon
  /// l'enrôlement est obligatoire avant de pouvoir pointer.
  Future<void> _ensureEnrolled() async {
    final faces = ref.read(faceRepositoryProvider);
    if (await faces.localEmbedding() != null) return;
    try {
      if (await faces.pullRemoteProfile()) return;
    } catch (e) {
      // Hors ligne ou serveur pas encore à jour : on n'insiste pas, la
      // vérification d'identité sera simplement inactive (score null).
      debugPrint('face: profil distant indisponible ($e)');
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const EnrollScreen()),
    );
  }

  Future<Position> _getPosition() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw Exception('Activez la localisation (GPS) sur le téléphone.');
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      throw Exception(
          'Autorisez l\'accès à la position dans les réglages de l\'app.');
    }
    try {
      return await Geolocator.getCurrentPosition(
        locationSettings: LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: AppConfig.gpsTimeout,
        ),
      );
    } on Exception {
      // Signal GPS faible : on retombe sur la dernière position connue.
      final last = await Geolocator.getLastKnownPosition();
      if (last != null) return last;
      rethrow;
    }
  }

  Future<void> _punch(String type) async {
    if (_busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      // 1. Liveness : visage + clignement + vérification d'identité.
      final result = await Navigator.of(context).push<LivenessResult>(
        MaterialPageRoute(builder: (_) => const LivenessScreen()),
      );
      if (result == null || !result.alive) return;

      // 2. Position GPS.
      final position = await _getPosition();

      // 3. Écriture locale (jamais bloquée par le réseau) + tentative de sync.
      final outcome = await ref.read(punchRepositoryProvider).punch(
            type: type,
            lat: position.latitude,
            lng: position.longitude,
            accuracy: position.accuracy,
            faceScore: result.faceScore,
            faceMatch: result.faceMatch,
            photoJpeg: result.photoJpeg,
          );

      final label = type == 'in' ? 'Arrivée' : 'Départ';
      final syncedMsg = outcome == PunchOutcome.synced
          ? '$label enregistrée et synchronisée ✓'
          : '$label enregistrée hors ligne — sync automatique dès que '
              'le réseau revient.';
      // Non-correspondance : le pointage passe (phase de calibration) mais
      // l'agent est prévenu que le pointage sera contrôlé.
      messenger.showSnackBar(SnackBar(
        content: Text(result.faceMatch == false
            ? '$syncedMsg\n⚠ Visage non reconnu : ce pointage sera vérifié '
                'par un superviseur.'
            : syncedMsg),
        backgroundColor: result.faceMatch == false
            ? Colors.deepOrange
            : outcome == PunchOutcome.synced
                ? Colors.green
                : Colors.orange,
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text('Échec du pointage : $e'),
        backgroundColor: Colors.red,
      ));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(authControllerProvider).value;
    final pending = ref.watch(pendingCountProvider).value ?? 0;
    final recent = ref.watch(recentPunchesProvider).value ?? const [];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Zonik'),
        actions: [
          if (pending > 0)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Center(
                child: Chip(
                  avatar: const Icon(Icons.cloud_upload, size: 18),
                  label: Text('$pending en attente'),
                  backgroundColor: Colors.orange.shade100,
                ),
              ),
            ),
          IconButton(
            tooltip: 'Se déconnecter',
            icon: const Icon(Icons.logout),
            onPressed: () =>
                ref.read(authControllerProvider.notifier).logout(),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                const CircleAvatar(child: Icon(Icons.person)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        session?.matricule ?? '',
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      Text(
                        session?.tenantSlug ?? '',
                        style: TextStyle(color: Colors.grey.shade600),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: _PunchButton(
                    label: 'ARRIVÉE',
                    icon: Icons.login,
                    color: Colors.green,
                    busy: _busy,
                    onPressed: () => _punch('in'),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _PunchButton(
                    label: 'DÉPART',
                    icon: Icons.logout,
                    color: Colors.redAccent,
                    busy: _busy,
                    onPressed: () => _punch('out'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          const Divider(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Historique',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ),
          Expanded(
            child: recent.isEmpty
                ? Center(
                    child: Text(
                      'Aucun pointage pour le moment.',
                      style: TextStyle(color: Colors.grey.shade600),
                    ),
                  )
                : ListView.builder(
                    itemCount: recent.length,
                    itemBuilder: (context, index) =>
                        _PunchTile(punch: recent[index]),
                  ),
          ),
        ],
      ),
    );
  }
}

class _PunchButton extends StatelessWidget {
  const _PunchButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.busy,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final Color color;
  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: busy ? null : onPressed,
      icon: busy
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(icon),
      label: Text(label),
      style: FilledButton.styleFrom(
        backgroundColor: color,
        padding: const EdgeInsets.symmetric(vertical: 24),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
      ),
    );
  }
}

class _PunchTile extends StatelessWidget {
  const _PunchTile({required this.punch});

  final Punch punch;

  @override
  Widget build(BuildContext context) {
    final isIn = punch.type == 'in';
    final time = DateFormat('dd/MM HH:mm').format(punch.punchedAt);
    return ListTile(
      dense: true,
      leading: Icon(
        isIn ? Icons.login : Icons.logout,
        color: isIn ? Colors.green : Colors.redAccent,
      ),
      title: Text('${isIn ? 'Arrivée' : 'Départ'} — $time'),
      subtitle: Text(
        '${punch.lat.toStringAsFixed(5)}, ${punch.lng.toStringAsFixed(5)}'
        '${punch.accuracy != null ? ' (±${punch.accuracy!.round()} m)' : ''}',
      ),
      trailing: punch.synced
          ? const Icon(Icons.cloud_done, color: Colors.green, size: 20)
          : Tooltip(
              message: punch.lastError ?? 'En attente de synchronisation',
              child: const Icon(Icons.cloud_queue,
                  color: Colors.orange, size: 20),
            ),
    );
  }
}

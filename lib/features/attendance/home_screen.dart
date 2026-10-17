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
import '../planning/planning_repository.dart';
import 'sync_service.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with WidgetsBindingObserver {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Démarre l'écoute réseau + la minuterie, fait le ménage et lance une
    // première sync (pointages + planning/sites).
    Future.microtask(() {
      ref.read(syncServiceProvider).start();
      _ensureEnrolled();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Retour au premier plan (l'agent rouvre l'app) : on tente l'envoi.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.read(syncServiceProvider).kick();
    }
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
      // Son heure de fix part avec le pointage : le serveur voit son âge.
      final last = await Geolocator.getLastKnownPosition();
      if (last != null) return last;
      rethrow;
    }
  }

  Future<void> _punch(String type) async {
    if (_busy) return;
    final owner = ref.read(ownerProvider);
    if (owner == null) return;
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

      // 3. Écriture locale immédiate (jamais bloquée par le réseau), puis
      //    envoi en arrière-plan : l'historique montre l'état en direct.
      final receipt = await ref.read(punchRepositoryProvider).punch(
            owner: owner,
            type: type,
            position: position,
            faceScore: result.faceScore,
            faceMatch: result.faceMatch,
            photoJpeg: result.photoJpeg,
          );
      ref.read(syncServiceProvider).kick();

      final label = type == 'in' ? 'Arrivée' : 'Départ';
      final lines = <String>['$label enregistrée ✓'];
      final zone = receipt.zone;
      if (zone.inZone == false) {
        lines.add('⚠ Hors zone : ${_distance(zone.distanceM)} de '
            '${zone.site!.name} (rayon ${zone.site!.radiusM.round()} m). '
            'Ce pointage sera vérifié.');
      } else if (zone.inZone == true) {
        lines.add('Dans la zone : ${zone.site!.name}.');
      }
      // Non-correspondance : le pointage passe (phase de calibration) mais
      // l'agent est prévenu que le pointage sera contrôlé.
      if (result.faceMatch == false) {
        lines.add('⚠ Visage non reconnu : ce pointage sera vérifié par un '
            'superviseur.');
      }
      final warning = zone.inZone == false || result.faceMatch == false;
      messenger.showSnackBar(SnackBar(
        content: Text(lines.join('\n')),
        backgroundColor: warning ? Colors.deepOrange : Colors.green,
        duration: Duration(seconds: warning ? 6 : 3),
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

  /// Déconnexion : si des pointages n'ont pas pu partir, on prévient
  /// (ils restent sur le téléphone, attachés à cet agent).
  Future<void> _logout() async {
    final pending = ref.read(pendingCountProvider).value ?? 0;
    if (pending > 0) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Pointages pas encore envoyés'),
          content: Text(
            '$pending pointage${pending > 1 ? 's' : ''} n\''
            '${pending > 1 ? 'ont' : 'a'} pas encore été envoyé'
            '${pending > 1 ? 's' : ''} au serveur.\n\n'
            'Rien n\'est perdu : ils restent sur ce téléphone et partiront '
            'automatiquement à ta prochaine connexion.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Rester connecté'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Se déconnecter'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    await ref.read(authControllerProvider.notifier).logout();
  }

  Future<void> _refreshPlanning() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(planningRepositoryProvider).refresh(force: true);
    } catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text('Planning non mis à jour ($e). '
            'Le planning enregistré reste affiché.'),
      ));
    }
  }

  Future<void> _showPunch(Punch p) async {
    if (!p.rejected) return;
    final retry = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Pointage refusé par le serveur'),
        content: Text(
          '${p.lastError ?? 'Motif inconnu.'}\n\n'
          'Préviens ton superviseur. S\'il a corrigé le problème, tu peux '
          'renvoyer ce pointage.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Fermer'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Renvoyer'),
          ),
        ],
      ),
    );
    if (retry == true) {
      await ref.read(databaseProvider).retryRejected(p.clientUuid);
      ref.read(syncServiceProvider).kick(force: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(authControllerProvider).value;
    final pending = ref.watch(pendingCountProvider).value ?? 0;
    final othersPending = ref.watch(othersPendingCountProvider).value ?? 0;
    final recent = ref.watch(recentPunchesProvider).value ?? const [];
    final today = ref.watch(todayShiftsProvider).value;
    final fetchedAt = ref.watch(planningFetchedAtProvider).value;
    final sync = ref.watch(syncStateProvider).value ?? const SyncState();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Zonik'),
        actions: [
          IconButton(
            tooltip: 'Se déconnecter',
            icon: const Icon(Icons.logout),
            onPressed: _logout,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                const CircleAvatar(child: Icon(Icons.person)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        session?.fullName.isNotEmpty == true
                            ? session!.fullName
                            : (session?.matricule ?? ''),
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      Text(
                        session?.fullName.isNotEmpty == true
                            ? '${session!.matricule} · ${session.tenantSlug}'
                            : (session?.tenantSlug ?? ''),
                        style: TextStyle(color: Colors.grey.shade600),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          _SyncPanel(
            state: sync,
            pending: pending,
            othersPending: othersPending,
            onSyncNow: () => ref.read(syncServiceProvider).kick(force: true),
            onReconnect: () =>
                ref.read(authControllerProvider.notifier).logout(),
          ),
          // Vacation du jour, lue dans le cache : visible hors ligne.
          if (today != null)
            _TodayCard(
              shifts: today,
              fetchedAt: fetchedAt,
              online: sync.lastError == null && !sync.needsReauth,
              onRefresh: _refreshPlanning,
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
                    itemBuilder: (context, index) => _PunchTile(
                      punch: recent[index],
                      onTap: () => _showPunch(recent[index]),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

String _distance(double? meters) {
  if (meters == null) return '?';
  if (meters >= 1000) return '${(meters / 1000).toStringAsFixed(1)} km';
  return '${meters.round()} m';
}

/// Bandeau d'état de la synchronisation : session à renouveler, pointages
/// en attente, heure du téléphone décalée, ou tout est à jour.
class _SyncPanel extends StatelessWidget {
  const _SyncPanel({
    required this.state,
    required this.pending,
    required this.othersPending,
    required this.onSyncNow,
    required this.onReconnect,
  });

  final SyncState state;
  final int pending;
  final int othersPending;
  final VoidCallback onSyncNow;
  final VoidCallback onReconnect;

  @override
  Widget build(BuildContext context) {
    final hm = DateFormat('dd/MM HH:mm');
    final banners = <Widget>[];

    if (state.needsReauth) {
      banners.add(_Banner(
        color: Colors.red,
        icon: Icons.lock_clock,
        text: pending > 0
            ? 'Session expirée : reconnecte-toi pour envoyer tes $pending '
                'pointage${pending > 1 ? 's' : ''}. Ils sont en sécurité sur '
                'le téléphone.'
            : 'Session expirée : reconnecte-toi.',
        action: TextButton(
          onPressed: onReconnect,
          child: const Text('Se reconnecter'),
        ),
      ));
    } else if (pending > 0) {
      final detail = state.lastError != null
          ? 'Hors ligne ou serveur injoignable — nouvel essai automatique.'
          : 'Envoi automatique dès que le réseau le permet.';
      banners.add(_Banner(
        color: Colors.orange,
        icon: Icons.cloud_upload,
        text: '$pending pointage${pending > 1 ? 's' : ''} en attente. $detail',
        action: state.running
            ? const Padding(
                padding: EdgeInsets.all(12),
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            : TextButton(onPressed: onSyncNow, child: const Text('Envoyer')),
      ));
    } else if (state.lastSuccessAt != null) {
      banners.add(Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          children: [
            const Icon(Icons.cloud_done, size: 16, color: Colors.green),
            const SizedBox(width: 6),
            Text(
              'Tout est envoyé · dernière sync ${hm.format(state.lastSuccessAt!)}',
              style: TextStyle(color: Colors.grey.shade700, fontSize: 12),
            ),
          ],
        ),
      ));
    }

    final offset = state.clockOffset;
    if (offset != null && offset.abs() > AppConfig.clockSkewWarning) {
      final minutes = offset.abs().inMinutes;
      banners.add(_Banner(
        color: Colors.amber.shade800,
        icon: Icons.schedule,
        text: 'L\'heure du téléphone est décalée de '
            '${minutes >= 60 ? '${(minutes / 60).toStringAsFixed(1)} h' : '$minutes min'}. '
            'Active « Date et heure automatiques » dans les réglages.',
      ));
    }

    if (othersPending > 0) {
      banners.add(Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Text(
          '$othersPending pointage${othersPending > 1 ? 's' : ''} d\'autres '
          'agents de ce téléphone attend${othersPending > 1 ? 'ent' : ''} '
          'leur prochaine connexion.',
          style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
        ),
      ));
    }

    if (banners.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final b in banners) ...[
            b,
            if (b != banners.last) const SizedBox(height: 6),
          ],
        ],
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.color,
    required this.icon,
    required this.text,
    this.action,
  });

  final Color color;
  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        border: Border.all(color: color.withValues(alpha: 0.45)),
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
          if (action != null) action!,
        ],
      ),
    );
  }
}

/// Carte "Ma vacation" : où et quand l'agent est attendu aujourd'hui,
/// lue dans le cache local avec la date de sa dernière mise à jour.
class _TodayCard extends StatelessWidget {
  const _TodayCard({
    required this.shifts,
    required this.fetchedAt,
    required this.online,
    required this.onRefresh,
  });

  final List<MyShift> shifts;
  final DateTime? fetchedAt;
  final bool online;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final hm = DateFormat('HH:mm');
    final stamp = DateFormat('dd/MM HH:mm');
    final theme = Theme.of(context);
    final stale = fetchedAt == null ||
        DateTime.now().difference(fetchedAt!) > const Duration(hours: 12);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Aujourd\'hui',
                      style: theme.textTheme.labelMedium
                          ?.copyWith(color: Colors.grey.shade600),
                    ),
                    const SizedBox(height: 4),
                    if (fetchedAt == null)
                      Text(
                        'Planning pas encore téléchargé — il le sera dès '
                        'que le réseau sera disponible.',
                        style: theme.textTheme.bodyMedium,
                      )
                    else if (shifts.isEmpty)
                      Text(
                        'Aucune vacation planifiée pour vous.',
                        style: theme.textTheme.bodyMedium,
                      )
                    else
                      for (final s in shifts) ...[
                        Row(
                          children: [
                            Icon(
                              s.isNow ? Icons.play_circle : Icons.schedule,
                              size: 18,
                              color: s.isNow ? Colors.green : Colors.teal,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                '${s.siteName.isNotEmpty ? s.siteName : 'Site'} · '
                                '${hm.format(s.startsAt)}–${hm.format(s.endsAt)}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600),
                              ),
                            ),
                          ],
                        ),
                        Padding(
                          padding: const EdgeInsets.only(left: 24, top: 2),
                          child: Text(
                            [
                              if (s.postName.isNotEmpty) s.postName,
                              if (s.role == 'remplacant') 'remplacement',
                              if (s.role == 'renfort') 'renfort',
                              if (s.isNow) 'en cours',
                            ].join(' · '),
                            style: TextStyle(
                                color: Colors.grey.shade600, fontSize: 12),
                          ),
                        ),
                        if (s != shifts.last) const SizedBox(height: 8),
                      ],
                    if (fetchedAt != null && (stale || !online)) ...[
                      const SizedBox(height: 6),
                      Text(
                        'Planning du ${stamp.format(fetchedAt!)}',
                        style: TextStyle(
                          color: stale
                              ? Colors.orange.shade800
                              : Colors.grey.shade600,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Actualiser',
                icon: const Icon(Icons.refresh, size: 20),
                onPressed: onRefresh,
              ),
            ],
          ),
        ),
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
  const _PunchTile({required this.punch, required this.onTap});

  final Punch punch;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isIn = punch.type == 'in';
    final time = DateFormat('dd/MM HH:mm').format(punch.punchedAt);

    final String where;
    if (punch.inZone != null && punch.siteName != null) {
      where = punch.inZone!
          ? punch.siteName!
          : '${punch.siteName} · hors zone (${_distance(punch.distanceM)})';
    } else {
      where = '${punch.lat.toStringAsFixed(5)}, ${punch.lng.toStringAsFixed(5)}'
          '${punch.accuracy != null ? ' (±${punch.accuracy!.round()} m)' : ''}';
    }

    final Widget trailing;
    if (punch.synced) {
      trailing = const Icon(Icons.cloud_done, color: Colors.green, size: 20);
    } else if (punch.rejected) {
      trailing = const Icon(Icons.error, color: Colors.red, size: 20);
    } else {
      trailing = Tooltip(
        message: punch.lastError ?? 'En attente de synchronisation',
        child: const Icon(Icons.cloud_queue, color: Colors.orange, size: 20),
      );
    }

    return ListTile(
      dense: true,
      onTap: punch.rejected ? onTap : null,
      leading: Icon(
        isIn ? Icons.login : Icons.logout,
        color: isIn ? Colors.green : Colors.redAccent,
      ),
      title: Text('${isIn ? 'Arrivée' : 'Départ'} — $time'),
      subtitle: Text(
        punch.rejected
            ? 'Refusé : ${punch.lastError ?? 'motif inconnu'} — toucher pour détails'
            : where,
        style: punch.rejected ? const TextStyle(color: Colors.red) : null,
      ),
      trailing: trailing,
    );
  }
}

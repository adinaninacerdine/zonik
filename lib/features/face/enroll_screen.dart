import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';
import '../liveness/liveness_screen.dart';

/// Enrôlement du visage de référence, exigé au premier login sur l'appareil.
/// L'empreinte + une photo témoin partent au serveur (statut « en attente »)
/// pour validation par un superviseur dans le dashboard.
class EnrollScreen extends ConsumerStatefulWidget {
  const EnrollScreen({super.key});

  @override
  ConsumerState<EnrollScreen> createState() => _EnrollScreenState();
}

class _EnrollScreenState extends ConsumerState<EnrollScreen> {
  bool _busy = false;
  String? _error;

  Future<void> _start() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await Navigator.of(context).push<LivenessResult>(
        MaterialPageRoute(
          builder: (_) => const LivenessScreen(mode: LivenessMode.enroll),
        ),
      );
      if (result == null || result.embedding == null) {
        setState(() => _busy = false);
        return; // abandon ou capture impossible : l'agent peut réessayer
      }
      await ref.read(faceRepositoryProvider).enroll(
            embedding: result.embedding!,
            photoJpeg: result.photoJpeg!,
          );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      setState(() {
        _busy = false;
        _error = 'Envoi impossible : $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Enregistrement du visage'),
        automaticallyImplyLeading: false,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.face_retouching_natural, size: 96),
            const SizedBox(height: 24),
            const Text(
              'Première connexion sur ce téléphone :\n'
              'votre visage doit être enregistré.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Text(
              'Il servira à vérifier votre identité à chaque pointage. '
              'Un superviseur validera cet enregistrement. '
              'Placez-vous dans un endroit éclairé, sans lunettes de soleil '
              'ni masque.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade600),
            ),
            const SizedBox(height: 32),
            if (_error != null) ...[
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.red),
              ),
              const SizedBox(height: 16),
            ],
            FilledButton.icon(
              onPressed: _busy ? null : _start,
              icon: _busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.camera_front),
              label: const Text('Enregistrer mon visage'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 20),
                textStyle:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

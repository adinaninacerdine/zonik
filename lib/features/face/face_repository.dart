import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/api_client.dart';

/// Profil facial de l'agent : l'empreinte de référence vit sur le serveur
/// (source de vérité, validée par un superviseur) et en cache local pour
/// vérifier hors ligne. Réinstaller l'app re-télécharge le profil validé —
/// se ré-enrôler exige une nouvelle validation superviseur.
class FaceRepository {
  FaceRepository({required this.api, required this.storage});

  static const _kEmbedding = 'faceEmbedding';
  static const _kStatus = 'faceStatus'; // pending | validated

  final ApiClient api;
  final FlutterSecureStorage storage;

  Future<Float32List?> localEmbedding() async {
    final b64 = await storage.read(key: _kEmbedding);
    if (b64 == null) return null;
    final bytes = base64Decode(b64);
    return bytes.buffer.asFloat32List();
  }

  Future<String?> localStatus() => storage.read(key: _kStatus);

  /// Envoie l'enrôlement au serveur (statut « pending » jusqu'à validation
  /// superviseur dans le dashboard) et le met en cache local.
  Future<void> enroll({
    required Float32List embedding,
    required Uint8List photoJpeg,
  }) async {
    await api.post('/api/face/enroll', {
      'embedding': embedding.toList(),
      'photo': base64Encode(photoJpeg),
    });
    await _storeLocal(embedding, 'pending');
  }

  /// Récupère le profil serveur (après réinstallation par exemple).
  /// Retourne true si un profil existe et a été mis en cache.
  Future<bool> pullRemoteProfile() async {
    final json = await api.get('/api/face/profile');
    final list = json['embedding'];
    if (list is! List || list.isEmpty) return false;
    final embedding = Float32List.fromList(
        list.map((e) => (e as num).toDouble()).toList());
    await _storeLocal(embedding, (json['status'] ?? 'pending').toString());
    return true;
  }

  Future<void> _storeLocal(Float32List embedding, String status) async {
    await storage.write(
      key: _kEmbedding,
      value: base64Encode(embedding.buffer.asUint8List()),
    );
    await storage.write(key: _kStatus, value: status);
  }
}

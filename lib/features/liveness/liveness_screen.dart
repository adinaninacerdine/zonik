import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import '../../core/config.dart';
import '../../providers.dart';
import '../face/face_service.dart';

enum LivenessMode {
  /// Pointage : clignement + comparaison avec l'empreinte enrôlée.
  verify,

  /// Enrôlement : clignement + capture de l'empreinte de référence.
  enroll,
}

/// Résultat de la vérification de présence.
class LivenessResult {
  const LivenessResult({
    required this.alive,
    this.embedding,
    this.faceScore,
    this.faceMatch,
    this.photoJpeg,
  });

  /// Clignement validé par un visage vivant.
  final bool alive;

  /// Empreinte capturée (mode enroll uniquement).
  final Float32List? embedding;

  /// Similarité cosinus avec l'empreinte enrôlée (mode verify,
  /// null si pas d'empreinte de référence ou si le modèle n'a pas chargé).
  final double? faceScore;

  /// true si [faceScore] ≥ seuil. Null si non évaluable.
  final bool? faceMatch;

  /// Photo témoin (frame validée, jointe au pointage pour audit).
  final Uint8List? photoJpeg;
}

/// Vérification de présence : détecte un visage, exige un clignement
/// (anti-photo), puis capture l'empreinte faciale pour vérifier l'identité
/// (mode verify) ou enrôler l'agent (mode enroll).
/// Retourne un [LivenessResult] via Navigator.pop, null si abandon.
class LivenessScreen extends ConsumerStatefulWidget {
  const LivenessScreen({super.key, this.mode = LivenessMode.verify});

  final LivenessMode mode;

  @override
  ConsumerState<LivenessScreen> createState() => _LivenessScreenState();
}

enum _Step { initializing, noFace, waitBlink, eyesClosed, capturing, done, error }

class _LivenessScreenState extends ConsumerState<LivenessScreen> {
  CameraController? _controller;
  late final FaceDetector _detector;
  bool _processing = false;
  _Step _step = _Step.initializing;
  String _errorMessage = '';
  int _consecutiveFailures = 0;
  Timer? _timeoutTimer;
  bool _diagLogged = false;
  bool _pathLogged = false;

  FaceService? _faceService;
  Float32List? _reference; // empreinte enrôlée (mode verify)
  final List<Float32List> _samples = [];
  Uint8List? _witness;

  // Dernière frame exploitable, gardée pour l'étape de capture.
  Uint8List? _lastNv21;
  int _lastWidth = 0;
  int _lastHeight = 0;
  int _lastRotationDeg = 0;

  /// Au-delà de N frames consécutives rejetées par ML Kit, on abandonne :
  /// le format caméra de l'appareil est réellement incompatible.
  static const _maxConsecutiveFailures = 10;
  static const _timeout = Duration(seconds: 15);

  /// La capture d'empreinte fait de l'inférence TFLite sur CPU : chaque
  /// échantillon peut prendre plusieurs secondes sur un petit appareil.
  static const _captureTimeout = Duration(seconds: 40);

  /// Frames d'empreinte à capturer après le clignement (moyennées à
  /// l'enrôlement ; meilleur score retenu à la vérification).
  int get _targetSamples => widget.mode == LivenessMode.enroll ? 3 : 2;

  static const _orientations = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  @override
  void initState() {
    super.initState();
    _detector = FaceDetector(
      options: FaceDetectorOptions(
        enableClassification: true, // probabilités yeux ouverts/fermés
        performanceMode: FaceDetectorMode.fast,
      ),
    );
    _loadFaceTools();
    _init();
  }

  /// Charge le modèle d'empreinte et la référence. Un échec ne bloque pas
  /// le pointage : on retombe sur le liveness seul (score null, à défaut).
  Future<void> _loadFaceTools() async {
    try {
      _faceService = await ref.read(faceServiceProvider.future);
      if (widget.mode == LivenessMode.verify) {
        _reference = await ref.read(faceRepositoryProvider).localEmbedding();
      }
    } catch (e) {
      debugPrint('face: modèle indisponible ($e)');
    }
  }

  Future<void> _init() async {
    try {
      final cameras = await availableCameras();
      final front = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        front,
        ResolutionPreset.low, // suffisant pour la détection, économe
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid
            ? ImageFormatGroup.nv21
            : ImageFormatGroup.bgra8888,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      _controller = controller;
      setState(() => _step = _Step.noFace);
      await controller.startImageStream(_onImage);
      _timeoutTimer = Timer(_timeout, _onTimeout);
    } on CameraException catch (e) {
      setState(() {
        _step = _Step.error;
        _errorMessage = e.description ?? 'Caméra indisponible.';
      });
    } catch (e) {
      setState(() {
        _step = _Step.error;
        _errorMessage = e.toString();
      });
    }
  }

  void _onTimeout() {
    if (!mounted || _step == _Step.done || _step == _Step.error) return;
    debugPrint('liveness: timeout à l\'étape $_step '
        '(${_samples.length}/$_targetSamples échantillons)');
    _stopStream();
    setState(() {
      _step = _Step.error;
      _errorMessage =
          'Délai dépassé. Placez votre visage bien en face de la caméra, '
          'dans un endroit éclairé, puis réessayez.';
    });
  }

  Future<void> _stopStream() async {
    final controller = _controller;
    if (controller != null && controller.value.isStreamingImages) {
      try {
        await controller.stopImageStream();
      } on CameraException {
        // Déjà arrêté ou caméra perdue : rien à faire.
      }
    }
  }

  Future<void> _retry() async {
    _timeoutTimer?.cancel();
    final old = _controller;
    _controller = null;
    _processing = false;
    _consecutiveFailures = 0;
    _diagLogged = false;
    _pathLogged = false;
    _samples.clear();
    _witness = null;
    setState(() {
      _step = _Step.initializing;
      _errorMessage = '';
    });
    await old?.dispose();
    await _init();
  }

  /// Trace une seule fois ce que la caméra livre réellement (diagnostic
  /// MediaTek : format, plans, strides). Visible via `adb logcat -s flutter`.
  void _logFrameDiagnostics(CameraImage image) {
    if (_diagLogged) return;
    _diagLogged = true;
    final planes = image.planes
        .asMap()
        .entries
        .map((e) =>
            'plane${e.key}{bytesPerRow=${e.value.bytesPerRow}, '
            'bytesPerPixel=${e.value.bytesPerPixel}, '
            'len=${e.value.bytes.length}}')
        .join(' ');
    debugPrint('liveness/diag: group=${image.format.group} '
        'raw=${image.format.raw} planes=${image.planes.length} '
        'size=${image.width}x${image.height} $planes');
  }

  /// Compte une frame inexploitable ; au bout de [_maxConsecutiveFailures]
  /// d'affilée, on abandonne avec un message propre.
  Future<void> _onFrameFailure(String reason) async {
    debugPrint('liveness: frame ignorée ($reason)');
    _consecutiveFailures++;
    if (_consecutiveFailures >= _maxConsecutiveFailures && mounted) {
      _timeoutTimer?.cancel();
      await _stopStream();
      if (mounted) {
        setState(() {
          _step = _Step.error;
          _errorMessage =
              "Impossible d'analyser l'image de la caméra sur cet "
              'appareil. Réessayez ou signalez le problème.';
        });
      }
    }
  }

  Future<void> _onImage(CameraImage image) async {
    if (_processing || _step == _Step.done || _step == _Step.error) return;
    _processing = true;
    try {
      _logFrameDiagnostics(image);
      final inputImage = _toInputImage(image);
      if (inputImage == null) {
        // Format non reconnu : sans compteur, l'écran tournerait en silence
        // jusqu'au timeout sans jamais signaler le vrai problème.
        await _onFrameFailure(
            'format inexploitable: group=${image.format.group} '
            'raw=${image.format.raw} planes=${image.planes.length}');
        return;
      }
      final List<Face> faces;
      try {
        faces = await _detector.processImage(inputImage);
        _consecutiveFailures = 0;
      } on Exception catch (e) {
        // Une frame ratée (format exotique MediaTek, buffer recyclé…) ne
        // doit pas casser le flux : on la saute et on ne s'arrête que si
        // aucune frame ne passe.
        await _onFrameFailure('processImage: $e');
        return;
      }
      if (!mounted || _step == _Step.done) return;

      if (faces.isEmpty) {
        // Pendant la capture on tolère les frames sans visage (l'agent
        // bouge un peu) : on attend la suivante sans régresser.
        if (_step != _Step.noFace && _step != _Step.capturing) {
          setState(() => _step = _Step.noFace);
        }
        return;
      }

      final face = faces.first;

      if (_step == _Step.capturing) {
        await _captureSample(face);
        return;
      }

      final left = face.leftEyeOpenProbability;
      final right = face.rightEyeOpenProbability;
      if (left == null || right == null) {
        if (_step == _Step.noFace) setState(() => _step = _Step.waitBlink);
        return;
      }

      final eyesOpen = left > 0.8 && right > 0.8;
      final eyesClosed = left < 0.2 && right < 0.2;

      switch (_step) {
        case _Step.noFace:
          setState(() => _step = _Step.waitBlink);
        case _Step.waitBlink:
          if (eyesClosed) setState(() => _step = _Step.eyesClosed);
        case _Step.eyesClosed:
          if (eyesOpen) {
            if (_faceService != null) {
              // Clignement validé : on capture l'empreinte sur les frames
              // suivantes (yeux ouverts). Délai dédié, large : chaque
              // échantillon coûte plusieurs secondes d'inférence CPU.
              _timeoutTimer?.cancel();
              _timeoutTimer = Timer(_captureTimeout, _onTimeout);
              setState(() => _step = _Step.capturing);
              await _captureSample(face);
            } else {
              // Modèle indisponible : liveness seul, comme avant.
              setState(() => _step = _Step.done);
              await _finish(const LivenessResult(alive: true));
            }
          }
        default:
          break;
      }
    } finally {
      _processing = false;
    }
  }

  /// Calcule l'empreinte du visage sur la frame courante ; au bout de
  /// [_targetSamples], conclut selon le mode.
  Future<void> _captureSample(Face face) async {
    final service = _faceService;
    final nv21 = _lastNv21;
    if (service == null || nv21 == null) return;

    try {
      final frame = FaceService.upright(
        FaceService.nv21ToImage(nv21, _lastWidth, _lastHeight),
        _lastRotationDeg,
      );
      _witness ??= FaceService.witnessJpeg(frame);
      _samples.add(service.embed(frame, face));
    } catch (e) {
      debugPrint('face: échantillon raté ($e)');
      return; // on retentera sur la frame suivante
    }
    if (_samples.length < _targetSamples) return;

    setState(() => _step = _Step.done);
    if (widget.mode == LivenessMode.enroll) {
      await _finish(LivenessResult(
        alive: true,
        embedding: FaceService.average(_samples),
        photoJpeg: _witness,
      ));
      return;
    }

    final reference = _reference;
    double? best;
    if (reference != null) {
      for (final sample in _samples) {
        final score = FaceService.cosine(sample, reference);
        if (best == null || score > best) best = score;
      }
      debugPrint(
          'face/diag: score=${best!.toStringAsFixed(3)} seuil=${AppConfig.faceMatchThreshold}');
    }
    await _finish(LivenessResult(
      alive: true,
      faceScore: best,
      faceMatch: best == null ? null : best >= AppConfig.faceMatchThreshold,
      photoJpeg: _witness,
    ));
  }

  Future<void> _finish(LivenessResult result) async {
    _timeoutTimer?.cancel();
    await _stopStream();
    if (!mounted) return;
    // Petit délai pour que l'utilisateur voie la validation.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (mounted) Navigator.of(context).pop(result);
  }

  /// Conversion CameraImage -> InputImage (NV21 Android / BGRA iOS),
  /// selon l'exemple officiel google_mlkit.
  InputImage? _toInputImage(CameraImage image) {
    final controller = _controller;
    if (controller == null) return null;
    final camera = controller.description;

    InputImageRotation? rotation;
    var rotationDeg = 0;
    if (Platform.isIOS) {
      rotationDeg = camera.sensorOrientation;
      rotation = InputImageRotationValue.fromRawValue(rotationDeg);
    } else {
      var compensation = _orientations[controller.value.deviceOrientation];
      if (compensation == null) return null;
      if (camera.lensDirection == CameraLensDirection.front) {
        compensation = (camera.sensorOrientation + compensation) % 360;
      } else {
        compensation = (camera.sensorOrientation - compensation + 360) % 360;
      }
      rotationDeg = compensation;
      rotation = InputImageRotationValue.fromRawValue(compensation);
    }
    if (rotation == null) return null;

    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null) return null;

    if (Platform.isIOS) {
      if (format != InputImageFormat.bgra8888 || image.planes.length != 1) {
        return null;
      }
      final plane = image.planes.first;
      return InputImage.fromBytes(
        bytes: plane.bytes,
        metadata: InputImageMetadata(
          size: Size(image.width.toDouble(), image.height.toDouble()),
          rotation: rotation,
          format: format,
          bytesPerRow: plane.bytesPerRow,
        ),
      );
    }

    // Android : le converter natif de ML Kit ne consomme que du NV21 sans
    // padding de fin de ligne. Certains capteurs (MediaTek notamment)
    // renvoient un stride > largeur, voire du YUV_420_888 trois plans
    // malgré le nv21 demandé au CameraController → NullPointerException
    // côté natif si on passe le buffer tel quel.
    final Uint8List nv21;
    final String path;
    if (format == InputImageFormat.nv21 && image.planes.length == 1) {
      nv21 = _stripRowPadding(image.planes.first, image.width, image.height);
      path = 'nv21-strip';
    } else if (format == InputImageFormat.yuv_420_888 &&
        image.planes.length == 3) {
      nv21 = _yuv420ToNv21(image);
      path = 'yuv420->nv21';
    } else {
      return null;
    }
    if (!_pathLogged) {
      _pathLogged = true;
      debugPrint('liveness/diag: conversion=$path rotation=$rotation '
          'out=${nv21.length} octets');
    }

    // Frame gardée pour l'empreinte faciale (capture post-clignement).
    _lastNv21 = nv21;
    _lastWidth = image.width;
    _lastHeight = image.height;
    _lastRotationDeg = rotationDeg;

    return InputImage.fromBytes(
      bytes: nv21,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: InputImageFormat.nv21,
        bytesPerRow: image.width,
      ),
    );
  }

  /// Supprime le padding de fin de ligne d'un buffer NV21 (stride > largeur).
  Uint8List _stripRowPadding(Plane plane, int width, int height) {
    final stride = plane.bytesPerRow;
    if (stride <= width) return plane.bytes;
    final rows = height * 3 ~/ 2; // lignes Y puis lignes VU entrelacées
    final out = Uint8List(width * rows);
    for (var row = 0; row < rows; row++) {
      final start = row * stride;
      if (start + width > plane.bytes.length) break;
      out.setRange(row * width, (row + 1) * width, plane.bytes, start);
    }
    return out;
  }

  /// Reconstruit un buffer NV21 (Y puis VU entrelacé) depuis les trois plans
  /// YUV_420_888, en respectant les strides ligne et pixel de chaque plan.
  Uint8List _yuv420ToNv21(CameraImage image) {
    final width = image.width;
    final height = image.height;
    final yPlane = image.planes[0];
    final uPlane = image.planes[1];
    final vPlane = image.planes[2];
    final out = Uint8List(width * height * 3 ~/ 2);

    var offset = 0;
    for (var row = 0; row < height; row++) {
      final start = row * yPlane.bytesPerRow;
      out.setRange(offset, offset + width, yPlane.bytes, start);
      offset += width;
    }

    final uvHeight = height ~/ 2;
    final uvWidth = width ~/ 2;
    final uPixelStride = uPlane.bytesPerPixel ?? 1;
    final vPixelStride = vPlane.bytesPerPixel ?? 1;
    for (var row = 0; row < uvHeight; row++) {
      for (var col = 0; col < uvWidth; col++) {
        out[offset++] = vPlane.bytes[row * vPlane.bytesPerRow + col * vPixelStride];
        out[offset++] = uPlane.bytes[row * uPlane.bytesPerRow + col * uPixelStride];
      }
    }
    return out;
  }

  @override
  void dispose() {
    _timeoutTimer?.cancel();
    _controller?.dispose();
    _detector.close();
    super.dispose();
  }

  String get _instruction => switch (_step) {
        _Step.initializing => 'Ouverture de la caméra…',
        _Step.noFace => 'Placez votre visage dans le cadre',
        _Step.waitBlink => 'Clignez des yeux',
        _Step.eyesClosed => 'Rouvrez les yeux…',
        _Step.capturing => 'Ne bougez pas…',
        _Step.done => widget.mode == LivenessMode.enroll
            ? 'Visage enregistré ✓'
            : 'Vérification réussie ✓',
        _Step.error => _errorMessage,
      };

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(widget.mode == LivenessMode.enroll
            ? 'Enregistrement du visage'
            : 'Vérification de présence'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: _step == _Step.error
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            _errorMessage,
                            style: const TextStyle(color: Colors.white),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 24),
                          FilledButton.icon(
                            onPressed: _retry,
                            icon: const Icon(Icons.refresh),
                            label: const Text('Réessayer'),
                          ),
                        ],
                      ),
                    )
                  : (controller == null || !controller.value.isInitialized)
                      ? const CircularProgressIndicator()
                      : ClipOval(
                          child: SizedBox(
                            width: 280,
                            height: 360,
                            child: FittedBox(
                              fit: BoxFit.cover,
                              child: SizedBox(
                                width: controller.value.previewSize?.height ??
                                    280,
                                height: controller.value.previewSize?.width ??
                                    360,
                                child: CameraPreview(controller),
                              ),
                            ),
                          ),
                        ),
            ),
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(24),
            child: Text(
              _instruction,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _step == _Step.done ? Colors.greenAccent : Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

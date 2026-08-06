import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

/// Reconnaissance faciale locale (MobileFaceNet via TFLite).
///
/// Produit un embedding (vecteur ~192 dimensions, normalisé L2) à partir
/// d'une frame caméra NV21 et de la boîte du visage détectée par ML Kit.
/// Deux embeddings de la même personne ont une similarité cosinus élevée.
/// Tout tourne sur l'appareil : rien ne sort du téléphone à part
/// l'embedding d'enrôlement et les photos témoins.
class FaceService {
  FaceService._(this._interpreter, this._inputSize, this._outputSize);

  final Interpreter _interpreter;
  final int _inputSize; // côté du carré d'entrée (112 pour MobileFaceNet)
  final int _outputSize; // dimensions de l'embedding (192)

  static Future<FaceService> load() async {
    final interpreter =
        await Interpreter.fromAsset('assets/models/mobilefacenet.tflite');
    final inShape = interpreter.getInputTensor(0).shape;
    final outShape = interpreter.getOutputTensor(0).shape;
    debugPrint('face/diag: modèle entrée=$inShape sortie=$outShape');
    return FaceService._(interpreter, inShape[1], outShape.last);
  }

  void dispose() => _interpreter.close();

  /// Décode une frame NV21 (sans padding) en image RGB.
  static img.Image nv21ToImage(Uint8List nv21, int width, int height) {
    final out = img.Image(width: width, height: height);
    final uvStart = width * height;
    for (var y = 0; y < height; y++) {
      final yRow = y * width;
      final uvRow = uvStart + (y >> 1) * width;
      for (var x = 0; x < width; x++) {
        final yy = nv21[yRow + x];
        final uvIndex = uvRow + (x & ~1);
        final v = nv21[uvIndex] - 128;
        final u = nv21[uvIndex + 1] - 128;
        var r = yy + (1.370705 * v).round();
        var g = yy - (0.337633 * u).round() - (0.698001 * v).round();
        var b = yy + (1.732446 * u).round();
        r = r.clamp(0, 255);
        g = g.clamp(0, 255);
        b = b.clamp(0, 255);
        out.setPixelRgb(x, y, r, g, b);
      }
    }
    return out;
  }

  /// Remet la frame dans le sens de lecture de ML Kit (l'orientation dans
  /// laquelle les boundingBox des visages sont exprimées).
  static img.Image upright(img.Image frame, int rotationDegrees) =>
      rotationDegrees == 0
          ? frame
          : img.copyRotate(frame, angle: rotationDegrees);

  /// Extrait le visage (boîte ML Kit + marge) et calcule son embedding.
  /// [uprightFrame] doit être l'image déjà remise droite via [upright].
  Float32List embed(img.Image uprightFrame, Face face) {
    // Marge de 20 % autour de la boîte : MobileFaceNet est entraîné sur des
    // visages cadrés larges (front + menton inclus).
    final box = face.boundingBox;
    final margin = box.width * 0.2;
    final x = (box.left - margin).round().clamp(0, uprightFrame.width - 1);
    final y = (box.top - margin).round().clamp(0, uprightFrame.height - 1);
    final w =
        (box.width + margin * 2).round().clamp(1, uprightFrame.width - x);
    final h =
        (box.height + margin * 2).round().clamp(1, uprightFrame.height - y);

    final crop = img.copyResize(
      img.copyCrop(uprightFrame, x: x, y: y, width: w, height: h),
      width: _inputSize,
      height: _inputSize,
    );

    // Normalisation MobileFaceNet : (pixel - 127.5) / 127.5
    final input = Float32List(_inputSize * _inputSize * 3);
    var i = 0;
    for (var py = 0; py < _inputSize; py++) {
      for (var px = 0; px < _inputSize; px++) {
        final p = crop.getPixel(px, py);
        input[i++] = (p.r - 127.5) / 127.5;
        input[i++] = (p.g - 127.5) / 127.5;
        input[i++] = (p.b - 127.5) / 127.5;
      }
    }

    // Sortie en List<double> brut : le copyTo de tflite_flutter affecte des
    // List<double> dans le conteneur -> un buffer typé Float32List le fait
    // planter ("List<double> is not a subtype of Float32List").
    final output = [List<double>.filled(_outputSize, 0.0)];
    _interpreter.run(
      input.reshape([1, _inputSize, _inputSize, 3]),
      output,
    );
    return _l2Normalize(Float32List.fromList(output.first));
  }

  static Float32List _l2Normalize(Float32List v) {
    var norm = 0.0;
    for (final x in v) {
      norm += x * x;
    }
    norm = math.sqrt(norm);
    if (norm == 0) return v;
    final out = Float32List(v.length);
    for (var i = 0; i < v.length; i++) {
      out[i] = v[i] / norm;
    }
    return out;
  }

  /// Similarité cosinus entre deux embeddings normalisés L2 : produit
  /// scalaire, dans [-1, 1]. Même personne ≈ 0.6+, inconnus ≈ < 0.4.
  static double cosine(Float32List a, Float32List b) {
    assert(a.length == b.length);
    var dot = 0.0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
    }
    return dot;
  }

  /// Moyenne L2-normalisée de plusieurs embeddings (enrôlement multi-frames).
  static Float32List average(List<Float32List> embeddings) {
    final out = Float32List(embeddings.first.length);
    for (final e in embeddings) {
      for (var i = 0; i < out.length; i++) {
        out[i] += e[i];
      }
    }
    for (var i = 0; i < out.length; i++) {
      out[i] /= embeddings.length;
    }
    return _l2Normalize(out);
  }

  /// Photo témoin compacte (jointe aux pointages pour audit dashboard).
  static Uint8List witnessJpeg(img.Image uprightFrame, {int width = 240}) =>
      Uint8List.fromList(img.encodeJpg(
        img.copyResize(uprightFrame, width: width),
        quality: 60,
      ));
}

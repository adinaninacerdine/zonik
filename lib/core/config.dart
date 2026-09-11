/// Configuration globale de l'application.
class AppConfig {
  AppConfig._();

  /// Backend Node/Express + PostGIS (VPS), servi en HTTPS par Caddy.
  /// Ne jamais remettre l'IP brute ici : le certificat n'est valable que
  /// pour le nom de domaine, et le manifest n'autorise plus le HTTP.
  static const String apiBaseUrl = 'https://api.zonik.info';

  /// Délai max pour obtenir une position GPS avant fallback.
  static const Duration gpsTimeout = Duration(seconds: 15);

  /// Intervalle de la synchronisation périodique de secours.
  static const Duration syncInterval = Duration(minutes: 2);

  /// Similarité cosinus minimale entre l'empreinte du pointage et celle
  /// de l'enrôlement pour considérer que c'est la même personne.
  /// Phase de calibration : les non-correspondances sont ACCEPTÉES mais
  /// marquées « identité douteuse » (visibles dans le dashboard avec photo).
  static const double faceMatchThreshold = 0.55;
}

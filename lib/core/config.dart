/// Configuration globale de l'application.
class AppConfig {
  AppConfig._();

  /// Backend Node/Express + PostGIS (VPS), servi en HTTPS par Caddy.
  /// Ne jamais remettre l'IP brute ici : le certificat n'est valable que
  /// pour le nom de domaine, et le manifest n'autorise plus le HTTP.
  static const String apiBaseUrl = 'https://api.zonik.info';

  /// Délai max pour obtenir une position GPS avant fallback.
  static const Duration gpsTimeout = Duration(seconds: 15);

  /// Similarité cosinus minimale entre l'empreinte du pointage et celle
  /// de l'enrôlement pour considérer que c'est la même personne.
  /// Phase de calibration : les non-correspondances sont ACCEPTÉES mais
  /// marquées « identité douteuse » (visibles dans le dashboard avec photo).
  static const double faceMatchThreshold = 0.55;

  // ---------------------------------------------------------------------------
  // Synchronisation
  // ---------------------------------------------------------------------------

  /// Intervalle du réveil périodique (le moteur respecte de toute façon le
  /// backoff de chaque pointage : ce n'est pas un envoi forcé).
  static const Duration syncInterval = Duration(minutes: 2);

  /// Nombre max de pointages par requête /sync.
  static const int syncBatchMaxItems = 10;

  /// Poids max (photos JPEG brutes) d'un lot. Un lot contient toujours au
  /// moins un pointage, même si sa photo dépasse seule ce plafond.
  static const int syncBatchMaxPhotoBytes = 1200 * 1024;

  /// Délai de base d'une requête, plus un supplément par photo du lot
  /// (réseau EDGE/3G faible : une photo de 60 Ko peut prendre 10 s).
  static const Duration syncBaseTimeout = Duration(seconds: 20);
  static const Duration syncTimeoutPerPhoto = Duration(seconds: 8);
  static const Duration syncMaxTimeout = Duration(seconds: 90);

  /// Backoff exponentiel après échec réseau/serveur : 30 s, 1 min, 2 min…
  /// plafonné à 30 min. Le bouton « Synchroniser » l'ignore.
  static const Duration syncBackoffBase = Duration(seconds: 30);
  static const Duration syncBackoffMax = Duration(minutes: 30);

  /// Pointages synchronisés conservés localement (historique de l'écran).
  static const Duration punchRetention = Duration(days: 30);

  // ---------------------------------------------------------------------------
  // Données de référence (sites, vacations) mises en cache hors ligne
  // ---------------------------------------------------------------------------

  /// Fréquence de rafraîchissement du cache quand le réseau est là.
  static const Duration contextRefreshInterval = Duration(minutes: 30);

  /// Fenêtre de vacations téléchargées : hier → J+7 (une semaine sans
  /// réseau reste couverte).
  static const int shiftsDaysBack = 1;
  static const int shiftsDaysAhead = 7;

  /// Tolérance ajoutée au rayon d'un site pour absorber l'imprécision GPS
  /// (plafonnée : une précision de 500 m ne doit pas valider n'importe quoi).
  static const double geofenceMaxAccuracyAllowance = 50;

  /// Écart d'horloge téléphone/serveur au-delà duquel l'agent est prévenu.
  static const Duration clockSkewWarning = Duration(minutes: 5);
}

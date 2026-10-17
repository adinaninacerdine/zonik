# Zonik — pointage géolocalisé

App Flutter de pointage pour agents de terrain (gardiennage).
Offline-first : chaque pointage est écrit en local (Drift/SQLite) puis
synchronisé vers le backend (`/api/attendance/sync`, dédup par `clientUuid`).

## Fonctionnement

1. Connexion : entreprise (slug) + matricule + PIN → token stocké en secure storage.
2. Pointage arrivée/départ :
   - vérification de présence (caméra frontale + clignement des yeux, ML Kit) ;
   - capture GPS (fallback dernière position connue si signal faible) ;
   - écriture locale immédiate, puis tentative de sync.
3. Sync automatique : au lancement, au retour au premier plan, au retour du
   réseau (connectivity_plus), après chaque pointage et toutes les 2 minutes —
   par petits lots, backoff exponentiel, refus isolés, 401 géré sans perte.
4. Planning et sites téléchargés (hier → J+7) et lus depuis le cache local :
   vacation du jour et contrôle de zone disponibles hors ligne.

Détail du fonctionnement hors ligne et du contrat backend :
[`docs/OFFLINE_SYNC.md`](docs/OFFLINE_SYNC.md).

Identifiants de test : slug `demo`, matricule `EMP001`, PIN `1234`.

## Structure

- `lib/core/` — config (URL API) et client HTTP (Bearer token)
- `lib/data/database.dart` — schéma Drift (table `punches`)
- `lib/features/auth/` — login, session, contrôleur Riverpod
- `lib/features/attendance/` — pointage, sync, écran d'accueil
- `lib/features/liveness/` — caméra + détection de clignement

## Commandes

```sh
flutter pub get
dart run build_runner build        # régénérer database.g.dart après modif du schéma
flutter analyze
flutter test
flutter build apk --debug          # APK de test
flutter run                        # sur téléphone physique branché (USB, débogage activé)
```

L'APK debug se trouve dans `build/app/outputs/flutter-apk/app-debug.apk`
(installable directement : `flutter install` ou copie sur le téléphone).

Backend : `github.com/adinaninacerdine/pointage-saas` — voir `CLAUDE.md`.

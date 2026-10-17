# Zonik — app mobile de pointage géolocalisé

## Contexte
App Flutter pour agents de terrain (gardiennage, Afrique francophone).
Backend Node/Express + PostGIS déployé sur VPS : http://31.207.37.178:3001
Repo backend : github.com/adinaninacerdine/pointage-saas

## API (testée, fonctionnelle)
- POST /api/auth/employee/login {tenantSlug, matricule, pin} → {token}
- POST /api/attendance/punch {type: in|out, method: gps, clientUuid, payload:{lat,lng}} (Bearer token)
- POST /api/attendance/sync {punches: [...]} — lot offline, dédup par clientUuid
  (réponse par pointage `results: [{clientUuid, status, reason}]` prise en charge)
- GET /api/mobile/context?from&to → {sites, shifts} (repli sur
  GET /api/scheduling/me/shifts tant qu'il renvoie 404)
- Identifiants de test : slug=demo, matricule=EMP001, PIN=1234
- Site test : Siège Moroni (-11.7022, 43.2551), rayon 150m

## Architecture décidée
- Gestion d'état : Riverpod
- Offline-first : chaque pointage écrit en local (Drift/SQLite) avec client_uuid,
  puis synchronisé via /sync. L'app ne dépend JAMAIS du réseau pour pointer.
- Depuis la 1.2 (voir docs/OFFLINE_SYNC.md) : pointages attachés à l'agent
  (tenant+matricule), moteur SyncEngine (lots, backoff, bisection des 4xx,
  413 → renvoi sans photo, 401 → suspension), horloge monotone native
  (canal com.zonik.pointage/clock dans MainActivity.kt), cache Drift des
  sites et vacations, contrôle de zone local indicatif. Schéma Drift v3 :
  après toute modif de database.dart → dart run build_runner build.
- Tests du moteur de sync : test/sync_engine_test.dart (base en mémoire +
  MockClient) — à garder verts avant chaque release.
- Liveness V1 : ML Kit détection visage + clignement (pas de reconnaissance d'identité)
- Test sur téléphone physique (pas d'émulateur — espace disque limité)

## Contraintes
- Disque C: presque plein (~2-6 Go libres selon pagefile) : rester économe, pas d'émulateur
- RAM 8 Go : gradle.properties limité à -Xmx2G (le -Xmx8G du template gonfle le
  pagefile Windows à ~12 Go et remplit le disque ; il dégonfle au redémarrage)
- Connexion internet instable : téléchargements avec reprise si besoin

## Pièges build Android (résolus, ne pas défaire)
- PAS de NDK possible (~4 Go). Trois protections en place :
  1. drift épinglé ">=2.28.0 <2.32.0" (sqlite3 3.x = native assets = NDK requis)
  2. path_provider_android épinglé "<2.3.0" (2.3+ passe par jni → NDK)
  3. android/app/build.gradle.kts : externalNativeBuild.cmake.path = null
     (annule le forceNdkDownload du plugin Gradle de Flutter 3.44 qui branche
     un CMakeLists factice exprès pour télécharger le NDK)
- ML Kit exige la plateforme android-35 (installée)
- minSdk 23 (flutter_secure_storage v10)
- R8 en release casse ML Kit : les ComponentRegistrar (FaceRegistrar, etc.)
  sont instanciés par réflexion, R8 supprime leurs constructeurs →
  NPE "InputImageConverterError … getClass() on null" sur CHAQUE frame,
  uniquement en release. Correction : android/app/proguard-rules.pro
  (-keep class com.google.mlkit.**) branché dans build.gradle.kts. Ne pas retirer.
- tflite_flutter 0.11 (reconnaissance faciale) : quatre rustines, ne pas défaire.
  1. Kotlin du module forcé en JVM 1.8 (racine build.gradle.kts) : son Java
     compile en 1.8, Kotlin héritait de 17 → "Inconsistent JVM Target"
  2. compileSdk du module remonté à 36 via afterEvaluate (racine)
  3. TFLite forcé à 2.16.1 (app build.gradle.kts) : les AAR 2.11 épinglés
     partagent le namespace org.tensorflow.lite, refusé par AGP 9
  4. proguard-rules.pro : -keep/-dontwarn org.tensorflow.lite.** (le runtime
     référence des classes gpu-api absentes ; inférence CPU de toute façon)
- tflite_flutter run() : buffer de sortie en List<double> NON typé (un
  Float32List fait planter son copyTo à l'exécution) — voir face_service.dart.

## Build de distribution (~27 Mo au lieu de 184)
Sans NDK, Gradle ne peut pas stripper libflutter.so (146 Mo de symboles !).
Procédure complète :
  1. flutter build apk --release --split-per-abi --target-platform android-arm
     (--split-per-abi vire aussi les libs x86_64/arm64 des plugins, ~20 Mo)
  2. python tool/shrink_apk.py build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk \
       build/app/outputs/flutter-apk/zonik-X.Y.Z.apk
     (strip des .so + rezip + zipalign + re-signature apksigner ; lit android/key.properties)
Prérequis : C:\Dev\tools\llvm-strip\llvm-strip.exe — extrait SEUL du zip NDK
(3,5 Mo téléchargés via requêtes HTTP Range, jamais les 780 Mo du zip).
Le keystore android/keystore/zonik-release.jks + android/key.properties sont
DÉFINITIFS et non versionnés : sauvegarde externe obligatoire.

## Test sur le Redmi 9C (MediaTek, MIUI)
- ABI armeabi-v7a (32 bits) → builds téléphone :
  flutter build apk --release --target-platform android-arm
  (l'APK debug fait ~400 Mo/ABI — moteur non strippé — et ne tient ni sur
  le disque PC ni sur le téléphone, qui n'a que quelques centaines de Mo libres)
- La caméra frontale livre du NV21 propre (1 plan, stride = largeur, 320x240) :
  CameraX honore bien imageFormatGroup nv21 sur cet appareil
- MIUI bloque l'injection adb (input tap/keyevent → SecurityException INJECT_EVENTS)
  et peut demander une confirmation à l'écran pour l'installation USB
- Buffer logcat main : 256 Kio, saturé en secondes par MIUI → adb logcat -G 4M
  avant toute session de debug
- Stockage presque plein : adb shell pm trim-caches 4G libère ~1 Go de caches
import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Signature release : les secrets vivent dans android/key.properties (jamais
// versionné). Le keystore android/keystore/zonik-release.jks est DÉFINITIF :
// le perdre = impossible de mettre à jour l'app publiée. Sauvegardez les deux.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    FileInputStream(keystorePropertiesFile).use { stream ->
        keystoreProperties.load(stream)
    }
}

android {
    namespace = "com.zonik.pointage"
    compileSdk = flutter.compileSdkVersion

    // ndkVersion est indispensable même sans code natif à compiler : c'est
    // l'outil `strip` du NDK que Gradle utilise pour retirer les symboles de
    // debug des .so de Flutter et des plugins. Sans lui, libflutter.so est
    // emballé tel quel (~165 Mo par architecture au lieu de ~10 Mo).
    // La version attendue est celle de flutter.ndkVersion (28.2.13676358 pour
    // Flutter 3.44) — installée via sdkmanager --install "ndk;<version>".
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.zonik.pointage"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // flutter_secure_storage v10 exige minSdk 23 ; ML Kit et CameraX 21+.
        minSdk = maxOf(23, flutter.minSdkVersion)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Le plugin Gradle de Flutter branche un CMakeLists factice pour les
    // "native assets" Dart. Ce projet n'en utilise aucun : on le débranche,
    // ce qui n'empêche pas le strip des bibliothèques (étape de packaging).
    externalNativeBuild {
        cmake {
            path = null
        }
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Repli sur la clé debug si key.properties absent (poste sans secrets).
            // ATTENTION : un APK signé en debug ne doit jamais être distribué aux
            // clients — la première mise à jour signée release serait refusée.
            signingConfig = if (keystorePropertiesFile.exists())
                signingConfigs.getByName("release")
            else
                signingConfigs.getByName("debug")
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

// tflite_flutter épingle TFLite 2.11, dont les AAR partagent tous le
// namespace org.tensorflow.lite -> refusé par la validation d'AGP 9
// (« Namespace used in multiple modules »). Les 2.16+ ont des namespaces
// uniques et une API C stable : on force la version.
configurations.configureEach {
    resolutionStrategy {
        force("org.tensorflow:tensorflow-lite:2.16.1")
        force("org.tensorflow:tensorflow-lite-gpu:2.16.1")
        force("org.tensorflow:tensorflow-lite-api:2.16.1")
    }
}

flutter {
    source = "../.."
}

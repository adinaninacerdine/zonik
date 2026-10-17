package com.zonik.pointage

import android.os.Build
import android.os.SystemClock
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Horloge de confiance pour les pointages hors ligne :
        // elapsedRealtime() compte les ms depuis le démarrage du téléphone,
        // sommeil compris, et l'utilisateur ne peut pas la modifier (contrairement
        // à l'heure système). Avec le compteur de démarrages, le serveur peut
        // recalculer l'heure réelle d'un pointage fait sans réseau.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CLOCK_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "sample" -> result.success(
                        mapOf(
                            "elapsedRealtimeMs" to SystemClock.elapsedRealtime(),
                            "bootCount" to bootCount(),
                            "wallClockMs" to System.currentTimeMillis(),
                            "autoTime" to autoTimeEnabled(),
                        )
                    )
                    else -> result.notImplemented()
                }
            }
    }

    /** Nombre de démarrages du téléphone (API 24+), -1 si indisponible. */
    private fun bootCount(): Int {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return -1
        return try {
            Settings.Global.getInt(contentResolver, Settings.Global.BOOT_COUNT)
        } catch (e: Exception) {
            -1
        }
    }

    /** Heure automatique (réseau) activée : 1, désactivée : 0, inconnue : -1. */
    private fun autoTimeEnabled(): Int {
        return try {
            Settings.Global.getInt(contentResolver, Settings.Global.AUTO_TIME)
        } catch (e: Exception) {
            -1
        }
    }

    companion object {
        private const val CLOCK_CHANNEL = "com.zonik.pointage/clock"
    }
}

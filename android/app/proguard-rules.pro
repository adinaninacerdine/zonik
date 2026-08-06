# ML Kit : ses ComponentRegistrar (FaceRegistrar, CommonComponentRegistrar,
# VisionCommonRegistrar) sont instanciés par réflexion au démarrage
# (ComponentDiscovery lit les meta-data du manifest). R8 ne voit aucun appel
# à leurs constructeurs et les supprime → "NoSuchMethodException: <init> []"
# → détection de visage entièrement hors service en release.
-keep class com.google.mlkit.** { *; }
-dontwarn com.google.mlkit.**

# TFLite (reconnaissance faciale). Le runtime référence des classes du
# délégué GPU (gpu-api) absentes du classpath — on ne l'utilise pas
# (inférence CPU sur armeabi-v7a) : on fait taire R8.
-keep class org.tensorflow.lite.** { *; }
-dontwarn org.tensorflow.lite.**

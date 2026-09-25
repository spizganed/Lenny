# lenny_jni.cpp looks these callbacks up by name (GetMethodID): R8 must not rename or drop them.
-keep interface com.spizganed.android_camera.SenderListener { *; }
-keepclassmembers class * implements com.spizganed.android_camera.SenderListener {
    public *** on*(...);
}

# The Google code scanner (scanQr) wires its internals by reflection; without these the release build throws an
# NPE inside ML Kit the moment the scanner starts.
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_code_scanner.** { *; }

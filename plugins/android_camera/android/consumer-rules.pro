# lenny_jni.cpp looks these callbacks up by name (GetMethodID): R8 must not rename or drop them.
-keep interface com.spizganed.android_camera.SenderListener { *; }
-keepclassmembers class * implements com.spizganed.android_camera.SenderListener {
    public *** on*(...);
}

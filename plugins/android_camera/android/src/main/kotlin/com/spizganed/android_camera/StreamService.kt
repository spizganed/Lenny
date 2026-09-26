package com.spizganed.android_camera

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat

/**
 * Foreground service with type "camera". It holds no pipeline state; its only job is to keep the process allowed to
 * use the camera with the screen off or another app in front (Android 11+ blocks background camera access otherwise).
 * It also holds Wi-Fi locks: with power saving on, the router holds traffic *to* the phone (TCP ACKs, PINGs) until the
 * radio wakes, the upload stalls, and the stream stutters every second or two (measured: RTT 300-900 ms instead of ~5).
 */
class StreamService : Service() {
    private val wifiLocks = mutableListOf<WifiManager.WifiLock>()

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        wifiLocks.forEach { if (it.isHeld) it.release() }
        wifiLocks.clear()
        super.onDestroy()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val nm = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(NotificationChannel(CHANNEL, "Streaming", NotificationManager.IMPORTANCE_LOW))
        }
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        val notification = NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_menu_camera)
            .setContentTitle(applicationInfo.loadLabel(packageManager))
            .setContentText("Streaming your camera")
            .setOngoing(true)
            .setContentIntent(
                launch?.let {
                    android.app.PendingIntent.getActivity(this, 0, it, android.app.PendingIntent.FLAG_IMMUTABLE)
                },
            )
            .build()
        val type = if (Build.VERSION.SDK_INT >= 30) ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA else 0
        ServiceCompat.startForeground(this, 1, notification, type)
        if (wifiLocks.isEmpty()) {
            val wm = applicationContext.getSystemService(WifiManager::class.java)
            // Low latency (API 29+) works while the app is in front with the screen on; high perf covers screen off
            // on phones before Android 14 (it's a no-op after).
            @Suppress("DEPRECATION")
            val modes = listOfNotNull(
                if (Build.VERSION.SDK_INT >= 29) WifiManager.WIFI_MODE_FULL_LOW_LATENCY else null,
                WifiManager.WIFI_MODE_FULL_HIGH_PERF,
            )
            modes.forEach { mode ->
                wm.createWifiLock(mode, "lenny:stream").apply { setReferenceCounted(false); acquire() }.also(wifiLocks::add)
            }
        }
        return START_NOT_STICKY
    }

    private companion object {
        const val CHANNEL = "stream"
    }
}

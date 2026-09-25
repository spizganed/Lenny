package com.spizganed.android_camera

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat

/**
 * Foreground service with type "camera". It holds no pipeline state; its only job is to keep the process allowed to
 * use the camera with the screen off or another app in front (Android 11+ blocks background camera access otherwise).
 */
class StreamService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

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
        return START_NOT_STICKY
    }

    private companion object {
        const val CHANNEL = "stream"
    }
}

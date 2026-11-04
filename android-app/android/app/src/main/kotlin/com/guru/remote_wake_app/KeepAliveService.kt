package com.guru.remote_wake_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.net.wifi.WifiManager
import android.os.PowerManager

// Foreground service held while a terminal session is open: stops Android from freezing/killing the process
// (which holds the Tailscale engine and the SSH connection) when the app is in the background or the screen is off.
class KeepAliveService : Service() {
    private var wl: PowerManager.WakeLock? = null
    private var wifi: WifiManager.WifiLock? = null

    override fun onBind(i: Intent?): IBinder? = null

    override fun onStartCommand(i: Intent?, flags: Int, startId: Int): Int {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel("session", "Active session", NotificationManager.IMPORTANCE_LOW))
        val tap = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val n = Notification.Builder(this, "session")
            .setContentTitle("Remote Wake")
            .setContentText(i?.getStringExtra("text") ?: "Terminal session open")
            .setSmallIcon(android.R.drawable.ic_lock_idle_lock)
            .setContentIntent(tap).setOngoing(true).build()
        if (Build.VERSION.SDK_INT >= 34) startForeground(1, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE) else startForeground(1, n)
        if (wl == null) {
            wl = (getSystemService(POWER_SERVICE) as PowerManager).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "remotewake:session")
                .apply { acquire(4 * 60 * 60 * 1000L) } // ponytail: 4 h cap so a forgotten session cannot drain the battery forever
        }
        if (wifi == null) {   // no Wi-Fi power saving while the screen is on and the app is in front: keystroke echoes stop waiting for the radio to wake (6-100 ms jitter without it)
            wifi = (applicationContext.getSystemService(WIFI_SERVICE) as WifiManager)
                .createWifiLock(if (Build.VERSION.SDK_INT >= 29) WifiManager.WIFI_MODE_FULL_LOW_LATENCY else WifiManager.WIFI_MODE_FULL_HIGH_PERF, "remotewake:wifi")
                .apply { setReferenceCounted(false); acquire() }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        wl?.let { if (it.isHeld) it.release() }
        wifi?.let { if (it.isHeld) it.release() }
        super.onDestroy()
    }
}

package com.guru.remote_wake_app

import android.Manifest
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "rw/native").setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    if (Build.VERSION.SDK_INT >= 33) requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
                    startForegroundService(Intent(this, KeepAliveService::class.java).putExtra("text", call.argument<String>("text")))
                    result.success(null)
                }
                "stop" -> { stopService(Intent(this, KeepAliveService::class.java)); result.success(null) }
                // returns true when the app is already exempt from battery optimisation; otherwise opens the system prompt and returns false
                "batteryExempt" -> {
                    val pm = getSystemService(POWER_SERVICE) as PowerManager
                    if (pm.isIgnoringBatteryOptimizations(packageName)) result.success(true) else {
                        startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$packageName")))
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}

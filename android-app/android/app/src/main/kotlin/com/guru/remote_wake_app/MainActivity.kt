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
                "deviceName" -> result.success(Settings.Global.getString(contentResolver, "device_name") ?: "${Build.MANUFACTURER} ${Build.MODEL}")
                "version" -> result.success(packageManager.getPackageInfo(packageName, 0).versionName)
                "saveToDownloads" -> {
                    try {
                        val name = call.argument<String>("name")!!
                        val src = java.io.File(call.argument<String>("path")!!)
                        val v = android.content.ContentValues().apply {
                            put(android.provider.MediaStore.Downloads.DISPLAY_NAME, name)
                            put(android.provider.MediaStore.Downloads.RELATIVE_PATH, "Download/Remote Wake")
                        }
                        val uri = contentResolver.insert(android.provider.MediaStore.Downloads.EXTERNAL_CONTENT_URI, v)!!
                        contentResolver.openOutputStream(uri)!!.use { o -> src.inputStream().use { it.copyTo(o) } }
                        result.success(null)
                    } catch (e: Throwable) { result.error("save", e.message, null) }
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

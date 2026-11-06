import 'package:flutter/services.dart';

// Android-side helpers (KeepAliveService + battery exemption), see MainActivity.kt.
class Native {
  static const _c = MethodChannel('rw/native');
  static Future<void> start(String text) => _c.invokeMethod('start', {'text': text});
  static Future<void> stop() => _c.invokeMethod('stop');
  // the name the user gave the phone (Settings > About), as a Tailscale-safe host name
  static Future<String> deviceName() async => (await _c.invokeMethod<String>('deviceName')) ?? 'phone';
  static Future<void> saveToDownloads(String path, String name) => _c.invokeMethod('saveToDownloads', {'path': path, 'name': name});
  static Future<String> version() async => (await _c.invokeMethod<String>('version')) ?? '';
  static Future<bool> batteryExempt() async => (await _c.invokeMethod<bool>('batteryExempt')) ?? false;
}

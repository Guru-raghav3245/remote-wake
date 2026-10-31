import 'package:flutter/services.dart';

// Android-side helpers (KeepAliveService + battery exemption), see MainActivity.kt.
class Native {
  static const _c = MethodChannel('rw/native');
  static Future<void> start(String text) => _c.invokeMethod('start', {'text': text});
  static Future<void> stop() => _c.invokeMethod('stop');
  static Future<bool> batteryExempt() async => (await _c.invokeMethod<bool>('batteryExempt')) ?? false;
}

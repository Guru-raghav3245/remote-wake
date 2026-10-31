import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'package:ffi/ffi.dart';

// Thin wrapper over libtsengine.so (Go: userspace Tailscale node + SSH client, see android-proto/engine).
final _lib = DynamicLibrary.open('libtsengine.so');
final _free = _lib.lookupFunction<Void Function(Pointer<Utf8>), void Function(Pointer<Utf8>)>('rw_free');

String _take(Pointer<Utf8> p) { final s = p.toDartString(); _free(p); return s; }

String _start(String dir, String key) {
  final f = _lib.lookupFunction<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>), Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>)>('rw_start');
  return using((a) => _take(f(dir.toNativeUtf8(allocator: a), key.toNativeUtf8(allocator: a))));
}

String _state() =>
    _take(_lib.lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>('rw_state')());

String _exec(String addr, String user, String cmd) {
  final f = _lib.lookupFunction<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>)>('rw_exec');
  return using((a) => _take(f(addr.toNativeUtf8(allocator: a), user.toNativeUtf8(allocator: a), cmd.toNativeUtf8(allocator: a))));
}

class Engine {
  static String start(String dir, {String authKey = ''}) => _start(dir, authKey);
  static Map<String, dynamic> state() => jsonDecode(_state()) as Map<String, dynamic>;
  // blocking Go calls run off the UI isolate
  static Future<String> exec(String addr, String user, String cmd) => Isolate.run(() => _exec(addr, user, cmd));
}

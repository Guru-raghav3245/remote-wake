import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'package:ffi/ffi.dart';

// Thin wrapper over libtsengine.so (Go: userspace Tailscale node + SSH client, see android-proto/engine).
final _lib = DynamicLibrary.open('libtsengine.so');
final _free = _lib.lookupFunction<Void Function(Pointer<Utf8>), void Function(Pointer<Utf8>)>('rw_free');

String _take(Pointer<Utf8> p) { final s = p.toDartString(); _free(p); return s; }

String _start(String dir, String key, String host) {
  final f = _lib.lookupFunction<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>), Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>)>('rw_start');
  return using((a) => _take(f(dir.toNativeUtf8(allocator: a), key.toNativeUtf8(allocator: a), host.toNativeUtf8(allocator: a))));
}

String _state() =>
    _take(_lib.lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>('rw_state')());

String _exec(String addr, String user, String cmd) {
  final f = _lib.lookupFunction<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>)>('rw_exec');
  return using((a) => _take(f(addr.toNativeUtf8(allocator: a), user.toNativeUtf8(allocator: a), cmd.toNativeUtf8(allocator: a))));
}

int _shellOpen(String addr, String user, String pinned, int cols, int rows) {
  final f = _lib.lookupFunction<Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Int32, Int32),
      int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, int, int)>('rw_shell_open');
  return using((a) => f(addr.toNativeUtf8(allocator: a), user.toNativeUtf8(allocator: a), pinned.toNativeUtf8(allocator: a), cols, rows));
}

String _fetch(String addr, String user, String pinned, String cmd, String dest) {
  final f = _lib.lookupFunction<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>)>('rw_fetch');
  return using((a) => _take(f(addr.toNativeUtf8(allocator: a), user.toNativeUtf8(allocator: a), pinned.toNativeUtf8(allocator: a), cmd.toNativeUtf8(allocator: a), dest.toNativeUtf8(allocator: a))));
}

class Engine {
  /// Runs [cmd] on the Mac and saves its stdout to the local file [dest]. Returns '' or 'ERROR: ...'.
  static Future<String> fetch(String addr, String user, String pinned, String cmd, String dest) => Isolate.run(() => _fetch(addr, user, pinned, cmd, dest));

  // Interactive shell with a PTY. open() blocks (dial + SSH handshake) so it runs off the UI isolate; the rest are quick buffer operations.
  static Future<int> shellOpen(String addr, String user, String pinned, int cols, int rows) => Isolate.run(() => _shellOpen(addr, user, pinned, cols, rows));
  static String lastHostKey() =>
      _take(_lib.lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>('rw_last_hostkey')());
  static String lastBanner() =>
      _take(_lib.lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>('rw_last_banner')());
  static String lastError() =>
      _take(_lib.lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>('rw_last_error')());
  static String shellRead(int id) => _take(_lib.lookupFunction<Pointer<Utf8> Function(Int32), Pointer<Utf8> Function(int)>('rw_shell_read')(id));
  /// Blocks (call it off the UI isolate) until output is waiting, the shell ended, or [ms] passed.
  static void shellWait(int id, int ms) => _lib.lookupFunction<Void Function(Int32, Int32), void Function(int, int)>('rw_shell_wait')(id, ms);
  static bool shellAlive(int id) => _lib.lookupFunction<Int32 Function(Int32), int Function(int)>('rw_shell_alive')(id) == 1;
  static bool shellDropped(int id) => _lib.lookupFunction<Int32 Function(Int32), int Function(int)>('rw_shell_dropped')(id) == 1;
  static void shellWrite(int id, String b64) => using((a) => _lib
      .lookupFunction<Void Function(Int32, Pointer<Utf8>), void Function(int, Pointer<Utf8>)>('rw_shell_write')(id, b64.toNativeUtf8(allocator: a)));
  static void shellResize(int id, int cols, int rows) =>
      _lib.lookupFunction<Void Function(Int32, Int32, Int32), void Function(int, int, int)>('rw_shell_resize')(id, cols, rows);
  static void shellClose(int id) => _lib.lookupFunction<Void Function(Int32), void Function(int)>('rw_shell_close')(id);

  static String start(String dir, {String authKey = '', String host = 'phone'}) => _start(dir, authKey, host);
  static Map<String, dynamic> state() => jsonDecode(_state()) as Map<String, dynamic>;
  // blocking Go calls run off the UI isolate
  static Future<String> exec(String addr, String user, String cmd) => Isolate.run(() => _exec(addr, user, cmd));
}

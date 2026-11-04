import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:xterm/xterm.dart';
import 'engine.dart';
import 'native.dart';
import 'store.dart';
import 'theme.dart';

// Waits for output in a background isolate (blocking call into the engine) and posts it to the UI the moment it arrives; no timer polling.
void _reader(List<Object> a) {
  final port = a[0] as SendPort, id = a[1] as int;
  while (true) {
    Engine.shellWait(id, 1000);
    final b = Engine.shellRead(id);
    if (b.isNotEmpty) port.send(b);
    if (!Engine.shellAlive(id)) { port.send(null); return; }
  }
}

// Interactive shell on the Mac: gets output from the Go engine, sends keystrokes back, with an extra-keys row for what phone keyboards lack.
class TerminalPage extends StatefulWidget {
  final String name, ip, user;
  const TerminalPage({super.key, required this.name, required this.ip, required this.user});
  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends State<TerminalPage> {
  final term = Terminal(maxLines: 10000);
  int id = -1;
  String status = 'connecting...';
  bool ctrl = false;
  ReceivePort? rp;
  bool reconnecting = false, gaveUp = false;
  int attempt = 0;
  String? seenUrl; // the engine keeps the last banner; only a NEW link means a new approval is needed
  String? approveUrl; // Tailscale "check" policy: the Mac asks for a browser approval (link arrives as the SSH banner)

  @override
  void initState() {
    super.initState();
    Native.start('Connected to ${widget.name}');
    term.onOutput = (data) => _send(data);
    term.onResize = (w, h, pw, ph) { if (id > 0) Engine.shellResize(id, w, h); };
    WidgetsBinding.instance.addPostFrameCallback((_) => _open()); // open after layout so the PTY gets the real size
  }

  Future<void> _open() async {
    final sw = Stopwatch()..start();
    final pin = await Store.hostKey(widget.ip);
    final bt = Timer.periodic(const Duration(milliseconds: 500), (_) {
      final b = Engine.lastBanner();
      final m = RegExp(r'https://\S+').firstMatch(b);
      if (m != null && seenUrl != m.group(0)) { debugPrint('APPROVEURL ${m.group(0)}'); seenUrl = m.group(0); setState(() { approveUrl = m.group(0); status = 'waiting for approval'; }); }
    });
    final r = await Engine.shellOpen('${widget.ip}:22', widget.user, pin, term.viewWidth, term.viewHeight);
    bt.cancel();
    if (!mounted) { if (r > 0) Engine.shellClose(r); return; }
    if (approveUrl != null) setState(() => approveUrl = null);
    if (r < 0) {
      final err = Engine.lastError();
      if (err.contains('HOSTKEY_CHANGED')) { _hostKeyChanged(Engine.lastHostKey()); return; }
      if (!reconnecting) setState(() => status = 'failed: $err');
      return;
    }
    if (pin.isEmpty) await Store.setHostKey(widget.ip, Engine.lastHostKey()); // trust on first use
    id = r;
    Engine.shellResize(id, term.viewWidth, term.viewHeight); // the layout may have changed while connecting
    if (reconnecting) term.write('\r\n[reconnected: programs outside a phone session were stopped]\r\n');
    reconnecting = false; gaveUp = false; attempt = 0;
    setState(() => status = 'connected in ${sw.elapsedMilliseconds} ms');
    rp = ReceivePort();
    rp!.listen((m) {
      if (m is String) {
        try { term.write(utf8.decode(base64.decode(m), allowMalformed: true)); } catch (e) { debugPrint('terminal parse error: $e'); }   // a bad escape sequence must not stop the screen
      } else {
        _ended();
      }
    });
    await Isolate.spawn(_reader, [rp!.sendPort, id]);
  }

  Future<void> _ended() async {
    rp?.close(); rp = null;
    await Future.delayed(const Duration(milliseconds: 200));   // the engine notes "connection lost" a moment after the output ends
    if (!mounted || id <= 0) return;
    final dropped = Engine.shellDropped(id);
    Engine.shellClose(id);
    id = -1;
    if (dropped) { _reconnect(); } else { setState(() => status = 'session ended'); }
  }

  // The connection dropped: keep the screen, retry with a growing pause (2,4,8,15 s ...), give up after 10 tries (button to retry).
  Future<void> _reconnect() async {
    reconnecting = true; gaveUp = false;
    while (mounted && attempt < 10) {
      attempt++;
      setState(() => status = 'reconnecting (try $attempt)...');
      await Future.delayed(Duration(seconds: [2, 4, 8, 15][(attempt - 1).clamp(0, 3)]));
      if (!mounted) return;
      await _open();
      if (id > 0) return; // _open sets id on success
    }
    if (mounted) setState(() { gaveUp = true; status = 'disconnected'; });
  }

  Future<void> _hostKeyChanged(String fp) async {
    setState(() => status = 'host key changed');
    final trust = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Host key changed'),
        content: Text('${widget.name} presented a different SSH key than before (new: $fp). This is normal after reinstalling Tailscale or the Mac, but it could also mean someone is in the way. Trust the new key?'),
        actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('No')), FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Trust new key'))],
      ),
    );
    if (trust == true) { await Store.setHostKey(widget.ip, fp); setState(() => status = 'connecting...'); _open(); }
  }

  void _send(String data) {
    if (id <= 0) return;
    if (ctrl && data.length == 1) { // sticky Ctrl: a-z -> control character
      final c = data.toLowerCase().codeUnitAt(0);
      if (c >= 97 && c <= 122) data = String.fromCharCode(c - 96);
      setState(() => ctrl = false);
    }
    Engine.shellWrite(id, base64.encode(utf8.encode(data)));
  }

  Widget _key(BuildContext c, String label, {String? data, bool on = false, VoidCallback? onTap}) {
    final s = c.sage;
    return Padding(
      padding: const EdgeInsets.only(right: Sp.sm),
      child: Material(
        color: on ? s.accent : s.soft,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap ?? () => _send(data!),
          child: Container(constraints: const BoxConstraints(minWidth: 44, minHeight: 44), alignment: Alignment.center, padding: const EdgeInsets.symmetric(horizontal: Sp.md),
              child: Text(label, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: on ? s.onAccent : s.text))),
        ),
      ),
    );
  }

  // Terminal stays dark in both modes (programs assume a dark screen); colors come from the Sage palette.
  static const _theme = TerminalTheme(
    cursor: Color(0xFF8FBF9A), selection: Color(0xFF2E3A33), foreground: Color(0xFFE4EBE5), background: Color(0xFF151B17),
    black: Color(0xFF1D2520), red: Color(0xFFE8A097), green: Color(0xFF8FBF9A), yellow: Color(0xFFE5C57A), blue: Color(0xFF8DB4D9), magenta: Color(0xFFC9A3D9), cyan: Color(0xFF7FC8C2), white: Color(0xFFCBD5CD),
    brightBlack: Color(0xFF5E6B61), brightRed: Color(0xFFF2B8B0), brightGreen: Color(0xFFA8D4B2), brightYellow: Color(0xFFF0D894), brightBlue: Color(0xFFA6C8E8), brightMagenta: Color(0xFFDDBCE8), brightCyan: Color(0xFF9AD9D3), brightWhite: Color(0xFFE4EBE5),
    searchHitBackground: Color(0xFFE5C57A), searchHitBackgroundCurrent: Color(0xFF8FBF9A), searchHitForeground: Color(0xFF151B17),
  );

  (String, Color) _tone(BuildContext c) {
    final s = c.sage;
    if (status.startsWith('connected')) return ('Connected', s.accent);
    if (status.startsWith('failed') || status == 'disconnected' || status == 'host key changed') return (status.startsWith('failed') ? 'Failed' : (status == 'disconnected' ? 'Disconnected' : 'Key changed'), s.danger);
    if (status == 'session ended') return ('Ended', s.muted);
    if (status.startsWith('reconnecting')) return ('Reconnecting', s.warn);
    if (status == 'waiting for approval') return ('Needs approval', s.warn);
    return ('Connecting', s.muted);
  }

  @override
  void dispose() {
    Native.stop();
    rp?.close();
    if (id > 0) Engine.shellClose(id);
    super.dispose();
  }

  @override
  Widget build(BuildContext c) {
    final s = c.sage, tone = _tone(c);
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.name, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          Text('${widget.user}@${widget.ip}', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w400, color: s.muted)),
        ]),
        actions: [Padding(padding: const EdgeInsets.only(right: Sp.lg), child: Center(child: StatusWord(tone.$1, tone.$2, key: const Key('tstatus'))))],
      ),
      body: SafeArea(
        child: Column(children: [
          if (approveUrl != null)
            Banner2(
              bg: s.warnBg, fg: s.warn, text: 'Tailscale needs you to approve this connection (about every 12 hours).',
              action: FilledButton(onPressed: () => launchUrl(Uri.parse(approveUrl!), mode: LaunchMode.externalApplication), child: const Text('Approve')),
            ),
          if (reconnecting)
            Banner2(
              bg: s.dangerBg, fg: s.danger, text: gaveUp ? 'Connection lost' : 'Connection lost, reconnecting...',
              lead: gaveUp ? null : SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: s.danger)),
              action: gaveUp ? FilledButton(onPressed: () { attempt = 0; _reconnect(); }, child: const Text('Retry')) : null,
            ),
          const SizedBox(height: Sp.sm),
          Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: Sp.sm), child: ClipRRect(borderRadius: BorderRadius.circular(12), child: TerminalView(term, autofocus: true, theme: _theme, padding: const EdgeInsets.all(Sp.sm), textStyle: const TerminalStyle(fontSize: 13))))),
          Container(
            color: s.card,
            padding: const EdgeInsets.all(Sp.sm),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                _key(c, 'Esc', data: '\x1b'),
                _key(c, 'Tab', data: '\t'),
                _key(c, 'Ctrl', on: ctrl, onTap: () => setState(() => ctrl = !ctrl)),
                _key(c, '^C', data: '\x03'),
                _key(c, '^D', data: '\x04'),
                _key(c, '↑', data: '\x1b[A'),
                _key(c, '↓', data: '\x1b[B'),
                _key(c, '←', data: '\x1b[D'),
                _key(c, '→', data: '\x1b[C'),
                _key(c, '|', data: '|'),
                _key(c, '/', data: '/'),
                _key(c, '-', data: '-'),
                _key(c, '~', data: '~'),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:xterm/xterm.dart';
import 'engine.dart';
import 'native.dart';
import 'store.dart';

// Interactive shell on the Mac: polls the Go engine for output, sends keystrokes back, with an extra-keys row for what phone keyboards lack.
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
  Timer? poll;
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
    if (reconnecting) term.write('\r\n[reconnected: new shell, earlier programs were stopped]\r\n');
    reconnecting = false; gaveUp = false; attempt = 0;
    setState(() => status = 'connected in ${sw.elapsedMilliseconds} ms');
    poll = Timer.periodic(const Duration(milliseconds: 40), (_) {
      final b64 = Engine.shellRead(id);
      if (b64.isNotEmpty) term.write(utf8.decode(base64.decode(b64), allowMalformed: true));
      if (!Engine.shellAlive(id)) {
        poll?.cancel();
        final dropped = Engine.shellDropped(id);
        Engine.shellClose(id);
        id = -1;
        if (dropped) { _reconnect(); } else { setState(() => status = 'session ended'); }
      }
    });
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

  Widget _key(String label, String data) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: OutlinedButton(
          style: OutlinedButton.styleFrom(minimumSize: const Size(44, 40), padding: const EdgeInsets.symmetric(horizontal: 8)),
          onPressed: () => _send(data),
          child: Text(label),
        ),
      );

  @override
  void dispose() {
    Native.stop();
    poll?.cancel();
    if (id > 0) Engine.shellClose(id);
    super.dispose();
  }

  @override
  Widget build(BuildContext c) => Scaffold(
        appBar: AppBar(title: Text('${widget.user}@${widget.name}', style: const TextStyle(fontSize: 14)), actions: [Padding(padding: const EdgeInsets.all(12), child: Text(status, key: const Key('tstatus'), style: const TextStyle(fontSize: 12)))]),
        body: SafeArea(
          child: Column(children: [
            if (approveUrl != null)
              Material(
                color: Theme.of(c).colorScheme.tertiaryContainer,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Row(children: [
                    const Expanded(child: Text('Tailscale needs you to approve this connection (about every 12 hours).', key: Key('approve'))),
                    FilledButton(onPressed: () => launchUrl(Uri.parse(approveUrl!), mode: LaunchMode.externalApplication), child: const Text('Approve')),
                  ]),
                ),
              ),
            if (reconnecting)
              Material(
                color: Theme.of(c).colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Row(children: [
                    if (!gaveUp) const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: 10),
                    Expanded(child: Text(gaveUp ? 'Connection lost' : 'Connection lost, reconnecting...', key: const Key('banner'))),
                    if (gaveUp) TextButton(onPressed: () { attempt = 0; _reconnect(); }, child: const Text('Retry')),
                  ]),
                ),
              ),
            Expanded(child: TerminalView(term, autofocus: true, textStyle: const TerminalStyle(fontSize: 13))),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                _key('Esc', '\x1b'),
                _key('Tab', '\t'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: (ctrl ? FilledButton.new : OutlinedButton.new)(
                    style: ButtonStyle(minimumSize: WidgetStateProperty.all(const Size(44, 40)), padding: WidgetStateProperty.all(const EdgeInsets.symmetric(horizontal: 8))),
                    onPressed: () => setState(() => ctrl = !ctrl),
                    child: const Text('Ctrl'),
                  ),
                ),
                _key('^C', '\x03'),
                _key('^D', '\x04'),
                _key('↑', '\x1b[A'),
                _key('↓', '\x1b[B'),
                _key('←', '\x1b[D'),
                _key('→', '\x1b[C'),
                _key('|', '|'),
                _key('/', '/'),
                _key('-', '-'),
                _key('~', '~'),
              ]),
            ),
          ]),
        ),
      );
}

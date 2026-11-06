import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:xterm/xterm.dart';
import 'engine.dart';
import 'files_page.dart';
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
  bool keysHidden = false; // the three rows of shortcut keys can be folded away to give the terminal more room
  final termFocus = FocusNode(); // the terminal itself is the only text input: the keyboard types straight into it
  ReceivePort? rp;
  bool reconnecting = false, gaveUp = false;
  int attempt = 0;
  String? seenUrl; // the engine keeps the last banner; only a NEW link means a new approval is needed
  String? blocked; // the Mac has a permission pending (Full Disk Access): no session until it is granted
  String? approveUrl; // Tailscale "check" policy: the Mac asks for a browser approval (link arrives as the SSH banner)

  @override
  void initState() {
    super.initState();
    Store.keysHidden().then((v) { if (mounted) setState(() => keysHidden = v); });
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
    // The helper on the Mac writes perms.json; while Full Disk Access is still pending, phone programs would hit permission dialogs
    // nobody can click, so do not start a session at all. (If the check itself cannot run, carry on.)
    final tmp = '${(await getTemporaryDirectory()).path}/perms.json';
    final chk = await Engine.fetch('${widget.ip}:22', widget.user, pin, r'cat "$HOME/Library/Application Support/Remote Wake/perms.json"', tmp);
    if (!mounted) { bt.cancel(); return; }
    if (chk.isEmpty || chk.contains('exited with status')) {
      final ok = chk.isEmpty && RegExp(r'"disk"\s*:\s*true').hasMatch(await File(tmp).readAsString());
      if (!ok) {
        bt.cancel();
        setState(() { approveUrl = null; blocked = chk.isEmpty ? 'This Mac is waiting for you to allow Full Disk Access.' : 'Remote Wake is not set up on this Mac yet.'; status = 'blocked'; });
        return;
      }
    }
    if (blocked != null) setState(() => blocked = null);
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
        title: Text('Host key changed', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: c.sage.warn)),
        content: Text('${widget.name} presented a different SSH key than before (new: $fp). This is normal after reinstalling Tailscale or the Mac, but it could also mean someone is in the way. Trust the new key?', style: const TextStyle(fontSize: 13, height: 1.5)),
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

  void _line(String text) => _send('$text\r');


  // A key in the grid: at least 44 x 44 dp.
  Widget _key(BuildContext c, String label, {String? data, bool on = false, Color? color, VoidCallback? onTap, String? tip, double minW = 44}) {
    final s = c.sage;
    return Padding(
      padding: const EdgeInsets.only(right: Sp.xs),
      child: Semantics(
        button: true, label: tip ?? label, excludeSemantics: true,
        child: Material(
          color: on ? s.accent : const Color(0xFF16161C),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: on ? s.accent : s.line)),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: onTap ?? () => _send(data!),
            child: Container(constraints: BoxConstraints(minWidth: minW, minHeight: 44), alignment: Alignment.center, padding: const EdgeInsets.symmetric(horizontal: Sp.md),
                child: Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: on ? s.onAccent : (color ?? s.text)))),
          ),
        ),
      ),
    );
  }

  Widget _chip(BuildContext c, String label, {String? line, String? data, Color? color}) {
    final s = c.sage;
    return Padding(
      padding: const EdgeInsets.only(right: Sp.sm),
      child: Semantics(
        button: true, label: label, excludeSemantics: true,
        child: Material(
          color: const Color(0xFF16161C),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: s.line)),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => line != null ? _line(line) : _send(data!),
            child: Container(constraints: const BoxConstraints(minHeight: 44), alignment: Alignment.center, padding: const EdgeInsets.symmetric(horizontal: Sp.md),
                child: Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: color ?? s.accent))),
          ),
        ),
      ),
    );
  }

  // Terminal palette from the design: mint / red / amber / blue / pink on near-black.
  static const _theme = TerminalTheme(
    cursor: Color(0xFFFF6AC1), selection: Color(0xFF2A2A35), foreground: Color(0xFFE8E8EC), background: Color(0xFF050507),
    black: Color(0xFF1A1A20), red: Color(0xFFE5484D), green: Color(0xFF7BE0B0), yellow: Color(0xFFE3B341), blue: Color(0xFF6CB6FF), magenta: Color(0xFFFF6AC1), cyan: Color(0xFF7FD7D0), white: Color(0xFFC8C8D0),
    brightBlack: Color(0xFF6B6B78), brightRed: Color(0xFFFF7A7F), brightGreen: Color(0xFF9CF0C8), brightYellow: Color(0xFFF2CB6B), brightBlue: Color(0xFF93C9FF), brightMagenta: Color(0xFFFF93D2), brightCyan: Color(0xFF9FE8E2), brightWhite: Color(0xFFFFFFFF),
    searchHitBackground: Color(0xFFE3B341), searchHitBackgroundCurrent: Color(0xFF7BE0B0), searchHitForeground: Color(0xFF050507),
  );

  (String, Color) _tone(BuildContext c) {
    final s = c.sage;
    if (status.startsWith('connected')) return ('Connected', s.accent);
    if (status.startsWith('failed') || status == 'disconnected' || status == 'host key changed') return (status.startsWith('failed') ? 'Failed' : (status == 'disconnected' ? 'Disconnected' : 'Key changed'), s.danger);
    if (status == 'session ended') return ('Ended', s.muted);
    if (status == 'blocked') return ('Blocked', s.warn);
    if (status.startsWith('reconnecting')) return ('Reconnecting', s.warn);
    if (status == 'waiting for approval') return ('Needs approval', s.warn);
    return ('Connecting', s.muted);
  }

  @override
  void dispose() {
    Native.stop();
    rp?.close();
    if (id > 0) Engine.shellClose(id);
    termFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext c) {
    final s = c.sage, tone = _tone(c);
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Tooltip(message: '${widget.user}@${widget.ip}', child: Text(widget.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700))),
          const SizedBox(height: 2),
          StatusWord(tone.$1, tone.$2, key: const Key('tstatus')),
        ]),
        actions: [
          IconButton(
            tooltip: 'Files on this Mac',
            icon: Icon(Icons.folder_open_outlined, color: s.muted),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => FilesPage(name: widget.name, ip: widget.ip, user: widget.user))),
          ),
          IconButton(
            tooltip: 'Show or hide the keyboard',
            icon: Icon(Icons.keyboard_outlined, color: s.muted),
            onPressed: () => termFocus.hasFocus ? termFocus.unfocus() : termFocus.requestFocus(),
          ),
          const SizedBox(width: Sp.xs),
        ],
      ),
      body: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (approveUrl != null)
            Banner2(
              bg: s.pinkBg, fg: s.pink, text: 'Tailscale needs you to approve this connection (about every 12 hours).',
              action: FilledButton(style: FilledButton.styleFrom(backgroundColor: s.pink, foregroundColor: s.bg), onPressed: () => launchUrl(Uri.parse(approveUrl!), mode: LaunchMode.externalApplication), child: const Text('Approve')),
            ),
          if (reconnecting)
            Banner2(
              bg: s.warnBg, fg: s.warn, text: gaveUp ? 'Connection lost' : 'Connection lost, reconnecting...',
              lead: gaveUp ? null : SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: s.warn)),
              action: gaveUp ? FilledButton(style: FilledButton.styleFrom(backgroundColor: s.warn, foregroundColor: s.bg), onPressed: () { attempt = 0; _reconnect(); }, child: const Text('Retry')) : null,
            ),
          const SizedBox(height: Sp.sm),
          Expanded(
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: Sp.sm),
              decoration: BoxDecoration(color: s.screen, borderRadius: BorderRadius.circular(12), border: Border.all(color: s.line)),
              clipBehavior: Clip.antiAlias,
              child: Stack(fit: StackFit.expand, children: [
                TerminalView(term, focusNode: termFocus, theme: _theme, padding: const EdgeInsets.all(Sp.sm), textStyle: const TerminalStyle(fontSize: 11), autofocus: blocked == null),
                if (blocked != null) Container(color: s.screen, padding: const EdgeInsets.all(Sp.xl), alignment: Alignment.center, child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.lock_outline, size: 32, color: s.warn),
                  const SizedBox(height: Sp.md),
                  Text(blocked!, textAlign: TextAlign.center, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                  const SizedBox(height: Sp.sm),
                  Text('Open Remote Wake on the Mac, click Allow access and switch on "Remote Wake Menu" in the list that opens. Phone sessions stay off until then.', textAlign: TextAlign.center, style: TextStyle(color: s.muted, fontSize: 13, height: 1.5)),
                  const SizedBox(height: Sp.lg),
                  AsciiButton('CHECK AGAIN', onPressed: () { setState(() => status = 'connecting...'); _open(); }),
                ])),
              ]),
            ),
          ),
          Semantics(
            button: true, label: keysHidden ? 'Show shortcut keys' : 'Hide shortcut keys', excludeSemantics: true,
            child: InkWell(
              onTap: () { setState(() => keysHidden = !keysHidden); Store.setKeysHidden(keysHidden); },
              child: SizedBox(height: 28, child: Center(child: Icon(keysHidden ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down, color: s.muted, size: 22))),
            ),
          ),
          if (!keysHidden && blocked == null) ...[
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(Sp.sm, Sp.sm, Sp.sm, 0),
            child: Row(children: [
              _chip(c, 'Stop ^C', data: '\x03', color: s.danger),
              _chip(c, 'claude', line: 'claude'),
              _chip(c, 'ls', line: 'ls'),
              _chip(c, 'git status', line: 'git status'),
              _chip(c, 'pwd', line: 'pwd'),
              _chip(c, 'clear', line: 'clear'),
            ]),
          ),
          for (final row in [
            [('Esc', '\x1b'), ('Tab', '\t'), ('Ctrl', null), ('←', '\x1b[D'), ('↓', '\x1b[B'), ('↑', '\x1b[A'), ('→', '\x1b[C')],
            [('|', '|'), ('/', '/'), ('~', '~'), ('-', '-'), ('_', '_'), ('*', '*'), ('^D', '\x04')],
          ])
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(Sp.sm, Sp.sm, Sp.sm, 0),
              child: Row(children: [
                for (final k in row)
                  k.$2 == null
                      ? _key(c, k.$1, on: ctrl, tip: 'Control, applies to the next key', onTap: () => setState(() => ctrl = !ctrl))
                      : _key(c, k.$1, data: k.$2),
              ]),
            ),
          ],
          const SizedBox(height: Sp.sm),
        ]),
      ),
    );
  }
}

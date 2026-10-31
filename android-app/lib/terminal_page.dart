import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';
import 'engine.dart';

// Interactive shell on the Mac: polls the Go engine for output, sends keystrokes back, with an extra-keys row for what phone keyboards lack.
class TerminalPage extends StatefulWidget {
  final String addr, user;
  const TerminalPage({super.key, required this.addr, required this.user});
  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends State<TerminalPage> {
  final term = Terminal(maxLines: 10000);
  int id = -1;
  String status = 'connecting...';
  bool ctrl = false;
  Timer? poll;

  @override
  void initState() {
    super.initState();
    term.onOutput = (data) => _send(data);
    term.onResize = (w, h, pw, ph) { if (id > 0) Engine.shellResize(id, w, h); };
    WidgetsBinding.instance.addPostFrameCallback((_) => _open()); // open after layout so the PTY gets the real size
  }

  Future<void> _open() async {
    final sw = Stopwatch()..start();
    final r = await Engine.shellOpen(widget.addr, widget.user, term.viewWidth, term.viewHeight);
    if (!mounted) { if (r > 0) Engine.shellClose(r); return; }
    if (r < 0) { setState(() => status = 'failed: ${Engine.lastError()}'); return; }
    id = r;
    Engine.shellResize(id, term.viewWidth, term.viewHeight); // the layout may have changed while connecting
    setState(() => status = 'connected in ${sw.elapsedMilliseconds} ms');
    poll = Timer.periodic(const Duration(milliseconds: 40), (_) {
      final b64 = Engine.shellRead(id);
      if (b64.isNotEmpty) term.write(utf8.decode(base64.decode(b64), allowMalformed: true));
      if (!Engine.shellAlive(id)) { poll?.cancel(); setState(() => status = 'session ended'); }
    });
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
    poll?.cancel();
    if (id > 0) Engine.shellClose(id);
    super.dispose();
  }

  @override
  Widget build(BuildContext c) => Scaffold(
        appBar: AppBar(title: Text('${widget.user}@${widget.addr}', style: const TextStyle(fontSize: 14)), actions: [Padding(padding: const EdgeInsets.all(12), child: Text(status, key: const Key('tstatus'), style: const TextStyle(fontSize: 12)))]),
        body: SafeArea(
          child: Column(children: [
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

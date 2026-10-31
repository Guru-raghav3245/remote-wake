import 'dart:async';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'engine.dart';
import 'terminal_page.dart';

void main() => runApp(const MaterialApp(home: Home()));

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  Map<String, dynamic> st = {'state': 'NotStarted'};
  final host = TextEditingController(text: '100.x.x.x:22');
  final user = TextEditingController(text: 'gururaghav');
  final cmd = TextEditingController(text: 'id -un; hostname');
  String out = '';
  bool busy = false;
  Timer? t;

  @override
  void initState() {
    super.initState();
    t = Timer.periodic(const Duration(seconds: 2), (_) {
      final n = Engine.state();
      if (n['authUrl'] != st['authUrl'] && (n['authUrl'] ?? '') != '') debugPrint('AUTHURL ${n['authUrl']}'); // dev aid: lets a test harness open it
      setState(() => st = n);
    });
    _start();
  }

  Future<void> _start() async {
    final d = await getApplicationSupportDirectory();
    final err = Engine.start(d.path);
    if (err.isNotEmpty) setState(() => out = err);
  }

  Future<void> _run() async {
    setState(() { busy = true; out = 'running...'; });
    final sw = Stopwatch()..start();
    final r = await Engine.exec(host.text, user.text, cmd.text);
    setState(() { busy = false; out = '$r\n(${sw.elapsedMilliseconds} ms)'; });
  }

  @override
  void dispose() { t?.cancel(); super.dispose(); }

  @override
  Widget build(BuildContext c) {
    final url = st['authUrl'] as String? ?? '';
    final ready = st['state'] == 'Running';
    return Scaffold(
      appBar: AppBar(title: const Text('Remote Wake')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text('Tailscale: ${st['state']}  ${(st['ips'] as List?)?.join(' ') ?? ''}', key: const Key('state')),
        if (url.isNotEmpty) FilledButton(onPressed: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication), child: const Text('Sign in to Tailscale')),
        const SizedBox(height: 12),
        TextField(controller: host, decoration: const InputDecoration(labelText: 'Mac address (host:port)')),
        TextField(controller: user, decoration: const InputDecoration(labelText: 'User')),
        TextField(controller: cmd, decoration: const InputDecoration(labelText: 'Command')),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: FilledButton(onPressed: ready && !busy ? _run : null, child: const Text('Run'))),
          const SizedBox(width: 8),
          Expanded(child: FilledButton.tonal(onPressed: ready ? () => Navigator.of(c).push(MaterialPageRoute(builder: (_) => TerminalPage(addr: host.text, user: user.text))) : null, child: const Text('Open terminal'))),
        ]),
        const SizedBox(height: 12),
        SelectableText(out, key: const Key('out'), style: const TextStyle(fontFamily: 'monospace')),
      ]),
    );
  }
}

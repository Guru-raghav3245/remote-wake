import 'dart:async';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'engine.dart';
import 'native.dart';
import 'store.dart';
import 'terminal_page.dart';
import 'tutorial.dart';

void main() => runApp(MaterialApp(theme: ThemeData(colorSchemeSeed: Colors.deepPurple, useMaterial3: true), home: const Home()));

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  Map<String, dynamic> st = {'state': 'NotStarted'};
  Timer? t;

  @override
  void initState() {
    super.initState();
    t = Timer.periodic(const Duration(seconds: 2), (_) {
      final n = Engine.state();
      if (n['authUrl'] != st['authUrl'] && (n['authUrl'] ?? '') != '') debugPrint('AUTHURL ${n['authUrl']}'); // dev aid: lets a test harness open it
      if (mounted) setState(() => st = n);
    });
    _start();
    WidgetsBinding.instance.addPostFrameCallback((_) async { if (!await Store.tutorialSeen()) await _tutorial(); });
  }

  Future<void> _tutorial() async {
    await Store.setTutorialSeen();
    if (mounted) await Navigator.of(context).push(MaterialPageRoute(builder: (_) => TutorialPage(onConnect: _open)));
  }

  Future<void> _start() async {
    final d = await getApplicationSupportDirectory();
    final err = Engine.start(d.path);
    if (err.isNotEmpty && mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
  }

  Future<void> _open(Map p) async {
    final ip = p['ip'] as String;
    final ctl = TextEditingController(text: await Store.user(ip));
    if (!mounted) return;
    final user = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Connect to ${p['name']}'),
        content: TextField(controller: ctl, autofocus: true, autocorrect: false, enableSuggestions: false, decoration: const InputDecoration(labelText: 'User name on that computer')),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(c, ctl.text.trim()), child: const Text('Connect'))],
      ),
    );
    if (user == null || user.isEmpty || !mounted) return;
    await Store.setUser(ip, user);
    if (!await Store.askedBattery()) { await Store.setAskedBattery(); await Native.batteryExempt(); } // once: lets Android keep the session alive in the background
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => TerminalPage(name: p['name'] as String, ip: ip, user: user)));
  }

  @override
  void dispose() { t?.cancel(); super.dispose(); }

  @override
  Widget build(BuildContext c) {
    final url = st['authUrl'] as String? ?? '';
    final running = st['state'] == 'Running';
    final peers = ((st['peers'] as List?) ?? []).cast<Map>().toList()
      ..sort((a, b) => ((b['online'] == true ? 2 : 0) + (b['os'] == 'macOS' ? 1 : 0)).compareTo((a['online'] == true ? 2 : 0) + (a['os'] == 'macOS' ? 1 : 0)));
    return Scaffold(
      appBar: AppBar(title: const Text('Remote Wake'), actions: [IconButton(icon: const Icon(Icons.help_outline), tooltip: 'Tutorial', onPressed: _tutorial)]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(running ? 'Connected to Tailscale' : 'Tailscale: ${st['state']}', style: Theme.of(c).textTheme.titleMedium),
          if (running) Text((st['ips'] as List?)?.firstOrNull?.toString() ?? '', style: Theme.of(c).textTheme.bodySmall),
          if (url.isNotEmpty) ...[const SizedBox(height: 8), FilledButton(onPressed: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication), child: const Text('Sign in to Tailscale'))],
        ]))),
        if (running) ...[
          const SizedBox(height: 16),
          Text('Your computers', style: Theme.of(c).textTheme.titleSmall),
          if (peers.isEmpty) const Padding(padding: EdgeInsets.all(12), child: Text('None yet. Install Remote Wake on your Mac and sign in to Tailscale with the same account.')),
          for (final p in peers)
            ListTile(
              leading: Icon(Icons.circle, size: 12, color: p['online'] == true ? Colors.green : Colors.grey),
              title: Text('${p['name']}'),
              subtitle: Text('${p['ip']}  ${p['os']}${p['online'] == true ? '' : '  (offline)'}'),
              enabled: p['online'] == true,
              onTap: () => _open(p),
            ),
        ],
      ]),
    );
  }
}

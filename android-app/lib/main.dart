import 'dart:async';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'engine.dart';
import 'native.dart';
import 'store.dart';
import 'terminal_page.dart';
import 'theme.dart';
import 'tutorial.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(MaterialApp(title: 'Remote Wake', theme: sageTheme(), darkTheme: sageTheme(), themeMode: ThemeMode.dark, home: const Home()));
}

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
    final host = (await Native.deviceName()).toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    final err = Engine.start(d.path, host: host.isEmpty ? 'phone' : host);
    if (err.isNotEmpty && mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
  }

  Future<void> _open(Map p) async {
    final ip = p['ip'] as String;
    final ctl = TextEditingController(text: await Store.user(ip));
    if (!mounted) return;
    final user = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Connect to ${p['name']}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Type the user name you log in with on that computer.', style: TextStyle(color: c.sage.muted, fontSize: 13, height: 1.4)),
          const SizedBox(height: Sp.lg),
          TextField(controller: ctl, autofocus: true, autocorrect: false, enableSuggestions: false, decoration: const InputDecoration(labelText: 'User name')),
        ]),
        actionsPadding: const EdgeInsets.fromLTRB(Sp.lg, 0, Sp.lg, Sp.lg),
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

  Widget _connection(BuildContext c) {
    final s = c.sage, url = st['authUrl'] as String? ?? '';
    final running = st['state'] == 'Running';
    final needsLogin = url.isNotEmpty;
    final ip = (st['ips'] as List?)?.firstOrNull?.toString() ?? '';
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        StatusWord(running ? 'Connected' : (needsLogin ? 'Sign-in needed' : 'Starting'), running ? s.accent : (needsLogin ? s.warn : s.muted)),
        const SizedBox(height: Sp.sm),
        Text(running ? 'Tailscale is on' : (needsLogin ? 'Sign in to Tailscale' : 'Starting Tailscale'), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        const SizedBox(height: Sp.xs),
        Text(running ? ip : (needsLogin ? 'Use the same account as on your Mac.' : 'This takes a few seconds.'), style: TextStyle(color: s.muted, fontSize: 13, height: 1.4)),
        if (needsLogin && !running) ...[const SizedBox(height: Sp.md), AsciiButton('Sign in', onPressed: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication))],
      ]),
    );
  }

  // Hero: the ASCII laptop and one plain status word about the Mac.
  Widget _hero(BuildContext c, List<Map> macs) {
    final s = c.sage, running = st['state'] == 'Running', needsLogin = (st['authUrl'] as String? ?? '').isNotEmpty;
    final online = macs.any((p) => p['online'] == true);
    final (mode, word, col) = !running
        ? (LaptopMode.idle, needsLogin ? 'SIGN IN' : 'CONNECTING', s.muted)
        : macs.isEmpty ? (LaptopMode.idle, 'NO MAC', s.muted)
        : online ? (LaptopMode.on, 'ONLINE', s.accent) : (LaptopMode.off, 'ASLEEP', s.danger);
    return Column(children: [
      AsciiLaptop(mode),
      const SizedBox(height: Sp.md),
      Text(word, style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: 3, color: col)),
      if (running && macs.isNotEmpty && !online) ...[
        const SizedBox(height: Sp.sm),
        Text('Your Mac is not reachable. Open Remote Wake on it and turn on stay awake.', textAlign: TextAlign.center, style: TextStyle(fontSize: 12, height: 1.4, color: s.danger)),
      ],
    ]);
  }

  Widget _computer(BuildContext c, Map p) {
    final s = c.sage, online = p['online'] == true;
    return Opacity(
      opacity: online ? 1 : .6,
      child: AppCard(
        onTap: online ? () => _open(p) : null,
        child: Row(children: [
          Container(width: 44, height: 44, decoration: BoxDecoration(color: s.bg, border: Border.all(color: s.line), borderRadius: BorderRadius.circular(12)), child: Icon(Icons.laptop_mac, color: online ? s.accent : s.muted)),
          const SizedBox(width: Sp.lg),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${p['name']}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            const SizedBox(height: Sp.xs),
            StatusWord(online ? 'Online' : 'Offline', online ? s.accent : s.muted),
          ])),
          if (online) Text('>', style: TextStyle(color: s.accent, fontSize: 20, fontWeight: FontWeight.w700)),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext c) {
    final s = c.sage;
    final running = st['state'] == 'Running';
    final peers = ((st['peers'] as List?) ?? []).cast<Map>().where((p) => p['os'] != 'android' && p['os'] != 'iOS').toList()
      ..sort((a, b) => ((b['online'] == true ? 2 : 0) + (b['os'] == 'macOS' ? 1 : 0)).compareTo((a['online'] == true ? 2 : 0) + (a['os'] == 'macOS' ? 1 : 0)));
    return Scaffold(
      appBar: AppBar(
        title: const Row(children: [Logo(size: 32), SizedBox(width: Sp.md), Text('remote-wake')]),
        actions: [
          IconButton(icon: const Icon(Icons.help_outline), tooltip: 'Guide', onPressed: _tutorial),
          const SizedBox(width: Sp.sm),
        ],
      ),
      body: ListView(padding: const EdgeInsets.all(Sp.lg), children: [
        _hero(c, peers.where((p) => p['os'] == 'macOS').toList()),
        const SizedBox(height: Sp.xl),
        _connection(c),
        if (running) ...[
          const SizedBox(height: Sp.xl),
          const Caption('Your computers'),
          const SizedBox(height: Sp.md),
          if (peers.isEmpty)
            AppCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('No computers yet', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              const SizedBox(height: Sp.xs),
              Text('On your Mac, open Remote Wake and finish the three setup steps. It shows up here by itself.', style: TextStyle(color: s.muted, fontSize: 13, height: 1.4)),
              const SizedBox(height: Sp.md),
              AsciiButton('Open the guide', primary: false, onPressed: _tutorial),
            ]))
          else
            for (final p in peers) Padding(padding: const EdgeInsets.only(bottom: Sp.md), child: _computer(c, p)),
        ],
      ]),
    );
  }
}

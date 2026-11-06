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
  bool edit = false, showOff = false; // showOff: the folded "Not reachable" group is open
  Set<String> hidden = {};

  @override
  void initState() {
    super.initState();
    Store.hidden().then((v) { if (mounted) setState(() => hidden = v); });
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

  Future<void> _setHidden(String ip, bool hide) async {
    final n = {...hidden};
    hide ? n.add(ip) : n.remove(ip);
    await Store.setHidden(n);
    if (mounted) setState(() => hidden = n);
  }

  // Removing only hides the computer on this phone: a phone cannot delete a device from the Tailscale account (that needs the admin console).
  Future<void> _remove(Map p) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Remove ${p['name']}?', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        content: Text('This hides it from the list on this phone. It stays in your Tailscale account; to delete it there, use the admin console. You can bring it back with Edit.', style: TextStyle(color: c.sage.muted, fontSize: 13, height: 1.5)),
        actionsPadding: const EdgeInsets.fromLTRB(Sp.lg, 0, Sp.lg, Sp.lg),
        actions: [
          TextButton(onPressed: () => launchUrl(Uri.parse('https://login.tailscale.com/admin/machines'), mode: LaunchMode.externalApplication), child: const Text('Admin console')),
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(style: FilledButton.styleFrom(backgroundColor: c.sage.danger, foregroundColor: Colors.white), onPressed: () => Navigator.pop(c, true), child: const Text('Remove')),
        ],
      ),
    );
    if (go == true) await _setHidden('${p['ip']}', true);
  }

  // " · last seen 3 days ago" from the engine's unix seconds ('' when unknown)
  static String _ago(Object? seen) {
    final n = seen is int ? seen : 0;
    if (n <= 0) return '';
    final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(n * 1000));
    String u(int v, String w) => '$v $w${v == 1 ? '' : 's'} ago';
    final t = d.inMinutes < 1 ? 'just now' : d.inMinutes < 60 ? u(d.inMinutes, 'minute') : d.inHours < 24 ? u(d.inHours, 'hour') : u(d.inDays, 'day');
    return ' · last seen $t';
  }

  Widget _computer(BuildContext c, Map p) {
    final s = c.sage, online = p['online'] == true;
    return Opacity(
      opacity: online ? 1 : .6,
      child: AppCard(
        onTap: online && !edit ? () => _open(p) : null,
        child: Row(children: [
          Container(width: 44, height: 44, decoration: BoxDecoration(color: s.bg, border: Border.all(color: s.line), borderRadius: BorderRadius.circular(12)), child: Icon(Icons.laptop_mac, color: online ? s.accent : s.muted)),
          const SizedBox(width: Sp.lg),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${p['name']}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            const SizedBox(height: Sp.xs),
            StatusWord(online ? 'Online' : 'Offline${_ago(p['seen'])}', online ? s.accent : s.muted),
          ])),
          if (edit) IconButton(tooltip: 'Remove from list', icon: Icon(Icons.remove_circle_outline, color: s.danger), onPressed: () => _remove(p))
          else if (online) Text('>', style: TextStyle(color: s.accent, fontSize: 20, fontWeight: FontWeight.w700)),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext c) {
    final s = c.sage;
    final running = st['state'] == 'Running';
    final all = ((st['peers'] as List?) ?? []).cast<Map>().where((p) => p['os'] != 'android' && p['os'] != 'iOS').toList();
    final gone = all.where((p) => hidden.contains(p['ip'])).toList();
    final peers = all.where((p) => !hidden.contains(p['ip'])).toList()
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
          Row(children: [
            const Expanded(child: Caption('Your computers')),
            if (all.isNotEmpty) TextButton(style: TextButton.styleFrom(minimumSize: const Size(48, 32), padding: const EdgeInsets.symmetric(horizontal: Sp.sm)), onPressed: () => setState(() => edit = !edit), child: Text(edit ? 'Done' : 'Edit')),
          ]),
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
            for (final p in peers.where((p) => p['online'] == true)) Padding(padding: const EdgeInsets.only(bottom: Sp.md), child: _computer(c, p)),
          // offline computers fold away while another one is online; with nothing online (or while editing) they show, so a Mac that went down is never hidden
          if (peers.any((p) => p['online'] != true)) ...[
            if (peers.any((p) => p['online'] == true) && !edit)
              InkWell(
                onTap: () => setState(() => showOff = !showOff),
                child: Padding(padding: const EdgeInsets.symmetric(vertical: Sp.sm), child: Row(children: [
                  Icon(showOff ? Icons.expand_less : Icons.expand_more, color: s.muted),
                  const SizedBox(width: Sp.sm),
                  Text('Not reachable (${peers.where((p) => p['online'] != true).length})', style: TextStyle(color: s.muted, fontWeight: FontWeight.w700)),
                ])),
              ),
            if (showOff || edit || !peers.any((p) => p['online'] == true))
              for (final p in peers.where((p) => p['online'] != true)) Padding(padding: const EdgeInsets.only(bottom: Sp.md), child: _computer(c, p)),
          ],
          if (edit && gone.isNotEmpty) ...[
            const SizedBox(height: Sp.md),
            Caption('Removed (${gone.length})'),
            const SizedBox(height: Sp.md),
            for (final p in gone) Padding(padding: const EdgeInsets.only(bottom: Sp.md), child: AppCard(child: Row(children: [
              Expanded(child: Text('${p['name']}', style: TextStyle(fontSize: 14, color: s.muted))),
              TextButton(onPressed: () => _setHidden('${p['ip']}', false), child: const Text('Restore')),
            ]))),
          ],
        ],
      ]),
    );
  }
}

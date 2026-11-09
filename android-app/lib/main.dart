import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'blackbox.dart';
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

class _HomeState extends State<Home> with WidgetsBindingObserver {
  Map<String, dynamic> st = {'state': 'NotStarted'};
  Timer? t, net;
  bool edit = false, showOff = false; // showOff: the folded "Not reachable" group is open
  Set<String> hidden = {};
  Map<String, String> batt = {}; // last battery reading per Mac (see Store.setBattery)
  Map<String, List<Incident>> reports = {}; // what the Mac's black box says happened while it was unreachable
  final probedAt = <String, int>{}; // ip -> ms of the last black-box read
  final wasOnline = <String, bool>{};
  final again = <String, bool>{}; // ip -> read once more soon: the Mac logs its own return only on its next 30 s sample
  bool phoneNet = true; // can this phone reach the internet at all
  bool recheck = false; // one pending quick re-check while the phone looks offline
  int netFails = 0; // consecutive failed internet checks
  bool probing = false; // a black-box read is in flight (one at a time)
  String? approveUrl; // Tailscale "check" policy holds the read until the user approves this link in a browser
  String lastWord = ''; // hero word last printed to the log (dev aid for test harnesses, like AUTHURL)

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Store.hidden().then((v) { if (mounted) setState(() => hidden = v); });
    Store.batteries().then((v) { if (mounted) setState(() => batt = v); });
    t = Timer.periodic(const Duration(seconds: 2), (_) {
      final n = Engine.state();
      if (n['authUrl'] != st['authUrl'] && (n['authUrl'] ?? '') != '') debugPrint('AUTHURL ${n['authUrl']}'); // dev aid: lets a test harness open it
      if (mounted) setState(() => st = n);
      _watch(n);
    });
    net = Timer.periodic(const Duration(seconds: 20), (_) => _checkNet());
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
  void dispose() { WidgetsBinding.instance.removeObserver(this); t?.cancel(); net?.cancel(); super.dispose(); }

  // Android freezes timers while the app is in the background: check again the moment the app is back in front.
  @override
  void didChangeAppLifecycleState(AppLifecycleState s) { if (s == AppLifecycleState.resumed) { netFails = 0; _checkNet(); } }

  // A plain TCP connection tells "my phone has no internet" apart from "the Mac is offline" (peer status is stale when the phone is offline).
  Future<void> _checkNet() async {
    if (st['state'] != 'Running') return;
    var ok = false;
    for (final a in const [('1.1.1.1', 443), ('8.8.8.8', 53)]) { // two public addresses: a network that blocks one must not look like "no internet"
      try { (await Socket.connect(a.$1, a.$2, timeout: const Duration(seconds: 3))).destroy(); ok = true; break; } catch (_) {}
    }
    netFails = ok ? 0 : netFails + 1;
    final up = netFails < 2; // one failed round is a blip; two in a row means the phone really has no internet
    if (mounted && up != phoneNet) setState(() => phoneNet = up);
    if (!up && !recheck) { recheck = true; Future.delayed(const Duration(seconds: 5), () { recheck = false; if (mounted && !phoneNet) _checkNet(); }); } // while down, look again soon so the word clears quickly
  }

  // For every Mac that is online: read its black box when it comes back and then every 5 minutes (battery for the offline guess, log for the outage report).
  void _watch(Map<String, dynamic> n) {
    if (probing) { // the Mac may be waiting for a browser approval: its link arrives as the SSH banner
      final m = RegExp(r'https://\S+').firstMatch(Engine.lastBanner())?.group(0);
      if (m != null && m != approveUrl) { debugPrint('APPROVEURL $m'); if (mounted) setState(() => approveUrl = m); }
      return;
    }
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return; // a terminal or files page is open: it dials the Mac itself
    for (final p in ((n['peers'] as List?) ?? []).cast<Map>().where((p) => p['os'] == 'macOS')) {
      final ip = '${p['ip']}', on = p['online'] == true;
      if (on && wasOnline[ip] != true) { probedAt[ip] = 0; again[ip] = true; } // just came (back) online: read it now, and again in 40 s
      wasOnline[ip] = on;
      if (on && DateTime.now().millisecondsSinceEpoch - (probedAt[ip] ?? 0) > 300000) _probe(ip);
    }
  }

  Future<void> _probe(String ip) async {
    probedAt[ip] = DateTime.now().millisecondsSinceEpoch;
    probing = true;
    try { await _probe0(ip); } finally { probing = false; if (again.remove(ip) == true) probedAt[ip] = DateTime.now().millisecondsSinceEpoch - 300000 + 40000; if (mounted && approveUrl != null) setState(() => approveUrl = null); }
  }

  Future<void> _probe0(String ip) async {
    final user = await Store.user(ip), pin = await Store.hostKey(ip);
    if (user.isEmpty || pin.isEmpty) { debugPrint('PROBE skipped: ${user.isEmpty ? 'no saved user name' : 'no saved host key'}'); return; } // never connected from this phone yet
    final tmp = '${(await getTemporaryDirectory()).path}/probe-$ip.txt';
    final r = await Engine.fetch('$ip:22', user, pin, 'pmset -g batt; echo @@@; tail -n 3000 /Library/Logs/RemoteWake/blackbox.log 2>/dev/null', tmp); // waits up to 3 min (engine deadline) so an approval can finish it
    debugPrint('PROBE ${r.isEmpty ? 'ok' : r}');
    if (r.isNotEmpty || !mounted) return;
    final out = await File(tmp).readAsString(), i = out.indexOf('@@@');
    final pm = i < 0 ? out : out.substring(0, i), log = i < 0 ? '' : out.substring(i + 3);
    final pct = int.tryParse(RegExp(r'(\d+)%').firstMatch(pm)?.group(1) ?? '');
    if (pct != null) await Store.setBattery(ip, pct, pm.contains('Battery Power'));
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000, seen = await Store.seenUntil(ip);
    final fresh = analyze(log, now).where((x) => x.end > seen && now - x.end < 3 * 86400).toList();
    final b = await Store.batteries();
    debugPrint('REPORT ${fresh.map((x) => x.title).join(' | ')}');
    if (mounted) setState(() { batt = b; reports = {...reports, ip: fresh}; });
  }

  Future<void> _dismiss(String ip) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await Store.setSeenUntil(ip, now);
    if (mounted) setState(() => reports = {...reports, ip: []});
  }

  Widget _connection(BuildContext c) {
    final s = c.sage, url = st['authUrl'] as String? ?? '';
    final running = st['state'] == 'Running';
    final needsLogin = url.isNotEmpty;
    final ip = (st['ips'] as List?)?.firstOrNull?.toString() ?? '';
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        StatusWord(running ? 'Connected' : (needsLogin ? 'Sign-in needed' : 'Starting'), running ? s.accent : (needsLogin ? s.warn : s.muted)),
        const SizedBox(height: Sp.sm),
        swapText(running ? 'Tailscale is on' : (needsLogin ? 'Sign in to Tailscale' : 'Starting Tailscale'), const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        const SizedBox(height: Sp.xs),
        swapText(running ? ip : (needsLogin ? 'Use the same account as on your Mac.' : 'This takes a few seconds.'), TextStyle(color: s.muted, fontSize: 13, height: 1.4)),
        Appear(child: needsLogin && !running ? Padding(key: const ValueKey('signin'), padding: const EdgeInsets.only(top: Sp.md), child: AsciiButton('Sign in', onPressed: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication))) : null),
      ]),
    );
  }

  // Hero: the ASCII laptop and one plain status word about the Mac. When it is offline, say since when and the likeliest reason.
  Widget _hero(BuildContext c, List<Map> macs) {
    final s = c.sage, running = st['state'] == 'Running', needsLogin = (st['authUrl'] as String? ?? '').isNotEmpty;
    final online = macs.any((p) => p['online'] == true);
    final off = running && macs.isNotEmpty && !online;
    // the Mac that was seen most recently is the one the user means
    final mac = off ? (([...macs]..sort((a, b) => ((b['seen'] as int?) ?? 0).compareTo((a['seen'] as int?) ?? 0))).first) : null;
    final (mode, word, col) = !running
        ? (LaptopMode.idle, needsLogin ? 'SIGN IN' : 'CONNECTING', s.muted)
        : !phoneNet ? (LaptopMode.idle, 'NO INTERNET', s.warn)
        : macs.isEmpty ? (LaptopMode.idle, 'NO MAC', s.muted)
        : online ? (LaptopMode.on, 'ONLINE', s.accent) : (LaptopMode.off, 'OFFLINE', s.danger);
    if (word != lastWord) { lastWord = word; debugPrint('HERO $word'); }
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final note = !running ? null
        : !phoneNet ? 'This phone has no internet, so it cannot reach your Mac. Check your Wi-Fi or mobile data.'
        : mac == null ? null
        : mac['expired'] == true ? 'Offline since ${(mac['seen'] as int? ?? 0) > 0 ? clock(mac['seen'] as int, now) : 'a while'}. Its Tailscale login expired, so it must sign in again. Do that on the Mac.'
        : reasonOffline(Reading.parse(batt['${mac['ip']}']), (mac['seen'] as int?) ?? 0, now);
    return Column(children: [
      AsciiLaptop(mode),
      const SizedBox(height: Sp.md),
      AnimatedSwitcher(duration: const Duration(milliseconds: 350), child: Text(word, key: ValueKey(word), style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: 3, color: col))),
      AnimatedSize(duration: const Duration(milliseconds: 280), curve: Curves.easeOutCubic, alignment: Alignment.topCenter, child: note != null
          ? Padding(padding: const EdgeInsets.only(top: Sp.sm), child: Text(note, textAlign: TextAlign.center, style: TextStyle(fontSize: 12, height: 1.4, color: !phoneNet ? s.warn : s.danger)))
          : const SizedBox(width: double.infinity)),
    ]);
  }

  // The Mac's Tailscale rule asks for a browser approval about every 12 hours; until it is given, the read above cannot run.
  Widget _approve(BuildContext c) {
    final s = c.sage, u = approveUrl;
    return Appear(child: u == null ? null : Padding(key: const ValueKey('approve'), padding: const EdgeInsets.only(bottom: Sp.md), child: AppCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Caption('Approval needed'),
      const SizedBox(height: Sp.sm),
      Text('Tailscale wants you to approve this phone before it can read what happened on your Mac. It asks about every 12 hours.', style: TextStyle(color: s.muted, fontSize: 13, height: 1.4)),
      const SizedBox(height: Sp.md),
      AsciiButton('Approve', onPressed: () => launchUrl(Uri.parse(u), mode: LaunchMode.externalApplication)),
    ]))));
  }

  // "While you were away": what the Mac's black box recorded (battery ran out, no internet, crash, sleep...), shown once until dismissed.
  Widget _report(BuildContext c, String ip, String name) {
    final s = c.sage, list = reports[ip] ?? const <Incident>[];
    if (list.isEmpty) return const SizedBox.shrink();
    return Padding(padding: const EdgeInsets.only(bottom: Sp.md), child: AppCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Caption('While you were away · $name'),
      const SizedBox(height: Sp.sm),
      for (final x in list.reversed.take(3)) Padding(padding: const EdgeInsets.only(bottom: Sp.sm), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(x.title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: s.warn)),
        const SizedBox(height: Sp.xs),
        Text(x.detail, style: TextStyle(color: s.muted, fontSize: 13, height: 1.4)),
      ])),
      const SizedBox(height: Sp.xs),
      AsciiButton('OK', primary: false, onPressed: () => _dismiss(ip)),
    ])));
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
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 350),
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
          AnimatedSwitcher(duration: const Duration(milliseconds: 220), child: edit
              ? IconButton(key: const ValueKey('rm'), tooltip: 'Remove from list', icon: Icon(Icons.remove_circle_outline, color: s.danger), onPressed: () => _remove(p))
              : online ? Text('>', key: const ValueKey('go'), style: TextStyle(color: s.accent, fontSize: 20, fontWeight: FontWeight.w700)) : const SizedBox(key: ValueKey('none'))),
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
          if (peers.any((p) => p['os'] == 'macOS' && p['online'] == true)) _approve(c),
          for (final p in peers.where((p) => p['os'] == 'macOS' && p['online'] == true)) _report(c, '${p['ip']}', '${p['name']}'),
          Row(children: [
            const Expanded(child: Caption('Your computers')),
            if (all.isNotEmpty) TextButton(style: TextButton.styleFrom(minimumSize: const Size(48, 32), padding: const EdgeInsets.symmetric(horizontal: Sp.sm)), onPressed: () => setState(() => edit = !edit), child: Text(edit ? 'Done' : 'Edit')),
          ]),
          const SizedBox(height: Sp.md),
          // computers appearing, going offline or being removed ease in and out
          AnimatedSize(duration: const Duration(milliseconds: 300), curve: Curves.easeOutCubic, alignment: Alignment.topCenter, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
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
                  AnimatedRotation(turns: showOff ? .5 : 0, duration: const Duration(milliseconds: 220), child: Icon(Icons.expand_more, color: s.muted)),
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
          ])),
        ],
      ]),
    );
  }
}

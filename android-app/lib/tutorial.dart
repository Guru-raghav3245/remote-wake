import 'dart:async';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'engine.dart';
import 'native.dart';
import 'store.dart';
import 'theme.dart';

// Interactive guide: a live checklist. Only the current step is open and shows its real action button; steps tick themselves.
// [onConnect] is called when the user taps their Mac in step 3.
class TutorialPage extends StatefulWidget {
  final void Function(Map peer) onConnect;
  const TutorialPage({super.key, required this.onConnect});
  @override
  State<TutorialPage> createState() => _TutorialPageState();
}

class _TutorialPageState extends State<TutorialPage> {
  Map<String, dynamic> st = Engine.state();
  bool battery = false;
  Timer? t;

  @override
  void initState() {
    super.initState();
    t = Timer.periodic(const Duration(seconds: 1), (_) { if (mounted) setState(() => st = Engine.state()); });
    Store.askedBattery().then((v) { if (mounted) setState(() => battery = v); });
  }

  @override
  void dispose() { t?.cancel(); super.dispose(); }

  Widget _step(BuildContext c, int n, String title, String body, bool done, bool active, [Widget? action]) {
    final s = c.sage;
    return Padding(
      padding: const EdgeInsets.only(bottom: Sp.lg),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 28, height: 28, alignment: Alignment.center,
          decoration: BoxDecoration(shape: BoxShape.circle, color: done ? s.accent : (active ? s.soft : null), border: done ? null : Border.all(color: s.line)),
          child: done ? Icon(Icons.check, size: 16, color: s.onAccent) : Text('$n', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: active ? s.text : s.muted)),
        ),
        const SizedBox(width: Sp.md),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.only(top: Sp.xs), child: Text(title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: done || active ? s.text : s.muted))),
          if (active) ...[
            const SizedBox(height: Sp.sm),
            Text(body, style: TextStyle(color: s.muted, fontSize: 15, height: 1.4)),
            if (action != null) ...[const SizedBox(height: Sp.md), action],
          ],
        ])),
      ]),
    );
  }

  @override
  Widget build(BuildContext c) {
    final s = c.sage, url = st['authUrl'] as String? ?? '';
    final signedIn = st['state'] == 'Running';
    final macs = ((st['peers'] as List?) ?? []).cast<Map>().where((p) => p['online'] == true && p['os'] == 'macOS').toList();
    final done = [signedIn, battery, macs.isNotEmpty];
    final cur = done.indexOf(false);
    const tips = [
      (Icons.schedule, 'About every 12 hours Tailscale asks you to approve a connection in the browser. Tap Approve when the banner shows.'),
      (Icons.sync, 'If the connection drops the app reconnects. Turn on Phone sessions in the Mac app to keep your programs running and stay signed in to tools like Claude Code.'),
      (Icons.lock_outline, 'After a power cut with FileVault on, the Mac waits for its password and cannot be reached until someone unlocks it.'),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('Set up')),
      body: ListView(padding: const EdgeInsets.all(Sp.lg), children: [
        Text('Reach your Mac from here', style: Theme.of(c).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: Sp.sm),
        Text('Three quick steps. Each one ticks itself when it is done.', style: TextStyle(color: s.muted, fontSize: 15)),
        const SizedBox(height: Sp.xl),
        AppCard(child: Column(children: [
          _step(c, 1, 'Sign in to Tailscale', 'Use the same account as on your Mac.', done[0], cur == 0,
              FilledButton(onPressed: url.isEmpty ? null : () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication), child: Text(url.isEmpty ? 'Starting...' : 'Sign in'))),
          _step(c, 2, 'Keep the app running', 'Android may stop your session when the screen is off. Allow it when asked.', done[1], cur == 1,
              FilledButton(onPressed: () async { await Store.setAskedBattery(); await Native.batteryExempt(); if (mounted) setState(() => battery = true); }, child: const Text('Allow'))),
          _step(c, 3, 'Find your Mac', 'On the Mac, open Remote Wake and finish its setup. It shows up here by itself.', done[2], cur == 2),
        ])),
        if (macs.isNotEmpty) ...[
          const SizedBox(height: Sp.xl),
          const Caption('Your Mac is ready'),
          const SizedBox(height: Sp.md),
          for (final p in macs)
            AppCard(
              onTap: () { Navigator.pop(c); widget.onConnect(p); },
              child: Row(children: [
                Icon(Icons.laptop_mac, color: s.accent),
                const SizedBox(width: Sp.md),
                Expanded(child: Text('${p['name']}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600))),
                Text('Connect', style: TextStyle(color: s.accent, fontWeight: FontWeight.w600)),
                Icon(Icons.chevron_right, color: s.accent),
              ]),
            ),
        ],
        const SizedBox(height: Sp.xl),
        const Caption('Good to know'),
        const SizedBox(height: Sp.md),
        AppCard(child: Column(children: [
          for (var i = 0; i < tips.length; i++) Padding(
            padding: EdgeInsets.only(bottom: i == tips.length - 1 ? 0 : Sp.md),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(tips[i].$1, size: 20, color: s.accent),
              const SizedBox(width: Sp.md),
              Expanded(child: Text(tips[i].$2, style: const TextStyle(fontSize: 14, height: 1.4))),
            ]),
          ),
        ])),
        const SizedBox(height: Sp.xl),
        Align(alignment: Alignment.centerRight, child: TextButton(onPressed: () => Navigator.pop(c), child: Text(cur == -1 ? 'Close' : 'Skip for now'))),
      ]),
    );
  }
}

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'engine.dart';
import 'native.dart';
import 'store.dart';

// Interactive first-run tutorial: a live checklist. Each step shows the real action button and ticks itself when done.
// Reopen it from the "?" button on the home screen. [onConnect] is called when the user taps their Mac in step 3.
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

  @override
  Widget build(BuildContext c) {
    final url = st['authUrl'] as String? ?? '';
    final signedIn = st['state'] == 'Running';
    final macs = ((st['peers'] as List?) ?? []).cast<Map>().where((p) => p['online'] == true && p['os'] == 'macOS').toList();
    final done = [signedIn, battery, macs.isNotEmpty];
    final cur = done.indexOf(false); // first step still to do (-1 = all done)

    Widget step(int n, String title, String body, {List<Widget> actions = const []}) {
      final ok = done[n], active = n == cur;
      return Card(
        color: active ? Theme.of(c).colorScheme.primaryContainer : null,
        child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(ok ? Icons.check_circle : Icons.radio_button_unchecked, color: ok ? Colors.green : Colors.grey),
            const SizedBox(width: 10),
            Expanded(child: Text('${n + 1}. $title', style: Theme.of(c).textTheme.titleMedium)),
          ]),
          if (!ok) ...[const SizedBox(height: 8), Text(body), for (final a in actions) Padding(padding: const EdgeInsets.only(top: 8), child: a)],
        ])),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Set up Remote Wake')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Text('Remote Wake keeps your Mac awake while it is plugged in, lid closed too, and opens a terminal on it from this phone. Tailscale links them: private and free.'),
        const SizedBox(height: 12),
        step(0, 'Sign in to Tailscale', 'Use the same account as on your Mac.', actions: [
          FilledButton(onPressed: url.isEmpty ? null : () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication), child: Text(url.isEmpty ? 'Starting...' : 'Sign in to Tailscale')),
        ]),
        step(1, 'Let the app run in the background', 'Android may stop your session when the screen is off. Allow it when asked.', actions: [
          FilledButton(onPressed: () async { await Store.setAskedBattery(); await Native.batteryExempt(); if (mounted) setState(() => battery = true); }, child: const Text('Allow background running')),
        ]),
        step(2, 'Find your Mac', 'On the Mac, open Remote Wake, click Install, Connect Tailscale and turn on "Stay awake on AC". It shows up here by itself.'),
        const SizedBox(height: 8),
        if (macs.isNotEmpty) ...[
          Text(cur == -1 ? 'Last step: tap your Mac' : 'Your Mac is ready. Tap it to connect', style: Theme.of(c).textTheme.titleSmall),
          for (final p in macs)
            Card(child: ListTile(
              leading: const Icon(Icons.laptop_mac), title: Text('${p['name']}'), subtitle: const Text('Type your Mac user name, then Connect'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () { Navigator.pop(c); widget.onConnect(p); },
            )),
        ],
        const SizedBox(height: 12),
        Text('Good to know', style: Theme.of(c).textTheme.titleSmall),
        const Text('• About every 12 hours Tailscale asks you to approve a connection in the browser: tap Approve when the banner shows.\n• If the connection drops the app reconnects, but programs that were running stop. Use tmux on the Mac to keep them.\n• After a power cut with FileVault on, the Mac waits for its password and cannot be reached until someone unlocks it.\n• Reopen this guide with the ? button.'),
        const SizedBox(height: 16),
        Align(alignment: Alignment.centerRight, child: TextButton(onPressed: () => Navigator.pop(c), child: Text(cur == -1 ? 'Close' : 'Skip for now'))),
      ]),
    );
  }
}

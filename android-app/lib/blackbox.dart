// Explains why a Mac was unreachable.
//  - reasonOffline(): a guess while the Mac is still down, from "last seen" (Tailscale) and the last battery reading the phone took.
//  - analyze(): the exact story after the Mac is back, read from the Mac's black box log (agent/remotewake-blackbox.sh):
//      <epoch> b=<boot> batt=<%> src=AC|BATT net=1|0 ts=1|0   (one a minute)   <epoch> BOOT b=.. sr=..   <epoch> STOP

class Incident {
  final int start, end; // unix seconds
  final String title, detail;
  const Incident(this.start, this.end, this.title, this.detail);
}

class _Ev {
  final int t, boot;
  final String type; // 's' sample, 'BOOT', 'STOP'
  final int? batt;
  final bool onBatt, net, ts;
  const _Ev(this.t, this.type, {this.boot = 0, this.batt, this.onBatt = false, this.net = true, this.ts = true});
}

const _day = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
String _two(int v) => v.toString().padLeft(2, '0');

/// "03:12" for today, "Mon 03:12" for another day.
String clock(int t, int now) {
  final d = DateTime.fromMillisecondsSinceEpoch(t * 1000), n = DateTime.fromMillisecondsSinceEpoch(now * 1000);
  final hm = '${_two(d.hour)}:${_two(d.minute)}';
  return d.year == n.year && d.month == n.month && d.day == n.day ? hm : '${_day[d.weekday - 1]} $hm';
}

String span(int secs) {
  final m = secs ~/ 60;
  if (m < 60) return '$m min';
  final h = m ~/ 60, r = m % 60;
  if (h < 48) return r == 0 ? '$h h' : '$h h $r min';
  return '${h ~/ 24} days';
}

List<_Ev> _parse(String log) {
  final out = <_Ev>[];
  for (final l in log.split('\n')) {
    final w = l.trim().split(RegExp(r'\s+'));
    final t = int.tryParse(w.first);
    if (t == null || w.length < 2) continue;
    String? kv(String k) { for (final x in w) { if (x.startsWith('$k=')) return x.substring(k.length + 1); } return null; }
    final boot = int.tryParse(kv('b') ?? '') ?? 0;
    if (w[1] == 'BOOT') { out.add(_Ev(t, 'BOOT', boot: boot)); continue; }
    if (w[1] == 'STOP') { out.add(_Ev(t, 'STOP')); continue; }
    out.add(_Ev(t, 's', boot: boot, batt: int.tryParse(kv('batt') ?? ''), onBatt: kv('src') == 'BATT', net: kv('net') != '0', ts: kv('ts') != '0'));
  }
  return out;
}

/// Incidents of 5 minutes or more found in [log], oldest first. [now] is unix seconds (the clock for "03:12" vs "Mon 03:12").
List<Incident> analyze(String log, int now) {
  const gapSecs = 90; // samples come every 30 s, so 90 s = two missed ones
  final ev = _parse(log), out = <Incident>[];
  _Ev? lastSample; // last sample before the current point
  int? netStart, tsStart; // start of an open "no internet" / "no Tailscale" run
  void closeRuns(int at) {
    if (netStart != null && at - netStart! >= gapSecs) out.add(Incident(netStart!, at, 'No internet', 'The Mac stayed on but had no internet from ${clock(netStart!, now)} to ${clock(at, now)} (${span(at - netStart!)}). Probably the Wi-Fi or the router.'));
    if (tsStart != null && at - tsStart! >= gapSecs) out.add(Incident(tsStart!, at, 'Tailscale was disconnected', 'The Mac had internet but Tailscale was disconnected from ${clock(tsStart!, now)} to ${clock(at, now)} (${span(at - tsStart!)}).'));
    netStart = tsStart = null;
  }
  for (var i = 0; i < ev.length; i++) {
    final e = ev[i], prev = i > 0 ? ev[i - 1] : null;
    if (prev != null && e.t - prev.t > gapSecs) {
      closeRuns(lastSample?.t ?? prev.t);
      final away = '${clock(prev.t, now)} to ${clock(e.t, now)} (${span(e.t - prev.t)})';
      final rebooted = e.type == 'BOOT' || (lastSample != null && e.boot != 0 && e.boot != lastSample.boot);
      final b = lastSample;
      if (prev.type == 'STOP') {
        out.add(rebooted
            ? Incident(prev.t, e.t, 'Shut down or restarted', 'The Mac shut down or restarted normally, $away.')
            : Incident(prev.t, e.t, 'Stay awake was off', 'Stay awake was switched off on the Mac, $away. It could sleep then.'));
      } else if (rebooted) {
        final bat = b?.batt != null ? ' Battery was ${b!.batt}% ${b.onBatt ? 'on battery' : 'plugged in'}.' : '';
        out.add(b != null && b.onBatt && (b.batt ?? 100) <= 10
            ? Incident(prev.t, e.t, 'Battery ran out', 'The Mac switched off about ${clock(prev.t, now)} and came back ${clock(e.t, now)} ($away).$bat')
            : Incident(prev.t, e.t, 'Stopped suddenly', 'The Mac stopped without shutting down, $away. A crash or a power cut.$bat'));
      } else {
        out.add(Incident(prev.t, e.t, 'The Mac was asleep', 'The Mac slept without restarting, $away.'));
      }
      lastSample = null;
    }
    if (e.type == 'BOOT' || e.type == 'STOP') { closeRuns(lastSample?.t ?? e.t); continue; }
    lastSample = e;
    if (!e.net) { netStart ??= e.t; tsStart = null; } else {
      if (netStart != null) { final s = netStart!; netStart = null; if (e.t - s >= gapSecs) out.add(Incident(s, e.t, 'No internet', 'The Mac stayed on but had no internet from ${clock(s, now)} to ${clock(e.t, now)} (${span(e.t - s)}). Probably the Wi-Fi or the router.')); }
      if (!e.ts) { tsStart ??= e.t; } else if (tsStart != null) { final s = tsStart!; tsStart = null; if (e.t - s >= gapSecs) out.add(Incident(s, e.t, 'Tailscale was disconnected', 'The Mac had internet but Tailscale was disconnected from ${clock(s, now)} to ${clock(e.t, now)} (${span(e.t - s)}).')); }
    }
  }
  out.sort((a, b) => a.start.compareTo(b.start));
  return out;
}

/// The phone's last battery reading of the Mac: "pct|onBattery|unix seconds" (see Store.setBattery).
class Reading {
  final int pct, t;
  final bool onBatt;
  const Reading(this.pct, this.onBatt, this.t);
  static Reading? parse(String? s) {
    final p = (s ?? '').split('|');
    if (p.length != 3) return null;
    final a = int.tryParse(p[0]), t = int.tryParse(p[2]);
    return a == null || t == null ? null : Reading(a, p[1] == '1', t);
  }
}

/// What the phone can say while the Mac is down. [seen] = Tailscale's last-seen (unix seconds, 0 unknown). Always a guess.
String reasonOffline(Reading? r, int seen, int now) {
  final when = seen > 0 ? 'Offline since ${clock(seen, now)} (${span(now - seen)} ago).' : 'Offline.';
  const tail = ' A restart can also leave it waiting for its password.';
  if (r == null) return '$when Cause unknown. If the Mac is still on, its Wi-Fi may have dropped; it may also have run out of battery.$tail';
  final at = clock(r.t, now);
  // A battery cannot go from above 10% to empty in the few minutes since the last reading, so only a low reading blames the battery.
  if (r.onBatt && r.pct <= 10) return '$when Last reading: ${r.pct}% on battery at $at. Most likely it ran out of battery.$tail';
  final src = r.onBatt ? '${r.pct}% on battery' : 'plugged in, ${r.pct}%';
  final old = now - r.t > 2 * 3600; // on battery, hours of drain are possible: an old reading proves nothing
  if (r.onBatt && old) return '$when Last reading: $src at $at, ${span(now - r.t)} ago. The battery may have run out since, or the network failed.$tail';
  return '$when Last reading: $src at $at. Not the battery. Most likely a network problem: the Mac\'s Wi-Fi or router.$tail';
}

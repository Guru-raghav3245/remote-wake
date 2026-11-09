import 'package:flutter_test/flutter_test.dart';
import 'package:remote_wake_app/blackbox.dart';

// Builds a black-box log: a sample every 60 s from [from] to [to] with the given fields.
String run(int from, int to, {int b = 100, int batt = 80, String src = 'AC', int net = 1, int ts = 1}) =>
    [for (var t = from; t <= to; t += 60) '$t b=$b batt=$batt src=$src net=$net ts=$ts'].join('\n') + '\n';

void main() {
  final t0 = DateTime(2026, 11, 9, 0, 0).millisecondsSinceEpoch ~/ 1000, now = t0 + 20 * 3600;
  String one(String log) { final i = analyze(log, now); expect(i.length, 1, reason: '$i'); return i.first.title; }

  test('battery ran out: low on battery, gap, new boot', () {
    final log = run(t0, t0 + 600, batt: 4, src: 'BATT') + '${t0 + 40000} BOOT b=200 sr=por\n' + run(t0 + 40000, t0 + 40200, b: 200);
    expect(one(log), 'Battery ran out');
  });
  test('stopped suddenly: healthy battery, gap, new boot', () {
    expect(one(run(t0, t0 + 600, batt: 70, src: 'BATT') + '${t0 + 4000} BOOT b=200 sr=por\n' + run(t0 + 4000, t0 + 4100, b: 200)), 'Stopped suddenly');
  });
  test('clean shutdown: STOP then boot', () {
    expect(one(run(t0, t0 + 600) + '${t0 + 660} STOP\n${t0 + 4000} BOOT b=200 sr=x\n' + run(t0 + 4000, t0 + 4100, b: 200)), 'Shut down or restarted');
  });
  test('stay awake switched off: STOP, same boot', () {
    expect(one(run(t0, t0 + 600) + '${t0 + 660} STOP\n' + run(t0 + 4000, t0 + 4100)), 'Stay awake was off');
  });
  test('asleep: gap, same boot, no STOP', () {
    expect(one(run(t0, t0 + 600) + run(t0 + 5000, t0 + 5100)), 'The Mac was asleep');
  });
  test('no internet while alive', () {
    expect(one(run(t0, t0 + 600) + run(t0 + 660, t0 + 4000, net: 0, ts: 0) + run(t0 + 4020, t0 + 4200)), 'No internet');
  });
  test('internet but Tailscale down', () {
    expect(one(run(t0, t0 + 600) + run(t0 + 660, t0 + 4000, ts: 0) + run(t0 + 4020, t0 + 4200)), 'Tailscale was disconnected');
  });
  test('power cut then router dead then battery dies: two incidents', () {
    final log = run(t0, t0 + 600) + run(t0 + 660, t0 + 6000, net: 0, ts: 0, src: 'BATT', batt: 30) + run(t0 + 6060, t0 + 8000, net: 0, ts: 0, src: 'BATT', batt: 3) + '${t0 + 60000} BOOT b=200 sr=por\n' + run(t0 + 60000, t0 + 60100, b: 200);
    expect(analyze(log, now).map((i) => i.title).toList(), ['No internet', 'Battery ran out']);
  });
  test('healthy log has no incidents; junk lines are ignored', () {
    expect(analyze('garbage\n\n${run(t0, t0 + 3000)}', now), isEmpty);
  });
  test('guess while down', () {
    expect(reasonOffline(Reading(4, true, t0), t0 + 100, now), contains('Most likely it ran out of battery'));
    expect(reasonOffline(Reading(10, true, t0), t0 + 100, now), contains('ran out of battery'));
    expect(reasonOffline(Reading(96, true, now - 600), now - 500, now), contains('network problem'));
    expect(reasonOffline(Reading(60, true, now - 5 * 3600), now - 4 * 3600, now), contains('may have run out since'));
    expect(reasonOffline(Reading(11, true, now - 600), now - 500, now), contains('network problem'));
    expect(reasonOffline(Reading(80, false, now - 600), now - 500, now), contains('network problem'));
    expect(reasonOffline(null, 0, now), startsWith('Offline. Cause unknown'));
  });
}

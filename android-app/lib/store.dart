import 'package:shared_preferences/shared_preferences.dart';

// Per-device memory: the user name last used and the pinned SSH host key fingerprint (trust on first use).
class Store {
  static Future<String> user(String ip) async => (await SharedPreferences.getInstance()).getString('user:$ip') ?? '';
  static Future<void> setUser(String ip, String u) async => (await SharedPreferences.getInstance()).setString('user:$ip', u);
  static Future<String> hostKey(String ip) async => (await SharedPreferences.getInstance()).getString('fp:$ip') ?? '';
  static Future<void> setHostKey(String ip, String fp) async => (await SharedPreferences.getInstance()).setString('fp:$ip', fp);
  // computers the user removed from the home list (by Tailscale IP); a local choice, the device stays in the Tailscale account
  static Future<Set<String>> hidden() async => ((await SharedPreferences.getInstance()).getStringList('hidden') ?? []).toSet();
  static Future<void> setHidden(Set<String> v) async => (await SharedPreferences.getInstance()).setStringList('hidden', v.toList());
  static Future<bool> askedBattery() async => (await SharedPreferences.getInstance()).getBool('askedBattery') ?? false;
  static Future<void> setAskedBattery() async => (await SharedPreferences.getInstance()).setBool('askedBattery', true);
  static Future<bool> keysHidden() async => (await SharedPreferences.getInstance()).getBool('keysHidden') ?? false;
  static Future<void> setKeysHidden(bool v) async => (await SharedPreferences.getInstance()).setBool('keysHidden', v);
  static Future<bool> tutorialSeen() async => (await SharedPreferences.getInstance()).getBool('tutorialSeen') ?? false;
  static Future<void> setTutorialSeen() async => (await SharedPreferences.getInstance()).setBool('tutorialSeen', true);
}

import 'package:shared_preferences/shared_preferences.dart';

// Per-device memory: the user name last used and the pinned SSH host key fingerprint (trust on first use).
class Store {
  static Future<String> user(String ip) async => (await SharedPreferences.getInstance()).getString('user:$ip') ?? '';
  static Future<void> setUser(String ip, String u) async => (await SharedPreferences.getInstance()).setString('user:$ip', u);
  static Future<String> hostKey(String ip) async => (await SharedPreferences.getInstance()).getString('fp:$ip') ?? '';
  static Future<void> setHostKey(String ip, String fp) async => (await SharedPreferences.getInstance()).setString('fp:$ip', fp);
  static Future<bool> askedBattery() async => (await SharedPreferences.getInstance()).getBool('askedBattery') ?? false;
  static Future<void> setAskedBattery() async => (await SharedPreferences.getInstance()).setBool('askedBattery', true);
  static Future<bool> tutorialSeen() async => (await SharedPreferences.getInstance()).getBool('tutorialSeen') ?? false;
  static Future<void> setTutorialSeen() async => (await SharedPreferences.getInstance()).setBool('tutorialSeen', true);
  static Future<String> themeMode() async => (await SharedPreferences.getInstance()).getString('themeMode') ?? 'system';
  static Future<void> setThemeMode(String m) async => (await SharedPreferences.getInstance()).setString('themeMode', m);
}

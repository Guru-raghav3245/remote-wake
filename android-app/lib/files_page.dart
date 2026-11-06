import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';
import 'engine.dart';
import 'native.dart';
import 'store.dart';
import 'theme.dart';

String _q(String p) => "'${p.replaceAll("'", "'\\''")}'"; // single-quote a path for the Mac's shell

// Read-only file browser for the Mac, over the same Tailscale SSH link as the terminal. Starts in the folder the phone session is in.
class FilesPage extends StatefulWidget {
  final String name, ip, user;
  const FilesPage({super.key, required this.name, required this.ip, required this.user});
  @override
  State<FilesPage> createState() => _FilesPageState();
}

class _FilesPageState extends State<FilesPage> {
  String dir = '';
  List<(String, bool)> items = []; // (name, isDir)
  bool busy = true;
  String? err;

  @override
  void initState() { super.initState(); _list(null); }

  // A command started over SSH is a child of tailscaled, so macOS would ask (on the Mac's screen) before it may read Desktop, Documents
  // or Downloads. The phone-session tmux server belongs to the helper app, which has Full Disk Access, so run the command inside it.
  // The command goes into a script file and its output into a temp dir, then is copied back out (binary-safe). Without a running
  // phone session it runs directly.
  static String _viaTmux(String cmd) {
    const t = r'"$HOME/Library/Application Support/Remote Wake/tmux"';
    return 'if [ -x $t ] && $t -L remotewake has-session 2>/dev/null; then '
        'd=\$(mktemp -d /tmp/rwf.XXXXXX); printf %s ${_q(cmd)} > \$d/c.sh; '
        '$t -L remotewake run-shell "sh \$d/c.sh >\$d/o 2>\$d/e; echo \\\$? >\$d/r"; '
        'rc=\$(cat \$d/r); cat \$d/o; rm -rf \$d; exit \$rc; '
        'else $cmd; fi';
  }

  Future<String> _run(String cmd, String dest) async =>
      Engine.fetch('${widget.ip}:22', widget.user, await Store.hostKey(widget.ip), _viaTmux(cmd), dest);

  // [to] null = the phone session's current folder (tmux pane path), else home
  Future<void> _list(String? to) async {
    setState(() { busy = true; err = null; });
    final tmp = '${(await getTemporaryDirectory()).path}/ls.txt';
    final start = to == '~' ? r'"$HOME"' : to != null ? _q(to)
        : r'''"$(p=$("$HOME/Library/Application Support/Remote Wake/tmux" -L remotewake display-message -p -t phone '#{pane_current_path}' 2>/dev/null); echo "${p:-$HOME}")"''';
    final r = await _run('cd $start && pwd -P && ls -1Ap', tmp);
    if (!mounted) return;
    if (r.isNotEmpty) { setState(() { busy = false; err = r.replaceFirst('ERROR: ', ''); }); return; }
    final lines = (await File(tmp).readAsString()).split('\n').where((l) => l.isNotEmpty).toList();
    final l = [for (final n in lines.skip(1)) n.endsWith('/') ? (n.substring(0, n.length - 1), true) : (n, false)]
      ..sort((a, b) => a.$2 != b.$2 ? (a.$2 ? -1 : 1) : a.$1.toLowerCase().compareTo(b.$1.toLowerCase()));
    setState(() { dir = lines.isEmpty ? '/' : lines.first; items = l; busy = false; });
  }

  Future<void> _open(String name) async {
    final path = dir == '/' ? '/$name' : '$dir/$name';
    setState(() => busy = true);
    final d = Directory('${(await getTemporaryDirectory()).path}/dl')..createSync(recursive: true);
    final f = '${d.path}/$name';
    final r = await _run('cat ${_q(path)}', f);
    if (!mounted) return;
    setState(() => busy = false);
    if (r.isNotEmpty) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(r.replaceFirst('ERROR: ', '')))); return; }
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => ViewerPage(file: File(f), name: name)));
  }

  @override
  Widget build(BuildContext c) {
    final s = c.sage;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Files', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          Text(dir.isEmpty ? widget.name : dir, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w400, color: s.muted)),
        ]),
        actions: [IconButton(tooltip: 'Home folder', icon: Icon(Icons.home_outlined, color: s.muted), onPressed: () => _list('~')), IconButton(tooltip: 'Refresh', icon: Icon(Icons.refresh, color: s.muted), onPressed: () => _list(dir.isEmpty ? null : dir))],
      ),
      body: SafeArea(
        child: Column(children: [
          if (busy) LinearProgressIndicator(color: s.accent, backgroundColor: s.line, minHeight: 2),
          if (err != null) Padding(padding: const EdgeInsets.all(Sp.lg), child: Text(err!, style: TextStyle(color: s.danger))),
          Expanded(child: ListView(children: [
            if (dir.isNotEmpty && dir != '/') _row(s, Icons.arrow_upward, '..', () => _list('$dir/..')),
            for (final it in items)
              _row(s, it.$2 ? Icons.folder_outlined : _icon(it.$1), it.$1, () => it.$2 ? _list(dir == '/' ? '/${it.$1}' : '$dir/${it.$1}') : _open(it.$1), dim: it.$1.startsWith('.')),
            if (!busy && items.isEmpty && err == null) Padding(padding: const EdgeInsets.all(Sp.lg), child: Text('Empty folder', style: TextStyle(color: s.muted))),
          ])),
        ]),
      ),
    );
  }

  Widget _row(Sage s, IconData i, String t, VoidCallback f, {bool dim = false}) => InkWell(
        onTap: busy ? null : f,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Sp.lg, vertical: Sp.md),
          child: Row(children: [
            Icon(i, size: 20, color: i == Icons.folder_outlined ? s.accent : s.muted),
            const SizedBox(width: Sp.md),
            Expanded(child: Text(t, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: dim ? s.muted : s.text))),
          ]),
        ),
      );
}

String _ext(String n) => n.contains('.') ? n.split('.').last.toLowerCase() : '';
const _md = {'md', 'markdown'}, _img = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'}, _vid = {'mp4', 'mov', 'm4v', 'webm', 'mkv'};
const _txt = {'txt', 'log', 'json', 'yaml', 'yml', 'toml', 'csv', 'py', 'js', 'ts', 'go', 'swift', 'dart', 'kt', 'java', 'sh', 'zsh', 'html', 'css', 'c', 'h', 'rs', 'rb', 'xml', 'ini', 'cfg', 'conf', 'env', 'sql'};
IconData _icon(String n) {
  final e = _ext(n);
  return _img.contains(e) ? Icons.image_outlined : _vid.contains(e) ? Icons.movie_outlined : _md.contains(e) || _txt.contains(e) ? Icons.description_outlined : Icons.insert_drive_file_outlined;
}

// Shows a downloaded file: markdown rendered, text/code as plain monospace, images, video; anything else goes to the share sheet.
class ViewerPage extends StatefulWidget {
  final File file;
  final String name;
  const ViewerPage({super.key, required this.file, required this.name});
  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<ViewerPage> {
  String? text;
  bool loaded = false, full = false;

  @override
  void initState() {
    super.initState();
    final e = _ext(widget.name);
    if (!_vid.contains(e) && !_img.contains(e)) _loadText();
  }

  // Any file that is not an image or video is shown as text when it has no NUL bytes (so .txt and unknown extensions both open).
  Future<void> _loadText() async {
    try {
      final raf = await widget.file.open();
      final b = await raf.read(2 * 1024 * 1024); // first 2 MB is plenty on a phone
      final more = await raf.length() > b.length;
      await raf.close();
      if (b.contains(0)) { if (mounted) setState(() => loaded = true); return; }
      final t = utf8.decode(b, allowMalformed: true) + (more ? '\n\n[... file continues; showing the first 2 MB]' : '');
      if (mounted) setState(() { text = t; loaded = true; });
    } catch (_) { if (mounted) setState(() => loaded = true); }
  }

  @override
  Widget build(BuildContext c) {
    final s = c.sage, e = _ext(widget.name);
    Widget body;
    if (_vid.contains(e)) {
      body = VideoView(file: widget.file, onFull: (f) => setState(() => full = f));
    } else if (_img.contains(e)) {
      body = InteractiveViewer(child: Center(child: Image.file(widget.file)));
    } else if (text != null) {
      body = _md.contains(e)
          ? Markdown(data: text!, selectable: true, onTapLink: (_, __, ___) {}, styleSheet: MarkdownStyleSheet(
              p: const TextStyle(fontSize: 14, height: 1.5), code: TextStyle(fontFamily: mono, fontSize: 12, backgroundColor: s.soft),
              codeblockDecoration: BoxDecoration(color: s.card, borderRadius: BorderRadius.circular(10), border: Border.all(color: s.line)),
              blockquoteDecoration: BoxDecoration(border: Border(left: BorderSide(color: s.accent, width: 3)))))
          : SingleChildScrollView(padding: const EdgeInsets.all(Sp.lg), child: SelectableText(text!, style: const TextStyle(fontFamily: mono, fontSize: 12, height: 1.4)));
    } else if (!loaded) {
      body = Center(child: CircularProgressIndicator(color: s.accent));
    } else {
      body = Center(child: Padding(padding: const EdgeInsets.all(Sp.xl), child: Text('No preview for this file type. Use Save or Share.', textAlign: TextAlign.center, style: TextStyle(color: s.muted))));
    }
    return Scaffold(
      backgroundColor: full ? Colors.black : null,
      appBar: full ? null : AppBar(
        titleSpacing: 0,
        title: Text(widget.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        actions: [
          IconButton(tooltip: 'Save to phone (Downloads)', icon: Icon(Icons.download_outlined, color: s.muted), onPressed: () async {
            final m = ScaffoldMessenger.of(c);
            try { await Native.saveToDownloads(widget.file.path, widget.name); m.showSnackBar(SnackBar(content: Text('Saved to Downloads: ${widget.name}'))); }
            catch (_) { m.showSnackBar(const SnackBar(content: Text('Could not save the file'))); }
          }),
          IconButton(tooltip: 'Share', icon: Icon(Icons.ios_share, color: s.muted), onPressed: () => Share.shareXFiles([XFile(widget.file.path)])),
        ],
      ),
      body: SafeArea(top: !full, bottom: !full, child: body),
    );
  }
}

String _t(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return d.inHours > 0 ? '${d.inHours}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}' : '${two(d.inMinutes)}:${two(d.inSeconds % 60)}';
}

// VLC-style player: tap to show/hide the controls, double-tap the left/right half to jump 10 s, time + seek bar, play speed,
// mute, and a full-screen (landscape, no system bars) toggle.
class VideoView extends StatefulWidget {
  final File file;
  final void Function(bool) onFull;
  const VideoView({super.key, required this.file, required this.onFull});
  @override
  State<VideoView> createState() => _VideoViewState();
}

class _VideoViewState extends State<VideoView> {
  late final VideoPlayerController v;
  bool show = true, full = false, muted = false, drag = false;
  double speed = 1, dragMs = 0;
  Timer? hide;
  String? flash; // "-10 s" / "+10 s" feedback after a double tap
  Timer? flashT;

  @override
  void initState() {
    super.initState();
    v = VideoPlayerController.file(widget.file)..addListener(() { if (mounted) setState(() {}); });
    v.initialize().then((_) { if (mounted) { setState(() {}); v.play(); _arm(); } });
  }

  @override
  void dispose() {
    hide?.cancel(); flashT?.cancel(); v.dispose();
    if (full) _setFull(false);
    super.dispose();
  }

  void _arm() { hide?.cancel(); hide = Timer(const Duration(seconds: 3), () { if (mounted && v.value.isPlaying && !drag) setState(() => show = false); }); }

  void _setFull(bool f) {
    SystemChrome.setPreferredOrientations(f ? [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight] : []);
    SystemChrome.setEnabledSystemUIMode(f ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge);
  }

  void _toggleFull() { full = !full; _setFull(full); widget.onFull(full); setState(() {}); _arm(); }

  void _seekBy(int sec) {
    final d = v.value.duration.inMilliseconds, p = v.value.position.inMilliseconds + sec * 1000;
    v.seekTo(Duration(milliseconds: p.clamp(0, d)));
    flashT?.cancel();
    setState(() => flash = sec < 0 ? '$sec s' : '+$sec s');
    flashT = Timer(const Duration(milliseconds: 700), () { if (mounted) setState(() => flash = null); });
  }

  void _playPause() { v.value.isPlaying ? v.pause() : v.play(); setState(() => show = true); _arm(); }

  @override
  Widget build(BuildContext c) {
    final s = c.sage;
    if (!v.value.isInitialized) return Center(child: v.value.hasError ? Text('Cannot play this video', style: TextStyle(color: s.danger)) : CircularProgressIndicator(color: s.accent));
    final dur = v.value.duration, pos = drag ? Duration(milliseconds: dragMs.round()) : v.value.position;
    final maxMs = math.max(1.0, dur.inMilliseconds.toDouble());
    Widget icon(IconData i, VoidCallback f, {double size = 28}) => IconButton(iconSize: size, color: Colors.white, icon: Icon(i), onPressed: () { f(); _arm(); });
    return Stack(fit: StackFit.expand, children: [
      Container(color: Colors.black),
      Center(child: AspectRatio(aspectRatio: v.value.aspectRatio, child: VideoPlayer(v))),
      // tap = controls, double tap left/right half = -/+ 10 s
      Row(children: [
        for (final back in [true, false])
          Expanded(child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () { setState(() => show = !show); if (show) _arm(); },
            onDoubleTap: () => _seekBy(back ? -10 : 10),
          )),
      ]),
      if (flash != null) Center(child: Container(padding: const EdgeInsets.symmetric(horizontal: Sp.lg, vertical: Sp.sm), decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)), child: Text(flash!, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)))),
      if (show) ...[
        Center(child: Row(mainAxisSize: MainAxisSize.min, children: [
          icon(Icons.replay_10, () => _seekBy(-10), size: 36),
          const SizedBox(width: Sp.lg),
          Container(decoration: BoxDecoration(color: Colors.black54, shape: BoxShape.circle), child: icon(v.value.isPlaying ? Icons.pause : Icons.play_arrow, _playPause, size: 48)),
          const SizedBox(width: Sp.lg),
          icon(Icons.forward_10, () => _seekBy(10), size: 36),
        ])),
        Positioned(left: 0, right: 0, bottom: 0, child: Container(
          decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.bottomCenter, end: Alignment.topCenter, colors: [Colors.black87, Colors.transparent])),
          padding: const EdgeInsets.fromLTRB(Sp.md, Sp.xl, Sp.sm, Sp.sm),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Text(_t(pos), style: const TextStyle(color: Colors.white, fontSize: 12)),
              Expanded(child: SliderTheme(
                data: SliderTheme.of(c).copyWith(trackHeight: 3, activeTrackColor: s.accent, thumbColor: s.accent, inactiveTrackColor: Colors.white24, overlayShape: SliderComponentShape.noOverlay),
                child: Slider(
                  min: 0, max: maxMs, value: (drag ? dragMs : v.value.position.inMilliseconds.toDouble()).clamp(0, maxMs),
                  onChangeStart: (x) { drag = true; dragMs = x; hide?.cancel(); },
                  onChanged: (x) => setState(() => dragMs = x),
                  onChangeEnd: (x) { v.seekTo(Duration(milliseconds: x.round())); setState(() => drag = false); _arm(); },
                ),
              )),
              Text(_t(dur), style: const TextStyle(color: Colors.white, fontSize: 12)),
            ]),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              PopupMenuButton<double>(
                tooltip: 'Playback speed', initialValue: speed, color: s.card,
                onSelected: (x) { setState(() => speed = x); v.setPlaybackSpeed(x); _arm(); },
                itemBuilder: (_) => [for (final x in [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]) PopupMenuItem(value: x, child: Text('${x}x'))],
                child: Padding(padding: const EdgeInsets.symmetric(horizontal: Sp.md, vertical: Sp.sm), child: Text('${speed}x', style: TextStyle(color: s.accent, fontWeight: FontWeight.w700))),
              ),
              Row(children: [
                icon(muted ? Icons.volume_off : Icons.volume_up, () { setState(() => muted = !muted); v.setVolume(muted ? 0 : 1); }, size: 22),
                icon(full ? Icons.fullscreen_exit : Icons.fullscreen, _toggleFull, size: 26),
              ]),
            ]),
          ]),
        )),
      ],
    ]);
  }
}

import 'dart:io';
import 'package:flutter/material.dart';
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
  VideoPlayerController? vc;
  String? text;

  @override
  void initState() {
    super.initState();
    final e = _ext(widget.name);
    if (_vid.contains(e)) {
      vc = VideoPlayerController.file(widget.file)..initialize().then((_) { if (mounted) setState(() {}); vc!.play(); });
    } else if (_md.contains(e) || _txt.contains(e) || e.isEmpty) {
      widget.file.readAsString().then((t) { if (mounted) setState(() => text = t); }).catchError((_) { if (mounted) setState(() => text = null); });
    }
  }

  @override
  void dispose() { vc?.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext c) {
    final s = c.sage, e = _ext(widget.name);
    Widget body;
    if (vc != null) {
      body = vc!.value.isInitialized
          ? Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              AspectRatio(aspectRatio: vc!.value.aspectRatio, child: VideoPlayer(vc!)),
              VideoProgressIndicator(vc!, allowScrubbing: true, colors: VideoProgressColors(playedColor: s.accent)),
              IconButton(iconSize: 40, color: s.accent, icon: Icon(vc!.value.isPlaying ? Icons.pause : Icons.play_arrow), onPressed: () => setState(() => vc!.value.isPlaying ? vc!.pause() : vc!.play())),
            ])
          : Center(child: CircularProgressIndicator(color: s.accent));
    } else if (_img.contains(e)) {
      body = InteractiveViewer(child: Center(child: Image.file(widget.file)));
    } else if (text != null) {
      body = _md.contains(e)
          ? Markdown(data: text!, selectable: true, onTapLink: (_, __, ___) {}, styleSheet: MarkdownStyleSheet(
              p: const TextStyle(fontSize: 14, height: 1.5), code: TextStyle(fontFamily: mono, fontSize: 12, backgroundColor: s.soft),
              codeblockDecoration: BoxDecoration(color: s.card, borderRadius: BorderRadius.circular(10), border: Border.all(color: s.line)),
              blockquoteDecoration: BoxDecoration(border: Border(left: BorderSide(color: s.accent, width: 3)))))
          : SingleChildScrollView(padding: const EdgeInsets.all(Sp.lg), scrollDirection: Axis.vertical,
              child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: SelectableText(text!, style: const TextStyle(fontFamily: mono, fontSize: 12, height: 1.4))));
    } else {
      body = Center(child: Padding(padding: const EdgeInsets.all(Sp.xl), child: Text('No preview for this file type. Use Save or Share.', textAlign: TextAlign.center, style: TextStyle(color: s.muted))));
    }
    return Scaffold(
      appBar: AppBar(
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
      body: SafeArea(child: body),
    );
  }
}

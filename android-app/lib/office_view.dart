import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

// Turns .docx, .xlsx and .pptx into a simple HTML page for the viewer's web view. Read only, no Office software needed.
// Shows text with bold/italic/underline, headings, bullets, tables, pictures, comments, charts (simple bar/line/pie/area drawn from
// the data stored in the file) and spreadsheet cells with dates, percentages and decimals applied; formulas without a stored value are
// calculated for + - * / ^, cell references and SUM, AVERAGE, MIN, MAX, COUNT, ABS, ROUND, SQRT.
// ponytail: layout is approximate (no fonts, colours, merged cells, page breaks, text boxes or shapes); charts are plain; formulas with
// other functions or other sheets show as =formula; EMF/WMF pictures show a placeholder. Legacy .doc/.xls/.ppt are converted by
// LibreOffice on the Mac (files_page.dart), not here.

const _css = '''<meta name=viewport content="width=device-width,initial-scale=1"><style>
body{font:15px/1.5 sans-serif;margin:12px;color:#111;background:#fff}h1,h2,h3{margin:.8em 0 .3em}p{margin:.4em 0}img,svg{max-width:100%;height:auto}
table{border-collapse:collapse;margin:8px 0}td,th{border:1px solid #bbb;padding:3px 7px;vertical-align:top}
.w{overflow-x:auto}nav a{margin-right:12px}.f{color:#888;font-style:italic}.n{text-align:right}.c{background:#fffbe6;border-left:3px solid #e0b000;padding:4px 8px;margin:4px 0;font-size:13px}
th{background:#eee;font-weight:600}hr{border:0;border-top:1px solid #ccc;margin:18px 0}</style>''';


// XML names are matched by local name so files whose writer used other prefixes (or none) still read.
extension _X on XmlElement {
  Iterable<XmlElement> all(String n) => descendantElements.where((e) => e.name.local == n);
  Iterable<XmlElement> kids(String n) => childElements.where((e) => e.name.local == n);
  XmlElement? kid(String n) => kids(n).firstOrNull;
  // a namespaced attribute (r:id, r:embed, w:val) wins over a plain one of the same local name (sldId has both id and r:id)
  String? at(String n) {
    final m = attributes.where((a) => a.name.local == n);
    return (m.where((a) => a.name.prefix != null).firstOrNull ?? m.firstOrNull)?.value;
  }
}

extension _D on XmlDocument {
  Iterable<XmlElement> all(String n) => [rootElement, ...rootElement.all(n)].where((e) => e.name.local == n);
}

String _esc(String s) => const HtmlEscape().convert(s);

String _norm(String p) {
  final out = <String>[];
  for (final s in p.split('/')) {
    if (s == '..') { if (out.isNotEmpty) out.removeLast(); } else if (s != '.' && s.isNotEmpty) { out.add(s); }
  }
  return out.join('/');
}

class _Pkg {
  final Archive a;
  int imgBytes = 0;
  _Pkg(File f) : a = ZipDecoder().decodeBytes(f.readAsBytesSync());

  XmlDocument? xml(String name) {
    final f = a.findFile(name);
    return f == null ? null : XmlDocument.parse(utf8.decode(f.content as List<int>, allowMalformed: true));
  }

  // relationships of a part: id -> (type, absolute path inside the zip)
  Map<String, (String, String)> rels(String part) {
    final i = part.lastIndexOf('/');
    final dir = i < 0 ? '' : part.substring(0, i);
    final x = xml('${i < 0 ? '' : '$dir/'}_rels/${part.substring(i + 1)}.rels');
    final m = <String, (String, String)>{};
    for (final r in x?.all('Relationship') ?? <XmlElement>[]) {
      if (r.getAttribute('TargetMode') == 'External') continue;
      final t = r.getAttribute('Target') ?? '';
      m[r.getAttribute('Id') ?? ''] = (r.getAttribute('Type') ?? '', _norm(t.startsWith('/') ? t.substring(1) : '$dir/$t'));
    }
    return m;
  }

  String img(String path) {
    final f = a.findFile(path);
    final e = path.split('.').last.toLowerCase();
    const mime = {'png': 'image/png', 'jpg': 'image/jpeg', 'jpeg': 'image/jpeg', 'gif': 'image/gif', 'bmp': 'image/bmp', 'webp': 'image/webp', 'svg': 'image/svg+xml'};
    if (f == null || !mime.containsKey(e)) return '<span class=f>[picture: .$e]</span>';
    final b = f.content as List<int>;
    if ((imgBytes += b.length) > 30 * 1024 * 1024) return '<span class=f>[picture skipped: too much picture data]</span>';
    return '<img src="data:${mime[e]};base64,${base64.encode(b)}">';
  }

  // pictures and charts inside a drawing / graphic frame / slide shape
  String drawing(XmlElement e, Map<String, (String, String)> rels, [_Resolve? resolve]) {
    final b = StringBuffer();
    for (final x in e.all('blip')) {
      final t = rels[x.at('embed')];
      if (t != null) b.write(img(t.$2));
    }
    for (final x in e.all('chart')) {
      final t = rels[x.at('id')];
      if (t != null) b.write(_chart(this, t.$2, resolve));
    }
    return b.toString();
  }
}

// ---------------------------------------------------------------- docx

String docxToHtml(File file) {
  final p = _Pkg(file);
  final body = p.xml('word/document.xml')?.all('body').firstOrNull;
  if (body == null) throw 'not a Word document';
  final rels = p.rels('word/document.xml');
  final out = StringBuffer(_css);
  for (final n in body.childElements) {
    if (n.name.local == 'p') {
      out.write(_para(n, p, rels));
    } else if (n.name.local == 'tbl') {
      out.write('<div class=w><table>');
      for (final tr in n.kids('tr')) {
        out.write('<tr>');
        for (final tc in tr.kids('tc')) { out.write('<td>${tc.kids('p').map((q) => _para(q, p, rels)).join()}</td>'); }
        out.write('</tr>');
      }
      out.write('</table></div>');
    }
  }
  final cs = p.xml('word/comments.xml')?.all('comment').toList() ?? [];
  if (cs.isNotEmpty) {
    out.write('<hr><h3>Comments</h3>');
    for (final c in cs) { out.write('<div class=c><b>${_esc(c.at('author') ?? '')}:</b> ${_esc(c.all('t').map((t) => t.innerText).join())}</div>'); }
  }
  return out.toString();
}

String _para(XmlElement p, _Pkg pkg, Map<String, (String, String)> rels) {
  final style = p.all('pStyle').firstOrNull?.at('val') ?? '';
  final h = RegExp(r'^(?:Heading|Title)(\d?)$', caseSensitive: false).firstMatch(style);
  final tag = h == null ? 'p' : 'h${(int.tryParse(h.group(1) ?? '') ?? 1).clamp(1, 3)}';
  final b = StringBuffer(p.all('numPr').isNotEmpty ? '&bull; ' : '');
  for (final r in p.all('r')) {
    final pr = r.kid('rPr');
    var t = r.children.whereType<XmlElement>().map((e) => switch (e.name.local) {
          't' => _esc(e.innerText),
          'tab' => '&emsp;',
          'br' => '<br>',
          'drawing' => pkg.drawing(e, rels),
          _ => ''
        }).join();
    if (pr?.kid('b') != null) t = '<b>$t</b>';
    if (pr?.kid('i') != null) t = '<i>$t</i>';
    if (pr?.kid('u') != null) t = '<u>$t</u>';
    b.write(t);
  }
  return '<$tag>${b.isEmpty ? '&nbsp;' : b}</$tag>';
}

// ---------------------------------------------------------------- pptx

String pptxToHtml(File file) {
  final p = _Pkg(file);
  final pres = p.xml('ppt/presentation.xml');
  if (pres == null) throw 'not a PowerPoint file';
  final prels = p.rels('ppt/presentation.xml');
  final out = StringBuffer(_css);
  var n = 0;
  for (final id in pres.all('sldId')) {
    final path = prels[id.at('id')]?.$2;
    final slide = path == null ? null : p.xml(path);
    final tree = slide?.all('spTree').firstOrNull;
    if (tree == null) continue;
    final rels = p.rels(path!);
    out.write('${n++ == 0 ? '' : '<hr>'}<p class=f>Slide $n</p>');
    for (final s in tree.childElements) {
      switch (s.name.local) {
        case 'sp':
          final ph = s.all('ph').firstOrNull?.getAttribute('type') ?? '';
          final title = ph == 'title' || ph == 'ctrTitle';
          for (final para in s.all('p')) {
            final t = para.all('t').map((e) => _esc(e.innerText)).join();
            if (t.isEmpty) continue;
            out.write(title ? '<h2>$t</h2>' : '<p>${para.all('buChar').isNotEmpty || ph == 'body' ? '&bull; ' : ''}$t</p>');
          }
        case 'pic':
          out.write(p.drawing(s, rels));
        case 'graphicFrame':
          final tbl = s.all('tbl').firstOrNull;
          if (tbl != null) {
            out.write('<div class=w><table>');
            for (final tr in tbl.kids('tr')) {
              out.write('<tr>${[for (final tc in tr.kids('tc')) '<td>${_esc(tc.all('t').map((e) => e.innerText).join(' '))}</td>'].join()}</tr>');
            }
            out.write('</table></div>');
          } else {
            out.write(p.drawing(s, rels));
          }
      }
    }
  }
  return out.toString();
}

// ---------------------------------------------------------------- xlsx

int _col(String ref) { // "AB12" -> 27 (zero based 26)
  var c = 0;
  for (final u in ref.toUpperCase().codeUnits) { if (u < 65 || u > 90) break; c = c * 26 + u - 64; }
  return c - 1;
}

String _colName(int i) {
  var s = '';
  for (var n = i + 1; n > 0; n = (n - 1) ~/ 26) { s = String.fromCharCode(65 + (n - 1) % 26) + s; }
  return s;
}

String _plain(double v) {
  final r = double.parse(v.toStringAsPrecision(12));
  return r == r.roundToDouble() && r.abs() < 1e15 ? r.toInt().toString() : r.toString();
}

String _group(String digits) => digits.replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');

// Applies the cell's number format (id from styles.xml, custom code when there is one): dates, times, percentages, fixed decimals.
String _numText(double v, int id, Map<int, String> codes) {
  final code = codes[id] ?? '';
  final c = code.replaceAll(RegExp(r'"[^"]*"|\[[^\]]*\]|\\.|_.|\*.'), '');
  final date = (id >= 14 && id <= 22) || (id >= 45 && id <= 47) || RegExp(r'[ymdhs]', caseSensitive: false).hasMatch(c);
  if (date) {
    final d = DateTime.utc(1899, 12, 30).add(Duration(milliseconds: (v * 86400000).round()));
    String two(int n) => n.toString().padLeft(2, '0');
    final time = RegExp(r'[hs]', caseSensitive: false).hasMatch(c) || (id >= 18 && id <= 22) || (id >= 45 && id <= 47);
    final day = v >= 1 ? '${d.year}-${two(d.month)}-${two(d.day)}' : '';
    final hm = time && (v < 1 || v != v.floorToDouble()) ? '${two(d.hour)}:${two(d.minute)}' : '';
    return [day, hm].where((s) => s.isNotEmpty).join(' ');
  }
  final dec = RegExp(r'\.(0+)').firstMatch(c)?.group(1)?.length ?? (id == 2 || id == 4 || id == 10 ? 2 : 0);
  final known = c.contains('0') || c.contains('#') || {1, 2, 3, 4, 9, 10}.contains(id);
  if (c.contains('%') || id == 9 || id == 10) return '${(v * 100).toStringAsFixed(dec)}%';
  if (!known) return _plain(v);
  final s = v.abs().toStringAsFixed(dec).split('.');
  final grouped = c.contains(',') || id == 3 || id == 4 ? _group(s[0]) : s[0];
  return '${v < 0 ? '-' : ''}$grouped${s.length > 1 ? '.${s[1]}' : ''}';
}

class _Sheet {
  final String name, path;
  final Map<(int, int), _Cell> cells = {};
  final Map<String, double> nums = {};
  int rowCount = 0;
  _Sheet(this.name, this.path);
}

String xlsxToHtml(File file) {
  final p = _Pkg(file);
  final wb = p.xml('xl/workbook.xml');
  if (wb == null) throw 'not an Excel workbook';
  final shared = [for (final si in p.xml('xl/sharedStrings.xml')?.all('si') ?? <XmlElement>[]) si.all('t').map((t) => t.innerText).join()];
  final styles = p.xml('xl/styles.xml');
  final codes = {for (final n in styles?.all('numFmt') ?? <XmlElement>[]) int.tryParse(n.getAttribute('numFmtId') ?? '') ?? -1: n.getAttribute('formatCode') ?? ''};
  final xfs = [for (final x in styles?.all('cellXfs').firstOrNull?.kids('xf') ?? <XmlElement>[]) int.tryParse(x.getAttribute('numFmtId') ?? '') ?? 0];
  final wrels = p.rels('xl/workbook.xml');
  final sheets = <_Sheet>[];
  for (final e in wb.all('sheet').where((s) => s.getAttribute('state') != 'hidden')) {
    final path = wrels[e.at('id')]?.$2 ?? 'xl/worksheets/sheet${sheets.length + 1}.xml';
    final sh = _Sheet(e.getAttribute('name') ?? 'Sheet ${sheets.length + 1}', path);
    final rows = p.xml(path)?.all('row').toList() ?? [];
    sh.rowCount = rows.length;
    // pass 1: read every cell; numbers go in a map so formulas can use them
    for (final row in rows.take(2000)) {
      for (final c in row.kids('c')) {
        final ref = c.getAttribute('r') ?? '';
        final m = RegExp(r'^([A-Za-z]+)(\d+)$').firstMatch(ref);
        if (m == null) continue;
        final t = c.getAttribute('t'), v = c.kid('v')?.innerText ?? '';
        final xf = int.tryParse(c.getAttribute('s') ?? '') ?? 0;
        final cell = _Cell(xf < xfs.length ? xfs[xf] : 0, c.kid('f')?.innerText ?? '');
        if (t == 's') {
          final k = int.tryParse(v) ?? -1;
          cell.text = k >= 0 && k < shared.length ? shared[k] : '';
        } else if (t == 'inlineStr') {
          cell.text = c.all('t').map((e) => e.innerText).join();
        } else if (t == 'b') {
          cell.text = v == '1' ? 'TRUE' : 'FALSE';
        } else if (t == 'str' || t == 'e') {
          cell.text = v;
        } else if (v.isNotEmpty) {
          cell.num = double.tryParse(v);
          if (cell.num != null) sh.nums['${m.group(1)!.toUpperCase()}${m.group(2)}'] = cell.num!;
        }
        sh.cells[(int.parse(m.group(2)!), _col(m.group(1)!))] = cell;
      }
    }
    // pass 2: formulas with no stored value (files written by scripts); a few rounds so a formula can use another formula
    final calc = _Calc(sh.nums);
    for (var round = 0; round < 3; round++) {
      for (final e in sh.cells.entries) {
        final c = e.value;
        if (c.f.isEmpty || c.num != null || c.text != null) continue;
        final v = calc.run(c.f);
        if (v != null && v.isFinite) { c.num = v; sh.nums['${_colName(e.key.$2)}${e.key.$1}'] = v; }
      }
    }
    sheets.add(sh);
  }
  // a chart range such as Sales!$B$2:$B$4 -> the cells' values
  List<(String, double?)>? resolve(String f) {
    final m = RegExp(r"^(?:'((?:[^']|'')+)'|([^!']+))!\$?([A-Za-z]+)\$?(\d+)(?::\$?([A-Za-z]+)\$?(\d+))?$").firstMatch(f);
    if (m == null) return null;
    final name = m.group(1)?.replaceAll("''", "'") ?? m.group(2);
    final sh = sheets.where((s) => s.name == name).firstOrNull;
    if (sh == null) return null;
    final c1 = _col(m.group(3)!), r1 = int.parse(m.group(4)!), c2 = _col(m.group(5) ?? m.group(3)!), r2 = int.parse(m.group(6) ?? m.group(4)!);
    return [
      for (var r = math.min(r1, r2); r <= math.max(r1, r2); r++)
        for (var c = math.min(c1, c2); c <= math.max(c1, c2); c++)
          (sh.cells[(r, c)]?.text ?? (sh.cells[(r, c)]?.num == null ? '' : _plain(sh.cells[(r, c)]!.num!)), sh.cells[(r, c)]?.num)
    ];
  }

  final out = StringBuffer(_css)..write('<nav>');
  for (var i = 0; i < sheets.length; i++) { out.write('<a href="#s$i">${_esc(sheets[i].name)}</a>'); }
  out.write('</nav>');
  for (var i = 0; i < sheets.length; i++) {
    final sh = sheets[i];
    out.write('<h3 id="s$i">${_esc(sh.name)}</h3><div class=w><table>');
    final rowNums = sh.cells.keys.map((k) => k.$1).toSet().toList()..sort();
    for (final r in rowNums) {
      final cols = sh.cells.keys.where((k) => k.$1 == r).map((k) => k.$2).toList();
      final last = cols.fold(-1, (m, k) => k > m ? k : m);
      out.write('<tr>');
      for (var k = 0; k <= last; k++) {
        final c = sh.cells[(r, k)];
        if (c == null) { out.write('<td></td>'); continue; }
        if (c.num != null) {
          out.write('<td class=n>${_numText(c.num!, c.fmt, codes)}</td>');
        } else if (c.text != null) {
          out.write('<td>${_esc(c.text!)}</td>');
        } else {
          out.write(c.f.isEmpty ? '<td></td>' : '<td><span class=f>=${_esc(c.f)}</span></td>');
        }
      }
      out.write('</tr>');
    }
    out.write('</table></div>');
    if (sh.rowCount > 2000) out.write('<p class=f>Showing the first 2000 rows of ${sh.rowCount}.</p>');
    // pictures, charts and comments attached to the sheet
    for (final r in p.rels(sh.path).values) {
      if (r.$1.endsWith('/drawing')) {
        final d = p.xml(r.$2)?.rootElement;
        if (d == null) continue;
        final drels = p.rels(r.$2);
        for (final anchor in d.childElements) { out.write(p.drawing(anchor, drels, resolve)); }
      } else if (r.$1.endsWith('/comments')) {
        final cx = p.xml(r.$2);
        final authors = [for (final a in cx?.all('author') ?? <XmlElement>[]) a.innerText];
        for (final c in cx?.all('comment') ?? <XmlElement>[]) {
          final a = int.tryParse(c.getAttribute('authorId') ?? '') ?? -1;
          out.write('<div class=c><b>${_esc(c.getAttribute('ref') ?? '')}${a >= 0 && a < authors.length ? ' (${_esc(authors[a])})' : ''}:</b> ${_esc(c.all('t').map((t) => t.innerText).join())}</div>');
        }
      }
    }
  }
  return out.toString();
}

class _Cell {
  final int fmt;
  final String f;
  String? text;
  double? num;
  _Cell(this.fmt, this.f);
}

// Small formula calculator: + - * / ^ % unary minus, parentheses, cell references (A1, $A$1), ranges inside functions.
class _Calc {
  final Map<String, double> n;
  String s = '';
  int i = 0;
  _Calc(this.n);

  double? run(String f) {
    s = f.replaceAll(RegExp(r'\s+'), '');
    i = 0;
    try {
      final v = _expr();
      return i == s.length ? v : null;
    } catch (_) {
      return null;
    }
  }

  bool _eat(String c) {
    if (i < s.length && s[i] == c) { i++; return true; }
    return false;
  }

  double _expr() {
    var v = _term();
    while (true) {
      if (_eat('+')) { v += _term(); } else if (_eat('-')) { v -= _term(); } else { return v; }
    }
  }

  double _term() {
    var v = _pow();
    while (true) {
      if (_eat('*')) { v *= _pow(); } else if (_eat('/')) { v /= _pow(); } else { return v; }
    }
  }

  double _pow() {
    var v = _unary();
    if (_eat('^')) v = math.pow(v, _pow()).toDouble();
    return v;
  }

  double _unary() {
    if (_eat('-')) return -_unary();
    if (_eat('+')) return _unary();
    return _atom();
  }

  static final _ref = RegExp(r'^\$?([A-Za-z]{1,3})\$?(\d+)');

  double _atom() {
    final rest = s.substring(i);
    if (_eat('(')) {
      final v = _expr();
      if (!_eat(')')) throw 0;
      return v;
    }
    final num = RegExp(r'^(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?').firstMatch(rest);
    if (num != null) {
      i += num.end;
      var v = double.parse(num.group(0)!);
      if (_eat('%')) v /= 100;
      return v;
    }
    final fn = RegExp(r'^([A-Za-z][A-Za-z0-9.]*)\(').firstMatch(rest);
    if (fn != null) {
      i += fn.end;
      final a = <double>[];
      if (!_eat(')')) {
        do { a.addAll(_arg()); } while (_eat(','));
        if (!_eat(')')) throw 0;
      }
      return _fn(fn.group(1)!.toUpperCase(), a);
    }
    final r = _ref.firstMatch(rest);
    if (r != null && !(i + r.end < s.length && (s[i + r.end] == '!' || s[i + r.end] == '('))) {
      i += r.end;
      return n['${r.group(1)!.toUpperCase()}${r.group(2)}'] ?? 0;
    }
    throw 0; // other sheets, text, unknown syntax
  }

  List<double> _arg() {
    final m = RegExp(r'^\$?([A-Za-z]{1,3})\$?(\d+):\$?([A-Za-z]{1,3})\$?(\d+)').firstMatch(s.substring(i));
    if (m == null) return [_expr()];
    i += m.end;
    final c1 = _col(m.group(1)!), c2 = _col(m.group(3)!), r1 = int.parse(m.group(2)!), r2 = int.parse(m.group(4)!);
    return [
      for (var r = math.min(r1, r2); r <= math.max(r1, r2); r++)
        for (var c = math.min(c1, c2); c <= math.max(c1, c2); c++)
          if (n.containsKey('${_colName(c)}$r')) n['${_colName(c)}$r']!
    ];
  }

  double _fn(String f, List<double> a) {
    switch (f) {
      case 'SUM': return a.fold(0.0, (x, y) => x + y);
      case 'AVERAGE': return a.fold(0.0, (x, y) => x + y) / a.length;
      case 'MIN': return a.reduce(math.min);
      case 'MAX': return a.reduce(math.max);
      case 'COUNT': return a.length.toDouble();
      case 'ABS': return a[0].abs();
      case 'SQRT': return math.sqrt(a[0]);
      case 'ROUND':
        final k = math.pow(10, a.length > 1 ? a[1] : 0).toDouble();
        return (a[0] * k).roundToDouble() / k;
    }
    throw 0;
  }
}

typedef _Resolve = List<(String, double?)>? Function(String ref);

// ---------------------------------------------------------------- charts

const _pal = ['#4472c4', '#ed7d31', '#a5a5a5', '#ffc000', '#5b9bd5', '#70ad47', '#264478', '#9e480e'];

// A chart part (word/charts, xl/charts, ppt/charts) as an SVG built from the values the file stores with the chart.
String _chart(_Pkg p, String path, _Resolve? resolve) {
  final x = p.xml(path);
  final plot = x?.all('plotArea').firstOrNull;
  if (x == null || plot == null) return '';
  final title = x.all('title').firstOrNull?.all('t').map((e) => e.innerText).join() ?? '';
  XmlElement? kind;
  for (final c in plot.childElements) { if (c.name.local.endsWith('Chart')) { kind = c; break; } }
  if (kind == null) return '';
  // the values stored with the chart; when a writer stored none (only the range, as openpyxl does) read the range from the sheet
  List<String> vals(XmlElement? e) {
    final c = [for (final v in e?.all('pt') ?? <XmlElement>[]) v.kid('v')?.innerText ?? ''];
    if (c.isNotEmpty || resolve == null) return c;
    final f = e?.all('f').firstOrNull?.innerText;
    return [for (final v in (f == null ? null : resolve(f)) ?? <(String, double?)>[]) v.$2 == null ? v.$1 : v.$2.toString()];
  }

  final names = <String>[], cats = <String>[], data = <List<double>>[];
  for (final s in kind.kids('ser')) {
    names.add(vals(s.kid('tx')).firstOrNull ?? '');
    final c = vals(s.kid('cat') ?? s.kid('xVal'));
    if (c.length > cats.length) { cats..clear()..addAll(c); }
    data.add([for (final v in vals(s.kid('val') ?? s.kid('yVal'))) double.tryParse(v) ?? 0]);
  }
  if (data.isEmpty) return '';
  const w = 360.0, h = 250.0, l = 44.0, r = 350.0, t = 28.0, b = 190.0;
  final sv = StringBuffer('<svg viewBox="0 0 $w $h" width="$w" font-family="sans-serif" font-size="10"><text x="${w / 2}" y="16" text-anchor="middle" font-size="12" font-weight="bold">${_esc(title)}</text>');
  final n = data.map((d) => d.length).fold(0, math.max);
  String lab(int i) => i < cats.length ? _esc(cats[i].length > 9 ? '${cats[i].substring(0, 8)}…' : cats[i]) : '${i + 1}';
  final kn = kind.name.local;
  if (kn == 'pieChart' || kn == 'doughnutChart') {
    final d = data.first, tot = d.fold(0.0, (a, v) => a + v.abs());
    var a0 = -math.pi / 2;
    const cx = 110.0, cy = 125.0, rad = 85.0;
    for (var i = 0; i < d.length && tot > 0; i++) {
      final a1 = a0 + d[i].abs() / tot * 2 * math.pi;
      final big = a1 - a0 > math.pi ? 1 : 0;
      sv.write('<path d="M$cx,$cy L${cx + rad * math.cos(a0)},${cy + rad * math.sin(a0)} A$rad,$rad 0 $big 1 ${cx + rad * math.cos(a1)},${cy + rad * math.sin(a1)} Z" fill="${_pal[i % _pal.length]}"/>');
      sv.write('<rect x="220" y="${40 + i * 16}" width="9" height="9" fill="${_pal[i % _pal.length]}"/><text x="234" y="${48 + i * 16}">${lab(i)} (${_plain(d[i])})</text>');
      a0 = a1;
    }
  } else {
    final all = data.expand((d) => d);
    final hi = math.max(all.fold(0.0, math.max), 0.0), lo = math.min(all.fold(0.0, math.min), 0.0);
    final span = hi - lo == 0 ? 1.0 : hi - lo;
    double y(double v) => b - (v - lo) / span * (b - t);
    sv.write('<line x1="$l" y1="${y(0)}" x2="$r" y2="${y(0)}" stroke="#999"/><line x1="$l" y1="$t" x2="$l" y2="$b" stroke="#999"/>');
    sv.write('<text x="${l - 4}" y="${t + 4}" text-anchor="end">${_plain(hi)}</text><text x="${l - 4}" y="${y(0) + 4}" text-anchor="end">0</text>');
    if (lo < 0) sv.write('<text x="${l - 4}" y="${b + 4}" text-anchor="end">${_plain(lo)}</text>');
    final gw = (r - l) / math.max(n, 1);
    for (var i = 0; i < n; i++) { sv.write('<text x="${l + gw * (i + .5)}" y="${b + 13}" text-anchor="middle">${lab(i)}</text>'); }
    if (kn == 'barChart') {
      final bw = gw * .8 / data.length;
      for (var s = 0; s < data.length; s++) {
        for (var i = 0; i < data[s].length; i++) {
          final top = y(data[s][i]), z = y(0);
          sv.write('<rect x="${l + gw * i + gw * .1 + bw * s}" y="${math.min(top, z)}" width="$bw" height="${(top - z).abs()}" fill="${_pal[s % _pal.length]}"/>');
        }
      }
    } else {
      for (var s = 0; s < data.length; s++) {
        final pts = [for (var i = 0; i < data[s].length; i++) '${l + gw * (i + .5)},${y(data[s][i])}'].join(' ');
        sv.write('<polyline points="$pts" fill="none" stroke="${_pal[s % _pal.length]}" stroke-width="2"/>');
      }
    }
    for (var s = 0; s < data.length && (data.length > 1 || names[s].isNotEmpty); s++) {
      sv.write('<rect x="${l + s * 90}" y="${h - 22}" width="9" height="9" fill="${_pal[s % _pal.length]}"/><text x="${l + s * 90 + 13}" y="${h - 14}">${_esc(names[s])}</text>');
    }
  }
  return '$sv</svg>';
}

// ---------------------------------------------------------------- csv / tsv

// A delimited text file as a table (first row as the header). Quotes and doubled quotes follow RFC 4180.
String csvToHtml(String text, {String sep = ','}) {
  final rows = <List<String>>[];
  var row = <String>[];
  final f = StringBuffer();
  var q = false, more = false;
  void field() { row.add(f.toString()); f.clear(); }
  void line() { field(); rows.add(row); row = []; }
  for (var i = 0; i < text.length; i++) {
    if (rows.length > 2000) { more = true; break; }
    final c = text[i];
    if (q) {
      if (c == '"') { if (i + 1 < text.length && text[i + 1] == '"') { f.write('"'); i++; } else { q = false; } } else { f.write(c); }
    } else if (c == '"') { q = true; }
    else if (c == sep) { field(); }
    else if (c == '\n') { line(); }
    else if (c != '\r') { f.write(c); }
  }
  if (!more && (f.isNotEmpty || row.isNotEmpty)) line();
  final out = StringBuffer(_css)..write('<div class=w><table>');
  final num = RegExp(r'^-?[\d,]*\.?\d+%?$');
  for (var r = 0; r < rows.length && r <= 2000; r++) {
    out.write('<tr>');
    for (final c in rows[r]) { out.write(r == 0 ? '<th>${_esc(c)}</th>' : '<td${num.hasMatch(c.trim()) ? ' class=n' : ''}>${_esc(c)}</td>'); }
    out.write('</tr>');
  }
  out.write('</table></div>');
  if (more) out.write('<p class=f>Showing the first 2000 rows.</p>');
  return out.toString();
}

// ---------------------------------------------------------------- OpenDocument (odt, ods, odp)

String odfToHtml(File file) {
  final p = _Pkg(file);
  final body = p.xml('content.xml')?.all('body').firstOrNull;
  if (body == null) throw 'not an OpenDocument file';
  final notes = <String>[];
  final out = StringBuffer(_css);
  var n = 0;
  for (final part in body.childElements) {
    if (part.name.local == 'presentation') {
      for (final pg in part.kids('page')) { out.write('${n++ == 0 ? '' : '<hr>'}<p class=f>Slide $n</p>${_odfBlocks(pg, p, notes)}'); }
    } else {
      out.write(_odfBlocks(part, p, notes));
    }
  }
  if (notes.isNotEmpty) {
    out.write('<hr><h3>Comments</h3>');
    for (final c in notes) { out.write('<div class=c>${_esc(c)}</div>'); }
  }
  return out.toString();
}

String _odfInline(XmlElement e, _Pkg p, List<String> notes) {
  final b = StringBuffer();
  for (final c in e.children) {
    if (c is XmlText) { b.write(_esc(c.value)); continue; }
    if (c is! XmlElement) continue;
    switch (c.name.local) {
      case 's': b.write('&nbsp;' * (int.tryParse(c.getAttribute('c') ?? '') ?? 1));
      case 'tab': b.write('&emsp;');
      case 'line-break': b.write('<br>');
      case 'annotation': notes.add('${c.all('creator').firstOrNull?.innerText ?? ''}: ${c.all('p').map((x) => x.innerText).join(' ')}'.replaceFirst(RegExp(r'^: '), ''));
      case 'image': b.write(_odfImage(c, p));
      default: b.write(_odfInline(c, p, notes));
    }
  }
  return b.toString();
}

String _odfImage(XmlElement c, _Pkg p) {
  final href = c.at('href');
  if (href == null || href.startsWith('http')) return '';
  // chart and object preview bitmaps (ObjectReplacements, .svm/.emf) are not pictures the author placed: skip them
  return RegExp(r'\.(png|jpe?g|gif|bmp|webp|svg)$', caseSensitive: false).hasMatch(href) ? p.img(_norm(href)) : '';
}

String _odfBlocks(XmlElement parent, _Pkg p, List<String> notes) {
  final b = StringBuffer();
  for (final e in parent.childElements) {
    switch (e.name.local) {
      case 'h':
        b.write('<h${((int.tryParse(e.at('outline-level') ?? '') ?? 1).clamp(1, 3))}>${_odfInline(e, p, notes)}</h${((int.tryParse(e.at('outline-level') ?? '') ?? 1).clamp(1, 3))}>');
      case 'p':
        final t = _odfInline(e, p, notes);
        if (t.isNotEmpty) b.write('<p>$t</p>');
      case 'list':
        for (final li in e.all('list-item')) {
          for (final x in li.kids('p')) { b.write('<p>&bull; ${_odfInline(x, p, notes)}</p>'); }
        }
      case 'table':
        final name = e.getAttribute('name');
        if (parent.name.local == 'spreadsheet' && name != null) b.write('<h3>${_esc(name)}</h3>');
        b.write(_odfTable(e, p, notes));
      case 'image':
        b.write(_odfImage(e, p));
      case 'annotation':
        notes.add(e.all('p').map((x) => x.innerText).join(' '));
      default:
        b.write(_odfBlocks(e, p, notes)); // sections, frames, text boxes
    }
  }
  return b.toString();
}

String _odfTable(XmlElement t, _Pkg p, List<String> notes) {
  final b = StringBuffer('<div class=w><table>');
  var rows = 0;
  for (final r in t.all('table-row')) {
    final cells = <String>[];
    var any = false;
    for (final c in r.kids('table-cell')) {
      final type = c.at('value-type');
      String v;
      final val = c.at('value'), date = c.at('date-value');
      if (type == 'float' && val != null) { v = _plain(double.tryParse(val) ?? 0); }
      else if (type == 'percentage' && val != null) { v = '${_plain(double.parse(((double.tryParse(val) ?? 0) * 100).toStringAsFixed(2)))}%'; }
      else if (type == 'currency' && val != null) { v = '${_plain(double.tryParse(val) ?? 0)} ${c.at('currency') ?? ''}'.trim(); }
      else if (date != null) { v = date.replaceFirst('T00:00:00', ''); }
      else { v = _odfBlocks(c, p, notes); }
      if (v.isNotEmpty) any = true;
      final reps = math.min(int.tryParse(c.at('number-columns-repeated') ?? '') ?? 1, v.isEmpty ? 1 : 20);
      for (var i = 0; i < reps; i++) { cells.add('<td${type == 'float' || type == 'percentage' || type == 'currency' ? ' class=n' : ''}>$v</td>'); }
    }
    if (!any) continue;
    if (++rows > 2000) { b.write('</table></div><p class=f>Showing the first 2000 rows.</p>'); return b.toString(); }
    b.write('<tr>${cells.join()}</tr>');
  }
  return '$b</table></div>';
}

// ---------------------------------------------------------------- Jupyter notebook

String ipynbToText(String json) {
  final nb = jsonDecode(json) as Map<String, dynamic>;
  String src(dynamic s) => s is List ? s.join() : '$s';
  final b = StringBuffer();
  for (final c in (nb['cells'] as List? ?? [])) {
    final m = c as Map<String, dynamic>;
    if (m['cell_type'] == 'markdown') {
      b.write('${src(m['source'])}\n\n');
    } else {
      b.write('In [${m['execution_count'] ?? ' '}]:\n${src(m['source'])}\n');
      for (final o in (m['outputs'] as List? ?? [])) {
        final om = o as Map<String, dynamic>;
        final t = om['text'] ?? (om['data'] is Map ? (om['data'] as Map)['text/plain'] : null);
        if (t != null) b.write('\nOut:\n${src(t)}\n');
      }
      b.write('\n');
    }
  }
  return b.toString();
}

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_wake_app/files_page.dart';

void main() {
  test('pageLinks keeps relative top-level names only', () {
    const html = '''<link rel="stylesheet" href="katex/katex.min.css">
<script src="katex/katex.min.js"></script><script src='./img/a.png'></script>
<a href="#top">x</a><a href="https://x.com/a.js">w</a><img src="/abs/p.png"><img src="../up/p.png">
<img src="data:image/png;base64,AA"><a href="other.html?x=1">o</a><img src="my%20pics/a.png">''';
    expect(pageLinks(html), {'katex', 'img', 'other.html', 'my pics'});
  });
}

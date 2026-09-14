import 'package:playwright/playwright.dart';
import 'package:test/test.dart';

/// Parity coverage for `page.accessibilitySnapshot()` on Chromium, Firefox and
/// WebKit.
///
/// The same page, with roles, accessible names from three different sources,
/// states and nesting, must produce equivalent trees on the three engines.
/// Where the engines legitimately diverge the test records the divergence
/// instead of hiding it.
const String kFixture = '''
<!DOCTYPE html>
<html><head><title>Arvore de acessibilidade</title></head>
<body>
  <h1>Relatorio</h1>
  <nav aria-label="Navegacao principal">
    <a href="/um">Um</a>
    <a href="/dois">Dois</a>
  </nav>
  <main>
    <h2>Secao</h2>
    <button aria-label="Salvar tudo">Salvar</button>
    <button disabled>Desabilitado</button>
    <button aria-expanded="true">Expandir</button>
    <label for="nome">Nome completo</label>
    <input id="nome" value="Isaque">
    <label>Email envolvente <input id="email" value="a@b.c"></label>
    <input type="checkbox" id="aceito" checked aria-label="Aceito os termos">
    <ul>
      <li>Primeiro</li>
      <li>Segundo</li>
    </ul>
  </main>
</body></html>
''';

void main() {
  group('accessibilitySnapshot', () {
    late Playwright playwright;

    setUpAll(() async {
      playwright = await Playwright.create();
    });

    for (final browserName in ['chromium', 'firefox', 'webkit']) {
      group('[$browserName]', () {
        late Browser browser;
        var browserLaunched = false;

        setUpAll(() async {
          browser = await switch (browserName) {
            'chromium' => playwright.chromium.launch(headless: true),
            'firefox' => playwright.firefox.launch(headless: true),
            _ => playwright.webkit.launch(headless: true),
          };
          browserLaunched = true;
        });

        tearDownAll(() async {
          if (browserLaunched) await browser.close();
        });

        Future<AccessibilitySnapshot> snapshot() async {
          final context = await browser.newContext();
          try {
            final page = await context.newPage();
            await page.setContent(kFixture);
            return await page.accessibilitySnapshot();
          } finally {
            await context.close();
          }
        }

        test('a arvore nao e um esqueleto', () async {
          final tree = await snapshot();
          final nodes = <AccessibilityNode>[];
          void walk(AccessibilityNode node) {
            nodes.add(node);
            node.children.forEach(walk);
          }

          walk(tree.root);
          expect(nodes.length, greaterThan(10),
              reason: '$browserName devolveu ${nodes.length} no(s): '
                  'a arvore esta vazia, nao e uma arvore de verdade');
          expect(tree.title, equals('Arvore de acessibilidade'));
        });

        test('papeis, nomes e estados aparecem', () async {
          final tree = await snapshot();
          final nodes = <AccessibilityNode>[];
          void walk(AccessibilityNode node) {
            nodes.add(node);
            node.children.forEach(walk);
          }

          walk(tree.root);

          bool has(String role, String name) =>
              nodes.any((n) => n.role == role && n.name == name);

          expect(has('heading', 'Relatorio'), isTrue, reason: 'h1');
          expect(has('navigation', 'Navegacao principal'), isTrue,
              reason: 'aria-label no nav');
          expect(has('link', 'Um'), isTrue, reason: 'link por conteudo');
          expect(has('button', 'Salvar tudo'), isTrue,
              reason: 'aria-label vence o conteudo');
          expect(has('textbox', 'Nome completo'), isTrue,
              reason: '<label for>');
          expect(has('textbox', 'Email envolvente'), isTrue,
              reason: '<label> envolvente');
          expect(has('checkbox', 'Aceito os termos'), isTrue);
          expect(has('listitem', 'Primeiro'), isTrue);
        });
      });
    }
  });
}

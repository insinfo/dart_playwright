import 'dart:io';

import 'package:playwright/playwright.dart';
import 'package:test/test.dart';

/// Parity coverage for `page.accessibilitySnapshot()` on Chromium, Firefox and
/// WebKit.
///
/// The same page, with roles, accessible names from three different sources,
/// states and nesting, must produce equivalent trees on the three engines.
/// Where the engines legitimately diverge the test records the divergence
/// instead of hiding it — see the `divergencias` group at the bottom.
///
/// This file started as the proof that the method was lying: before the tree
/// moved into the injected script, Firefox and WebKit answered with a single
/// empty `WebArea` node and Chromium answered with the raw CDP tree, in a
/// vocabulary (`RootWebArea`, `StaticText`, `InlineTextBox`) that was neither
/// upstream's nor the other two engines'.
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
    <button aria-label="Salvar tudo" aria-describedby="dica">Salvar</button>
    <span id="dica">Grava o formulario</span>
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

/// The tree the three engines have to agree on, as aria snapshot YAML.
const String kExpectedYaml = '''
- heading "Relatorio" [level=1]
- navigation "Navegacao principal":
  - link "Um":
    - /url: /um
  - link "Dois":
    - /url: /dois
- main:
  - heading "Secao" [level=2]
  - button "Salvar tudo": Salvar
  - text: Grava o formulario
  - button "Desabilitado" [disabled]
  - button "Expandir" [expanded]
  - text: Nome completo
  - textbox "Nome completo": Isaque
  - text: Email envolvente
  - textbox "Email envolvente": a@b.c
  - checkbox "Aceito os termos" [checked]
  - list:
    - listitem: Primeiro
    - listitem: Segundo''';

void main() {
  group('accessibilitySnapshot', () {
    late Playwright playwright;

    setUpAll(() async {
      playwright = await Playwright.create();
    });

    Future<Browser> launch(String browserName) => switch (browserName) {
          'chromium' => playwright.chromium.launch(headless: true),
          'firefox' => playwright.firefox.launch(headless: true),
          _ => playwright.webkit.launch(headless: true),
        };

    for (final browserName in ['chromium', 'firefox', 'webkit']) {
      group('[$browserName]', () {
        late Browser browser;
        late BrowserContext context;
        late Page page;
        var browserLaunched = false;

        setUpAll(() async {
          browser = await launch(browserName);
          browserLaunched = true;
        });

        tearDownAll(() async {
          if (browserLaunched) await browser.close();
        });

        setUp(() async {
          context = await browser.newContext();
          page = await context.newPage();
          await page.setContent(kFixture);
        });

        tearDown(() async {
          await context.close();
        });

        test('a arvore nao e um esqueleto', () async {
          final tree = await page.accessibilitySnapshot();
          expect(tree.title, equals('Arvore de acessibilidade'));
          expect(tree.root.role, equals('fragment'));
          expect(tree.allNodes.length, greaterThan(10),
              reason: '$browserName devolveu ${tree.allNodes.length} no(s)');
          // The old skeleton: one node, role WebArea, no name.
          expect(tree.allNodes.map((node) => node.role),
              isNot(contains('WebArea')));
        });

        test('papeis e nomes acessiveis, de tres origens', () async {
          final tree = await page.accessibilitySnapshot();
          AccessibilityNode find(String role, String name) => tree.allNodes
              .firstWhere((node) => node.role == role && node.name == name,
                  orElse: () =>
                      fail('$browserName: sem no $role "$name" em\n$tree'));

          expect(find('heading', 'Relatorio').level, equals(1));
          expect(find('heading', 'Secao').level, equals(2));
          // aria-label on a container.
          find('navigation', 'Navegacao principal');
          // Name from content.
          find('link', 'Um');
          // aria-label beats the content.
          find('button', 'Salvar tudo');
          // <label for>.
          find('textbox', 'Nome completo');
          // Wrapping <label>.
          find('textbox', 'Email envolvente');
          // aria-label on an input.
          find('checkbox', 'Aceito os termos');
        });

        test('estados: checked, disabled, expanded', () async {
          final tree = await page.accessibilitySnapshot();
          AccessibilityNode find(String role, String name) => tree.allNodes
              .firstWhere((node) => node.role == role && node.name == name);

          expect(find('checkbox', 'Aceito os termos').checked, equals('true'));
          expect(find('button', 'Desabilitado').disabled, isTrue);
          expect(find('button', 'Expandir').expanded, isTrue);
          // A button with no aria-expanded is not "expanded=false": the
          // markup says nothing, and upstream keeps that distinction.
          expect(find('button', 'Salvar tudo').expanded, isNull);
          // The role has no aria-checked at all, so the field is absent.
          expect(find('button', 'Salvar tudo').checked, isNull);
        });

        test('valor, descricao e props', () async {
          final tree = await page.accessibilitySnapshot();
          AccessibilityNode find(String role, String name) => tree.allNodes
              .firstWhere((node) => node.role == role && node.name == name);

          expect(find('textbox', 'Nome completo').value, equals('Isaque'));
          expect(find('button', 'Salvar tudo').description,
              equals('Grava o formulario'));
          expect(find('link', 'Um').props['url'], equals('/um'));
        });

        test('aninhamento: os links moram dentro da navegacao', () async {
          final tree = await page.accessibilitySnapshot();
          final nav =
              tree.allNodes.firstWhere((node) => node.role == 'navigation');
          expect(
              nav.children.map((node) => node.role), equals(['link', 'link']));
          expect(nav.children.map((node) => node.name), equals(['Um', 'Dois']));

          final list = tree.allNodes.firstWhere((node) => node.role == 'list');
          expect(list.children.map((node) => node.role),
              equals(['listitem', 'listitem']));
          // A listitem takes no name from its content, so the text is a child.
          expect(list.children.first.name, isEmpty);
          expect(list.children.first.children.single.isText, isTrue);
          expect(list.children.first.children.single.name, equals('Primeiro'));
        });

        test('a arvore rende exatamente o YAML esperado', () async {
          expect(await page.ariaSnapshot(), equals(kExpectedYaml));
        });

        test('interestingOnly: false mantem os wrappers genericos', () async {
          await page.setContent('<div><span><button>Ok</button></span></div>');

          final pruned = await page.accessibilitySnapshot();
          expect(pruned.root.children.single.role, equals('button'),
              reason: 'por padrao o div e o span nao viram nos');

          // The three generics are <body> - the element the snapshot is
          // rooted at, and itself a generic - plus the div and the span.
          final full = await page.accessibilitySnapshot(interestingOnly: false);
          expect(full.allNodes.map((node) => node.role).toList(),
              equals(['fragment', 'generic', 'generic', 'generic', 'button']));
        });
      });
    }

    // ----------------------------------------------------------- paridade

    group('paridade entre os tres motores', () {
      late Map<String, Browser> browsers;

      setUpAll(() async {
        browsers = {
          for (final name in ['chromium', 'firefox', 'webkit'])
            name: await launch(name),
        };
      });

      tearDownAll(() async {
        for (final browser in browsers.values) {
          await browser.close();
        }
      });

      /// The aria snapshot of [html] on each engine, keyed by engine name.
      Future<Map<String, String>> snapshotEverywhere(String html) async {
        final result = <String, String>{};
        for (final entry in browsers.entries) {
          final context = await entry.value.newContext();
          try {
            final page = await context.newPage();
            await page.setContent(html);
            result[entry.key] = await page.ariaSnapshot();
          } finally {
            await context.close();
          }
        }
        return result;
      }

      test('a mesma pagina da a mesma arvore nos tres motores', () async {
        final snapshots = await snapshotEverywhere(kFixture);
        expect(snapshots['firefox'], equals(snapshots['chromium']),
            reason: 'firefox divergiu do chromium');
        expect(snapshots['webkit'], equals(snapshots['chromium']),
            reason: 'webkit divergiu do chromium');
        expect(snapshots['chromium'], equals(kExpectedYaml));
      });

      test('widgets nativos dao os mesmos papeis, nomes e estados nos tres',
          () async {
        // Everything here is computed from the DOM by the injected script, so
        // even the labels the browsers themselves would render differently -
        // "Choose File" on a file input - come out the same, because they come
        // from upstream's roleUtils and not from the browser.
        final snapshots = await snapshotEverywhere('''
          <input value='hello world'>
          <input type=file>
          <input type=checkbox checked>
          <input type=radio checked>
          <input type=range>
          <input type=number value="3">
          <progress></progress>
          <select><option>a</option><option selected>b</option></select>
          <textarea placeholder="ph"></textarea>
          <button aria-pressed="mixed">P</button>
          <table><caption>Cap</caption><tr><th>H</th><td>D</td></tr></table>
        ''');
        expect(snapshots['firefox'], equals(snapshots['chromium']));
        expect(snapshots['webkit'], equals(snapshots['chromium']));
        expect(snapshots['chromium'], contains('- button "Choose File"'));
        expect(snapshots['chromium'], contains('- checkbox [checked]'));
        expect(snapshots['chromium'], contains('- button "P" [pressed=mixed]'));
        expect(snapshots['chromium'], contains('- rowheader "H"'));
      });

      // ------------------------------------------------------ divergencias

      test(
          'DIVERGENCIA: o valor default de <input type=color> depende da '
          'plataforma, nao do motor', () async {
        // Not an accessibility difference: the tree asks the DOM for
        // `input.value`. Chromium and Firefox start that at "#000000"
        // everywhere.
        //
        // O WebKit nao: ele devolve valor vazio no Windows e "#000000" no
        // Linux e no macOS. Isto aqui ja afirmou que o vazio era "o
        // comportamento do WebKit", o que passava na maquina em que foi
        // escrito e quebrava o CI nos outros dois sistemas. Nao e o motor que
        // diverge, e o port: o `<input type=color>` do WebKit depende do
        // widget nativo, e a build de Windows nao traz o mesmo seletor de cor
        // que as builds de GTK e de macOS.
        //
        // Por isso a asserçao e por plataforma em vez de "aceita os dois":
        // aceitar qualquer um dos dois nao afirmaria mais nada, e esta
        // divergencia existe justamente para ficar registrada.
        final snapshots = await snapshotEverywhere('<input type=color>');
        expect(snapshots['chromium'], equals('- textbox: "#000000"'));
        expect(snapshots['firefox'], equals(snapshots['chromium']),
            reason: 'o Firefox acompanha o Chromium aqui');
        expect(snapshots['webkit'],
            equals(Platform.isWindows ? '- textbox' : '- textbox: "#000000"'),
            reason: Platform.isWindows
                ? 'a build de Windows do WebKit devolve value vazio para '
                    'type=color'
                : 'fora do Windows a build do WebKit acompanha o Chromium');
      });
    });
  });
}

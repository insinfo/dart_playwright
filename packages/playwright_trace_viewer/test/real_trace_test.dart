@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:playwright/playwright.dart';
import 'package:playwright_trace_viewer/io.dart';
import 'package:test/test.dart';

/// A prova de que o modelo le o que o gravador deste porte escreve.
///
/// Todo o resto da suite roda sobre fixtures; este teste grava um trace de
/// verdade com `context.tracing`, no Chromium, e o abre com o
/// `TraceLoader`/`TraceModel`. Se o contrato entre os dois lados quebrar, e
/// aqui que aparece.
void main() {
  group('Trace real gravado por este porte', () {
    late HttpServer server;
    late String base;
    late Playwright playwright;
    late Browser browser;
    late Directory outputDir;
    late TraceModel model;
    late TraceLoader loader;

    setUpAll(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://127.0.0.1:${server.port}';
      server.listen((request) async {
        final path = request.uri.path;
        if (path == '/api/items') {
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({
              'items': ['alpha', 'beta']
            }));
          await request.response.close();
          return;
        }
        if (path == '/style.css') {
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType('text', 'css')
            ..write('body { font-family: sans-serif; background: #fafafa; }');
          await request.response.close();
          return;
        }
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.html
          ..write('''
<!doctype html>
<html><head><title>Trace probe</title>
<link rel="stylesheet" href="/style.css"></head>
<body>
  <h1>Trace probe</h1>
  <button id="load">Load items</button>
  <ul id="items"></ul>
  <script>
    console.log('page booted');
    document.getElementById('load').addEventListener('click', async () => {
      const res = await fetch('/api/items');
      const data = await res.json();
      document.getElementById('items').innerHTML =
          data.items.map(i => '<li>' + i + '</li>').join('');
    });
  </script>
</body></html>
''');
        await request.response.close();
      });

      outputDir = Directory.systemTemp.createTempSync('pw-dart-trace-model-');
      playwright = await Playwright.create();
      browser = await playwright.chromium.launch(headless: true);
      final context =
          await browser.newContext(viewport: (width: 900, height: 600));
      await context.tracing.start(
        title: 'Sonda do modelo',
        screenshots: true,
        snapshots: true,
        sources: true,
      );

      final page = await context.newPage();
      await page.goto('$base/');
      await page.locator('#load').click();
      await page.locator('li').first.waitFor();
      await page.locator('#items').innerText();
      await page.title();

      final path = '${outputDir.path}/trace.zip';
      await context.tracing.stop(path: path);
      await context.close();

      loader = await loadTraceFile(path);
      model = TraceModel(path, loader.contextEntries);
    });

    tearDownAll(() async {
      await browser.close();
      await server.close(force: true);
      if (outputDir.existsSync()) outputDir.deleteSync(recursive: true);
    });

    test('Deve trazer o contexto com o navegador e o viewport gravados', () {
      expect(model.browserName, 'chromium');
      expect(model.title, 'Sonda do modelo');
      expect(model.options.viewport?.width, 900);
      expect(model.options.viewport?.height, 600);
      expect(model.playwrightVersion, isNotNull);
      // O gravador deste porte nao declara sdkLanguage; o formatador cai no
      // 'javascript' do upstream, e o titulo sai igual.
      expect(model.sdkLanguage, isNull);
      expect(model.startTime, lessThan(model.endTime));
      expect(model.hasStepData, isFalse);
    });

    test('Deve listar as acoes com os titulos que a UI mostra', () {
      final titles = model.renderActionTree(ActionGroup.values);
      expect(titles.join('\n'), contains('Navigate'));
      expect(titles.join('\n'), contains('Click'));
      expect(model.actions, isNotEmpty);
      for (final action in model.actions) {
        expect(action.callId, isNotEmpty);
        expect(action.className, isNotEmpty);
        expect(action.method, isNotEmpty);
        expect(action.endTime, greaterThanOrEqualTo(action.startTime));
      }
      expect(model.actions.any((a) => a.method == 'goto'), isTrue);
      expect(model.actions.any((a) => a.method == 'click'), isTrue);
      expect(model.failedAction(), isNull);
    });

    test('Deve trazer a rede, com o corpo de cada resposta no arquivo',
        () async {
      final urls = model.resources.map((r) => r.request.url).toList();
      expect(urls.any((u) => u.endsWith('/style.css')), isTrue);
      expect(urls.any((u) => u.endsWith('/api/items')), isTrue);

      final css = model.resources
          .firstWhere((r) => r.request.url.endsWith('/style.css'));
      final body = await loader.resourceEntry(css.response.content.file!);
      expect(utf8.decode(body!.bytes), contains('font-family'));
    });

    test('Deve trazer a mensagem de console da pagina', () {
      final console =
          model.events.whereType<ConsoleMessageTraceEvent>().toList();
      expect(console.map((c) => c.text), contains('page booted'));
    });

    test('Deve trazer a fonte Dart da acao e o arquivo dentro do zip',
        () async {
      expect(model.hasSource, isTrue);
      expect(model.sources, isNotEmpty);
      final file = model.sources.keys
          .firstWhere((f) => f.endsWith('real_trace_test.dart'));
      expect(file, isNotEmpty);
      // O arquivo em si viaja no zip, sob src/<sha1>.dart.
      final names = await ZipTraceLoaderBackend(
              File('${outputDir.path}/trace.zip').readAsBytesSync())
          .entryNames();
      expect(names.where((n) => n.startsWith('src/')), isNotEmpty);
    });

    test('Deve ter a tira de filme e os snapshots de DOM', () {
      expect(model.pages, isNotEmpty);
      expect(model.pages.first.screencastFrames, isNotEmpty);
      expect(model.hasDomSnapshots, isTrue);
      final click = model.actions.firstWhere((a) => a.method == 'click');
      expect(model.hasDomSnapshotForCall(click.callId, ActionPhase.before),
          isTrue);
      expect(
          model.hasDomSnapshotForCall(click.callId, ActionPhase.after), isTrue);
    });

    test('Deve redesenhar a pagina do snapshot, com alvo e recurso', () async {
      final click = model.actions.firstWhere((a) => a.method == 'click');
      final server = SnapshotServer(
        loader.storage(),
        (file) async => (await loader.resourceEntry(file))?.bytes,
      );

      const snapshotUrl = 'http://viewer/snapshot/click';
      final response =
          server.serveSnapshot(click.callId, {'phase': 'before'}, snapshotUrl);
      expect(response.status, 200);
      final html = response.bodyAsString;
      expect(html, contains('Trace probe'));
      expect(html, contains('Load items'));
      // O elemento alvo da acao vem marcado para o destaque.
      expect(html, contains('__playwright_target__'));
      // O bootstrap do snapshot esta la, sob o nonce.
      expect(html, contains('applyPlaywrightAttributes'));

      // A folha de estilo que a pagina redesenhada vai pedir sai do trace.
      final css =
          await server.serveResource(['$base/style.css'], 'GET', snapshotUrl);
      expect(css.status, 200);
      expect(utf8.decode(css.body!), contains('font-family'));
      expect(css.headers['content-type'], startsWith('text/css'));

      // E o quadro de filme mais proximo, que pinta os canvas.
      final screenshot = await server
          .serveClosestScreenshot(click.callId, {'phase': 'before'});
      expect(screenshot.status, 200);
      expect(screenshot.body, isNotEmpty);
    });

    test('Deve capturar a pagina ja com os itens que o clique carregou', () {
      // O clique dispara um fetch; qual das capturas posteriores pega a lista
      // ja desenhada depende do relogio, entao a asercao e sobre o conjunto:
      // em algum ponto do trace a lista esta la, e o modelo a devolve.
      final storage = loader.storage();
      final rendered = <String>[];
      for (final action in model.actions) {
        for (final phase in ActionPhase.values) {
          final renderer = storage.snapshotForCall(action.callId, phase);
          if (renderer != null) rendered.add(renderer.render().html);
        }
      }
      expect(rendered, isNotEmpty);
      expect(rendered.any((html) => html.contains('alpha')), isTrue);
      expect(rendered.any((html) => html.contains('beta')), isTrue);
      // E a primeira captura, antes do clique, ainda nao a tem.
      expect(rendered.first, isNot(contains('alpha')));
    });
  });
}

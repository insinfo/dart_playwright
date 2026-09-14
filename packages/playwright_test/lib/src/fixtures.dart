import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:playwright/playwright.dart';
import 'package:test/test.dart';

import 'source_maps.dart';
import 'web_server.dart';

/// What a Playwright test body receives.
///
/// The page is fresh for every test, in a context of its own, so nothing
/// leaks between tests: no cookies, no storage, no leftover tabs.
class PlaywrightFixtures {
  /// Which engine this run is using: `chromium`, `firefox` or `webkit`.
  final String browserName;

  /// The browser, shared by every test in this file for this engine.
  final Browser browser;

  /// A context created for this test alone.
  final BrowserContext context;

  /// A page created for this test alone.
  final Page page;

  /// O servidor que [playwrightGroup] subiu para este grupo, se houver.
  ///
  /// Nulo quando o grupo nao pediu nenhum -- o caso de uma suite que testa um
  /// site que ja esta no ar.
  final PlaywrightWebServer? webServer;

  PlaywrightFixtures({
    required this.browserName,
    required this.browser,
    required this.context,
    required this.page,
    this.webServer,
  });
}

/// Options for [playwrightTest] and [playwrightGroup].
class PlaywrightTestOptions {
  /// Engines to run the body on. Defaults to Chromium only, because running
  /// three browsers per test is a choice, not a default.
  final List<String> browsers;

  final bool headless;
  final ({int width, int height})? viewport;
  final String? locale;
  final String? timezoneId;
  final String? colorScheme;
  final bool hasTouch;
  final String? baseURL;

  /// Where a failure screenshot is written. Null turns the capture off.
  final String? artifactsPath;

  /// Reescreve, na mensagem de falha, os stack traces que vierem do navegador
  /// em JavaScript compilado pelo dart2js.
  ///
  /// Ligado por padrao: `main.dart.js:4821:3` nao diz nada a ninguem, e o
  /// source map que o compilador emite ao lado do bundle transforma isso em
  /// `main.dart 11:3`. Desligue se o app sob teste nao for Dart.
  final bool translateDartStackTraces;

  const PlaywrightTestOptions({
    this.browsers = const ['chromium'],
    this.headless = true,
    this.viewport,
    this.locale,
    this.timezoneId,
    this.colorScheme,
    this.hasTouch = false,
    this.baseURL,
    this.artifactsPath = 'test-results',
    this.translateDartStackTraces = true,
  });
}

/// One browser per (file, engine), launched on first use and closed by the
/// test runner's tearDownAll.
class _BrowserPool {
  static final Map<String, Future<Browser>> _browsers = {};
  static Playwright? _playwright;

  static Future<Browser> get(String name, {required bool headless}) {
    final key = '$name:$headless';
    return _browsers.putIfAbsent(key, () async {
      final playwright = _playwright ??= await Playwright.create();
      final type = switch (name) {
        'firefox' => playwright.firefox,
        'webkit' => playwright.webkit,
        'chromium' => playwright.chromium,
        _ => throw ArgumentError.value(
            name, 'browser', 'Expected chromium, firefox or webkit'),
      };
      return type.launch(headless: headless);
    });
  }

  static Future<void> closeAll() async {
    final pending = _browsers.values.toList();
    _browsers.clear();
    for (final browser in pending) {
      await (await browser).close();
    }
  }
}

/// Registers a test that runs once per browser in [options].
///
/// ```dart
/// void main() {
///   playwrightTest('the heading is there', (t) async {
///     await t.page.goto('https://example.com');
///     await expectLocator(t.page.getByRole('heading')).toBeVisible();
///   }, options: const PlaywrightTestOptions(
///        browsers: ['chromium', 'firefox', 'webkit']));
/// }
/// ```
///
/// The browser is shared across the tests in the file; the context and the
/// page are not. When a test fails and `artifactsPath` is set, a screenshot
/// is written next to the failure and its path is added to the error, which
/// is usually the fastest way to see what the page actually looked like.
void playwrightTest(
  String description,
  Future<void> Function(PlaywrightFixtures fixtures) body, {
  PlaywrightTestOptions options = const PlaywrightTestOptions(),
  Timeout? timeout,
  Object? skip,
  Object? tags,
}) {
  for (final browserName in options.browsers) {
    test(
      options.browsers.length == 1
          ? description
          : '$description [$browserName]',
      () => _runOne(description, browserName, options, body),
      timeout: timeout ?? const Timeout(Duration(minutes: 2)),
      skip: skip,
      tags: tags,
    );
  }
}

/// Groups Playwright tests and closes every browser they launched.
///
/// Call this once per test file, around the `playwrightTest` calls, or the
/// browsers stay open until the process exits.
///
/// [webServer], quando dado, sobe o servidor no `setUpAll` do grupo, entrega-o
/// aos testes em `PlaywrightFixtures.webServer` e o derruba no fim. E opcional
/// porque nem toda suite serve a propria aplicacao; quem prefere controlar o
/// ciclo de vida a mao chama [PlaywrightWebServer.start] no seu proprio
/// `setUpAll`.
///
/// ```dart
/// playwrightGroup(
///   'meu app',
///   webServer: () => PlaywrightWebServer.start(
///     command: 'webdev serve web:8080',
///     url: 'http://127.0.0.1:8080/',
///   ),
///   () {
///     playwrightTest('abre', (t) async {
///       await t.page.goto(t.webServer!.baseURL);
///     });
///   },
/// );
/// ```
void playwrightGroup(
  String description,
  void Function() body, {
  Future<PlaywrightWebServer> Function()? webServer,
}) {
  group(description, () {
    if (webServer != null) {
      setUpAll(() async => _grupoWebServer = await webServer());
      // Registrado antes do fechamento dos navegadores e portanto executado
      // depois dele: derrubar o servidor com paginas ainda abertas encheria o
      // log de erros de rede que nao sao a falha de ninguem.
      tearDownAll(() async {
        final servidor = _grupoWebServer;
        _grupoWebServer = null;
        await servidor?.stop();
      });
    }
    tearDownAll(_BrowserPool.closeAll);
    body();
  });
}

/// O servidor do grupo em execucao, entre o `setUpAll` e o `tearDownAll`.
///
/// Estado de escopo, como o proprio `package:test` faz com os seus ganchos: um
/// grupo de cada vez roda, porque `dart test` executa um arquivo por isolate e
/// os grupos de um arquivo em sequencia.
PlaywrightWebServer? _grupoWebServer;

Future<void> _runOne(
  String description,
  String browserName,
  PlaywrightTestOptions options,
  Future<void> Function(PlaywrightFixtures) body,
) async {
  final browser =
      await _BrowserPool.get(browserName, headless: options.headless);
  final context = await browser.newContext(
    viewport: options.viewport,
    locale: options.locale,
    timezoneId: options.timezoneId,
    colorScheme: options.colorScheme,
    hasTouch: options.hasTouch,
  );
  final page = await context.newPage();
  // Coletados durante o teste porque depois da falha a pagina ja foi fechada.
  final errosDaPagina = <PageError>[];
  final assinatura = options.translateDartStackTraces
      ? page.onPageError.listen(errosDaPagina.add)
      : null;
  final fixtures = PlaywrightFixtures(
    browserName: browserName,
    browser: browser,
    context: context,
    page: page,
    webServer: _grupoWebServer,
  );

  try {
    await body(fixtures);
  } catch (error) {
    final detalhe = options.translateDartStackTraces
        ? await _traduzirErrosDart(error, errosDaPagina)
        : '$error';
    final shot = await _captureFailure(
        page, description, browserName, options.artifactsPath);
    if (shot == null) {
      // Sem traducao e sem screenshot nao ha o que acrescentar: preserva o
      // erro original, com o tipo e o stack que ele ja tinha.
      if (detalhe == '$error') rethrow;
      throw StateError(detalhe);
    }
    // Keep the original error first: the screenshot is a hint, not the
    // failure.
    throw StateError('$detalhe\n\nScreenshot of the failure: $shot');
  } finally {
    await assinatura?.cancel();
    await context.close();
  }
}

/// Devolve a falha com os stack traces do navegador reescritos para `.dart`.
///
/// A traducao acontece so aqui, depois que o teste ja falhou: baixar e parsear
/// um source map de megabytes durante um teste que esta passando seria pagar
/// caro por nada.
///
/// Nunca lanca. Se o source map nao existir ou nao puder ser lido, volta o
/// texto original -- trocar a falha de verdade por uma falha da traducao seria
/// a pior troca possivel.
Future<String> _traduzirErrosDart(
    Object error, List<PageError> errosDaPagina) async {
  try {
    final buffer = StringBuffer(await translateDartStackTracesIn('$error'));
    for (final erro in errosDaPagina) {
      final traduzido = await translateDartStackTrace(erro.stack);
      // O proprio stack ja comeca pela linha `Nome: mensagem` que a engine
      // reportou; repeti-la aqui so duplicaria. Sem stack, ela e tudo o que ha.
      final corpo = traduzido.translated.trim().isEmpty
          ? '${erro.name.isEmpty ? 'Error' : erro.name}: ${erro.message}'
          : traduzido.translated;
      buffer.write('\n\nErro nao capturado na pagina:\n$corpo');
      if (!traduzido.didTranslate && traduzido.note != null) {
        buffer.write('\n(stack nao traduzido: ${traduzido.note})');
      }
    }
    return buffer.toString();
  } catch (_) {
    return '$error';
  }
}

/// Writes a screenshot of the failing page, returning its path.
///
/// Returns null when capture is off or when the page is in no state to be
/// photographed — a crashed or closed page cannot be, and failing here would
/// replace the real failure with a less useful one.
Future<String?> _captureFailure(Page page, String description,
    String browserName, String? artifactsPath) async {
  if (artifactsPath == null) return null;
  try {
    final safe = description
        .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '')
        .toLowerCase();
    final file = p.join(artifactsPath, '$safe-$browserName.png');
    await Directory(p.dirname(file)).create(recursive: true);
    await page.screenshot(path: file, fullPage: true);
    return file;
  } catch (_) {
    return null;
  }
}

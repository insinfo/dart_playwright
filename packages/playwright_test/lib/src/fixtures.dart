import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:playwright/playwright.dart';
import 'package:test/test.dart';

import 'fixture.dart';
import 'soft_failures.dart';
import 'step.dart';
import 'storage_state.dart';

/// What a Playwright test body receives.
///
/// The page is fresh for every test, in a context of its own, so nothing
/// leaks between tests: no cookies, no storage, no leftover tabs.
class PlaywrightFixtures implements FixtureContext {
  /// Which engine this run is using: `chromium`, `firefox` or `webkit`.
  @override
  final String browserName;

  /// The browser, shared by every test in this file for this engine.
  @override
  final Browser browser;

  /// A context created for this test alone.
  @override
  final BrowserContext context;

  /// A page created for this test alone.
  @override
  final Page page;

  final FixtureResolver _resolver;

  PlaywrightFixtures({
    required this.browserName,
    required this.browser,
    required this.context,
    required this.page,
    FixtureResolver? resolver,
  }) : _resolver = resolver ??
            FixtureResolver.test(
              worker: FixtureResolver.worker(
                  browserName: browserName, browser: browser),
              context: context,
              page: page,
            );

  /// O valor de [fixture], criando-a na primeira vez que este teste a pede.
  ///
  /// ```dart
  /// final page = await t.use(loggedInPage);
  /// ```
  ///
  /// Uma fixture de escopo [FixtureScope.test] e criada e desfeita dentro
  /// deste teste; uma de [FixtureScope.worker] e compartilhada pelo arquivo
  /// inteiro, por motor, e so e desfeita quando o `playwrightGroup` acaba.
  ///
  /// O tipo do retorno vem de [fixture]: nao ha `dynamic` nem `as` no corpo do
  /// teste, que e o ponto onde uma traducao literal do `test.extend()` do JS
  /// daria errado em Dart.
  @override
  Future<T> use<T>(Fixture<T> fixture) => _resolver.use(fixture);

  /// Registra uma limpeza que roda no fim deste teste, mesmo que ele falhe.
  @override
  void onTeardown(Future<void> Function() callback) =>
      _resolver.onTeardown(callback);
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

  /// Fixtures automaticas e trocas de opcao que valem para estes testes.
  ///
  /// Uma fixture comum nao precisa aparecer aqui: `t.use(f)` ja traz tudo de
  /// que ela depende. Esta lista e para o que o teste nao pede pelo nome —
  /// `minhaFixture.asAuto` e `minhaOpcao.overrideWith(valor)`.
  final List<FixtureRegistration> fixtures;

  /// Um login gravado em disco e reaproveitado pelos testes.
  ///
  /// O estado e produzido uma vez por arquivo e motor, e aplicado ao contexto
  /// de cada teste antes de a pagina abrir. Ver [StorageState].
  final StorageState? storageState;

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
    this.fixtures = const [],
    this.storageState,
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
void playwrightGroup(String description, void Function() body) {
  group(description, () {
    // Ordem importa: `tearDownAll` roda na ordem inversa do registro, e as
    // fixtures de worker podem guardar contextos deste navegador — desfaze-las
    // depois de fecha-lo daria um erro em cima de cada uma.
    tearDownAll(_BrowserPool.closeAll);
    tearDownAll(WorkerFixtureScopes.tearDownAll);
    body();
  });
}

Future<void> _runOne(
  String description,
  String browserName,
  PlaywrightTestOptions options,
  Future<void> Function(PlaywrightFixtures) body,
) async {
  final browser =
      await _BrowserPool.get(browserName, headless: options.headless);
  final worker = WorkerFixtureScopes.of(
    browserName,
    browser,
    headless: options.headless,
    registrations: options.fixtures,
  );
  await worker.ensureAutoFixtures();

  // O estado de login sai do escopo de worker, entao o login roda uma vez por
  // arquivo e motor. Resolve-se antes do contexto porque e ele que diz o que o
  // contexto ja nasce sabendo.
  final storageState = options.storageState;
  final state =
      storageState == null ? null : await worker.use(storageState.fixture);

  final context = await browser.newContext(
    viewport: options.viewport,
    locale: options.locale,
    timezoneId: options.timezoneId,
    colorScheme: options.colorScheme,
    hasTouch: options.hasTouch,
  );
  if (state != null) await applyStorageState(context, state);
  final page = await context.newPage();
  final resolver = FixtureResolver.test(
    worker: worker,
    context: context,
    page: page,
    registrations: options.fixtures,
  );
  final fixtures = PlaywrightFixtures(
    browserName: browserName,
    browser: browser,
    context: context,
    page: page,
    resolver: resolver,
  );

  try {
    await resolver.ensureAutoFixtures();
    await runWithCurrentPage(page, () => body(fixtures));
    // Uma falha soft nao interrompe o corpo, entao o screenshot dela tem de
    // ser tirado aqui, com a pagina ainda aberta.
    if (hasPendingSoftFailures) {
      final soft = await _captureFailure(
          page, description, browserName, options.artifactsPath);
      if (soft != null) noteSoftFailureArtifact(soft);
    }
  } catch (error) {
    final shot = await _captureFailure(
        page, description, browserName, options.artifactsPath);
    if (shot == null) rethrow;
    // Keep the original error first: the screenshot is a hint, not the
    // failure.
    throw StateError('$error\n\nScreenshot of the failure: $shot');
  } finally {
    // As fixtures do teste saem antes do contexto: uma delas pode guardar uma
    // pagina, e fechar o contexto primeiro faria o teardown falhar em cima de
    // um recurso ja morto.
    try {
      await resolver.tearDown();
    } finally {
      await context.close();
    }
  }
}

/// Writes a screenshot of the failing page, returning its path.
///
/// Returns null when capture is off or when the page is in no state to be
/// photographed — a crashed or closed page cannot be, and failing here would
/// replace the real failure with a less useful one.
Future<String?> _captureFailure(
    Page page, String description, String browserName, String? artifactsPath) async {
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

import 'dart:async';

import 'package:playwright/playwright.dart';

/// Quanto tempo uma fixture vive.
enum FixtureScope {
  /// Criada para cada teste e desfeita quando ele termina, mesmo que falhe.
  test,

  /// Criada uma vez por arquivo e motor, e desfeita quando o
  /// `playwrightGroup` acaba. E o equivalente do "worker" do upstream: aqui
  /// nao ha processo worker proprio, entao o que corresponde a ele e o par
  /// (arquivo, navegador) que ja compartilha o mesmo `Browser`.
  worker,
}

/// O que o `setUp` de uma fixture recebe.
///
/// Traz as fixtures embutidas e o [use] com que uma fixture chama outra, que e
/// como a composicao acontece: quem escreve `loggedInPage` pede `page` aqui e
/// nao precisa saber quem criou a pagina.
abstract class FixtureContext {
  /// Qual motor esta rodando: `chromium`, `firefox` ou `webkit`.
  String get browserName;

  /// O navegador, compartilhado pelo arquivo inteiro.
  Browser get browser;

  /// O contexto deste teste. Uma fixture de escopo [FixtureScope.worker] nao
  /// tem um: pedir aqui e um erro, com a explicacao junto.
  BrowserContext get context;

  /// A pagina deste teste. Mesma regra de [context].
  Page get page;

  /// O valor de [fixture], criando-a se este escopo ainda nao a criou.
  ///
  /// O tipo sai daqui ja certo: `use(loggedInPage)` devolve `Future<Page>`
  /// porque [Fixture] carrega o tipo. Nao ha cast no caminho de quem escreve o
  /// teste.
  Future<T> use<T>(Fixture<T> fixture);

  /// Registra uma limpeza extra deste escopo.
  ///
  /// Roda na ordem inversa do registro, junto com os teardowns das fixtures.
  void onTeardown(Future<void> Function() callback);
}

/// Cria o valor de uma fixture.
typedef FixtureSetUp<T> = Future<T> Function(FixtureContext use);

/// Desfaz o valor de uma fixture.
typedef FixtureTearDown<T> = Future<void> Function(T value);

/// Uma fixture: um valor com setup, teardown e escopo.
///
/// O objeto devolvido por [defineFixture] e a *chave tipada* da fixture: e ele
/// que se passa para [FixtureContext.use], e e dele que sai o tipo do valor.
/// Isso e o que substitui o truque de objeto-de-fixtures do JS, que em Dart
/// so existiria com `dynamic` ou geracao de codigo.
class Fixture<T> {
  /// Nome usado nas mensagens de erro.
  final String name;

  final FixtureScope scope;

  final FixtureSetUp<T> _setUp;
  final FixtureTearDown<T>? _tearDown;

  Fixture._(this.name, this.scope, this._setUp, this._tearDown);

  /// Registra esta fixture como automatica: ela e criada antes do corpo do
  /// teste mesmo que ninguem a peca.
  ///
  /// Serve para fixture que existe pelo efeito e nao pelo valor — ligar um
  /// coletor de erros de console, por exemplo.
  FixtureRegistration get asAuto => FixtureRegistration._(this, auto: true);

  @override
  String toString() => 'Fixture("$name", ${scope.name})';
}

/// Uma fixture cujo valor pode ser trocado por quem usa a suite.
///
/// O upstream marca isso com `{ option: true }` e recusa em tempo de execucao
/// a troca de uma fixture comum. Aqui a regra e do tipo: so [FixtureOption]
/// tem [overrideWith], entao trocar o que nao e opcao nem compila.
class FixtureOption<T> extends Fixture<T> {
  FixtureOption._(String name, FixtureScope scope, FixtureSetUp<T> setUp)
      : super._(name, scope, setUp, null);

  /// Troca o valor desta opcao.
  FixtureRegistration overrideWith(T value) => FixtureRegistration._(this,
      setUp: (_) async => value, value: value, hasValue: true);

  /// Troca o *modo* de calcular esta opcao, para quando ela depende de outra.
  FixtureRegistration overrideWithSetUp(FixtureSetUp<T> setUp) =>
      FixtureRegistration._(this, setUp: setUp);
}

/// Uma fixture declarada nas opcoes de um teste ou grupo: ou uma automatica,
/// ou a troca do valor de uma opcao.
class FixtureRegistration {
  final Fixture<Object?> fixture;
  final bool auto;
  final FixtureSetUp<Object?>? setUp;

  /// O valor literal passado a [FixtureOption.overrideWith], quando houve um.
  ///
  /// Entra na chave do escopo de worker para que dois grupos com o mesmo
  /// override compartilhem o mesmo escopo em vez de refazer o setup.
  final Object? value;

  /// Distingue `overrideWith(null)` de "nao houve valor literal".
  final bool hasValue;

  FixtureRegistration._(this.fixture,
      {this.auto = false, this.setUp, this.value, this.hasValue = false});
}

/// Declara uma fixture.
///
/// ```dart
/// final loggedInPage = defineFixture<Page>('loggedInPage', (f) async {
///   await f.page.goto('https://app.exemplo/login');
///   await f.page.fill('#user', 'ana');
///   await f.page.fill('#pass', 's3cr3t');
///   await f.page.click('#entrar');
///   return f.page;
/// });
/// ```
Fixture<T> defineFixture<T>(
  String name,
  FixtureSetUp<T> setUp, {
  FixtureTearDown<T>? tearDown,
  FixtureScope scope = FixtureScope.test,
}) =>
    Fixture._(name, scope, setUp, tearDown);

/// Declara uma opcao: uma fixture com valor padrao que a suite pode trocar.
FixtureOption<T> defineOption<T>(
  String name,
  T defaultValue, {
  FixtureScope scope = FixtureScope.worker,
}) =>
    FixtureOption._(name, scope, (_) async => defaultValue);

/// O estado de um escopo: o que ja foi criado e o que falta desfazer.
///
/// E tambem o [FixtureContext] que chega ao `setUp` de cada fixture, para que
/// uma fixture componha com outra pelo mesmo caminho que o teste usa.
class FixtureResolver implements FixtureContext {
  final FixtureScope scope;

  /// O escopo de worker, quando este e o de teste. E para la que vai um
  /// `use` de fixture de worker.
  final FixtureResolver? _worker;

  @override
  final String browserName;

  @override
  final Browser browser;

  final BrowserContext? _context;
  final Page? _page;
  final List<FixtureRegistration> _registrations;

  final Map<Fixture<Object?>, Future<Object?>> _values = {};
  final List<Future<void> Function()> _teardowns = [];
  final Set<Fixture<Object?>> _resolving = {};
  Future<void>? _autos;

  FixtureResolver.worker({
    required this.browserName,
    required this.browser,
    List<FixtureRegistration> registrations = const [],
  })  : scope = FixtureScope.worker,
        _worker = null,
        _context = null,
        _page = null,
        _registrations = registrations;

  FixtureResolver.test({
    required FixtureResolver worker,
    required BrowserContext context,
    required Page page,
    List<FixtureRegistration> registrations = const [],
  })  : scope = FixtureScope.test,
        _worker = worker,
        browserName = worker.browserName,
        browser = worker.browser,
        _context = context,
        _page = page,
        _registrations = registrations;

  @override
  BrowserContext get context =>
      _context ??
      (throw StateError('Uma fixture de escopo worker nao tem BrowserContext: '
          'o contexto nasce e morre com um teste, e a fixture de worker vive '
          'mais que ele. Use scope: FixtureScope.test.'));

  @override
  Page get page =>
      _page ??
      (throw StateError('Uma fixture de escopo worker nao tem Page: a pagina '
          'nasce e morre com um teste, e a fixture de worker vive mais que '
          'ele. Use scope: FixtureScope.test.'));

  @override
  void onTeardown(Future<void> Function() callback) => _teardowns.add(callback);

  @override
  Future<T> use<T>(Fixture<T> fixture) {
    if (fixture.scope == FixtureScope.worker && scope == FixtureScope.test) {
      return _worker!.use(fixture);
    }
    if (fixture.scope == FixtureScope.test && scope == FixtureScope.worker) {
      throw StateError(
          'Uma fixture de worker nao pode usar a fixture de teste '
          '"${fixture.name}": ela viveria mais que o contexto que a criou, e o '
          'valor guardado apontaria para uma pagina ja fechada.');
    }

    final pending = _values[fixture];
    // O valor fica guardado como Future, nao como valor pronto: dois `use`
    // concorrentes da mesma fixture tem de esperar o mesmo setup, nao rodar
    // dois.
    if (pending != null) return pending.then((value) => value as T);

    if (!_resolving.add(fixture)) {
      throw StateError('Ciclo entre fixtures: "${fixture.name}" depende de si '
          'mesma, direta ou indiretamente.');
    }
    final created = _create(fixture);
    _values[fixture] = created;
    return created.then((value) => value as T);
  }

  Future<Object?> _create(Fixture<Object?> fixture) async {
    try {
      final setUp = _overrideFor(fixture) ?? fixture._setUp;
      final value = await setUp(this);
      // O teardown entra depois do setup e so se ele deu certo: desfazer o que
      // nunca foi feito costuma dar um segundo erro que esconde o primeiro.
      final tearDown = fixture._tearDown;
      if (tearDown != null) _teardowns.add(() => tearDown(value));
      return value;
    } finally {
      _resolving.remove(fixture);
    }
  }

  FixtureSetUp<Object?>? _overrideFor(Fixture<Object?> fixture) {
    for (final registration in _registrations) {
      if (identical(registration.fixture, fixture) &&
          registration.setUp != null) {
        return registration.setUp;
      }
    }
    if (scope == FixtureScope.test) return _worker?._overrideFor(fixture);
    return null;
  }

  /// Cria as fixtures automaticas deste escopo, uma unica vez.
  Future<void> ensureAutoFixtures() => _autos ??= _createAutoFixtures();

  Future<void> _createAutoFixtures() async {
    for (final registration in _registrations) {
      if (!registration.auto) continue;
      if (registration.fixture.scope != scope) continue;
      await use(registration.fixture);
    }
  }

  /// Desfaz tudo que este escopo criou, na ordem inversa.
  ///
  /// Um teardown que falha nao impede os outros de rodar: o vazamento de um
  /// recurso porque o teardown anterior explodiu e pior que o erro original.
  /// O primeiro erro e o que sobe, como no upstream.
  Future<void> tearDown() async {
    Object? firstError;
    StackTrace? firstStack;
    for (final callback in _teardowns.reversed.toList()) {
      try {
        await callback();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStack ??= stackTrace;
      }
    }
    _teardowns.clear();
    _values.clear();
    _autos = null;
    if (firstError != null) Error.throwWithStackTrace(firstError, firstStack!);
  }
}

/// Os escopos de worker vivos, um por (motor, headless, conjunto de opcoes).
///
/// Fica aqui e nao dentro de `playwrightTest` porque o escopo tem de
/// atravessar os varios `playwrightTest` do arquivo — e exatamente o que
/// `_BrowserPool` ja faz com o navegador.
class WorkerFixtureScopes {
  static final Map<String, FixtureResolver> _scopes = {};

  static FixtureResolver of(
    String browserName,
    Browser browser, {
    required bool headless,
    required List<FixtureRegistration> registrations,
  }) {
    final key = '$browserName:$headless:${_digest(registrations)}';
    return _scopes.putIfAbsent(
        key,
        () => FixtureResolver.worker(
              browserName: browserName,
              browser: browser,
              registrations: registrations,
            ));
  }

  /// A chave de um escopo de worker leva o que mudaria o setup dele.
  ///
  /// So as registros que tocam fixtures de worker entram: trocar uma opcao de
  /// escopo de teste nao justifica refazer o login do arquivo inteiro. E o
  /// mesmo motivo do `digest` do upstream, que decide se um worker pode ser
  /// reaproveitado.
  static String _digest(List<FixtureRegistration> registrations) {
    final parts = <String>[];
    for (final registration in registrations) {
      if (registration.fixture.scope != FixtureScope.worker) continue;
      final override = registration.setUp == null
          ? 'auto'
          : registration.hasValue
              ? 'v=${registration.value}'
              // Um override por funcao nao tem valor para comparar, entao a
              // identidade da funcao e o que resta.
              : 'f=${identityHashCode(registration.setUp)}';
      parts.add('${registration.fixture.name}#$override');
    }
    parts.sort();
    return parts.join(',');
  }

  static Future<void> tearDownAll() async {
    final pending = _scopes.values.toList().reversed.toList();
    _scopes.clear();
    Object? firstError;
    StackTrace? firstStack;
    for (final scope in pending) {
      try {
        await scope.tearDown();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStack ??= stackTrace;
      }
    }
    if (firstError != null) Error.throwWithStackTrace(firstError, firstStack!);
  }
}

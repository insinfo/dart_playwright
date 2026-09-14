import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:playwright/playwright.dart';

import 'fixture.dart';

/// Um login feito uma vez e reaproveitado pelos testes seguintes.
///
/// O estado (cookies e localStorage) e gravado em [path] depois do primeiro
/// login e aplicado no contexto de cada teste, entao a suite paga o login uma
/// vez por arquivo e motor em vez de uma vez por teste.
///
/// ```dart
/// final auth = StorageState(
///   path: '.auth/usuario.json',
///   logIn: (page) async {
///     await page.goto('http://localhost:8080/login');
///     await page.fill('#user', 'ana');
///     await page.fill('#pass', 's3cr3t');
///     await page.click('#entrar');
///     await page.waitForURL(RegExp(r'/painel$'));
///   },
///   verify: (page) async {
///     await page.goto('http://localhost:8080/painel');
///     return page.locator('#sair').isVisible();
///   },
/// );
///
/// playwrightTest('ve o painel', (t) async {
///   await t.page.goto('http://localhost:8080/painel');
///   await expectLocator(t.page.locator('#sair')).toBeVisible();
/// }, options: PlaywrightTestOptions(storageState: auth));
/// ```
///
/// ## Estado que venceu
///
/// Um arquivo de ontem faz a suite inteira falhar com "nao logado", e a
/// mensagem nao diz o que houve. O upstream nao trata isso: o arquivo e lido,
/// os cookies vencidos sao entregues ao navegador, e o teste falha como se o
/// app estivesse quebrado. Aqui ha tres camadas, da mais barata para a mais
/// exata:
///
/// 1. **Cookie vencido no proprio arquivo.** O `storageState` guarda o
///    `expires` de cada cookie. Se algum ja passou, o estado esta morto e
///    da para saber sem abrir o navegador.
/// 2. **[maxAge].** Idade do arquivo em disco. E um chute — o servidor decide
///    a validade real, nao nos — mas e um chute que custa zero e evita a ida
///    ao navegador na maioria dos casos.
/// 3. **[verify].** A unica camada que sabe a verdade: abre um contexto
///    descartavel com o estado aplicado e pergunta ao app se ainda esta
///    logado. Quando ela reprova, o login roda de novo e o arquivo e
///    reescrito, **uma vez**. Se o estado recem-criado tambem reprova, a falha
///    e real e sobe com o motivo escrito, em vez de virar um laco de login.
///
/// Sem [verify] valem so as duas primeiras: elas cobrem o caso comum e nao
/// custam nada, mas nao substituem a pergunta ao app.
class StorageState {
  /// Onde o estado e gravado. Diretorios sao criados se faltarem.
  final String path;

  /// Faz o login numa pagina limpa. O que ficar em cookies e localStorage
  /// depois disso e o que sera reaproveitado.
  final Future<void> Function(Page page) logIn;

  /// Responde se o estado aplicado ainda vale.
  ///
  /// Recebe uma pagina de um contexto descartavel que ja tem o estado. Deve
  /// navegar para algo que exija sessao e devolver se continua logado.
  final Future<bool> Function(Page page)? verify;

  /// Idade maxima do arquivo em disco antes de ser ignorado.
  final Duration maxAge;

  /// A fixture de escopo de worker que produz o estado.
  ///
  /// Fica exposta para quem quiser ler o estado dentro de um teste
  /// (`await t.use(auth.fixture)`); `PlaywrightTestOptions.storageState`
  /// resolve-a sozinho antes de criar o contexto.
  late final Fixture<Map<String, dynamic>> fixture = defineFixture(
    'storageState($path)',
    (f) => _obtain(f.browser),
    scope: FixtureScope.worker,
  );

  StorageState({
    required this.path,
    required this.logIn,
    this.verify,
    this.maxAge = const Duration(hours: 8),
  });

  Future<Map<String, dynamic>> _obtain(Browser browser) async {
    final stored = _read();
    if (stored != null) {
      final reason = _staleReason(stored);
      if (reason == null) {
        if (verify == null) return stored.state;
        if (await _passesVerification(browser, stored.state)) {
          return stored.state;
        }
      }
    }

    final fresh = await _logInAndSave(browser);
    if (verify != null && !await _passesVerification(browser, fresh)) {
      throw StateError(
          'O login gravado em "$path" foi refeito agora e mesmo assim verify() '
          'disse que a sessao nao vale. Isso nao e estado vencido: ou logIn() '
          'nao esta logando, ou verify() esta olhando para a coisa errada. '
          'Nenhum teste roda com um estado que ja se sabe invalido.');
    }
    return fresh;
  }

  /// Por que o arquivo lido nao serve, ou null quando serve.
  String? _staleReason(_Stored stored) {
    final now = DateTime.now();
    final age = now.difference(stored.modified);
    if (age > maxAge) {
      return 'o arquivo tem ${age.inMinutes} min e maxAge e '
          '${maxAge.inMinutes} min';
    }
    final cookies = stored.state['cookies'];
    if (cookies is List) {
      final nowSeconds = now.millisecondsSinceEpoch / 1000;
      for (final cookie in cookies) {
        if (cookie is! Map) continue;
        final expires = cookie['expires'];
        // -1 (ou ausente) e cookie de sessao: nao tem data para vencer.
        if (expires is num && expires > 0 && expires < nowSeconds) {
          return 'o cookie "${cookie['name']}" venceu';
        }
      }
    }
    return null;
  }

  Future<bool> _passesVerification(
      Browser browser, Map<String, dynamic> state) async {
    final check = verify;
    if (check == null) return true;
    final context = await browser.newContext();
    try {
      await applyStorageState(context, state);
      final page = await context.newPage();
      return await check(page);
    } catch (_) {
      // Uma verificacao que explode e uma verificacao que nao passou: o
      // caminho de recuperacao e o mesmo, e deixar o erro subir aqui trocaria
      // "sessao vencida" por um stack trace no meio do setup.
      return false;
    } finally {
      await context.close();
    }
  }

  Future<Map<String, dynamic>> _logInAndSave(Browser browser) async {
    final context = await browser.newContext();
    try {
      final page = await context.newPage();
      await logIn(page);
      final state = await context.storageState();
      final file = File(path);
      await file.parent.create(recursive: true);
      await file
          .writeAsString(const JsonEncoder.withIndent('  ').convert(state));
      return state;
    } finally {
      await context.close();
    }
  }

  _Stored? _read() {
    final file = File(path);
    if (!file.existsSync()) return null;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map<String, dynamic>) return null;
      return _Stored(decoded, file.lastModifiedSync());
    } catch (_) {
      // Arquivo truncado por uma execucao interrompida: tratar como ausente e
      // logar de novo e melhor que quebrar a suite com um erro de JSON.
      return null;
    }
  }
}

class _Stored {
  final Map<String, dynamic> state;
  final DateTime modified;

  _Stored(this.state, this.modified);
}

/// Aplica um `storageState` a um contexto recem-criado.
///
/// Os cookies entram direto. O localStorage precisa de uma pagina na origem
/// certa, e por isso uma pagina descartavel navega para cada origem com as
/// requisicoes interceptadas — a mesma coisa que o upstream faz do lado do
/// servidor. Sem origens (o caso comum, sessao so por cookie) nada disso
/// acontece e o custo e uma chamada.
///
/// A alternativa seria um `addInitScript` que reescreve o localStorage a cada
/// documento; ela custa menos, mas ressuscita chaves que o proprio app apagou,
/// e um logout que nao desloga e pior que uma navegacao a mais.
Future<void> applyStorageState(
    BrowserContext context, Map<String, dynamic> state) async {
  final cookies = state['cookies'];
  if (cookies is List && cookies.isNotEmpty) {
    await context.addCookies([
      for (final cookie in cookies)
        if (cookie is Map) Map<String, dynamic>.from(cookie),
    ]);
  }

  final origins = state['origins'];
  if (origins is! List || origins.isEmpty) return;

  final page = await context.newPage();
  try {
    await page.route('**/*', (route) {
      route.fulfill(body: '<html></html>', contentType: 'text/html');
    });
    for (final origin in origins) {
      if (origin is! Map) continue;
      final url = origin['origin'];
      final items = origin['localStorage'];
      if (url is! String || items is! List) continue;
      await page.goto(url);
      await page.evaluate('''
        () => {
          const items = ${jsonEncode(items)};
          for (const item of items)
            window.localStorage.setItem(item.name, item.value);
        }
      ''');
    }
  } finally {
    await page.close();
  }
}

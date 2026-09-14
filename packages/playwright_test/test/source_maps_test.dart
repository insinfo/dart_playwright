import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:playwright_test/playwright_test.dart';

import 'web_app_fixture.dart';

/// Um source map minusculo e deterministico: a linha 3 coluna 1 de `app.js`
/// veio da linha 7 coluna 3 de `app.dart`.
///
/// Feito a mao de proposito. Um source map de verdade (o do app compilado) e o
/// que o teste de navegador usa; aqui o que se quer e poder afirmar numeros
/// exatos sem depender do compilador.
const _mapaSintetico = '{"version":3,"file":"app.js","sourceRoot":"",'
    '"sources":["app.dart"],"names":[],"mappings":";;AAME"}';

void main() {
  group('traducao sem navegador', () {
    late _ServidorDeArquivos servidor;

    setUp(() async {
      servidor = await _ServidorDeArquivos.iniciar();
    });

    tearDown(() async => servidor.parar());

    test('reescreve o quadro para o arquivo e a linha do Dart', () async {
      servidor.arquivos['/app.js'] = 'linha1\nlinha2\nlinha3\n';
      servidor.arquivos['/app.js.map'] = _mapaSintetico;
      final resolver = DartSourceMapResolver();
      addTearDown(resolver.close);

      final resultado = await resolver.translate('Error: boom\n'
          '    at explode (${servidor.url}/app.js:3:1)');

      expect(resultado.didTranslate, isTrue);
      expect(resultado.translated, contains('app.dart 7:3'));
      expect(resultado.translated, contains('Error: boom'));
      expect(resultado.translated, isNot(contains('app.js:3:1')));
    });

    test('degrada para o trace original quando nao ha source map', () async {
      servidor.arquivos['/app.js'] = 'sem comentario de source map\n';
      final resolver = DartSourceMapResolver();
      addTearDown(resolver.close);

      final original = 'Error: boom\n'
          '    at explode (${servidor.url}/app.js:3:1)';
      final resultado = await resolver.translate(original);

      expect(resultado.didTranslate, isFalse);
      expect(resultado.translated, equals(original));
      expect(resultado.note, contains('sem source map'));
    });

    test(
        'acha o map pelo comentario sourceMappingURL quando o vizinho '
        'nao existe', () async {
      servidor.arquivos['/bundle.js'] =
          'codigo\n//# sourceMappingURL=outro-nome.map\n';
      servidor.arquivos['/outro-nome.map'] = _mapaSintetico;
      final resolver = DartSourceMapResolver();
      addTearDown(resolver.close);

      final resultado = await resolver.translate('Error: boom\n'
          '    at explode (${servidor.url}/bundle.js:3:1)');

      expect(resultado.didTranslate, isTrue);
      expect(resultado.translated, contains('app.dart 7:3'));
    });

    test('baixa o source map uma vez por URL', () async {
      servidor.arquivos['/app.js'] = 'x\n';
      servidor.arquivos['/app.js.map'] = _mapaSintetico;
      final resolver = DartSourceMapResolver();
      addTearDown(resolver.close);

      final trace = 'Error: boom\n'
          '    at explode (${servidor.url}/app.js:3:1)';
      for (var i = 0; i < 5; i++) {
        expect((await resolver.translate(trace)).didTranslate, isTrue);
      }

      expect(servidor.contagem['/app.js.map'], equals(1),
          reason: 'num app real esse arquivo tem megabytes');
    });

    test('lembra tambem a ausencia do map, para nao sondar a cada erro',
        () async {
      servidor.arquivos['/app.js'] = 'nada aqui\n';
      final resolver = DartSourceMapResolver();
      addTearDown(resolver.close);

      final trace = 'Error: boom\n'
          '    at explode (${servidor.url}/app.js:3:1)';
      for (var i = 0; i < 4; i++) {
        await resolver.translate(trace);
      }

      expect(servidor.contagem['/app.js.map'] ?? 0, lessThanOrEqualTo(1));
      expect(servidor.contagem['/app.js'] ?? 0, lessThanOrEqualTo(2));
    });

    test('nao aplica o map de um script no quadro de outro', () async {
      servidor.arquivos['/app.js'] = 'x\n';
      servidor.arquivos['/app.js.map'] = _mapaSintetico;
      // Sem map proprio, e sem nada a ver com app.dart.
      servidor.arquivos['/vendor.js'] = 'y\n';
      final resolver = DartSourceMapResolver();
      addTearDown(resolver.close);

      final resultado = await resolver.translate('Error: boom\n'
          '    at explode (${servidor.url}/app.js:3:1)\n'
          '    at vendorCoisa (${servidor.url}/vendor.js:3:1)');

      expect(resultado.translated, contains('app.dart 7:3'));
      expect(resultado.translated, contains('vendor.js 3:1'),
          reason: 'o quadro do outro script tem de sobreviver intacto; '
              'spanFor ignora a URI pedida, entao traduzir o trace inteiro '
              'com um map so inventaria uma origem para ele');
    });

    test('um source map corrompido nao derruba a traducao', () async {
      servidor.arquivos['/app.js'] = 'x\n';
      servidor.arquivos['/app.js.map'] = 'isto nao e json';
      final resolver = DartSourceMapResolver();
      addTearDown(resolver.close);

      final original = 'Error: boom\n'
          '    at explode (${servidor.url}/app.js:3:1)';
      final resultado = await resolver.translate(original);

      expect(resultado.didTranslate, isFalse);
      expect(resultado.translated, equals(original));
      expect(resultado.note, isNotNull);
    });

    test('deixa em paz o que nao e quadro de JS compilado', () async {
      final resolver = DartSourceMapResolver();
      addTearDown(resolver.close);

      const texto = 'TimeoutException apos 5s: o elemento nunca apareceu';
      expect(await resolver.translateEmbedded(texto), equals(texto));

      final semQuadros = await resolver.translate('so uma mensagem solta');
      expect(semQuadros.didTranslate, isFalse);
      expect(semQuadros.translated, equals('so uma mensagem solta'));
    });

    test('traduz stack embutido no meio de outro texto', () async {
      servidor.arquivos['/app.js'] = 'x\n';
      servidor.arquivos['/app.js.map'] = _mapaSintetico;
      final resolver = DartSourceMapResolver();
      addTearDown(resolver.close);

      final texto = 'PlaywrightException: evaluation failed\n'
          '    at explode (${servidor.url}/app.js:3:1)\n'
          'depois do stack';
      final traduzido = await resolver.translateEmbedded(texto);

      expect(traduzido, contains('PlaywrightException'));
      expect(traduzido, contains('app.dart 7:3'));
      expect(traduzido, contains('depois do stack'));
    });
  });

  // O servidor sobe pelo proprio `playwrightGroup`, que e a integracao
  // opcional que o pacote oferece; o corpo do teste o alcanca por
  // `t.webServer`.
  playwrightGroup(
    'traducao do app Dart compilado, no navegador',
    webServer: () async {
      await garantirAppCompilado();
      final porta = await _portaLivre();
      return PlaywrightWebServer.start(
        command: '"${Platform.resolvedExecutable}" run '
            'test/fixtures/serve_app.dart --port=$porta',
        url: 'http://127.0.0.1:$porta/',
        readyUrl: 'http://127.0.0.1:$porta/main.dart.js',
        readyBody: 'explodeDeliberadamente',
        timeout: const Duration(seconds: 90),
      );
    },
    () {
      playwrightTest(
          'o trace do navegador volta apontando para o main.dart '
          'na linha do throw', (t) async {
        final erros = <PageError>[];
        final sub = t.page.onPageError.listen(erros.add);

        await t.page.goto(t.webServer!.baseURL);
        await expectLocator(t.page.locator('#pronto')).toBeVisible();
        await t.page.click('#estoura');
        await _esperar(() => erros.isNotEmpty);
        await sub.cancel();

        final bruto = erros.first.stack;
        // O que o navegador entrega e inutil por si so.
        expect(bruto, contains('main.dart.js:'));

        final traduzido = (await translateDartStackTrace(bruto)).translated;

        final linha = linhaDoThrow();
        expect(traduzido, contains('main.dart $linha:'),
            reason: 'o quadro tem de apontar para a linha do throw '
                '($linha) em main.dart; veio:\n$traduzido');
        expect(traduzido, contains('explodeDeliberadamente'));
      }, options: const PlaywrightTestOptions(artifactsPath: null));

      playwrightTest('dobra os quadros de runtime do Dart', (t) async {
        final erros = <PageError>[];
        final sub = t.page.onPageError.listen(erros.add);
        await t.page.goto(t.webServer!.baseURL);
        await expectLocator(t.page.locator('#pronto')).toBeVisible();
        await t.page.click('#estoura');
        await _esperar(() => erros.isNotEmpty);
        await sub.cancel();

        final completo = await DartSourceMapResolver(terse: false)
            .translate(erros.first.stack);
        final dobrado = await translateDartStackTrace(erros.first.stack);

        expect(completo.translated, contains('dart:html'),
            reason: 'sem terse, os quadros de runtime aparecem');
        expect(dobrado.translated, isNot(contains('dart:html')),
            reason: 'com terse, eles saem da frente');
        expect(dobrado.translated, contains('main.dart'));
      }, options: const PlaywrightTestOptions(artifactsPath: null));
    },
  );
}

Future<int> _portaLivre() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final porta = socket.port;
  await socket.close();
  return porta;
}

Future<void> _esperar(bool Function() condicao) async {
  final limite = DateTime.now().add(const Duration(seconds: 15));
  while (DateTime.now().isBefore(limite)) {
    if (condicao()) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  throw StateError('a condicao nunca ficou verdadeira');
}

/// Servidor de arquivos em memoria que conta quantas vezes cada caminho foi
/// pedido -- que e como o teste de cache prova o que promete.
class _ServidorDeArquivos {
  final HttpServer _server;
  final Map<String, String> arquivos = {};
  final Map<String, int> contagem = {};

  _ServidorDeArquivos._(this._server);

  String get url => 'http://127.0.0.1:${_server.port}';

  static Future<_ServidorDeArquivos> iniciar() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final instancia = _ServidorDeArquivos._(server);
    server.listen((request) async {
      final caminho = request.uri.path;
      instancia.contagem[caminho] = (instancia.contagem[caminho] ?? 0) + 1;
      final conteudo = instancia.arquivos[caminho];
      if (conteudo == null) {
        request.response.statusCode = HttpStatus.notFound;
      } else {
        request.response.add(utf8.encode(conteudo));
      }
      await request.response.close();
    });
    return instancia;
  }

  Future<void> parar() => _server.close(force: true);
}

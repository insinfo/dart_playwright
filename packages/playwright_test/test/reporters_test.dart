import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:playwright_test/reporters.dart';
import 'package:test/test.dart';

/// Builds the `dart test --file-reporter json:<file>` stream by hand.
///
/// A synthetic stream and not a real run: the point of these tests is the
/// translation, and a real run drags three browsers and a minute of wall clock
/// into a test of a parser. The end-to-end proof lives in
/// `report_end_to_end_test.dart`, which runs a suite that fails on purpose and
/// then reads the rendered page back out of a browser.
class _Stream {
  final List<String> lines = [];
  int _time = 0;

  void add(String type, Map<String, Object?> payload) {
    lines.add(jsonEncode({...payload, 'type': type, 'time': _time}));
  }

  void advance(int ms) => _time += ms;

  void start() =>
      add('start', {'protocolVersion': '0.1.1', 'runnerVersion': '1.26.3'});

  void suite(int id, String path, {String platform = 'vm'}) => add('suite', {
        'suite': {'id': id, 'platform': platform, 'path': path}
      });

  void group(int id, int suiteId, String name, {int? parentId}) =>
      add('group', {
        'group': {
          'id': id,
          'suiteID': suiteId,
          'parentID': parentId,
          'name': name,
          'metadata': {'skip': false, 'skipReason': null},
          'testCount': 1,
        }
      });

  void testStart(int id, int suiteId, String name,
          {List<int> groupIds = const [],
          bool skip = false,
          String? skipReason,
          String? url,
          int line = 1,
          int column = 1}) =>
      add('testStart', {
        'test': {
          'id': id,
          'name': name,
          'suiteID': suiteId,
          'groupIDs': groupIds,
          'metadata': {'skip': skip, 'skipReason': skipReason},
          'line': line,
          'column': column,
          'url': url,
        }
      });

  void print(int testId, String message, {String type = 'print'}) =>
      add('print', {
        'testID': testId,
        'messageType': type,
        'message': message,
      });

  void error(int testId, String message, {String stack = ''}) => add('error', {
        'testID': testId,
        'error': message,
        'stackTrace': stack,
        'isFailure': true,
      });

  void testDone(int id, String result,
          {bool skipped = false, bool hidden = false}) =>
      add('testDone', {
        'testID': id,
        'result': result,
        'skipped': skipped,
        'hidden': hidden,
      });

  void done({bool success = true}) => add('done', {'success': success});
}

/// A run with one passing test, one failure, one skip and one retried test.
_Stream _sample() {
  final stream = _Stream()..start();
  stream.suite(0, p.join(p.current, 'test', 'exemplo_test.dart'));
  stream.group(1, 0, '');
  stream.group(2, 0, 'login', parentId: 1);

  stream.testStart(3, 0, 'login entra com a senha certa', groupIds: [1, 2]);
  stream.advance(120);
  stream.testDone(3, 'success');

  stream.testStart(4, 0, 'login recusa a senha errada', groupIds: [1, 2]);
  stream.print(4, 'uma linha que o teste imprimiu');
  stream.error(4, 'Expected: exactly one matching node\n  Actual: found none',
      stack: 'test/exemplo_test.dart 42:7  main.<fn>\n'
          'package:test_api/src/backend/invoker.dart 258:15');
  stream.advance(80);
  stream.testDone(4, 'failure');

  stream.testStart(5, 0, 'login pulado',
      groupIds: [1, 2], skip: true, skipReason: 'ainda nao');
  stream.testDone(5, 'success', skipped: true);

  stream.testStart(6, 0, 'login instavel', groupIds: [1, 2]);
  stream.error(6, 'TestFailure: falhou na primeira');
  stream.advance(30);
  stream.print(6, 'Retry: login instavel');
  stream.advance(40);
  stream.testDone(6, 'success');

  stream.advance(10);
  stream.done(success: false);
  return stream;
}

ReportRun _parsed({List<String>? events}) {
  final parser = DartTestParser(rootDir: p.current);
  final run = parser.parse(_sample().lines);
  if (events != null) parser.applyEvents(events);
  return run;
}

ReportTest _test(ReportRun run, String title) =>
    run.tests.firstWhere((test) => test.title == title);

void main() {
  group('DartTestParser', () {
    test('coloca cada teste no seu arquivo, com o grupo separado do titulo',
        () {
      final run = _parsed();
      expect(run.files, hasLength(1));
      expect(run.files.single.path, 'test/exemplo_test.dart');
      final test = _test(run, 'entra com a senha certa');
      // O `package:test` guarda o nome ja prefixado pelo grupo. Um relatorio
      // que mostrasse os dois repetiria "login" em toda linha.
      expect(test.groups, ['login']);
      expect(test.fullTitle, 'login entra com a senha certa');
      expect(test.platform, 'vm');
    });

    test('um teste pulado nao conta como passado', () {
      final run = _parsed();
      final test = _test(run, 'pulado');
      expect(test.outcome, ReportOutcome.skipped);
      expect(test.expectedStatus, ReportStatus.skipped);
      expect(test.skipReason, 'ainda nao');
      // O `package:test` reporta um skip como `success`, o que esta certo para
      // um codigo de saida e errado para um relatorio.
      expect(run.stats.expected, isNot(4));
      expect(run.stats.skipped, 1);
    });

    test('guarda a falha com a pilha e o lugar dela', () {
      final run = _parsed();
      final test = _test(run, 'recusa a senha errada');
      expect(test.outcome, ReportOutcome.unexpected);
      final error = test.lastResult!.error!;
      expect(error.message, contains('exactly one matching node'));
      expect(error.stack, contains('invoker.dart'));
      expect(error.location?.file, 'test/exemplo_test.dart');
      expect(error.location?.line, 42);
      expect(
          test.lastResult!.stdout, contains('uma linha que o teste imprimiu'));
    });

    test('a linha de retry vira uma segunda tentativa, e o teste fica flaky',
        () {
      final run = _parsed();
      final test = _test(run, 'instavel');
      expect(test.results, hasLength(2));
      expect(test.results.first.status, ReportStatus.failed);
      expect(test.results.last.status, ReportStatus.passed);
      expect(test.outcome, ReportOutcome.flaky);
      // A linha de retry e bookkeeping do runner, nao saida do teste.
      expect(test.results.first.stdout, isEmpty);
      expect(run.stats.flaky, 1);
    });

    test('um timeout e um estado proprio, nao uma falha qualquer', () {
      final stream = _Stream()..start();
      stream.suite(0, p.join(p.current, 'test', 'lento_test.dart'));
      stream.group(1, 0, '');
      stream.testStart(2, 0, 'demora', groupIds: [1]);
      stream.error(
          2,
          'TimeoutException after 0:00:30.000000: Test timed out '
          'after 30 seconds.');
      stream.testDone(2, 'error');
      stream.done(success: false);

      final run = DartTestParser(rootDir: p.current).parse(stream.lines);
      expect(run.tests.single.lastResult!.status, ReportStatus.timedOut);
    });

    test('uma falha sem teste vira erro do run inteiro', () {
      final stream = _Stream()..start();
      stream.suite(0, p.join(p.current, 'test', 'quebrado_test.dart'));
      stream.error(99, 'Failed to load "test/quebrado_test.dart".');
      stream.done(success: false);

      final run = DartTestParser(rootDir: p.current).parse(stream.lines);
      // Sem isto, um run em que nenhum arquivo carregou sairia verde e vazio.
      expect(run.errors, hasLength(1));
      expect(run.errors.single.message, contains('Failed to load'));
      expect(run.ok, isFalse);
    });

    test('o teste interno que carrega o arquivo nao entra no relatorio', () {
      final stream = _Stream()..start();
      stream.suite(0, p.join(p.current, 'test', 'exemplo_test.dart'));
      stream.testStart(1, 0, 'loading test/exemplo_test.dart');
      stream.testDone(1, 'success', hidden: true);
      stream.group(2, 0, '');
      stream.testStart(3, 0, 'de verdade', groupIds: [2]);
      stream.testDone(3, 'success');
      stream.done();

      final run = DartTestParser(rootDir: p.current).parse(stream.lines);
      expect(run.tests.map((t) => t.title), ['de verdade']);
    });

    test('um teste que o run interrompeu e relatado, nao esquecido', () {
      final stream = _Stream()..start();
      stream.suite(0, p.join(p.current, 'test', 'exemplo_test.dart'));
      stream.group(1, 0, '');
      stream.testStart(2, 0, 'nunca terminou', groupIds: [1]);
      // Sem `testDone`: e o que sobra quando alguem aperta Ctrl-C.

      final run = DartTestParser(rootDir: p.current).parse(stream.lines);
      expect(run.tests.single.outcome, ReportOutcome.unexpected);
      expect(run.tests.single.lastResult!.error!.message,
          contains('ended before this test reported a result'));
    });
  });

  group('applyEvents', () {
    List<String> eventos(String suite, String test, {int attempt = 0}) => [
          jsonEncode({
            'kind': 'step-begin',
            'suite': suite,
            'platform': 'vm',
            'test': test,
            'attempt': attempt,
            'id': 's1',
            'parentId': null,
            'title': 'abre a pagina',
            'category': 'test.step',
            'startTime': 5000,
          }),
          jsonEncode({
            'kind': 'attachment',
            'suite': suite,
            'platform': 'vm',
            'test': test,
            'attempt': attempt,
            'name': 'nota',
            'contentType': 'text/plain',
            'body': base64Encode(utf8.encode('deu ruim')),
            'stepId': 's1',
          }),
          jsonEncode({
            'kind': 'step-begin',
            'suite': suite,
            'platform': 'vm',
            'test': test,
            'attempt': attempt,
            'id': 's2',
            'parentId': 's1',
            'title': 'um passo dentro do outro',
            'category': 'test.step',
            'startTime': 5010,
          }),
          jsonEncode({
            'kind': 'step-end',
            'suite': suite,
            'platform': 'vm',
            'test': test,
            'attempt': attempt,
            'id': 's2',
            'endTime': 5030,
          }),
          jsonEncode({
            'kind': 'step-end',
            'suite': suite,
            'platform': 'vm',
            'test': test,
            'attempt': attempt,
            'id': 's1',
            'endTime': 5040,
            'error': 'o passo falhou',
          }),
        ];

    test('remonta a arvore de passos e prende o anexo ao passo certo', () {
      final suite = p.join(p.current, 'test', 'exemplo_test.dart');
      final run =
          _parsed(events: eventos(suite, 'login recusa a senha errada'));
      final result = _test(run, 'recusa a senha errada').lastResult!;

      expect(result.steps, hasLength(1));
      final passo = result.steps.single;
      expect(passo.title, 'abre a pagina');
      expect(passo.error, 'o passo falhou');
      // Os tempos vem do cronometro da isolate, que comecou muito antes do
      // teste; o que o relatorio mostra e o deslocamento dentro do teste.
      expect(passo.startTime, 0);
      expect(passo.duration, const Duration(milliseconds: 40));
      expect(passo.steps.single.title, 'um passo dentro do outro');
      expect(passo.steps.single.duration, const Duration(milliseconds: 20));

      expect(result.attachments.single.name, 'nota');
      expect(result.attachments.single.stepId, 's1');
      expect(utf8.decode(result.attachments.single.body!), 'deu ruim');
    });

    test('o anexo da tentativa que falhou fica na tentativa que falhou', () {
      final suite = p.join(p.current, 'test', 'exemplo_test.dart');
      final run = _parsed(events: eventos(suite, 'login instavel'));
      final test = _test(run, 'instavel');
      // Sem o indice de tentativa, o screenshot da falha apareceria na aba da
      // tentativa que passou, que e onde ele nao ajuda ninguem.
      expect(test.results.first.attachments, hasLength(1));
      expect(test.results.last.attachments, isEmpty);
    });

    test('uma linha ilegivel nao derruba o relatorio', () {
      final run = _parsed(events: ['nao e json', '', '{"kind":"nada"}']);
      expect(run.tests, isNotEmpty);
    });
  });

  group('JsonReporter', () {
    Map<String, Object?> relatorio() => JsonReporter(
          rootDir: p.current,
          version: '3.6.2',
        ).build(_parsed());

    test('as chaves de topo sao as do upstream, nessa ordem', () {
      expect(
          relatorio().keys.toList(), ['config', 'suites', 'errors', 'stats']);
    });

    test('stats usa o vocabulario de desfecho, nao o de resultado', () {
      final stats = relatorio()['stats'] as Map<String, Object?>;
      expect(stats.keys.toList(), [
        'startTime',
        'duration',
        'expected',
        'unexpected',
        'flaky',
        'skipped',
      ]);
      expect(stats['expected'], 1);
      expect(stats['unexpected'], 1);
      expect(stats['flaky'], 1);
      expect(stats['skipped'], 1);
      // ISO 8601 em UTC, que e o que `toISOString()` produz do outro lado.
      expect(stats['startTime'], endsWith('Z'));
    });

    test('o grupo vira uma suite aninhada dentro da do arquivo', () {
      final arquivo = (relatorio()['suites'] as List).single as Map;
      expect(arquivo['title'], 'test/exemplo_test.dart');
      expect(arquivo['specs'], isEmpty);
      final grupo = (arquivo['suites'] as List).single as Map;
      expect(grupo['title'], 'login');
      expect((grupo['specs'] as List), hasLength(4));
    });

    test('um spec carrega o desfecho, e um result carrega o status', () {
      final grupo =
          ((relatorio()['suites'] as List).single as Map)['suites'] as List;
      final specs = ((grupo.single as Map)['specs'] as List).cast<Map>();
      final falha =
          specs.firstWhere((s) => s['title'] == 'recusa a senha errada');
      expect(falha['ok'], isFalse);
      expect(falha['id'], hasLength(20));
      final test = (falha['tests'] as List).single as Map;
      // Os dois vocabularios, lado a lado: o teste e `unexpected`, o resultado
      // e `failed`. Trocar um pelo outro quebra quem le o relatorio.
      expect(test['status'], 'unexpected');
      expect(test['expectedStatus'], 'passed');
      final result = (test['results'] as List).single as Map;
      expect(result['status'], 'failed');
      expect(result['retry'], 0);
      expect(result['stdout'], [
        {'text': 'uma linha que o teste imprimiu\n'}
      ]);
    });

    test('steps so aparece quando ha passos', () {
      final grupo =
          ((relatorio()['suites'] as List).single as Map)['suites'] as List;
      final specs = ((grupo.single as Map)['specs'] as List).cast<Map>();
      final result =
          ((specs.first['tests'] as List).single as Map)['results'] as List;
      // O upstream omite a chave em vez de escrever uma lista vazia, e ha
      // consumidor que trata `steps: []` como um no que ainda tem de percorrer.
      expect((result.single as Map).containsKey('steps'), isFalse);
    });

    test('render sai indentado com dois espacos, como o upstream', () {
      final texto =
          JsonReporter(rootDir: p.current, version: '3.6.2').render(_parsed());
      expect(texto, startsWith('{\n  "config": {'));
      expect(texto, isNot(endsWith('\n')));
    });
  });

  group('JUnitReporter', () {
    String xml({String? outputFile}) => JUnitReporter(
          rootDir: p.current,
          outputFile: outputFile,
          suiteName: 'minha suite',
        ).render(_parsed());

    test('sem prologo e sem tag que se fecha sozinha', () {
      final texto = xml();
      // As duas coisas sao escolhas do upstream; parser nenhum la fora reclama
      // delas e mudar qualquer uma e uma diferenca a toa num diff de CI.
      expect(texto, startsWith('<testsuites '));
      expect(texto, contains('<skipped>\n</skipped>'));
      expect(texto, isNot(contains('<?xml')));
    });

    test('os atributos da raiz vem na ordem do upstream', () {
      final primeira = xml().split('\n').first;
      expect(
          primeira,
          matches(RegExp(r'^<testsuites id="" name="minha suite" tests="\d+" '
              r'failures="\d+" skipped="\d+" errors="\d+" time="[\d.]+">$')));
    });

    test('time e em segundos, e inteiro sai sem virgula', () {
      // Milissegundos no JSON, segundos aqui. E uma diferenca real entre os
      // dois formatos, e trocar uma pela outra da numeros mil vezes errados.
      expect(xml(), contains('time="0.08"'));
    });

    test('o nome do caso junta o caminho com o separador do upstream', () {
      expect(xml(), contains('name="login › recusa a senha errada"'));
    });

    test('uma assertion e failure; uma excecao e error', () {
      final texto = xml();
      expect(texto, contains('<failure message="exactly one matching node'));
      expect(texto, contains('type="expect"'));
    });

    test('escapa atributo com entidade e texto com CDATA', () {
      final stream = _Stream()..start();
      stream.suite(0, p.join(p.current, 'test', 'aspas_test.dart'));
      stream.group(1, 0, '');
      stream.testStart(2, 0, 'aspas & <sinais>', groupIds: [1]);
      stream.error(2, 'TestFailure: esperava "isto" & nao <aquilo>');
      stream.testDone(2, 'failure');
      stream.done(success: false);

      final texto = JUnitReporter(rootDir: p.current)
          .render(DartTestParser(rootDir: p.current).parse(stream.lines));
      // Atributo leva entidade, texto vai em CDATA: as duas regras do
      // upstream, e sao elas que decidem se o arquivo abre no parser do CI.
      expect(texto, contains('name="aspas &amp; &lt;sinais&gt;"'));
      expect(texto, contains('message="esperava &quot;isto&quot;'));
      expect(texto, contains('<![CDATA[TestFailure: esperava "isto"'));
    });

    test('fecha um CDATA que contem a propria sequencia de fim', () {
      final stream = _Stream()..start();
      stream.suite(0, p.join(p.current, 'test', 'cdata_test.dart'));
      stream.group(1, 0, '');
      stream.testStart(2, 0, 'com fim de cdata', groupIds: [1]);
      stream.error(2, 'TestFailure: o texto tinha ]]> dentro');
      stream.testDone(2, 'failure');
      stream.done(success: false);

      final texto = JUnitReporter(rootDir: p.current)
          .render(DartTestParser(rootDir: p.current).parse(stream.lines));
      // Sem isto o CDATA fecharia no meio e o resto do arquivo viraria markup.
      expect(texto, contains(']]&gt; dentro'));
      expect(']]>'.allMatches(texto), hasLength(1),
          reason: 'so o ]]> que fecha o unico CDATA do arquivo');
    });

    test('o anexo entra no system-out no formato que o CI conhece', () async {
      final pasta = await Directory.systemTemp.createTemp('pw_junit');
      addTearDown(() => pasta.delete(recursive: true));
      final arquivo = File(p.join(pasta.path, 'shot.png'))
        ..writeAsBytesSync([1, 2, 3]);

      final parser = DartTestParser(rootDir: p.current);
      final run = parser.parse(_sample().lines);
      parser.applyEvents([
        jsonEncode({
          'kind': 'attachment',
          'suite': p.join(p.current, 'test', 'exemplo_test.dart'),
          'platform': 'vm',
          'test': 'login recusa a senha errada',
          'attempt': 0,
          'name': 'screenshot',
          'contentType': 'image/png',
          'path': arquivo.path,
        })
      ]);

      final texto = JUnitReporter(
              rootDir: p.current, outputFile: p.join(pasta.path, 'r.xml'))
          .render(run);
      expect(texto, contains('[[ATTACHMENT|shot.png]]'));
    });

    test('um anexo que sumiu vira aviso, nao um caminho quebrado', () {
      final parser = DartTestParser(rootDir: p.current);
      final run = parser.parse(_sample().lines);
      parser.applyEvents([
        jsonEncode({
          'kind': 'attachment',
          'suite': p.join(p.current, 'test', 'exemplo_test.dart'),
          'platform': 'vm',
          'test': 'login recusa a senha errada',
          'attempt': 0,
          'name': 'screenshot',
          'contentType': 'image/png',
          'path': 'nao/existe.png',
        })
      ]);
      expect(JUnitReporter(rootDir: p.current).render(run),
          contains('is missing'));
    });
  });

  group('HtmlReporter', () {
    late Directory pasta;

    setUp(() async {
      pasta = await Directory.systemTemp.createTemp('pw_html');
    });
    tearDown(() => pasta.delete(recursive: true));

    test('o payload tem a forma do HTMLReport do upstream', () {
      final payload = HtmlReporter(
              outputFolder: p.join(pasta.path, 'relatorio'), rootDir: p.current)
          .buildReport(_parsed());
      final report = payload['report'] as Map<String, Object?>;
      // O contrato de dados e o que uma UI futura vai ter de ler; os nomes sao
      // os de packages/html-reporter/src/types.d.ts.
      expect(
          report.keys,
          containsAll([
            'metadata',
            'files',
            'stats',
            'projectNames',
            'startTime',
            'duration',
            'machines',
            'errors',
            'options',
          ]));
      expect(report['startTime'], isA<int>());
      final stats = report['stats'] as Map<String, Object?>;
      expect(stats.keys.toList(),
          ['total', 'expected', 'unexpected', 'flaky', 'skipped', 'ok']);
      expect(stats['ok'], isFalse);

      final arquivo = (report['files'] as List).single as Map;
      expect(arquivo['fileId'], hasLength(20));
      final caso = (arquivo['tests'] as List).first as Map;
      // Falha primeiro: quem abre o relatorio veio por causa dela.
      expect(caso['outcome'], 'unexpected');
      expect(
          caso.keys,
          containsAll([
            'testId',
            'title',
            'path',
            'projectName',
            'location',
            'annotations',
            'tags',
            'outcome',
            'duration',
            'ok',
            'results',
          ]));
    });

    test('escreve uma pagina so, com os dados embutidos', () async {
      final destino = p.join(pasta.path, 'relatorio');
      final index =
          await HtmlReporter(outputFolder: destino, rootDir: p.current)
              .write(_parsed());
      final html = File(index).readAsStringSync();
      expect(html, contains('<template id="playwrightReportJson">'));
      expect(html, contains('data:application/json;base64,'));

      final base64Payload = RegExp(
              r'<template id="playwrightReportJson">data:application/json;base64,([^<]*)</template>')
          .firstMatch(html)!
          .group(1)!;
      final decoded = jsonDecode(utf8.decode(base64Decode(base64Payload)));
      expect((decoded as Map)['report'], isA<Map>());
      // Base64 e nao JSON cru: uma mensagem de falha com `</script>` dentro
      // fecharia a tag e apagaria a pagina, justo nas falhas interessantes.
      expect(html, isNot(contains('"unexpected"')));
    });

    test('copia o anexo para data/ pelo conteudo, uma vez so', () async {
      final origem = File(p.join(pasta.path, 'shot.png'))
        ..writeAsBytesSync(List.filled(64, 7));
      final parser = DartTestParser(rootDir: p.current);
      final run = parser.parse(_sample().lines);
      parser.applyEvents([
        for (final teste in ['login recusa a senha errada', 'login instavel'])
          jsonEncode({
            'kind': 'attachment',
            'suite': p.join(p.current, 'test', 'exemplo_test.dart'),
            'platform': 'vm',
            'test': teste,
            'attempt': 0,
            'name': 'screenshot',
            'contentType': 'image/png',
            'path': origem.path,
          })
      ]);

      final destino = p.join(pasta.path, 'relatorio');
      await HtmlReporter(outputFolder: destino, rootDir: p.current).write(run);
      final dados = Directory(p.join(destino, 'data')).listSync();
      expect(dados, hasLength(1),
          reason: 'o mesmo arquivo anexado duas vezes e escrito uma');
      expect(p.basename(dados.single.path), endsWith('.png'));
    });

    test('apaga a pasta antes de escrever', () async {
      final destino = p.join(pasta.path, 'relatorio');
      File(p.join(destino, 'data', 'velho.png'))
        ..createSync(recursive: true)
        ..writeAsBytesSync([9]);

      await HtmlReporter(outputFolder: destino, rootDir: p.current)
          .write(_parsed());
      // Um screenshot da corrida anterior e um screenshot da falha errada.
      expect(File(p.join(destino, 'data', 'velho.png')).existsSync(), isFalse);
    });
  });

  group('stripAnsiEscapes', () {
    test('tira cor e deixa o texto', () {
      expect(stripAnsiEscapes('\u001b[31mvermelho\u001b[0m'), 'vermelho');
      expect(stripAnsiEscapes('sem cor'), 'sem cor');
    });
  });
}

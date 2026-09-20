import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:playwright_test/playwright_test.dart';

import 'app_server.dart';

/// `step` so vale a pena se o passo chegar ao trace: um nome que so aparece
/// numa mensagem de erro nao paga o custo da API. Estes testes abrem o arquivo
/// gravado e conferem entrada por entrada, como o visualizador faria.
void main() {
  late AppServer app;
  late Directory saida;

  setUpAll(() async {
    app = await AppServer.start();
    saida = Directory.systemTemp.createTempSync('pw-dart-step-trace-');
  });

  tearDownAll(() async {
    await app.stop();
    if (saida.existsSync()) saida.deleteSync(recursive: true);
  });

  /// As linhas de `trace.trace`, como o visualizador as le: um JSON por linha.
  List<Map<String, dynamic>> eventos(String zip) {
    final archive = ZipDecoder().decodeBytes(File(zip).readAsBytesSync());
    final trace = archive.files.firstWhere((f) => f.name == 'trace.trace');
    return [
      for (final line in utf8.decode(trace.content as List<int>).split('\n'))
        if (line.trim().isNotEmpty) jsonDecode(line) as Map<String, dynamic>,
    ];
  }

  /// Os nomes dos arquivos dentro do zip.
  List<String> arquivos(String zip) {
    final archive = ZipDecoder().decodeBytes(File(zip).readAsBytesSync());
    return [
      for (final file in archive.files)
        if (file.isFile) file.name,
    ];
  }

  playwrightGroup('test.step no trace', () {
    const opcoes = PlaywrightTestOptions(artifactsPath: null);

    playwrightTest('um passo vira uma entrada do trace', (t) async {
      final zip = '${saida.path}${Platform.pathSeparator}passo.zip';
      await t.context.tracing.start(sources: false);

      await step('abre os widgets', () async {
        await t.page.goto(app.url('/widgets'));
      });

      await t.context.tracing.stop(path: zip);

      final linhas = eventos(zip);
      final antes = linhas.firstWhere(
        (e) => e['type'] == 'before' && e['title'] == 'abre os widgets',
        orElse: () => throw StateError(
            'nenhum "before" com o titulo do passo em:\n'
            '${linhas.where((e) => e['type'] == 'before').map((e) => e['method']).toList()}'),
      );
      // `class`/`method` sao os que o `tracing.group()` do upstream escreve; e
      // por esse par que o visualizador decide como desenhar a linha.
      expect(antes['class'], equals('Tracing'));
      expect(antes['method'], equals('tracingGroup'));

      // O `after` fecha o mesmo callId, senao a linha fica aberta no
      // visualizador e a duracao do passo nao existe.
      final depois = linhas
          .where((e) => e['type'] == 'after' && e['callId'] == antes['callId']);
      expect(depois, hasLength(1));
      expect(depois.first['endTime'], greaterThan(antes['startTime'] as num));

      // O `goto` de dentro do passo aparece pendurado nele.
      final goto = linhas
          .firstWhere((e) => e['type'] == 'before' && e['method'] == 'goto');
      expect(goto['parentId'], equals(antes['callId']),
          reason: 'as acoes de dentro do passo aninham embaixo dele');
    }, options: opcoes);

    playwrightTest('passos aninhados aninham no trace', (t) async {
      final zip = '${saida.path}${Platform.pathSeparator}aninhado.zip';
      await t.context.tracing.start(sources: false);

      await step('fluxo inteiro', () async {
        await step('abre', () => t.page.goto(app.url('/widgets')));
        await step('confere', () async {
          await expectLocator(t.page.locator('#pintado')).toBeVisible();
        });
      });

      await t.context.tracing.stop(path: zip);

      final linhas = eventos(zip);
      Map<String, dynamic> passo(String titulo) => linhas
          .firstWhere((e) => e['type'] == 'before' && e['title'] == titulo);

      final fora = passo('fluxo inteiro');
      expect(fora['parentId'], isNull);
      expect(passo('abre')['parentId'], equals(fora['callId']));
      expect(passo('confere')['parentId'], equals(fora['callId']));
    }, options: opcoes);

    playwrightTest('um passo que falha fecha vermelho e deixa o erro subir',
        (t) async {
      final zip = '${saida.path}${Platform.pathSeparator}falha.zip';
      await t.context.tracing.start(sources: false);
      await t.page.goto(app.url('/widgets'));

      await expectLater(
        step('confere o que nao existe', () async {
          await expectLocator(t.page.locator('#nao-existe'),
                  timeout: const Duration(milliseconds: 300))
              .toBeVisible();
        }),
        // O erro sobe como veio: quem le a falha quer a assertion, nao um
        // embrulho com o nome do passo.
        throwsA(isA<AssertionFailure>()),
      );

      await t.context.tracing.stop(path: zip);

      final linhas = eventos(zip);
      final antes = linhas.firstWhere((e) =>
          e['type'] == 'before' && e['title'] == 'confere o que nao existe');
      final depois = linhas.firstWhere(
          (e) => e['type'] == 'after' && e['callId'] == antes['callId']);
      expect(depois['error'], isNotNull,
          reason: 'a linha vermelha e a razao de alguem abrir um trace');
    }, options: opcoes);

    playwrightTest('um anexo vira attachments no after do passo', (t) async {
      final zip = '${saida.path}${Platform.pathSeparator}anexo.zip';
      await t.context.tracing.start(sources: false);

      await step('tira uma foto', () async {
        await t.page.goto(app.url('/widgets'));
        await attach('foto',
            body: await t.page.screenshot(), contentType: 'image/png');
        await attach('nota',
            body: utf8.encode('deu certo'), contentType: 'text/plain');
      });

      await t.context.tracing.stop(path: zip);

      final linhas = eventos(zip);
      final antes = linhas.firstWhere(
          (e) => e['type'] == 'before' && e['title'] == 'tira uma foto');
      final depois = linhas.firstWhere(
          (e) => e['type'] == 'after' && e['callId'] == antes['callId']);
      final anexos =
          (depois['attachments'] as List).cast<Map<String, dynamic>>();
      expect(anexos, hasLength(2));
      expect(anexos.map((a) => a['name']), containsAll(['foto', 'nota']));

      final nomes = arquivos(zip);
      for (final anexo in anexos) {
        // O visualizador resolve o anexo pelo nome do arquivo dentro do
        // arquivo: sem ele a aba de anexos mostra um link que nao abre.
        expect(anexo['file'], isNotNull);
        expect(nomes, contains(anexo['file']));
      }
      expect(anexos.firstWhere((a) => a['name'] == 'foto')['contentType'],
          'image/png');
    }, options: opcoes);

    playwrightTest('anexo por caminho entra no zip e guarda o caminho',
        (t) async {
      final zip = '${saida.path}${Platform.pathSeparator}anexo-arquivo.zip';
      final origem = File('${saida.path}${Platform.pathSeparator}nota.txt')
        ..writeAsStringSync('conteudo do arquivo');
      await t.context.tracing.start(sources: false);

      await step('anexa um arquivo', () async {
        await t.page.goto(app.url('/widgets'));
        await attach('nota', path: origem.path);
      });

      await t.context.tracing.stop(path: zip);

      final linhas = eventos(zip);
      final antes = linhas.firstWhere(
          (e) => e['type'] == 'before' && e['title'] == 'anexa um arquivo');
      final depois = linhas.firstWhere(
          (e) => e['type'] == 'after' && e['callId'] == antes['callId']);
      final anexo =
          (depois['attachments'] as List).first as Map<String, dynamic>;
      expect(anexo['path'], origem.path);
      expect(anexo['contentType'], 'text/plain');

      // O que o visualizador abre e a copia de dentro do arquivo, para que o
      // trace continue completo depois de mudar de maquina.
      final archive = ZipDecoder().decodeBytes(File(zip).readAsBytesSync());
      final dentro = archive.files.firstWhere((f) => f.name == anexo['file']);
      expect(utf8.decode(dentro.content as List<int>), 'conteudo do arquivo');
    }, options: opcoes);

    playwrightTest('fora de um trace o passo so roda o corpo', (t) async {
      // Sem gravacao ligada nao ha o que reportar, e `step` nao pode custar
      // nada nem mudar o resultado.
      final valor = await step('conta os widgets', () async {
        await t.page.goto(app.url('/widgets'));
        return t.page.locator('select').count();
      });
      expect(valor, equals(2));
    }, options: opcoes);
  });
}

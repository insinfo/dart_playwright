@Timeout(Duration(minutes: 6))
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Roda uma suite que falha de proposito, gera os tres relatorios dela e
/// **abre o HTML no Chromium deste porte** para ler de volta o que a pagina
/// desenhou.
///
/// E esta a prova que vale. Um relatorio que escreve um arquivo e nao renderiza
/// nada e um arquivo, nao um relatorio; e a unica forma de saber a diferenca e
/// abrindo. Os testes de unidade em `reporters_test.dart` cuidam do formato dos
/// dados; este cuida do caminho inteiro, do `dart test` que falha ate o pixel.
///
/// Custa um `dart test` filho mais um navegador, entao ele tem um timeout
/// generoso e roda uma vez so, com tudo que precisa ser conferido saindo da
/// mesma pagina aberta.
void main() {
  late Directory temporario;
  late String relatorio;

  setUpAll(() async {
    temporario = await Directory.systemTemp.createTemp('pw_relatorio_e2e');
    relatorio = p.join(temporario.path, 'relatorio');

    // `inheritStdio` porque a suite filha sobe navegadores, e um processo de
    // navegador segura o cano de stdout aberto depois de o `dart test` sair --
    // quem lesse o cano esperaria para sempre.
    final filho = await Process.start(
      Platform.resolvedExecutable,
      [
        'run',
        'playwright_test:report',
        '--html',
        relatorio,
        '--json',
        p.join(temporario.path, 'report.json'),
        '--junit',
        p.join(temporario.path, 'results.xml'),
        '--',
        p.join('test', 'fixtures', 'relatorio_child.dart'),
        '-j',
        '1',
      ],
      environment: {
        'PW_DART_ARTEFATOS': p.join(temporario.path, 'artefatos'),
      },
      mode: ProcessStartMode.inheritStdio,
    );
    // A suite filha falha de proposito, entao o codigo de saida tem de ser
    // diferente de zero: se fosse zero, o wrapper estaria escondendo a falha,
    // que e a pior coisa que um gerador de relatorio pode fazer num CI.
    expect(await filho.exitCode, isNot(0),
        reason: 'a suite filha falha de proposito');
  });

  tearDownAll(() => temporario.delete(recursive: true));

  test('o JSON tem a falha, o skip e os passos', () {
    final relatorioJson = jsonDecode(
        File(p.join(temporario.path, 'report.json')).readAsStringSync());
    final stats = (relatorioJson as Map)['stats'] as Map;
    expect(stats['unexpected'], 1);
    expect(stats['skipped'], 1);
    expect(stats['expected'], 2);

    final specs = _specs(relatorioJson['suites'] as List);
    final comPassos =
        specs.firstWhere((s) => s['title'] == 'um teste com passos e um anexo');
    final resultado =
        ((comPassos['tests'] as List).single as Map)['results'] as List;
    final passos = (resultado.single as Map)['steps'] as List;
    expect(passos.map((s) => (s as Map)['title']),
        ['abre a pagina', 'anexa o que viu']);
    expect(((passos[1] as Map)['steps'] as List).single,
        containsPair('title', 'um passo dentro do outro'));

    final falha = specs
        .firstWhere((s) => s['title'] == 'um teste que falha de proposito');
    final anexos =
        ((((falha['tests'] as List).single as Map)['results'] as List).single
            as Map)['attachments'] as List;
    expect((anexos.single as Map)['name'], 'screenshot');
  });

  test('o JUnit aponta o anexo do jeito que o CI espera', () {
    final xml = File(p.join(temporario.path, 'results.xml')).readAsStringSync();
    expect(xml, contains('[[ATTACHMENT|'));
    expect(xml, contains('um-teste-que-falha-de-proposito-chromium.png'));
    expect(xml, contains('<skipped>'));
  });

  test('o HTML abre num navegador e mostra a falha, a pilha e o anexo',
      () async {
    final leitura = p.join(temporario.path, 'leitura.txt');
    // `inheritStdio` e nao `Process.run`: o script sobe um navegador, e o
    // processo dele segura o cano de stdout aberto depois de o script sair, o
    // que deixa quem estiver lendo o cano esperando para sempre. O `--out`
    // existe por causa disso.
    final processo = await Process.start(
      Platform.resolvedExecutable,
      [
        'run',
        p.join('..', '..', 'tool', 'open_report_in_browser.dart'),
        p.join(relatorio, 'index.html'),
        p.join(temporario.path, 'pagina.png'),
        'passos',
        '--out=$leitura',
      ],
      mode: ProcessStartMode.inheritStdio,
    );
    final codigo = await processo.exitCode;
    final texto =
        File(leitura).existsSync() ? File(leitura).readAsStringSync() : '';
    expect(codigo, 0, reason: 'a pagina nao renderiu\n$texto');

    // Os contadores do cabecalho: 4 testes, um deles pulado, entao "All" conta
    // 3 -- e a mesma conta que o upstream faz.
    expect(texto, contains('COUNTERS: All3 | Passed2 | Failed1'));
    expect(texto, contains('Skipped1'));

    // O filtro `s:failed` e a primeira coisa que alguem clica.
    expect(texto, contains('[unexpected] relatorio'));
    expect(texto, contains('um teste que falha de proposito'));

    // A falha com a mensagem e a pilha.
    expect(texto, contains('DETAIL error:'));
    expect(texto, contains('um texto que nao esta la'));
    expect(texto, contains('fixtures.dart'));

    // O screenshot: presente no DOM *e* decodificado pelo navegador. Uma
    // imagem quebrada esta no DOM do mesmo jeito, e e justo o caso em que o
    // relatorio mente.
    expect(texto, contains('DETAIL attachment: screenshot (image/png)'));
    expect(texto, matches(RegExp(r'image data/\w+\.png \((\d+)px wide\)')));
    expect(texto, isNot(contains('(0px wide)')));

    // A arvore de passos, com o anexo pendurado no passo que o criou.
    expect(texto, contains('- abre a pagina'));
    expect(texto, contains('- anexa o que viu  [+ nota (text/plain)]'));
    expect(texto, contains('  - um passo dentro do outro'));
  });
}

/// Todos os specs do relatorio, entrando nas suites aninhadas.
List<Map<String, Object?>> _specs(List suites) {
  final out = <Map<String, Object?>>[];
  for (final suite in suites.cast<Map<String, Object?>>()) {
    out.addAll((suite['specs'] as List).cast<Map<String, Object?>>());
    if (suite['suites'] != null) out.addAll(_specs(suite['suites'] as List));
  }
  return out;
}

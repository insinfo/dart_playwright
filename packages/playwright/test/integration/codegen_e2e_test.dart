// O que este teste prova: o codigo que o recorder gera roda.
//
// Uma sessao e gravada de verdade num navegador, o gerador Dart produz o
// arquivo, o arquivo e escrito dentro do workspace (onde `package:playwright`
// resolve), passa por `dart analyze` e entao e **executado** contra a mesma
// pagina de teste, que continua no ar neste processo. Um locator errado, um
// metodo que este porte nao tem ou uma acao que nao repete o que o usuario fez
// reprovam aqui, e nao numa comparacao de strings.
@Tags(['analyzer'])
library;

import 'dart:io';

import 'package:playwright/playwright.dart';
import 'package:playwright/recorder.dart';
import 'package:playwright/src/recorder/codegen_command.dart';
import 'package:test/test.dart';

import 'test_server.dart';

/// Sobe da pasta atual ate a raiz do workspace.
Directory _workspaceRoot() {
  var dir = Directory.current;
  while (true) {
    if (Directory('${dir.path}/packages/playwright_test').existsSync()) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('Nao achei a raiz do workspace a partir de '
          '${Directory.current.path}');
    }
    dir = parent;
  }
}

void main() {
  group('Codegen de ponta a ponta', () {
    late Playwright playwright;
    late TestServer server;
    late Directory checkDir;

    setUpAll(() async {
      server = await TestServer.start();
      playwright = await Playwright.create();
      // Dentro do `playwright_test` porque e de la que o sabor de test
      // runner importa `playwrightTest`. O nome e proprio desta frente: outra
      // suite ja usa `codegen_check` no mesmo pacote.
      checkDir = Directory('${_workspaceRoot().path}/packages/playwright_test'
          '/test/codegen_recorder_check');
      if (checkDir.existsSync()) checkDir.deleteSync(recursive: true);
      checkDir.createSync(recursive: true);
    });

    tearDownAll(() async {
      await server.stop();
      if (checkDir.existsSync()) checkDir.deleteSync(recursive: true);
    });

    test('[chromium] O Dart gravado compila e roda contra a mesma pagina',
        () async {
      final browser = await playwright.chromium.launch(headless: true);
      final context = await browser.newContext();
      final recorder = Recorder(context, isUnderTest: true);
      await recorder.install();
      final collection = RecorderCollection(
        recorder: recorder,
        // O sabor de biblioteca: um `main()` proprio, que roda com um
        // `dart run` e nao precisa do runner de teste aninhado.
        generatorId: 'dart',
        options: const LanguageGeneratorOptions(
          browserName: 'chromium',
          // O programa gerado roda num processo filho, sem tela.
          launchOptions: {'headless': true},
          contextOptions: {},
        ),
      );
      await recorder.setMode(RecorderMode.recording);

      final page = await context.newPage();
      await page.goto(server.url('/recorder-page'));
      await _waitForRecordingMode(page);

      // A sessao: uma de cada familia de acao que o gerador sabe escrever.
      await page.click('#submit-button');
      await page.fill('#name', 'Isaque');
      await page.fill('#search', 'playwright');
      await page.locator('#agree').check();
      await page.locator('#pet').selectOption('dog');
      await page.locator('#name').press('Tab');
      await page.click('#next');
      await page.waitForLoadState();
      // A chamada de binding do clique ainda pode estar voando quando a
      // navegacao comeca; espera ela chegar antes de fechar a gravacao.
      await Future<void>.delayed(const Duration(milliseconds: 800));

      recorder.flushPendingActions();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final source = collection.generate().text;
      final testFlavourSource = generateCode(
        collection.actions,
        generatorById('dart-test'),
        const LanguageGeneratorOptions(
          browserName: 'chromium',
          launchOptions: {'headless': true},
          contextOptions: {},
        ),
      ).text;
      await collection.dispose();
      await recorder.dispose();
      await browser.close();

      // O que foi gravado tem de ser o que o usuario fez, em locator legivel.
      expect(source, contains("getByRole('button', name: 'Submit').click()"));
      expect(source,
          contains("getByRole('textbox', name: 'Full name').fill('Isaque')"));
      // O placeholder entra no nome acessivel, e o upstream pontua
      // `getByRole` com nome acima de `getByPlaceholder`; e esse locator que
      // sai, e nao o do placeholder.
      expect(
          source,
          contains(
              "getByRole('textbox', name: 'Search here').fill('playwright')"));
      expect(source, contains("getByTestId('pet-picker').selectOption('dog')"));
      expect(source, contains('.check()'));
      expect(source, contains(".press('Tab')"));
      expect(source, contains("getByRole('link', name: 'Go to text')"));
      // Nenhum seletor cru sobreviveu ate o codigo.
      expect(source, isNot(contains('internal:')));

      final file = File('${checkDir.path}/generated_session.dart');
      file.writeAsStringSync(source);

      // O mesmo roteiro no sabor de test runner, que e o padrao do comando:
      // ele nao e executado aqui (seria um runner de teste dentro de outro),
      // mas passa pelo mesmo `dart analyze`.
      File('${checkDir.path}/generated_session_test_flavour.dart')
          .writeAsStringSync(testFlavourSource);

      // O programa gerado termina com `browser.close()` e nada mais; quem
      // encerra o processo e este invocador, que so existe para isso. Se
      // algum locator gravado nao achar o elemento, `generated.main()` lanca e
      // o processo sai com codigo diferente de zero.
      File('${checkDir.path}/run_generated.dart').writeAsStringSync('''
import 'dart:io';

import 'generated_session.dart' as generated;

Future<void> main() async {
  await generated.main();
  exit(0);
}
''');

      final analyze = await Process.run(
        Platform.resolvedExecutable,
        ['analyze', '--no-fatal-warnings', checkDir.path],
        workingDirectory: _workspaceRoot().path,
      );
      expect(analyze.exitCode, 0,
          reason: 'dart analyze recusou o codigo gerado:\n'
              '${analyze.stdout}\n${analyze.stderr}\n\n$source');

      // E agora a prova: rodar. O servidor de teste deste processo ainda
      // responde, entao o `goto` gravado encontra a mesma pagina.
      final run = await Process.run(
        Platform.resolvedExecutable,
        ['run', '${checkDir.path}/run_generated.dart'],
        workingDirectory: _workspaceRoot().path,
      ).timeout(const Duration(minutes: 3));
      expect(run.exitCode, 0,
          reason: 'o codigo gerado falhou ao rodar:\n'
              '${run.stdout}\n${run.stderr}\n\n$source');
    }, timeout: const Timeout(Duration(minutes: 6)));

    test('[chromium] O comando codegen devolve o codigo da sessao', () async {
      // O caminho do comando de linha, sem o parser de argumentos: abre o
      // navegador, grava e devolve o arquivo quando o contexto fecha.
      final code = await runCodegen(
        browserName: 'chromium',
        url: server.url('/recorder-page'),
        headless: true,
        quiet: true,
        isUnderTest: true,
        timeout: const Duration(seconds: 60),
        onReady: (page) async {
          await _waitForRecordingMode(page);
          await page.click('#submit-button');
          await Future<void>.delayed(const Duration(milliseconds: 800));
          await page.context().close();
        },
      );
      expect(code,
          contains("import 'package:playwright_test/playwright_test.dart'"));
      expect(code, contains("getByRole('button', name: 'Submit').click()"));
    }, timeout: const Timeout(Duration(minutes: 4)));
  });
}

/// Espera a pagina confirmar que ja leu o estado `recording`.
Future<void> _waitForRecordingMode(Page page) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (DateTime.now().isBefore(deadline)) {
    final mode = await page.evaluate(
        '() => window.__pwRecorder && window.__pwRecorder._recorder.state.mode');
    if (mode == 'recording') return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw StateError('O recorder da pagina nao entrou em modo recording');
}

import 'dart:convert';
import 'dart:io';

import 'package:playwright_test/playwright_test.dart';

/// Uma suite que **tem de falhar**, para o relatorio ter o que mostrar.
///
/// Nao termina em `_test.dart` de proposito: `dart test` nao a pega sozinho.
/// Quem a roda e `report_end_to_end_test.dart`, que gera o relatorio dela e
/// depois o abre no Chromium deste porte para ler de volta o que a pagina
/// desenhou. Um relatorio que gera e nao renderiza nao prova nada, e a unica
/// forma de saber que renderiza e essa.
///
/// A saida dos artefatos vem do ambiente porque duas frentes rodando ao mesmo
/// tempo nao podem dividir `test-results/`.
void main() {
  final artefatos = Platform.environment['PW_DART_ARTEFATOS'] ??
      'test-results/relatorio-child';
  final opcoes = PlaywrightTestOptions(artifactsPath: artefatos);

  playwrightGroup('relatorio', () {
    playwrightTest('um teste que passa', (t) async {
      await t.page.setContent('<h1 id="ok">tudo certo</h1>');
      await expectLocator(t.page.locator('#ok')).toBeVisible();
    }, options: opcoes);

    playwrightTest('um teste com passos e um anexo', (t) async {
      await step('abre a pagina', () async {
        await t.page.setContent('<h1 id="ok">com passos</h1>');
      });
      await step('anexa o que viu', () async {
        await attach('nota',
            body: utf8.encode('o passo chegou ate aqui'),
            contentType: 'text/plain');
        await step('um passo dentro do outro', () async {
          await expectLocator(t.page.locator('#ok')).toBeVisible();
        });
      });
    }, options: opcoes);

    playwrightTest('um teste que falha de proposito', (t) async {
      await t.page.setContent(
          '<h1 id="titulo">esta pagina esta no screenshot da falha</h1>');
      await expectLocator(t.page.locator('#titulo'),
              timeout: const Duration(milliseconds: 300))
          .toHaveText('um texto que nao esta la');
    }, options: opcoes);

    playwrightTest('um teste pulado', (t) async {
      await t.page.setContent('<p>nunca roda</p>');
    }, options: opcoes, skip: 'pulado de proposito');
  });
}

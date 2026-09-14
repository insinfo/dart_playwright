import 'dart:async';

import 'package:playwright/playwright.dart';
// Import de implementacao de proposito: `instrumented` e o unico caminho que
// existe para reportar uma chamada ao gravador de trace, e um passo de teste e
// exatamente isso — uma chamada com nome proprio. A alternativa seria montar o
// par before/after na mao e duplicar o aninhamento por zone que este arquivo ja
// faz certo.
import 'package:playwright/src/instrumented.dart';

/// A pagina do teste em andamento, para que [step] a encontre sozinho.
const _currentPageKey = #playwrightTestCurrentPage;

/// Roda [body] com [page] como a pagina corrente dos passos.
///
/// Zone e nao campo porque o valor tem de sobreviver aos `await` do corpo do
/// teste e continuar certo se dois testes rodarem ao mesmo tempo.
R runWithCurrentPage<R>(Page page, R Function() body) =>
    runZoned(body, zoneValues: {_currentPageKey: page});

/// A pagina que [step] usaria agora, ou null fora de um `playwrightTest`.
Page? get currentStepPage => Zone.current[_currentPageKey] as Page?;

/// Um passo nomeado dentro de um teste.
///
/// ```dart
/// await step('faz login', () async {
///   await t.page.fill('#user', 'ana');
///   await t.page.click('#entrar');
/// });
/// ```
///
/// O passo vira uma linha no trace gravado por `context.tracing`, e as acoes
/// de dentro dele aparecem aninhadas embaixo — e esse o motivo de a feature
/// existir, e nao o nome numa mensagem de erro. O par `before`/`after` sai com
/// `class: Tracing` e `method: tracingGroup`, que e o que o `tracing.group()`
/// do upstream escreve e o que o visualizador oficial sabe desenhar; o
/// aninhamento vem do `parentId` que a instrumentacao ja propaga por zone,
/// entao um passo dentro de outro tambem aninha.
///
/// Devolve o que [body] devolveu, para que o passo possa produzir um valor:
///
/// ```dart
/// final total = await step('conta os itens', () => lista.count());
/// ```
///
/// Se [body] falha, o erro sobe sem alteracao — o passo aparece vermelho no
/// trace e a falha continua sendo a falha original, com o tipo que
/// `package:test` espera.
///
/// [page] so e preciso fora de um `playwrightTest`, ou quando o passo age numa
/// pagina diferente da do teste. Sem pagina nenhuma o passo ainda roda: ele
/// simplesmente nao tem onde ser gravado.
Future<T> step<T>(
  String title,
  FutureOr<T> Function() body, {
  Page? page,
}) {
  final target = page ?? currentStepPage;
  if (target == null) return Future<T>.sync(body);

  final corePage = (target.mainFrame() as FrameImpl).coreFrame.page;
  return instrumented<T>(
    page: corePage,
    type: 'Tracing',
    method: 'tracingGroup',
    title: title,
    body: () async => await body(),
  );
}

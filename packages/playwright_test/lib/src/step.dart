import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:playwright/playwright.dart';
// Import de implementacao de proposito: `instrumented` e o unico caminho que
// existe para reportar uma chamada ao gravador de trace, e um passo de teste e
// exatamente isso — uma chamada com nome proprio. A alternativa seria montar o
// par before/after na mao e duplicar o aninhamento por zone que este arquivo ja
// faz certo.
import 'package:playwright/src/instrumented.dart';

import 'reporting_protocol.dart';

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
///
/// O passo tambem sai no relatorio (`dart run playwright_test:report`), como
/// uma linha aninhada embaixo do teste, com duracao e com os anexos que forem
/// criados dentro dele. Sao dois destinos com a mesma chamada: o trace e para
/// depurar a pagina, o relatorio e para quem le a suite inteira de fora.
Future<T> step<T>(
  String title,
  FutureOr<T> Function() body, {
  Page? page,
}) {
  final target = page ?? currentStepPage;
  // O passo de relatorio envolve o de trace, e nao o contrario: o marcador de
  // fim tem de sair depois de o grupo do trace fechar, senao um anexo criado
  // no fim do passo cairia fora dele.
  return runReportedStep<T>(title, () {
    if (target == null) return Future<T>.sync(body);

    final corePage = (target.mainFrame() as FrameImpl).coreFrame.page;
    return instrumented<T>(
      page: corePage,
      type: 'Tracing',
      method: 'tracingGroup',
      title: title,
      body: () async => await body(),
    );
  });
}

/// Attaches a file to the step that is running, so it shows up in the trace
/// next to that step.
///
/// ```dart
/// await step('checkout', () async {
///   await page.click('#pay');
///   await attach('receipt', body: await page.screenshot(),
///       contentType: 'image/png');
/// });
/// ```
///
/// This is where upstream's `testInfo.attach` lands in the trace: the same
/// `attachments` array on the step's `after` event, which the viewer draws as
/// its Attachments tab. What differs is only the source — upstream has a test
/// runner holding a `TestInfo`, and this port's test layer is `package:test`,
/// which has no such object. So the attachment hangs off the innermost
/// running call, found through the zone the instrumentation already keeps.
///
/// Give it [body] or [path]. A [path] is read here, in the caller's own
/// async frame, because the recorder runs in event handlers and cannot wait
/// for a disk read; the path travels into the trace as well, but what the
/// viewer opens is the copy inside the archive, so the attachment survives
/// the trace being carried to another machine.
///
/// [contentType] decides whether the viewer renders the body inline. Without
/// one it is guessed from the file extension, falling back to
/// `application/octet-stream`.
///
/// Outside a [step] — or with nothing recording — the attachment still reaches
/// the report; it just has no trace to land in, which is what lets an attach
/// stay in the code when tracing is off.
///
/// There are two destinations and one call, the same split [step] has. The
/// trace is for somebody debugging the page frame by frame; the report is for
/// somebody reading the whole suite from outside, who needs to see the
/// screenshot of the failure without downloading anything. Upstream reaches
/// both from one `testInfo.attach` and so does this.
Future<void> attach(
  String name, {
  String? contentType,
  List<int>? body,
  String? path,
}) async {
  if (body == null && path == null) {
    throw ArgumentError('attach needs either a body or a path');
  }
  final resolvedType = contentType ?? _contentTypeFor(path);

  // The report goes first and unconditionally. It takes the path as given
  // rather than the bytes, so attaching a video does not push a base64 copy of
  // it through stdout.
  reportAttachment(
    name,
    contentType: resolvedType,
    path: path,
    body: path == null ? body : null,
  );

  final metadata = currentCallMetadata;
  // Nothing is recording, or this is not inside a step: reading the file
  // would be work whose result nobody can see.
  if (metadata == null) return;
  final bytes = body ?? await File(path!).readAsBytes();
  metadata.attachments.add(CoreCallAttachment(
    name: name,
    contentType: resolvedType,
    body: bytes,
    path: path,
  ));
}

/// The content type a file name suggests. Deliberately short: the viewer only
/// treats a handful specially and shows a download link for everything else.
String _contentTypeFor(String? path) {
  if (path == null) return 'application/octet-stream';
  switch (p.extension(path).toLowerCase()) {
    case '.png':
      return 'image/png';
    case '.jpg':
    case '.jpeg':
      return 'image/jpeg';
    case '.gif':
      return 'image/gif';
    case '.webp':
      return 'image/webp';
    case '.svg':
      return 'image/svg+xml';
    case '.json':
      return 'application/json';
    case '.txt':
    case '.log':
      return 'text/plain';
    case '.html':
      return 'text/html';
    case '.csv':
      return 'text/csv';
    case '.zip':
      return 'application/zip';
    case '.webm':
      return 'video/webm';
    default:
      return 'application/octet-stream';
  }
}

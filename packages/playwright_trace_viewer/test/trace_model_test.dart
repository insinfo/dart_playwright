import 'package:playwright_trace_viewer/playwright_trace_viewer.dart';
import 'package:test/test.dart';

ActionEntry _action({
  required String callId,
  required double startTime,
  required double endTime,
  String className = 'Frame',
  String method = 'click',
  Map<String, dynamic>? params,
  String? parentId,
  String? title,
  TraceError? error,
  List<StackFrame>? stack,
  List<AfterActionTraceEventAttachment>? attachments,
}) =>
    ActionEntry(
      callId: callId,
      startTime: startTime,
      endTime: endTime,
      className: className,
      method: method,
      params: params ?? <String, dynamic>{},
      parentId: parentId,
      title: title,
      error: error,
      stack: stack,
      attachments: attachments,
    );

ContextEntry _context({
  required String origin,
  double wallTime = 0,
  double monotonicTime = 0,
  double startTime = 0,
  double endTime = 0,
  List<ActionEntry>? actions,
  List<TimelineTraceEvent>? events,
  List<ResourceSnapshot>? resources,
  List<ErrorTraceEvent>? errors,
  bool hasSource = false,
  String browserName = 'chromium',
}) {
  final context = ContextEntry.empty();
  context.origin = origin;
  context.browserName = browserName;
  context.wallTime = wallTime;
  context.monotonicTime = monotonicTime;
  context.startTime = startTime;
  context.endTime = endTime;
  context.hasSource = hasSource;
  if (actions != null) context.actions = actions;
  if (events != null) context.events = events;
  if (resources != null) context.resources = resources;
  if (errors != null) context.errors = errors;
  return context;
}

void main() {
  group('TraceModel', () {
    test('Deve ler um trace so da biblioteca', () {
      final context = _context(
        origin: kTraceOriginLibrary,
        wallTime: 1700000000000,
        monotonicTime: 1000,
        startTime: 1000,
        endTime: 2000,
        actions: [
          _action(callId: 'a@1', startTime: 1100, endTime: 1200),
          _action(
              callId: 'a@2',
              startTime: 1300,
              endTime: 1400,
              method: 'title',
              title: 'Get page title'),
        ],
      );
      final model = TraceModel('trace.zip', [context]);

      expect(model.browserName, 'chromium');
      expect(model.startTime, 1000);
      expect(model.endTime, 2000);
      expect(model.hasStepData, isFalse);
      expect(model.actions.map((a) => a.callId), ['a@1', 'a@2']);
      // O grupo vem da tabela do protocolo quando a acao nao o traz.
      expect(model.actions[1].group, ActionGroup.getter);
      expect(model.actionCounters[ActionGroup.getter], 1);
      // Sem filtro, so aparece o que nao tem grupo.
      expect(model.filteredActions(const []).map((a) => a.callId), ['a@1']);
      expect(model.filteredActions([ActionGroup.getter]).map((a) => a.callId),
          ['a@1', 'a@2']);
    });

    test('Deve juntar o contexto da biblioteca com o do runner', () {
      // Os dois relogios monotonicos estao 500ms fora de fase; so o par
      // wallTime/monotonicTime de cada contexto revela isso.
      final library = _context(
        origin: kTraceOriginLibrary,
        wallTime: 1700000001000,
        monotonicTime: 1000,
        startTime: 1000,
        endTime: 2000,
        actions: [
          _action(callId: 'a@1', startTime: 1100, endTime: 1200),
        ],
        events: [
          EventTraceEvent(
              time: 1150, className: 'BrowserContext', method: 'page'),
        ],
      );
      final runner = _context(
        origin: kTraceOriginTestRunner,
        wallTime: 1700000001000,
        monotonicTime: 1500,
        startTime: 1500,
        endTime: 2500,
        actions: [
          _action(
            callId: 'a@1',
            startTime: 1600,
            endTime: 1700,
            error: TraceError(message: 'falhou', name: 'Error'),
            attachments: [
              AfterActionTraceEventAttachment(
                  name: 'screenshot', contentType: 'image/png'),
            ],
          ),
        ],
      );

      final model = TraceModel('trace.zip', [library, runner]);

      expect(model.hasStepData, isTrue);
      expect(model.actions, hasLength(1));
      final action = model.actions.single;
      // O tempo do runner vence, para preservar a ordem que o cliente viu.
      expect(action.startTime, 1600);
      expect(action.endTime, 1700);
      expect(action.error!.message, 'falhou');
      expect(action.attachments!.single.name, 'screenshot');
      // O evento da biblioteca foi deslocado para o relogio do runner.
      expect(model.events.single.time, 1650);
      expect(model.attachments.single.callId, 'a@1');
      expect(model.visibleAttachments, hasLength(1));
      // Com um contexto de runner, os erros exibidos sao os eventos `error`
      // dele, nao os das acoes: a mensagem util e a que o runner formatou.
      expect(model.errorDescriptors, isEmpty);
      expect(model.failedAction()!.callId, 'a@1');
    });

    test('Deve esconder o anexo que comeca com sublinhado', () {
      final context = _context(
        origin: kTraceOriginLibrary,
        actions: [
          _action(
            callId: 'a@1',
            startTime: 1,
            endTime: 2,
            attachments: [
              AfterActionTraceEventAttachment(
                  name: '_interno', contentType: 'text/plain'),
              AfterActionTraceEventAttachment(
                  name: 'relatorio', contentType: 'text/plain'),
            ],
          ),
        ],
      );
      final model = TraceModel('trace.zip', [context]);
      expect(model.attachments, hasLength(2));
      expect(model.visibleAttachments.map((a) => a.name), ['relatorio']);
    });

    test('Deve montar a arvore de acoes e herdar a pilha do pai', () {
      final parentStack = [
        StackFrame(file: 'test/a_test.dart', line: 10, column: 3)
      ];
      final context = _context(
        origin: kTraceOriginLibrary,
        actions: [
          _action(
              callId: 'a@1',
              startTime: 10,
              endTime: 40,
              method: 'click',
              stack: parentStack),
          _action(
              callId: 'a@2',
              startTime: 20,
              endTime: 30,
              parentId: 'a@1',
              method: 'waitForSelector'),
          _action(callId: 'a@3', startTime: 50, endTime: 60, method: 'goto'),
        ],
      );
      final model = TraceModel('trace.zip', [context]);
      final tree = buildActionTree(model.actions);

      expect(tree.rootItem.children.map((i) => i.id), ['a@1', 'a@3']);
      expect(tree.itemMap['a@1']!.children.map((i) => i.id), ['a@2']);
      expect(tree.itemMap['a@2']!.parent!.id, 'a@1');
      // A filha nao tinha pilha; herdou a da mae, senao a aba Source fica vazia.
      expect(
          model.actions.firstWhere((a) => a.callId == 'a@2').stack!.single.file,
          'test/a_test.dart');

      expect(model.renderActionTree(), [
        'Click',
        '  Wait for selector',
        'Navigate',
      ]);
    });

    test('Deve ligar cada acao a anterior e a proxima', () {
      final context = _context(
        origin: kTraceOriginLibrary,
        actions: [
          _action(callId: 'a@1', startTime: 10, endTime: 20),
          _action(callId: 'a@2', startTime: 30, endTime: 40),
          _action(callId: 'a@3', startTime: 50, endTime: 60),
        ],
      );
      final model = TraceModel('trace.zip', [context]);
      expect(nextActionByStartTime(model.actions[0])!.callId, 'a@2');
      expect(previousActionByEndTime(model.actions[2])!.callId, 'a@2');
      expect(nextActionByStartTime(model.actions[2]), isNull);
      expect(previousActionByEndTime(model.actions[0]), isNull);
    });

    test('Deve recortar os eventos de cada acao, pulando as rotas', () {
      final context = _context(
        origin: kTraceOriginLibrary,
        actions: [
          _action(callId: 'a@1', startTime: 10, endTime: 100),
          _action(
              callId: 'r@1',
              startTime: 20,
              endTime: 30,
              className: 'Route',
              method: 'continue'),
          _action(callId: 'a@2', startTime: 200, endTime: 300),
        ],
        events: [
          ConsoleMessageTraceEvent(
            time: 15,
            messageType: 'error',
            text: 'boom',
            location: ConsoleMessageLocation(
                url: 'http://localhost/', lineNumber: 1, columnNumber: 1),
          ),
          ConsoleMessageTraceEvent(
            time: 25,
            messageType: 'warning',
            text: 'aviso',
            location: ConsoleMessageLocation(
                url: 'http://localhost/', lineNumber: 1, columnNumber: 1),
          ),
          EventTraceEvent(
              time: 40, className: 'Page', method: 'pageError', params: {}),
          ConsoleMessageTraceEvent(
            time: 250,
            messageType: 'log',
            text: 'depois',
            location: ConsoleMessageLocation(
                url: 'http://localhost/', lineNumber: 1, columnNumber: 1),
          ),
        ],
      );
      final model = TraceModel('trace.zip', [context]);
      final first = model.actions.firstWhere((a) => a.callId == 'a@1');

      // A proxima acao e a rota; ela e pulada, entao a janela vai ate a@2.
      expect(model.eventsForAction(first), hasLength(3));
      final stats = model.stats(first);
      expect(stats.errors, 2);
      expect(stats.warnings, 1);
    });

    test('Deve nomear quem emitiu cada requisicao', () {
      final page = PageEntry(pageId: 'page@1');
      final context = _context(
        origin: kTraceOriginLibrary,
        resources: [
          HarEntry(
            startedDateTime: '2026-09-19T00:00:00.000Z',
            time: 1,
            monotonicTime: 20,
            pageref: 'page@1',
            request: HarRequest(method: 'GET', url: 'http://localhost/a'),
            response: HarResponse(
                status: 200,
                content: HarContent(size: 1, mimeType: 'text/html')),
          ),
          HarEntry(
            startedDateTime: '2026-09-19T00:00:00.000Z',
            time: 1,
            monotonicTime: 10,
            apiRequestRef: 'api-request-context@1',
            request: HarRequest(method: 'POST', url: 'http://localhost/api'),
            response: HarResponse(
                status: 200,
                content: HarContent(size: 1, mimeType: 'application/json')),
          ),
          HarEntry(
            startedDateTime: '2026-09-19T00:00:00.000Z',
            time: 1,
            monotonicTime: 30,
            serviceWorkerRef: 'sw@1',
            request: HarRequest(method: 'GET', url: 'http://localhost/sw.js'),
            response: HarResponse(
                status: 200,
                content:
                    HarContent(size: 1, mimeType: 'application/javascript')),
          ),
        ],
      );
      context.pages.add(page);

      final model = TraceModel('trace.zip', [context]);
      // Ordenadas por tempo monotonico.
      expect(model.resources.map((r) => r.request.url), [
        'http://localhost/api',
        'http://localhost/a',
        'http://localhost/sw.js',
      ]);
      expect(model.resourceOwnerRefToTitle['page@1'], 'page#1');
      expect(model.resourceOwnerRefToTitle['api-request-context@1'], 'api#1');
      expect(model.resourceOwnerRefToTitle['sw@1'], 'service-worker#1');
      expect(model.resources.first.id,
          'api-request-context@1-2026-09-19T00:00:00.000Z-http://localhost/api');
    });

    test('Deve descrever os erros a partir das acoes quando nao ha runner', () {
      final context = _context(
        origin: kTraceOriginLibrary,
        hasSource: true,
        actions: [
          _action(callId: 'a@1', startTime: 10, endTime: 20),
          _action(
            callId: 'a@2',
            startTime: 30,
            endTime: 40,
            error: TraceError(message: 'nao achou', name: 'TimeoutError'),
            stack: [
              StackFrame(file: 'test/a_test.dart', line: 12, column: 5),
            ],
          ),
        ],
      );
      final model = TraceModel('trace.zip', [context]);

      expect(model.hasSource, isTrue);
      expect(model.failedAction()!.callId, 'a@2');
      expect(model.errorDescriptors.single.message, 'nao achou');
      expect(model.sources.keys, ['test/a_test.dart']);
      expect(model.sources['test/a_test.dart']!.errors.single.line, 12);
    });

    test('Deve descrever os erros do runner quando ele gravou', () {
      final library = _context(origin: kTraceOriginLibrary);
      final runner = _context(
        origin: kTraceOriginTestRunner,
        monotonicTime: 10,
        wallTime: 10,
        errors: [
          ErrorTraceEvent(
            message: 'expect(received).toBe(expected)',
            stack: [StackFrame(file: 'test/a_test.dart', line: 3, column: 1)],
          ),
          ErrorTraceEvent(message: ''),
        ],
      );
      final model = TraceModel('trace.zip', [library, runner]);
      expect(model.errorDescriptors, hasLength(1));
      expect(model.errorDescriptors.single.message,
          'expect(received).toBe(expected)');
      // Sem acao, o erro do runner nao marca linha em fonte nenhuma.
      expect(model.sources, isEmpty);
    });

    test('Deve montar uma URL relativa carregando a do trace', () {
      final model = TraceModel('http://localhost:1234/trace.zip',
          [_context(origin: kTraceOriginLibrary)]);
      expect(model.createRelativeUrl('snapshot/call@1?phase=before'),
          'snapshot/call@1?phase=before&trace=http%3A%2F%2Flocalhost%3A1234%2Ftrace.zip');
    });

    test('Deve saber se ha snapshot, screenshot e aria snapshot por chamada',
        () {
      final context = _context(origin: kTraceOriginLibrary);
      context.domSnapshots
          .add(const DomSnapshotRef(callId: 'a@1', phase: ActionPhase.before));
      context.screenshots.add(ScreenshotTraceEvent(
        callId: 'a@1',
        phase: ActionPhase.after,
        pageId: 'page@1',
        timestamp: 10,
        file: 'resources/x',
      ));
      context.ariaSnapshots.add(AriaSnapshotTraceEvent(
        callId: 'a@1',
        phase: ActionPhase.before,
        pageId: 'page@1',
        timestamp: 10,
        file: 'resources/y',
      ));

      final model = TraceModel('trace.zip', [context]);
      expect(model.hasDomSnapshots, isTrue);
      expect(model.hasAriaSnapshots, isTrue);
      expect(model.hasDomSnapshotForCall('a@1', ActionPhase.before), isTrue);
      expect(model.hasDomSnapshotForCall('a@1', ActionPhase.after), isFalse);
      expect(model.screenshotForCall('a@1', ActionPhase.after)!.file,
          'resources/x');
      expect(model.ariaSnapshotForCall('a@1', ActionPhase.before)!.file,
          'resources/y');
    });
  });
}

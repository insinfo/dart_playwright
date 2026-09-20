import 'dart:convert';

import 'package:playwright_trace_viewer/playwright_trace_viewer.dart';
import 'package:playwright_trace_viewer/src/versions/trace_v3.dart';
import 'package:playwright_trace_viewer/src/versions/trace_v4.dart';
import 'package:playwright_trace_viewer/src/versions/trace_v5.dart';
import 'package:playwright_trace_viewer/src/versions/trace_v6.dart';
import 'package:playwright_trace_viewer/src/versions/trace_v7.dart';
import 'package:playwright_trace_viewer/src/versions/trace_v8.dart';
import 'package:playwright_trace_viewer/src/versions/trace_v9.dart';
import 'package:test/test.dart';

/// Um modernizador pronto para receber linhas, com o contexto e o
/// armazenamento de snapshots que ele preenche.
class _Fixture {
  final ContextEntry context = ContextEntry.empty();
  late final SnapshotStorage storage = SnapshotStorage();
  late final TraceModernizer modernizer = TraceModernizer(context, storage);

  void append(List<Map<String, dynamic>> events) {
    modernizer.appendTrace(events.map(jsonEncode).join('\n'));
  }

  List<ActionEntry> get actions => modernizer.actions();
}

void main() {
  group('TraceModernizer', () {
    test('Deve recusar um trace de versao mais nova que a do leitor', () {
      final fixture = _Fixture();
      expect(
        () => fixture.append([
          ContextCreatedTraceEventV9(
            version: kLatestTraceVersion + 1,
            origin: 'library',
            browserName: 'chromium',
            platform: 'win32',
            wallTime: 1700000000000,
            monotonicTime: 1000,
          ).toJson(),
        ]),
        throwsA(isA<TraceVersionError>()),
      );
    });

    test('Deve aceitar a versao 9 que o gravador deste porte emite', () {
      final fixture = _Fixture();
      fixture.append([
        ContextCreatedTraceEventV9(
          origin: 'library',
          browserName: 'chromium',
          platform: 'win32',
          playwrightVersion: '1.62.0',
          wallTime: 1700000000000,
          monotonicTime: 1000,
          options: {
            'viewport': {'width': 900, 'height': 600}
          },
          sdkLanguage: 'dart',
        ).toJson(),
        BeforeActionTraceEventV9(
          callId: 'abcd@1',
          startTime: 1100,
          title: 'Click',
          className: 'Frame',
          method: 'click',
          params: {'selector': '#load'},
        ).toJson(),
        InputActionTraceEventV9(
          callId: 'abcd@1',
          point: const PointV3(x: 10, y: 20),
          box: (x: 1, y: 2, width: 30, height: 40),
        ).toJson(),
        LogTraceEventV6(
          callId: 'abcd@1',
          time: 1150,
          message: 'waiting for locator',
        ).toJson(),
        AfterActionTraceEventV9(callId: 'abcd@1', endTime: 1200).toJson(),
      ]);

      expect(fixture.context.origin, kTraceOriginLibrary);
      expect(fixture.context.browserName, 'chromium');
      expect(fixture.context.playwrightVersion, '1.62.0');
      expect(fixture.context.sdkLanguage, 'dart');
      expect(fixture.context.options.viewport?.width, 900);

      final actions = fixture.actions;
      expect(actions, hasLength(1));
      final action = actions.single;
      // Sem stepId, a versao 9 chega a 10 com o mesmo id.
      expect(action.callId, 'abcd@1');
      expect(action.title, 'Click');
      expect(action.className, 'Frame');
      expect(action.method, 'click');
      expect(action.params['selector'], '#load');
      expect(action.startTime, 1100);
      expect(action.endTime, 1200);
      expect(action.point?.x, 10);
      expect(action.box?.width, 30);
      expect(action.log.single.message, 'waiting for locator');
      expect(action.log.single.time, 1150);
    });

    test('Deve adotar o stepId como callId ao subir da versao 9 para a 10', () {
      final fixture = _Fixture();
      fixture.append([
        ContextCreatedTraceEventV9(
          origin: 'testRunner',
          browserName: 'chromium',
          platform: 'linux',
          wallTime: 1700000000000,
          monotonicTime: 0,
        ).toJson(),
        BeforeActionTraceEventV9(
          callId: 'call@7',
          stepId: 'step@7',
          startTime: 10,
          className: 'Frame',
          method: 'click',
        ).toJson(),
        BeforeActionTraceEventV9(
          callId: 'call@8',
          stepId: 'step@8',
          parentId: 'call@7',
          startTime: 11,
          className: 'Frame',
          method: 'waitForSelector',
        ).toJson(),
        AfterActionTraceEventV9(callId: 'call@8', endTime: 12).toJson(),
        AfterActionTraceEventV9(callId: 'call@7', endTime: 13).toJson(),
        FrameSnapshotTraceEventV9(
          snapshot: FrameSnapshotV9(
            phase: 'before',
            callId: 'call@7',
            pageId: 'page@1',
            frameId: 'frame@1',
            frameUrl: 'http://localhost/',
            timestamp: 10,
            collectionTime: 1,
            html: const ['HTML', <String, String>{}],
            viewport: (width: 800, height: 600),
            isMainFrame: true,
          ),
        ).toJson(),
      ]);

      final actions = fixture.actions;
      expect(actions.map((a) => a.callId), ['step@7', 'step@8']);
      expect(actions[1].parentId, 'step@7');
      expect(actions[0].endTime, 13);
      // O snapshot segue o mesmo remapeamento, senao o painel nao acha nada.
      expect(fixture.storage.snapshotsForTest(), ['step@7/before']);
      expect(fixture.context.domSnapshots.single.callId, 'step@7');
      expect(fixture.context.domSnapshots.single.phase, ActionPhase.before);
    });

    test('Deve casar as pilhas do .stacks com os ids ja remapeados', () {
      final fixture = _Fixture();
      fixture.append([
        ContextCreatedTraceEventV9(
          origin: 'library',
          browserName: 'chromium',
          platform: 'linux',
          wallTime: 1,
          monotonicTime: 0,
        ).toJson(),
        BeforeActionTraceEventV9(
          callId: 'call@1',
          stepId: 'step@1',
          startTime: 10,
          className: 'Frame',
          method: 'click',
        ).toJson(),
      ]);
      fixture.modernizer.appendStacks(jsonEncode({
        'files': ['test/example_test.dart'],
        'stacks': [
          [
            'call@1',
            [
              [0, 42, 7, 'main']
            ]
          ]
        ],
      }));

      final stack = fixture.actions.single.stack!;
      expect(stack.single.file, 'test/example_test.dart');
      expect(stack.single.line, 42);
      expect(stack.single.column, 7);
      expect(stack.single.function, 'main');
    });

    test('Deve aceitar o id numerico legado do .stacks', () {
      final fixture = _Fixture();
      fixture.append([
        ContextCreatedTraceEventV9(
          origin: 'library',
          browserName: 'chromium',
          platform: 'linux',
          wallTime: 1,
          monotonicTime: 0,
        ).toJson(),
        BeforeActionTraceEventV9(
          callId: 'call@3',
          startTime: 10,
          className: 'Frame',
          method: 'click',
        ).toJson(),
      ]);
      fixture.modernizer.appendStacks(jsonEncode({
        'files': ['a.dart'],
        'stacks': [
          [
            3,
            [
              [0, 1, 2, 'f']
            ]
          ]
        ],
      }));
      expect(fixture.actions.single.stack!.single.file, 'a.dart');
    });

    test('Deve trocar sha1 por file em toda parte, da versao 8 para a 9', () {
      final fixture = _Fixture();
      fixture.append([
        ContextCreatedTraceEventV8(
          origin: 'library',
          browserName: 'chromium',
          platform: 'linux',
          wallTime: 1700000000000,
          monotonicTime: 500,
        ).toJson(),
        BeforeActionTraceEventV8(
          callId: 'call@1',
          startTime: 600,
          title: 'Click',
          className: 'Frame',
          method: 'click',
          beforeSnapshot: 'before@call@1',
        ).toJson(),
        {
          'type': 'after',
          'callId': 'call@1',
          'endTime': 700,
          'afterSnapshot': 'after@call@1',
          'attachments': [
            {'name': 'screenshot', 'contentType': 'image/png', 'sha1': 'aaa'}
          ],
        },
        ScreencastFrameTraceEventV7(
          pageId: 'page@1',
          sha1: 'bbb',
          width: 800,
          height: 600,
          timestamp: 650,
        ).toJson(),
        FrameSnapshotTraceEventV7(
          snapshot: FrameSnapshotV7(
            snapshotName: 'before@call@1',
            callId: 'call@1',
            pageId: 'page@1',
            frameId: 'frame@1',
            frameUrl: 'http://localhost/',
            timestamp: 600,
            collectionTime: 1,
            html: const ['HTML', <String, String>{}],
            resourceOverrides: const [
              ResourceOverrideV3(url: 'http://localhost/a.css', sha1: 'ccc')
            ],
            viewport: (width: 800, height: 600),
            isMainFrame: true,
          ),
        ).toJson(),
        {
          'type': 'resource-snapshot',
          'snapshot': {
            'startedDateTime': '2026-09-19T00:00:00.000Z',
            'time': 1,
            '_monotonicTime': 550,
            '_apiRequest': true,
            'request': {
              'method': 'POST',
              'url': 'http://localhost/api',
              'postData': {'mimeType': 'application/json', '_sha1': 'ddd'},
            },
            'response': {
              'status': 200,
              'content': {'mimeType': 'application/json', '_sha1': 'eee'},
            },
          },
        },
      ]);

      final action = fixture.actions.single;
      expect(action.attachments!.single.file, 'resources/aaa');
      expect(fixture.context.pages.single.screencastFrames.single.file,
          'resources/bbb');
      // O nome do snapshot virou fase, a partir do que a acao dizia.
      expect(fixture.storage.snapshotsForTest(), ['call@1/before']);
      final resource = fixture.context.resources.single;
      expect(resource.request.postData!.file, 'resources/ddd');
      expect(resource.response.content.file, 'resources/eee');
      expect(resource.apiRequestRef, startsWith('api-request-context@'));
    });

    test('Deve transformar apiName em title, da versao 7 para a 8', () {
      final fixture = _Fixture();
      fixture.append([
        ContextCreatedTraceEventV7(
          origin: 'library',
          browserName: 'firefox',
          platform: 'linux',
          wallTime: 1700000000000,
          monotonicTime: 100,
          contextId: 'ctx@1',
        ).toJson(),
        BeforeActionTraceEventV7(
          callId: 'call@1',
          startTime: 200,
          apiName: 'page.click',
          className: 'Frame',
          method: 'click',
        ).toJson(),
        AfterActionTraceEventV7(callId: 'call@1', endTime: 300).toJson(),
      ]);

      final action = fixture.actions.single;
      expect(action.title, 'page.click');
      // Sem stepId no trace, a 8 usa o proprio callId, e a 10 nao mexe nele.
      expect(action.callId, 'call@1');
    });

    test('Deve tirar o log de dentro do after, da versao 5 para a 6', () {
      final fixture = _Fixture();
      fixture.append([
        const ContextCreatedTraceEventV5(
          browserName: 'webkit',
          platform: 'darwin',
          wallTime: 1700000000000,
        ).toJson(),
        const BeforeActionTraceEventV4(
          callId: 'call@1',
          startTime: 10,
          apiName: 'page.goto',
          className: 'Frame',
          method: 'goto',
          wallTime: 1700000000000,
        ).toJson(),
        const AfterActionTraceEventV4(
          callId: 'call@1',
          endTime: 20,
          log: ['navigating to "/"', 'navigated'],
        ).toJson(),
      ]);

      final action = fixture.actions.single;
      expect(
          action.log.map((l) => l.message), ['navigating to "/"', 'navigated']);
      // As linhas nao tinham tempo proprio; a 6 as marca com -1.
      expect(action.log.map((l) => l.time), [-1, -1]);
      // 6->7 cunha o stepId a partir do apiName e do wallTime, e a 10 o adota.
      expect(action.callId, 'page.goto@1700000000000');
    });

    test('Deve juntar as duas metades da mensagem de console, da 4 para a 5',
        () {
      final fixture = _Fixture();
      fixture.append([
        const ContextCreatedTraceEventV4(
          browserName: 'chromium',
          platform: 'linux',
          wallTime: 1700000000000,
          options: BrowserContextEventOptionsV4(),
        ).toJson(),
        // O handle referenciado por guid nos args da mensagem.
        const EventTraceEventV4(
          time: 5,
          className: 'JSHandle',
          method: '__create__',
          params: {
            'guid': 'handle@1',
            'initializer': {'preview': 'Object'},
          },
        ).toJson(),
        const ConsoleMessageTraceEventV4(
          messageType: 'error',
          text: 'boom',
          locationUrl: 'http://localhost/app.js',
          locationLineNumber: 3,
          locationColumnNumber: 9,
          args: [
            {'guid': 'handle@1'}
          ],
          guid: 'console@1',
        ).toJson(),
        const EventTraceEventV4(
          time: 7,
          className: 'BrowserContext',
          method: 'console',
          pageId: 'page@1',
          params: {
            'message': {'guid': 'console@1'}
          },
        ).toJson(),
      ]);

      final console =
          fixture.context.events.whereType<ConsoleMessageTraceEvent>().single;
      expect(console.messageType, 'error');
      expect(console.text, 'boom');
      expect(console.time, 7);
      expect(console.pageId, 'page@1');
      expect(console.location.url, 'http://localhost/app.js');
      expect(console.location.lineNumber, 3);
      expect(console.args!.single.preview, 'Object');
    });

    test('Deve abrir o CallMetadata da versao 3 e descartar o que e interno',
        () {
      final fixture = _Fixture();
      fixture.append([
        const ContextCreatedTraceEventV3(
          browserName: 'chromium',
          platform: 'linux',
          wallTime: 1700000000000,
          options: BrowserContextEventOptionsV3(
            viewport: (width: 1024, height: 768),
          ),
          sdkLanguage: 'javascript',
        ).toJson(),
        const ActionTraceEventV3(
          type: 'action',
          metadata: CallMetadataV3(
            id: 'call@1',
            startTime: 100,
            endTime: 200,
            className: 'Frame',
            method: 'click',
            apiName: 'page.click',
            wallTime: 1700000000000,
            params: {'selector': '#load'},
            snapshots: [
              CallSnapshotV3(title: 'before', snapshotName: 'before@call@1'),
              CallSnapshotV3(title: 'after', snapshotName: 'after@call@1'),
            ],
            stack: [StackFrameV3(file: 'a.js', line: 1, column: 2)],
          ),
        ).toJson(),
        // Interno: some no caminho da 3 para a 4.
        const ActionTraceEventV3(
          type: 'action',
          metadata: CallMetadataV3(
            id: 'call@2',
            startTime: 110,
            endTime: 120,
            className: 'Frame',
            method: 'querySelector',
            internal: true,
          ),
        ).toJson(),
        // Chamada de tracing: idem.
        const ActionTraceEventV3(
          type: 'action',
          metadata: CallMetadataV3(
            id: 'call@3',
            startTime: 130,
            endTime: 140,
            className: 'Tracing',
            method: 'tracingStopChunk',
          ),
        ).toJson(),
        const ActionTraceEventV3(
          type: 'event',
          metadata: CallMetadataV3(
            id: 'event@1',
            startTime: 150,
            endTime: 150,
            className: 'BrowserContext',
            method: 'page',
            pageId: 'page@1',
            params: {'pageId': 'page@1'},
          ),
        ).toJson(),
      ]);

      final actions = fixture.actions;
      expect(actions, hasLength(1));
      final action = actions.single;
      expect(action.title, 'page.click');
      expect(action.className, 'Frame');
      expect(action.method, 'click');
      // A pilha de dentro do CallMetadata nao sobrevive: o 3->4 nao a copia,
      // e e o arquivo .stacks que passa a fornece-la. Upstream faz o mesmo.
      expect(action.stack, isNull);
      // 6->7 cunhou o stepId, 9->10 o adotou como id.
      expect(action.callId, 'page.click@1700000000000');
      expect(fixture.context.events.whereType<EventTraceEvent>().single.method,
          'page');
      expect(fixture.context.pages.map((p) => p.pageId), ['page@1']);
    });

    test('Deve envolver o erro em string da versao 0', () {
      final fixture = _Fixture();
      fixture.append([
        const ContextCreatedTraceEventV3(
          version: 0,
          browserName: 'chromium',
          platform: 'linux',
          wallTime: 1,
          options: BrowserContextEventOptionsV3(),
        ).toJson(),
        {
          'type': 'action',
          'metadata': {
            'id': 'call@1',
            'startTime': 10,
            'endTime': 20,
            'type': 'Frame',
            'method': 'click',
            'apiName': 'page.click',
            'wallTime': 5,
            'log': <String>[],
            'snapshots': <Map<String, dynamic>>[],
            'error': 'strict mode violation',
          },
        },
      ]);

      final action = fixture.actions.single;
      expect(action.error!.name, 'Error');
      expect(action.error!.message, 'strict mode violation');
    });

    test('Deve corrigir o viewport errado do snapshot da versao 1', () {
      final fixture = _Fixture();
      fixture.append([
        const ContextCreatedTraceEventV3(
          version: 1,
          browserName: 'chromium',
          platform: 'linux',
          wallTime: 1,
          options: BrowserContextEventOptionsV3(
            viewport: (width: 1024, height: 768),
          ),
        ).toJson(),
        const ActionTraceEventV3(
          type: 'action',
          metadata: CallMetadataV3(
            id: 'call@1',
            startTime: 10,
            endTime: 20,
            className: 'Frame',
            method: 'click',
            apiName: 'page.click',
            wallTime: 7,
            snapshots: [
              CallSnapshotV3(title: 'before', snapshotName: 'before@call@1'),
            ],
          ),
        ).toJson(),
        {
          'type': 'frame-snapshot',
          'snapshot': {
            'callId': 'call@1',
            'snapshotName': 'before@call@1',
            'pageId': 'page@1',
            'frameId': 'frame@1',
            'frameUrl': 'http://localhost/',
            'timestamp': 10,
            'collectionTime': 1,
            'html': ['HTML', <String, String>{}],
            'resourceOverrides': <Map<String, dynamic>>[],
            'viewport': {'width': 0, 'height': 0},
            'isMainFrame': true,
          },
        },
      ]);

      // O snapshot vinha com um viewport errado; a 2 o troca pelo do contexto.
      final renderer =
          fixture.storage.snapshotForCall('page.click@7', ActionPhase.before)!;
      expect(renderer.viewport().width, 1024);
      expect(renderer.viewport().height, 768);
    });

    test('Deve migrar o recurso antigo para uma entrada HAR, da 2 para a 3',
        () {
      final fixture = _Fixture();
      fixture.append([
        const ContextCreatedTraceEventV3(
          version: 2,
          browserName: 'chromium',
          platform: 'linux',
          wallTime: 1,
          options: BrowserContextEventOptionsV3(),
        ).toJson(),
        {
          'type': 'resource-snapshot',
          'snapshot': {
            'frameId': 'frame@1',
            'url': 'http://localhost/style.css',
            'method': 'GET',
            'requestHeaders': [
              {'name': 'accept', 'value': 'text/css'}
            ],
            'status': 200,
            'responseHeaders': [
              {'name': 'content-type', 'value': 'text/css'}
            ],
            'contentType': 'text/css',
            'responseSha1': 'fff',
            'timestamp': 42,
          },
        },
      ]);

      final resource = fixture.context.resources.single;
      expect(resource.request.url, 'http://localhost/style.css');
      expect(resource.request.method, 'GET');
      expect(resource.request.headers.single.name, 'accept');
      expect(resource.response.status, 200);
      expect(resource.response.content.mimeType, 'text/css');
      // Passou tambem pelo 8->9, que troca _sha1 por _file.
      expect(resource.response.content.file, 'resources/fff');
      expect(resource.monotonicTime, 42);
      expect(resource.frameref, 'frame@1');
    });

    test('Deve sintetizar o context-options quando o trace nao traz um', () {
      final fixture = _Fixture();
      // Sem primeira linha de contexto: o modernizador assume a versao 6.
      fixture.append([
        LogTraceEventV6(callId: 'call@1', time: 5, message: 'ignorada')
            .toJson(),
      ]);
      expect(fixture.context.origin, kTraceOriginTestRunner);
      expect(fixture.context.platform, 'unknown');
      expect(fixture.context.sdkLanguage, 'javascript');
    });

    test('Deve tolerar um log sem a acao correspondente', () {
      final fixture = _Fixture();
      fixture.append([
        ContextCreatedTraceEventV9(
          origin: 'library',
          browserName: 'chromium',
          platform: 'linux',
          wallTime: 1,
          monotonicTime: 0,
        ).toJson(),
        LogTraceEventV6(callId: 'orfa@1', time: 5, message: 'x').toJson(),
      ]);
      expect(fixture.actions, isEmpty);
    });

    test('Deve mover o relogio do contexto com as acoes e os eventos', () {
      final fixture = _Fixture();
      fixture.append([
        ContextCreatedTraceEventV9(
          origin: 'library',
          browserName: 'chromium',
          platform: 'linux',
          wallTime: 1700000000000,
          monotonicTime: 1000,
        ).toJson(),
        BeforeActionTraceEventV9(
          callId: 'a@1',
          startTime: 900,
          className: 'Frame',
          method: 'goto',
        ).toJson(),
        AfterActionTraceEventV9(callId: 'a@1', endTime: 1500).toJson(),
        const EventTraceEventV4(
          time: 2000,
          className: 'BrowserContext',
          method: 'page',
          params: {'pageId': 'page@9'},
        ).toJson(),
      ]);

      expect(fixture.context.startTime, 900);
      expect(fixture.context.endTime, 2000);
      expect(fixture.context.pages.map((p) => p.pageId), ['page@9']);
    });
  });
}

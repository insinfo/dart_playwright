import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:playwright_trace_viewer/playwright_trace_viewer.dart';
import 'package:playwright_trace_viewer/src/versions/trace_v9.dart';
import 'package:test/test.dart';

/// Monta um zip de trace na memoria, do mesmo jeito que o gravador monta um
/// no disco: uma linha JSON por evento e os corpos por caminho relativo.
Uint8List _zip(Map<String, Object> entries) {
  final archive = Archive();
  entries.forEach((name, content) {
    if (content is String) {
      archive.add(ArchiveFile.string(name, content));
    } else {
      archive.add(ArchiveFile.bytes(name, content as List<int>));
    }
  });
  return ZipEncoder().encodeBytes(archive);
}

String _lines(List<Map<String, dynamic>> events) =>
    events.map(jsonEncode).join('\n');

Map<String, dynamic> _harEntry({
  required String url,
  required String file,
  required String mimeType,
  required double monotonicTime,
}) =>
    {
      'type': 'resource-snapshot',
      'snapshot': {
        'startedDateTime': '2026-09-19T00:00:00.000Z',
        'time': 1,
        '_monotonicTime': monotonicTime,
        '_frameref': 'frame@1',
        'request': {
          'method': 'GET',
          'url': url,
          'headers': <Map<String, String>>[],
        },
        'response': {
          'status': 200,
          'statusText': 'OK',
          'headers': [
            {'name': 'content-encoding', 'value': 'gzip'},
            {'name': 'x-teste', 'value': '1'},
          ],
          'content': {'size': 10, 'mimeType': mimeType, '_file': file},
        },
      },
    };

Uint8List _archiveBytes() => _zip({
      'trace.trace': _lines([
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
          title: 'sonda',
        ).toJson(),
        BeforeActionTraceEventV9(
          callId: 'abcd@1',
          startTime: 1100,
          title: 'Navigate',
          subtitle: 'localhost/',
          className: 'Frame',
          method: 'goto',
          params: {'url': 'http://localhost/'},
        ).toJson(),
        LogTraceEventV6(callId: 'abcd@1', time: 1120, message: 'navegando')
            .toJson(),
        AfterActionTraceEventV9(callId: 'abcd@1', endTime: 1200).toJson(),
        // Uma acao que nunca recebeu o after; o loader a fecha pelo filho.
        BeforeActionTraceEventV9(
          callId: 'abcd@2',
          startTime: 1300,
          className: 'Frame',
          method: 'click',
        ).toJson(),
        BeforeActionTraceEventV9(
          callId: 'abcd@3',
          parentId: 'abcd@2',
          startTime: 1310,
          className: 'Frame',
          method: 'waitForSelector',
        ).toJson(),
        AfterActionTraceEventV9(callId: 'abcd@3', endTime: 1400).toJson(),
        ScreencastFrameTraceEventV9(
          pageId: 'page@1',
          file: 'resources/quadro',
          width: 900,
          height: 600,
          timestamp: 1150,
        ).toJson(),
        FrameSnapshotTraceEventV9(
          snapshot: FrameSnapshotV9(
            phase: 'before',
            callId: 'abcd@1',
            pageId: 'page@1',
            frameId: 'frame@1',
            frameUrl: 'http://localhost/',
            timestamp: 1100,
            collectionTime: 1,
            html: const [
              'HTML',
              <String, String>{},
              [
                'BODY',
                <String, String>{},
                [
                  'LINK',
                  {'rel': 'stylesheet', 'href': 'http://localhost/a.css'}
                ],
                'ola'
              ]
            ],
            viewport: (width: 900, height: 600),
            isMainFrame: true,
          ),
        ).toJson(),
      ]),
      'trace.network': _lines([
        _harEntry(
          url: 'http://localhost/a.css',
          file: 'resources/css',
          mimeType: 'text/css; charset=utf-8',
          monotonicTime: 1050,
        ),
      ]),
      'trace.stacks': jsonEncode({
        'files': ['example/tracing_example.dart'],
        'stacks': [
          [
            'abcd@1',
            [
              [0, 77, 5, 'main']
            ]
          ]
        ],
      }),
      'resources/css': 'body { color: red }',
      'resources/quadro': const [1, 2, 3],
    });

void main() {
  group('TraceLoader', () {
    test('Deve ler um zip inteiro e montar o contexto', () async {
      final loader = TraceLoader();
      final progress = <String>[];
      await loader.load(
        ZipTraceLoaderBackend(_archiveBytes()),
        unzipProgress: (done, total) => progress.add('$done/$total'),
      );

      expect(progress, ['1/3', '2/3', '3/3']);
      expect(loader.contextEntries, hasLength(1));
      final context = loader.contextEntries.single;
      expect(context.origin, kTraceOriginLibrary);
      expect(context.title, 'sonda');
      expect(context.hasSource, isFalse);
      expect(
          context.actions.map((a) => a.callId), ['abcd@1', 'abcd@2', 'abcd@3']);
      expect(context.actions.first.log.single.message, 'navegando');
      // A pilha veio do .stacks.
      expect(context.actions.first.stack!.single.line, 77);
      // A acao sem after foi fechada pelo fim da filha.
      expect(context.actions[1].endTime, 1400);
      expect(context.resources.single.request.url, 'http://localhost/a.css');
      expect(context.pages.single.screencastFrames.single.file,
          'resources/quadro');
    });

    test('Deve marcar hasSource quando o zip traz as fontes', () async {
      final bytes = _zip({
        'trace.trace': _lines([
          ContextCreatedTraceEventV9(
            origin: 'library',
            browserName: 'chromium',
            platform: 'win32',
            wallTime: 1,
            monotonicTime: 0,
          ).toJson(),
        ]),
        'resources/src@abc123.txt': 'void main() {}',
      });
      final loader = TraceLoader();
      await loader.load(ZipTraceLoaderBackend(bytes));
      expect(loader.contextEntries.single.hasSource, isTrue);
    });

    test('Deve reclamar de um zip sem .trace', () async {
      final bytes = _zip({'leiame.txt': 'nada aqui'});
      await expectLater(
        TraceLoader().load(ZipTraceLoaderBackend(bytes)),
        throwsA(isA<Exception>()),
      );
    });

    test('Deve devolver o recurso com o tipo que o HAR gravou', () async {
      final loader = TraceLoader();
      await loader.load(ZipTraceLoaderBackend(_archiveBytes()));

      final resource = (await loader.resourceEntry('resources/css'))!;
      expect(utf8.decode(resource.bytes), 'body { color: red }');
      // O charset sai do tipo: o visualizador o define por conta propria.
      expect(resource.contentType, 'text/css');
      // Sem entrada no HAR, nao ha tipo a declarar.
      expect((await loader.resourceEntry('resources/quadro'))!.contentType,
          isNull);
      expect(await loader.resourceEntry('resources/nao-existe'), isNull);
      expect(await loader.hasEntry('trace.network'), isTrue);
      expect(await loader.hasEntry('trace.zip'), isFalse);
    });

    test('Deve manter as acoes abertas de um trace ao vivo', () async {
      final loader = TraceLoader();
      await loader.load(ZipTraceLoaderBackend(_archiveBytes(), live: true));
      // Sem o fechamento gracioso, a acao sem after fica com endTime zero.
      final action = loader.contextEntries.single.actions
          .firstWhere((a) => a.callId == 'abcd@2');
      expect(action.endTime, 0);
    });
  });

  group('SnapshotServer', () {
    late TraceLoader loader;
    late SnapshotServer server;

    setUp(() async {
      loader = TraceLoader();
      await loader.load(ZipTraceLoaderBackend(_archiveBytes()));
      server = SnapshotServer(
        loader.storage(),
        (file) async => (await loader.resourceEntry(file))?.bytes,
      );
    });

    test('Deve servir o snapshot com a politica que so o nonce satisfaz',
        () async {
      final response = server.serveSnapshot(
          'abcd@1', {'phase': 'before'}, 'http://viewer/snapshot/abcd@1');
      expect(response.status, 200);
      expect(response.headers['content-type'], 'text/html; charset=utf-8');
      final csp = response.headers['content-security-policy']!;
      expect(csp, startsWith("script-src 'nonce-"));
      expect(csp, endsWith("object-src 'none'"));
      final html = response.bodyAsString;
      expect(html, contains('<HTML><BODY><LINK'));
      expect(html, contains('ola'));
      // O nonce do cabecalho e o mesmo do script.
      final nonce = RegExp(r"nonce-([0-9a-f]{32})").firstMatch(csp)!.group(1)!;
      expect(html, contains('nonce="$nonce"'));
    });

    test('Deve dar 404 para uma chamada ou fase que nao tem snapshot',
        () async {
      expect(
          server.serveSnapshot('abcd@9', {'phase': 'before'}, 'x').status, 404);
      expect(
          server.serveSnapshot('abcd@1', {'phase': 'after'}, 'x').status, 404);
      expect(server.serveSnapshot('abcd@1', const {}, 'x').status, 404);
    });

    test('Deve descrever o snapshot para o painel', () async {
      final response = server.serveSnapshotInfo('abcd@1', {'phase': 'before'});
      final info = jsonDecode(response.bodyAsString) as Map<String, dynamic>;
      expect(info['viewport'], {'width': 900, 'height': 600});
      expect(info['url'], 'http://localhost/');
      expect(info['timestamp'], 1100);
      expect(response.headers['cache-control'], 'public, max-age=31536000');

      final missing = server.serveSnapshotInfo('abcd@9', {'phase': 'before'});
      expect(jsonDecode(missing.bodyAsString), {'error': 'No snapshot found'});
    });

    test('Deve servir o recurso que a pagina do snapshot pede', () async {
      const snapshotUrl = 'http://viewer/snapshot/abcd@1';
      server.serveSnapshot('abcd@1', {'phase': 'before'}, snapshotUrl);

      final response = await server.serveResource(
        ['http://localhost/a.css#frag'],
        'GET',
        snapshotUrl,
      );
      expect(response.status, 200);
      expect(response.statusText, 'OK');
      expect(utf8.decode(response.body!), 'body { color: red }');
      expect(response.headers['content-type'], 'text/css; charset=utf-8');
      expect(response.headers['x-teste'], '1');
      // O corpo ja esta descomprimido no zip.
      expect(response.headers.contains('content-encoding'), isFalse);
      expect(response.headers['content-length'], '19');
      expect(response.headers['access-control-allow-origin'], '*');
      expect(response.headers['cache-control'], 'public, max-age=31536000');
    });

    test('Deve dar 404 para um recurso que o trace nao gravou', () async {
      const snapshotUrl = 'http://viewer/snapshot/abcd@1';
      server.serveSnapshot('abcd@1', {'phase': 'before'}, snapshotUrl);
      final response = await server
          .serveResource(['http://localhost/b.css'], 'GET', snapshotUrl);
      expect(response.status, 404);
      // Sem o snapshot registrado, nao ha por onde procurar.
      expect(
          (await server.serveResource(
                  ['http://localhost/a.css'], 'GET', 'desconhecido'))
              .status,
          404);
    });

    test('Deve servir o quadro de filme mais proximo', () async {
      final response =
          await server.serveClosestScreenshot('abcd@1', {'phase': 'before'});
      expect(response.status, 200);
      expect(response.body, [1, 2, 3]);
      expect(
          (await server.serveClosestScreenshot('abcd@9', {'phase': 'before'}))
              .status,
          404);
    });
  });
}

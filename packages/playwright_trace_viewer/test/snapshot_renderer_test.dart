import 'package:playwright_trace_viewer/playwright_trace_viewer.dart';
import 'package:test/test.dart';

FrameSnapshot _snapshot(
  Object html, {
  String callId = 'call@1',
  ActionPhase phase = ActionPhase.before,
  String frameId = 'frame@1',
  double timestamp = 100,
  String? doctype,
  List<ResourceOverride> resourceOverrides = const [],
  bool isMainFrame = true,
  double? wallTime,
}) =>
    FrameSnapshot(
      phase: phase,
      callId: callId,
      pageId: 'page@1',
      frameId: frameId,
      frameUrl: 'http://localhost/',
      timestamp: timestamp,
      wallTime: wallTime,
      collectionTime: 1,
      doctype: doctype,
      html: html,
      resourceOverrides: List<ResourceOverride>.from(resourceOverrides),
      viewport: TraceSize(width: 800, height: 600),
      isMainFrame: isMainFrame,
    );

/// Renderiza e devolve so o corpo, sem o prefixo que todo snapshot carrega.
String _body(String html) {
  const marker = '</script>';
  return html.substring(html.indexOf(marker) + marker.length);
}

HarEntry _resource({
  required String url,
  String method = 'GET',
  int status = 200,
  String mimeType = 'text/css',
  String? file,
  String? frameref,
  required double monotonicTime,
}) =>
    HarEntry(
      startedDateTime: '2026-09-19T00:00:00.000Z',
      time: 1,
      monotonicTime: monotonicTime,
      frameref: frameref,
      request: HarRequest(method: method, url: url),
      response: HarResponse(
        status: status,
        content: HarContent(size: 1, mimeType: mimeType, file: file),
      ),
    );

void main() {
  group('SnapshotRenderer', () {
    test('Deve desenhar a arvore com texto escapado e tags que se fecham', () {
      final storage = SnapshotStorage();
      final renderer = storage.addFrameSnapshot(
        _snapshot([
          'HTML',
          <String, String>{},
          [
            'BODY',
            <String, String>{},
            [
              'P',
              {'class': 'x'},
              'a < b & c'
            ],
            [
              'IMG',
              {'src': 'http://localhost/a.png'}
            ],
          ]
        ], doctype: 'html'),
        const [],
      );

      final rendered = renderer.render();
      expect(rendered.html, startsWith('<!DOCTYPE html>'));
      expect(rendered.html, contains('nonce="${rendered.scriptNonce}"'));
      expect(
        _body(rendered.html),
        '<HTML><BODY><P class="x">a &lt; b &amp; c</P>'
        '<IMG src="http://localhost/a.png"></BODY></HTML>',
      );
    });

    test('Deve sanear o doctype forjado', () {
      final storage = SnapshotStorage();
      final renderer = storage.addFrameSnapshot(
        _snapshot(['HTML', <String, String>{}],
            doctype: 'html><script>alert(1)</script'),
        const [],
      );
      expect(renderer.render().html, startsWith('<!DOCTYPE htmlscriptalert1'));
    });

    test('Deve descartar script e atributos de evento de um trace forjado', () {
      final storage = SnapshotStorage();
      final renderer = storage.addFrameSnapshot(
        _snapshot([
          'BODY',
          <String, String>{},
          ['SCRIPT', <String, String>{}, 'alert(1)'],
          [
            'DIV',
            {'onclick': 'alert(1)', 'id': 'ok'}
          ],
        ]),
        const [],
      );
      final body = _body(renderer.render().html);
      expect(body, isNot(contains('SCRIPT')));
      expect(body, isNot(contains('onclick')));
      expect(body, contains('<DIV id="ok">'));
    });

    test('Deve neutralizar um meta http-equiv perigoso', () {
      final storage = SnapshotStorage();
      final renderer = storage.addFrameSnapshot(
        _snapshot([
          'HEAD',
          <String, String>{},
          [
            'META',
            {'http-equiv': 'refresh', 'content': '0;url=http://evil/'}
          ],
          [
            'META',
            {'http-equiv': 'content-type', 'content': 'text/html'}
          ],
        ]),
        const [],
      );
      final body = _body(renderer.render().html);
      expect(body, contains('_http-equiv="refresh"'));
      expect(body, contains('_content="0;url=http://evil/"'));
      // O do whitelist passa intacto.
      expect(body, contains('http-equiv="content-type"'));
    });

    test('Deve renomear src, srcdoc e sandbox de um iframe', () {
      final storage = SnapshotStorage();
      final renderer = storage.addFrameSnapshot(
        _snapshot([
          'BODY',
          <String, String>{},
          [
            'IFRAME',
            {
              'src': '/snapshot/frame@2',
              'srcdoc': '<script>alert(1)</script>',
              'sandbox': 'allow-scripts',
            }
          ],
        ]),
        const [],
      );
      final body = _body(renderer.render().html);
      expect(body, contains('__playwright_src__="/snapshot/frame@2"'));
      expect(body, contains('__playwright_srcdoc__='));
      expect(body, contains('__playwright_sandbox__="allow-scripts"'));
      expect(body, isNot(contains(' src="')));
    });

    test('Deve renomear noscript para que o visualizador o desenhe', () {
      final storage = SnapshotStorage();
      final renderer = storage.addFrameSnapshot(
        _snapshot(['NOSCRIPT', <String, String>{}, 'sem script']),
        const [],
      );
      expect(
          _body(renderer.render().html), '<X-NOSCRIPT>sem script</X-NOSCRIPT>');
    });

    test('Deve mover o conteudo de style para um atributo', () {
      final storage = SnapshotStorage();
      final renderer = storage.addFrameSnapshot(
        _snapshot([
          'STYLE',
          <String, String>{},
          'body { background: url("vscode-file://vscode-app/x.png") }'
        ]),
        const [],
      );
      final body = _body(renderer.render().html);
      expect(
        body,
        '<STYLE __playwright_style_content__="body { background: '
        'url(&quot;https://pw-vscode-file--vscode-app/x.png&quot;) }"></STYLE>',
      );
    });

    test('Deve usar o currentSrc de uma imagem e desligar src e srcset', () {
      final storage = SnapshotStorage();
      final renderer = storage.addFrameSnapshot(
        _snapshot([
          'IMG',
          {
            'src': 'http://localhost/small.png',
            'srcset': 'http://localhost/big.png 2x',
            '__playwright_current_src__': 'http://localhost/big.png',
          }
        ]),
        const [],
      );
      final body = _body(renderer.render().html);
      expect(body, contains('_src="http://localhost/small.png"'));
      expect(body, contains('_srcset="http://localhost/big.png 2x"'));
      expect(body, contains(' src="http://localhost/big.png"'));
    });

    test('Deve resolver a referencia [[n, i]] no snapshot anterior', () {
      final storage = SnapshotStorage();
      final first = _snapshot([
        'HTML',
        <String, String>{},
        [
          'BODY',
          <String, String>{},
          [
            'DIV',
            {'id': 'a'},
            'ola'
          ],
        ]
      ], callId: 'call@1');
      storage.addFrameSnapshot(first, const []);

      // Numeracao em pos-ordem, so dos nos que nao sao referencia:
      // 0 = "ola", 1 = DIV, 2 = BODY, 3 = HTML.
      expect(snapshotNodes(first), hasLength(4));
      expect((snapshotNodes(first)[1] as List)[0], 'DIV');

      final second = _snapshot([
        'HTML',
        <String, String>{},
        [
          'BODY',
          <String, String>{},
          [
            [1, 1]
          ],
        ]
      ], callId: 'call@2', timestamp: 200);
      final renderer = storage.addFrameSnapshot(second, const []);

      expect(_body(renderer.render().html),
          '<HTML><BODY><DIV id="a">ola</DIV></BODY></HTML>');
    });

    test('Deve ignorar uma referencia que aponta para fora', () {
      final storage = SnapshotStorage();
      final renderer = storage.addFrameSnapshot(
        _snapshot([
          'BODY',
          <String, String>{},
          [
            [5, 0]
          ],
          [
            [0, 99]
          ],
        ]),
        const [],
      );
      expect(_body(renderer.render().html), '<BODY></BODY>');
    });

    test('Deve servir o ultimo recurso que nao e 304, e o do proprio frame',
        () {
      final storage = SnapshotStorage();
      storage.addResource(_resource(
          url: 'http://localhost/a.css',
          file: 'resources/velho',
          monotonicTime: 10));
      storage.addResource(_resource(
          url: 'http://localhost/a.css',
          status: 304,
          file: 'resources/nao-modificado',
          monotonicTime: 20));
      storage.addResource(_resource(
          url: 'http://localhost/a.css',
          file: 'resources/deste-frame',
          frameref: 'frame@1',
          monotonicTime: 30));
      storage.addResource(_resource(
          url: 'http://localhost/a.css',
          file: 'resources/depois-do-snapshot',
          monotonicTime: 200));

      final renderer = storage.addFrameSnapshot(
        _snapshot(['HTML', <String, String>{}], timestamp: 100),
        const [],
      );
      storage.finalizeStorage();

      final resource = renderer.resourceByUrl('http://localhost/a.css', 'GET')!;
      expect(resource.response.content.file, 'resources/deste-frame');
      expect(renderer.resourceByUrl('http://localhost/b.css', 'GET'), isNull);
      expect(renderer.resourceByUrl('http://localhost/a.css', 'POST'), isNull);
    });

    test('Deve aplicar o override do snapshot, inclusive o que usa ref', () {
      final storage = SnapshotStorage();
      final original = _resource(
          url: 'http://localhost/a.css',
          file: 'resources/original',
          monotonicTime: 10);
      storage.addResource(original);

      final first = _snapshot(
        ['HTML', <String, String>{}],
        callId: 'call@1',
        timestamp: 100,
        resourceOverrides: [
          ResourceOverride(
              url: 'http://localhost/a.css', file: 'resources/editado'),
        ],
      );
      final firstRenderer = storage.addFrameSnapshot(first, const []);

      // O segundo snapshot nao repete o corpo: aponta para um atras.
      final second = _snapshot(
        ['HTML', <String, String>{}],
        callId: 'call@2',
        timestamp: 200,
        resourceOverrides: [
          ResourceOverride(url: 'http://localhost/a.css', ref: 1),
        ],
      );
      final secondRenderer = storage.addFrameSnapshot(second, const []);
      storage.finalizeStorage();

      expect(
          firstRenderer
              .resourceByUrl('http://localhost/a.css', 'GET')!
              .response
              .content
              .file,
          'resources/editado');
      expect(
          secondRenderer
              .resourceByUrl('http://localhost/a.css', 'GET')!
              .response
              .content
              .file,
          'resources/editado');
      // O recurso guardado continua apontando para o corpo gravado.
      expect(original.response.content.file, 'resources/original');
      expect(storage.hasResourceOverride('http://localhost/a.css'), isTrue);
      expect(storage.hasResourceOverride('http://localhost/b.css'), isFalse);
    });

    test('Deve achar o quadro de filme mais proximo do snapshot', () {
      final storage = SnapshotStorage();
      final frames = [
        ScreencastFrameTraceEvent(
            pageId: 'page@1',
            file: 'resources/f1',
            width: 8,
            height: 6,
            timestamp: 10),
        ScreencastFrameTraceEvent(
            pageId: 'page@1',
            file: 'resources/f2',
            width: 8,
            height: 6,
            timestamp: 90),
        ScreencastFrameTraceEvent(
            pageId: 'page@1',
            file: 'resources/f3',
            width: 8,
            height: 6,
            timestamp: 300),
      ];
      final renderer = storage.addFrameSnapshot(
        _snapshot(['HTML', <String, String>{}], timestamp: 100),
        frames,
      );
      expect(renderer.closestScreenshot(), 'resources/f2');
    });

    test('Deve indexar o snapshot por chamada e fase, e achar o main frame',
        () {
      final storage = SnapshotStorage();
      final child = _snapshot(['HTML', <String, String>{}],
          frameId: 'frame@2', isMainFrame: false);
      storage.addFrameSnapshot(child, const []);
      final main = _snapshot(['HTML', <String, String>{}]);
      storage.addFrameSnapshot(main, const []);

      expect(storage.snapshotsForTest(), ['call@1/before']);
      expect(
          storage
              .snapshotForCall('call@1', ActionPhase.before)!
              .snapshot()
              .frameId,
          'frame@1');
      expect(
          storage
              .snapshotForCall('call@1', ActionPhase.before, 'frame@2')!
              .snapshot()
              .frameId,
          'frame@2');
      expect(storage.snapshotForCall('call@1', ActionPhase.after), isNull);
      expect(storage.snapshotForCall('call@9', ActionPhase.before), isNull);
    });
  });

  group('rewriteUrlForCustomProtocol', () {
    test('Deve deixar passar os esquemas conhecidos', () {
      expect(rewriteUrlForCustomProtocol('https://example.com/a?b=1'),
          'https://example.com/a?b=1');
      expect(rewriteUrlForCustomProtocol('about:blank'), 'about:blank');
      expect(
          rewriteUrlForCustomProtocol('data:text/html,x'), 'data:text/html,x');
    });

    test('Deve reescrever um esquema proprio para o dominio do visualizador',
        () {
      expect(rewriteUrlForCustomProtocol('vscode-file://vscode-app/out/x.js'),
          'https://pw-vscode-file--vscode-app/out/x.js');
    });

    test('Deve reescrever file, que nao tem host', () {
      expect(rewriteUrlForCustomProtocol('file:///tmp/a.html'),
          'https://pw-file/tmp/a.html');
    });

    test('Deve matar javascript: e vbscript:', () {
      expect(rewriteUrlForCustomProtocol('javascript:alert(1)'),
          'javascript:void(0)');
      expect(rewriteUrlForCustomProtocol('vbscript:msgbox(1)'),
          'javascript:void(0)');
    });

    test('Deve tirar o prefixo legado de blob', () {
      expect(
        rewriteUrlForCustomProtocol(
            'http://playwright.bloburl/#https://example.com/x'),
        'https://example.com/x',
      );
    });

    test('Deve devolver uma URL relativa sem mexer', () {
      expect(rewriteUrlForCustomProtocol('/a/b.css'), '/a/b.css');
    });
  });

  group('rewriteUrlsInStyleSheetForCustomProtocol', () {
    test('Deve reescrever so os esquemas proprios', () {
      expect(
        rewriteUrlsInStyleSheetForCustomProtocol(
            'a { background: url("https://x/y") } '
            'b { background: url(vscode-file://vscode-app/z) }'),
        'a { background: url("https://x/y") } '
        'b { background: url(https://pw-vscode-file--vscode-app/z) }',
      );
    });
  });
}

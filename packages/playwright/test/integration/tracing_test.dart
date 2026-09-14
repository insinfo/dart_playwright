import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:playwright/playwright.dart';
import 'package:test/test.dart';

import 'test_server.dart';

/// The trace archive, read back the way the viewer reads it.
class _Trace {
  final Map<String, List<int>> files;

  _Trace(this.files);

  factory _Trace.read(String path) {
    final archive = ZipDecoder().decodeBytes(File(path).readAsBytesSync());
    return _Trace({
      for (final file in archive.files)
        if (file.isFile) file.name: file.content as List<int>,
    });
  }

  List<Map<String, dynamic>> lines(String name) => [
        for (final line in utf8.decode(files[name]!).split('\n'))
          if (line.trim().isNotEmpty) jsonDecode(line) as Map<String, dynamic>,
      ];

  List<Map<String, dynamic>> get events => lines('trace.trace');
  List<Map<String, dynamic>> get network => lines('trace.network');

  Iterable<Map<String, dynamic>> ofType(String type) =>
      events.where((event) => event['type'] == type);
}

/// The recorder writes a trace that `npx playwright show-trace` opens. These
/// tests check it against the format contract of upstream's
/// `packages/isomorphic/trace/versions/traceV9.ts` — the one the shipped
/// viewer reads — entry by entry, on all three engines.
void main() {
  group('Tracing', () {
    late Playwright playwright;
    late TestServer server;
    late Directory outputDir;

    setUpAll(() async {
      server = await TestServer.start();
      playwright = await Playwright.create();
      outputDir = Directory.systemTemp.createTempSync('pw-dart-trace-test-');
    });

    tearDownAll(() async {
      await server.stop();
      if (outputDir.existsSync()) outputDir.deleteSync(recursive: true);
    });

    var traceOrdinal = 0;
    String nextPath() => '${outputDir.path}/trace-${traceOrdinal++}.zip';

    for (final browserName in ['chromium', 'firefox', 'webkit']) {
      group('[$browserName]', () {
        late Browser browser;
        var browserLaunched = false;
        late BrowserContext context;
        late Page page;

        setUpAll(() async {
          browser = await switch (browserName) {
            'chromium' => playwright.chromium.launch(headless: true),
            'firefox' => playwright.firefox.launch(headless: true),
            _ => playwright.webkit.launch(headless: true),
          };
          browserLaunched = true;
        });

        setUp(() async {
          context =
              await browser.newContext(viewport: (width: 800, height: 600));
        });

        tearDown(() async {
          await context.close();
        });

        tearDownAll(() async {
          if (browserLaunched) await browser.close();
        });

        test('Deve gravar um zip com trace.trace, trace.network e recursos',
            () async {
          await context.tracing.start(title: 'probe');
          page = await context.newPage();
          await page.goto(server.url('/resources'));
          await page.locator('#styled').innerText();
          final path = nextPath();
          expect(await context.tracing.stop(path: path), path);

          final trace = _Trace.read(path);
          expect(trace.files.keys, contains('trace.trace'));
          expect(trace.files.keys, contains('trace.network'));

          // The context-options line is the version gate: the viewer refuses a
          // trace whose version it does not know, so this is what decides
          // whether the file opens at all.
          final options = trace.events.first;
          expect(options['type'], 'context-options');
          expect(options['version'], 9);
          expect(options['browserName'], browserName);
          expect(options['title'], 'probe');
          expect(options['origin'], 'library');
          expect(options['wallTime'], isA<int>());
          expect(options['monotonicTime'], isA<num>());
          expect(options['options']['viewport'], {'width': 800, 'height': 600});

          // Every resource is named by the sha1 of its own bytes, which is
          // what lets the same body be stored once however often it is served.
          final resources = trace.files.keys
              .where((name) => name.startsWith('resources/'))
              .toList();
          expect(resources, isNotEmpty);
          for (final name in resources) {
            final sha1Name = name.split('/')[1].split('.').first;
            expect(sha1.convert(trace.files[name]!).toString(), sha1Name,
                reason: '$name is not named by the sha1 of its content');
          }
        });

        test('Deve emitir before e after casados para cada ação', () async {
          await context.tracing.start();
          page = await context.newPage();
          await page.goto(server.url('/button'));
          await page.locator('#clickMe').click();
          final path = nextPath();
          await context.tracing.stop(path: path);

          final trace = _Trace.read(path);
          final before = trace.ofType('before').toList();
          final after = trace.ofType('after').toList();
          expect(before, isNotEmpty);
          expect(after.map((e) => e['callId']).toSet(),
              before.map((e) => e['callId']).toSet());

          final titles = before.map((e) => '${e['class']}.${e['method']}');
          expect(titles, contains('BrowserContext.newPage'));
          expect(titles, contains('Frame.goto'));
          expect(titles, contains('Frame.click'));

          final click = before.firstWhere((e) => e['method'] == 'click');
          // The viewer renders params['selector'] as a locator, so it has to
          // carry Playwright's selector syntax, not a Dart description.
          expect(click['params']['selector'], '#clickMe');
          expect(click['startTime'], isA<num>());
          expect(
              after
                  .firstWhere((e) => e['callId'] == click['callId'])['endTime'],
              isA<num>());
        });

        test('Deve registrar as requisições no trace.network com o corpo',
            () async {
          await context.tracing.start();
          page = await context.newPage();
          await page.goto(server.url('/resources'));
          final path = nextPath();
          await context.tracing.stop(path: path);

          final trace = _Trace.read(path);
          final entries = trace.network
              .map((e) => e['snapshot'])
              .cast<Map<String, dynamic>>();
          expect(trace.network.every((e) => e['type'] == 'resource-snapshot'),
              isTrue);

          final css = entries.firstWhere((entry) =>
              (entry['request']['url'] as String).endsWith('style.css'));
          expect(css['response']['status'], 200);
          expect(css['_resourceType'], 'stylesheet');
          expect(css['_frameref'], startsWith('frame@'));
          expect(css['pageref'], startsWith('page@'));
          final file = css['response']['content']['_file'] as String;
          expect(trace.files.keys, contains(file));
          expect(utf8.decode(trace.files[file]!), contains('rgb(1, 2, 3)'));
        });

        test('Deve registrar mensagens de console', () async {
          await context.tracing.start();
          page = await context.newPage();
          await page.goto(server.url('/console'));
          await page.evaluate('() => window.emitLog()');
          final path = nextPath();
          await context.tracing.stop(path: path);

          final messages = _Trace.read(path).ofType('console').toList();
          expect(messages.map((m) => m['text']), contains('hello 42'));
          expect(messages.first['location'], isA<Map<String, dynamic>>());
        });

        test('snapshots deve gravar o DOM antes e depois de cada ação',
            () async {
          await context.tracing.start(snapshots: true);
          page = await context.newPage();
          await page.goto(server.url('/input'));
          await page.locator('input[name=search]').fill('gravado');
          final path = nextPath();
          await context.tracing.stop(path: path);

          final trace = _Trace.read(path);
          final pageId = trace
              .ofType('event')
              .firstWhere((e) => e['method'] == 'page')['params']['pageId'];
          final snapshots = trace
              .ofType('frame-snapshot')
              .map((event) => event['snapshot'] as Map<String, dynamic>)
              .toList();
          expect(snapshots, isNotEmpty);
          expect(snapshots.map((s) => s['phase']).toSet(),
              containsAll(<String>['before', 'after']));
          expect(snapshots.every((s) => s['isMainFrame'] == true), isTrue);
          expect(snapshots.every((s) => s['pageId'] == pageId), isTrue);
          expect(snapshots.every((s) => s['frameId'] != null), isTrue);
          expect(snapshots.last['viewport'], {'width': 800, 'height': 600});

          // The serialized DOM has to carry what the HTML does not: the live
          // value of the input, and the element the action targeted. Without
          // those the viewer shows an empty field and highlights nothing.
          final flattened = jsonEncode(snapshots.last['html']);
          expect(flattened, contains('__playwright_value_'));
          expect(
              snapshots
                  .where((s) => s['phase'] == 'after')
                  .map((s) => jsonEncode(s['html']))
                  .join(),
              contains('gravado'));
          expect(snapshots.map((s) => jsonEncode(s['html'])).join(),
              contains('__playwright_target__'));
        });

        test('screenshots deve gravar a tira de filme em screencast-frame',
            () async {
          await context.tracing.start(screenshots: true);
          page = await context.newPage();
          await page.goto(server.url('/hello'));

          // A tira segue o relógio, não as ações: é preciso que o tempo passe
          // com a página aberta para haver mais de um quadro.
          await _idleForFilmstrip(page);

          final path = nextPath();
          await context.tracing.stop(path: path);

          final trace = _Trace.read(path);
          final pageId = trace
              .ofType('event')
              .firstWhere((e) => e['method'] == 'page')['params']['pageId'];
          final events = trace.ofType('screencast-frame').toList();
          expect(events, isNotEmpty);
          expect(events.length, greaterThanOrEqualTo(2));

          for (final event in events) {
            expect(event['pageId'], pageId);
            expect(event['width'], isA<int>());
            expect(event['height'], isA<int>());
            expect(event['width'], greaterThan(0));
            expect(event['height'], greaterThan(0));
            expect(event['timestamp'], isA<num>());
            // O visualizador pega o recurso pelo nome do arquivo: se ele não
            // estiver no zip, a tira fica com buracos pretos.
            final file = event['file'] as String;
            expect(file, startsWith('screencast/'));
            expect(file, endsWith('.jpeg'));
            expect(trace.files.keys, contains(file));
            final bytes = trace.files[file]!;
            // SOI de JPEG. O ffmpeg empacotado só decodifica mjpeg, então um
            // PNG aqui seria um quadro que nem a tira nem o vídeo aproveitam.
            expect(bytes.take(3).toList(), [0xFF, 0xD8, 0xFF]);
          }

          // Os tempos são do mesmo relógio monotônico das ações, e crescem.
          final times = events.map((e) => e['timestamp'] as num).toList();
          expect(times, orderedEquals(List.of(times)..sort()));
          final firstAction = trace.ofType('before').first['startTime'] as num;
          expect(times.last, greaterThan(firstAction));

          // Estrangulado: o upstream segura um quadro a cada 200 ms.
          for (var i = 1; i < times.length; i++) {
            expect(times[i] - times[i - 1], greaterThanOrEqualTo(200));
          }
        });

        test('sem screenshots não há tira de filme nem recursos dela',
            () async {
          await context.tracing.start();
          page = await context.newPage();
          await page.goto(server.url('/hello'));
          await _idleForFilmstrip(page);
          final path = nextPath();
          await context.tracing.stop(path: path);

          final trace = _Trace.read(path);
          expect(trace.ofType('screencast-frame'), isEmpty);
          expect(trace.files.keys.where((f) => f.startsWith('screencast/')),
              isEmpty);
        });

        test('actionScreenshots é outra coisa: um PNG por fase da ação',
            () async {
          await context.tracing.start(actionScreenshots: true);
          page = await context.newPage();
          await page.goto(server.url('/hello'));
          final path = nextPath();
          await context.tracing.stop(path: path);

          final trace = _Trace.read(path);
          final shots = trace.ofType('screenshot').toList();
          expect(shots, isNotEmpty);
          expect(shots.map((s) => s['phase']).toSet(),
              containsAll(<String>['before', 'after']));
          for (final shot in shots) {
            final file = shot['file'] as String;
            expect(file, startsWith('screenshots/'));
            expect(trace.files.keys, contains(file));
            // Assinatura de PNG.
            expect(trace.files[file]!.take(4).toList(), [0x89, 0x50, 0x4E, 0x47]);
          }
          // E nenhuma tira de filme: as duas opções são independentes.
          expect(trace.ofType('screencast-frame'), isEmpty);
        });

        test('Deve registrar o erro de uma ação que falhou', () async {
          await context.tracing.start();
          page = await context.newPage();
          await page.goto(server.url('/hello'));
          await expectLater(
              page
                  .locator('#nao-existe')
                  .click(timeout: const Duration(milliseconds: 300)),
              throwsA(anything));
          final path = nextPath();
          await context.tracing.stop(path: path);

          final failed = _Trace.read(path)
              .ofType('after')
              .where((event) => event['error'] != null)
              .toList();
          expect(failed, hasLength(1));
          expect(failed.first['error']['message'], isNotEmpty);
          expect(failed.first['error']['name'], isNotEmpty);
        });
      });
    }

    // The rest of the contract does not depend on the engine; one is enough,
    // and this machine does not have the memory to prove it three times.
    group('[chromium]', () {
      late Browser browser;
      var browserLaunched = false;
      late BrowserContext context;

      setUpAll(() async {
        browser = await playwright.chromium.launch(headless: true);
        browserLaunched = true;
      });

      setUp(() async {
        context = await browser.newContext();
      });

      tearDown(() async {
        await context.close();
      });

      tearDownAll(() async {
        if (browserLaunched) await browser.close();
      });

      test('sources deve colocar o arquivo Dart do chamador em src/', () async {
        await context.tracing.start(sources: true);
        final page = await context.newPage();
        await page.goto(server.url('/hello'));
        final path = nextPath();
        await context.tracing.stop(path: path);

        final trace = _Trace.read(path);
        final sources =
            trace.files.keys.where((name) => name.startsWith('src/')).toList();
        expect(sources, isNotEmpty);
        expect(sources.every((name) => name.endsWith('.dart')), isTrue);
        expect(utf8.decode(trace.files[sources.first]!),
            contains('sources deve colocar'));

        // The viewer finds the file by the sha1 of its *path*, not of its
        // content — that is what lets it show the right file when two runs of
        // the same test edited it in between.
        final goto = trace
            .ofType('before')
            .firstWhere((event) => event['method'] == 'goto');
        final frames = goto['stack'] as List;
        expect(frames, isNotEmpty);
        final callerFile = frames.first['file'] as String;
        expect(callerFile, endsWith('tracing_test.dart'));
        expect(sources,
            contains('src/${sha1.convert(utf8.encode(callerFile))}.dart'));
      });

      test('sem sources não deve haver src/ nem pilha', () async {
        await context.tracing.start();
        final page = await context.newPage();
        await page.goto(server.url('/hello'));
        final path = nextPath();
        await context.tracing.stop(path: path);

        final trace = _Trace.read(path);
        expect(
            trace.files.keys.where((name) => name.startsWith('src/')), isEmpty);
        expect(trace.ofType('before').every((e) => e['stack'] == null), isTrue);
      });

      test('startChunk e stopChunk devem produzir um arquivo por trecho',
          () async {
        await context.tracing.start();
        final page = await context.newPage();
        await page.goto(server.url('/hello'));
        final first = nextPath();
        await context.tracing.stopChunk(path: first);

        await context.tracing.startChunk(title: 'segundo trecho');
        await page.goto(server.url('/resources'));
        final second = nextPath();
        await context.tracing.stop(path: second);

        final one = _Trace.read(first);
        final two = _Trace.read(second);
        expect(
            one
                .ofType('before')
                .where((e) => e['method'] == 'goto')
                .map((e) => e['params']['url']),
            everyElement(endsWith('/hello')));
        expect(
            two
                .ofType('before')
                .where((e) => e['method'] == 'goto')
                .map((e) => e['params']['url']),
            everyElement(endsWith('/resources')));
        expect(two.events.first['title'], 'segundo trecho');
        // The network stream is shared across the chunks of one recording, so
        // a body served in the first chunk is still there to serve a snapshot
        // taken in the second.
        expect(two.network.map((e) => e['snapshot']['request']['url']),
            anyElement(endsWith('/hello')));
      });

      test('um iframe no snapshot deve apontar para o snapshot do filho',
          () async {
        await context.tracing.start(snapshots: true);
        final page = await context.newPage();
        await page.goto(server.url('/frames'));
        await page.locator('#host').innerText();
        final path = nextPath();
        await context.tracing.stop(path: path);

        final snapshots = _Trace.read(path)
            .ofType('frame-snapshot')
            .map((event) => event['snapshot'] as Map<String, dynamic>)
            .toList();
        final frameIds = snapshots.map((s) => s['frameId']).toSet();
        // Host, the two siblings and the nested one.
        expect(frameIds.length, greaterThanOrEqualTo(4));

        // Only the snapshot that first serialized the iframe carries its
        // `src`; the later ones replace the unchanged subtree with a
        // back-reference, which is the whole point of the node cache.
        final html = snapshots
            .where((s) => s['isMainFrame'] == true)
            .map((s) => jsonEncode(s['html']))
            .join();
        // The engines report a frame's own id, never the element that owns it;
        // the recorder builds the mapping by asking the page which frame each
        // iframe element contains. Without it the viewer renders an empty box
        // where the iframe was.
        final referenced = RegExp(r'/snapshot/(frame@[0-9a-f]+)')
            .allMatches(html)
            .map((m) => m.group(1))
            .toSet();
        expect(referenced, isNotEmpty);
        expect(frameIds, containsAll(referenced));
      });

      test('stop deve apagar o diretório temporário', () async {
        final before = Directory.systemTemp
            .listSync()
            .whereType<Directory>()
            .where((d) => d.path.contains('playwright-dart-tracing-'))
            .length;
        await context.tracing.start();
        final page = await context.newPage();
        await page.goto(server.url('/hello'));
        await context.tracing.stop(path: nextPath());
        final after = Directory.systemTemp
            .listSync()
            .whereType<Directory>()
            .where((d) => d.path.contains('playwright-dart-tracing-'))
            .length;
        expect(after, before);
      });

      test('sem tracing ligado a instrumentação não deve custar nada',
          () async {
        // Nothing to assert beyond "it still works": this is the path every
        // call takes when nobody is recording, and it must not throw.
        final page = await context.newPage();
        await page.goto(server.url('/title'));
        expect(await page.title(), isNotEmpty);
      });
    });
  });
}

/// Leaves [page] open and idle long enough for the screencast to deliver
/// several throttled frames.
///
/// This is one of the few places where waiting on the clock is the subject
/// rather than a shortcut: the filmstrip is driven by wall time, not by
/// actions, so a trace that navigates once and stops legitimately holds a
/// single frame. The page is left *idle* on purpose — the stand-in screencast
/// samples screenshots, and a navigation in flight holds a screenshot up.
Future<void> _idleForFilmstrip(Page page) async {
  for (var i = 0; i < 12; i++) {
    await page.waitForTimeout(const Duration(milliseconds: 250));
  }
}

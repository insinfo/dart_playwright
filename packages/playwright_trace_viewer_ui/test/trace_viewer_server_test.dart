// Part of the Dart port of the Playwright trace viewer UI.

/// The routes `show-trace` answers.
///
/// Upstream answers these from a service worker; this port answers them from
/// a socket. The tests are here rather than in the model package because the
/// model's `SnapshotServer` owns no transport on purpose — this is the half
/// that turns its answers into bytes, and the half that can get the status,
/// the headers or the body wrong.
library;

import 'dart:convert';
import 'dart:io';

import 'package:playwright_trace_viewer_ui/server.dart';
import 'package:test/test.dart';

import 'fixture.dart';

void main() {
  group('the trace viewer server', () {
    late Directory temporary;
    late TraceViewerServer server;
    late HttpClient client;

    setUpAll(() async {
      temporary = await Directory.systemTemp.createTemp('trace-viewer-ui');
      final trace = await LoadedTrace.open(await writeFixtureTrace(temporary));
      // The routes under test do not touch the compiled bundle, so the tests
      // serve a stub rather than waiting thirty seconds for dart2js.
      server = TraceViewerServer(trace, _stubAssets());
      await server.start();
      client = HttpClient();
    });

    tearDownAll(() async {
      client.close(force: true);
      await server.close();
      await temporary.delete(recursive: true);
    });

    Future<HttpClientResponse> get(String path) async {
      final request = await client.getUrl(Uri.parse('${server.origin}$path'));
      return request.close();
    }

    Future<String> getBody(String path) async =>
        (await get(path)).transform(utf8.decoder).join();

    test('serves the viewer shell at the root', () async {
      final response = await get('/');
      expect(response.statusCode, 200);
      expect(response.headers.contentType.toString(), contains('text/html'));
      expect(await response.transform(utf8.decoder).join(), contains('<html'));
    });

    test('serves the service worker with a root scope', () async {
      final response = await get('/sw.js');
      expect(response.statusCode, 200);
      // Without this header the browser refuses the root scope, and the
      // snapshot frames' cross-origin requests never reach this server.
      expect(response.headers.value('service-worker-allowed'), '/');
      await response.drain<void>();
    });

    test('hands the whole model over at /contexts', () async {
      final json = jsonDecode(await getBody('/contexts'))
          as Map<String, dynamic>;
      final decoded = contextEntriesFromJson(json);
      expect(decoded.contexts, hasLength(1));
      expect(decoded.contexts.single.actions, hasLength(2));
      expect(decoded.contexts.single.browserName, 'chromium');
    });

    test('renders a snapshot as a whole document under a nonce', () async {
      final response = await get('/snapshot/call%401?phase=before');
      expect(response.statusCode, 200);
      final policy = response.headers.value('content-security-policy');
      // A trace is data from outside; nothing in the rendered page may run
      // except the bootstrap script this server put there.
      expect(policy, contains("script-src 'nonce-"));
      expect(policy, contains("object-src 'none'"));
      final body = await response.transform(utf8.decoder).join();
      expect(body, contains('hello from the fixture'));
    });

    test('answers snapshotInfo with the recorded viewport', () async {
      final json = jsonDecode(await getBody('/snapshotInfo/call%401?phase=before'))
          as Map<String, dynamic>;
      expect(json['url'], 'http://localhost/');
      expect((json['viewport'] as Map)['width'], 900);
      expect((json['viewport'] as Map)['height'], 600);
    });

    test('reports a snapshot it does not have, rather than inventing one',
        () async {
      final json = jsonDecode(await getBody('/snapshotInfo/nope?phase=before'))
          as Map<String, dynamic>;
      expect(json['error'], 'No snapshot found');
    });

    test('serves a body of the archive by its trace path', () async {
      final response = await get('/file/resources%2Fa.css');
      expect(response.statusCode, 200);
      expect(await response.transform(utf8.decoder).join(),
          'body { color: red; }');
    });

    test('names a download when the attachment route asks it to', () async {
      final response =
          await get('/file/resources%2Fa.css?dn=styles.css&dct=text%2Fcss');
      expect(response.headers.value('content-disposition'),
          'text/css; filename="styles.css"');
      await response.drain<void>();
    });

    test('finds a source file by the path the stack recorded', () async {
      // The archive names it by the sha1 of the path; the UI only knows the
      // path, so this route is what closes the gap.
      final body = await getBody(
          '/source?path=${Uri.encodeQueryComponent(kFixtureSourcePath)}');
      expect(body, kFixtureSourceText);
    });

    test('404s a source the trace never recorded', () async {
      final response = await get('/source?path=nowhere.dart');
      expect(response.statusCode, 404);
      await response.drain<void>();
    });

    test('serves a resource the snapshot asked another origin for', () async {
      // This is the request the service worker forwards. It only resolves
      // because the snapshot was served first, at the URL passed as `sw`.
      final snapshotUrl = '${server.origin}/snapshot/call%401?phase=before';
      await (await get('/snapshot/call%401?phase=before')).drain<void>();

      final response = await get('$kResourceRoute'
          '?url=${Uri.encodeQueryComponent('http://localhost/a.css')}'
          '&method=GET'
          '&sw=${Uri.encodeQueryComponent(snapshotUrl)}');
      expect(response.statusCode, 200);
      expect(response.headers.value('access-control-allow-origin'), '*');
      expect(await response.transform(utf8.decoder).join(),
          'body { color: red; }');
    });

    test('404s a resource the trace never saw', () async {
      final response = await get('$kResourceRoute'
          '?url=${Uri.encodeQueryComponent('http://elsewhere/x.css')}'
          '&method=GET&sw=');
      expect(response.statusCode, 404);
      await response.drain<void>();
    });

    test('404s an unknown route instead of guessing', () async {
      final response = await get('/not-a-route');
      expect(response.statusCode, 404);
      await response.drain<void>();
    });
  });
}

/// The smallest asset set the shell routes need.
ViewerAssets _stubAssets() => ViewerAssets({
      'index.html': ViewerAsset(
          utf8Bytes('<html><body>viewer</body></html>'),
          'text/html; charset=utf-8'),
      'sw.js': ViewerAsset(
          utf8Bytes('// stub'), 'text/javascript; charset=utf-8'),
    });

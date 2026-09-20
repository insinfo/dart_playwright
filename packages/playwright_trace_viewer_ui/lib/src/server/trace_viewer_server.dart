// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream counterpart: packages/trace-viewer/src/sw/main.ts, which is a
// service worker. Here the same routes are answered by an HttpServer.

/// The `show-trace` server.
///
/// Upstream reads the archive inside a service worker and answers the
/// viewer's requests from there, because the viewer is a static site on
/// `trace.playwright.dev` with no server of its own. This port has one: the
/// `show-trace` process already holds the trace, so it reads it once with
/// `dart:io` and answers the same routes over a socket.
///
/// That moves the model to the server side, which is the reason the UI can be
/// a thin drawing layer: `/contexts` hands the browser the whole
/// `ContextEntry` list and the dart2js bundle rebuilds a real [TraceModel]
/// from it, with the same methods the server-side one has.
///
/// One thing still needs a service worker, and only one: a page inside the
/// snapshot iframe asks for `https://example.com/style.css`, an origin this
/// server does not own and cannot be routed to by a URL rewrite. `sw.dart`
/// intercepts those and forwards them to [kResourceRoute], which is the only
/// reason it exists — it holds no model and reads no archive.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:playwright_trace_viewer/io.dart';

import '../wire.dart';
import 'viewer_assets.dart';

/// Where the service worker forwards a request the snapshot made to an origin
/// this server does not own.
const String kResourceRoute = '/_pwresource';

/// A trace, open and ready to be served.
class LoadedTrace {
  final String traceUri;
  final TraceLoader loader;
  final SnapshotServer snapshotServer;

  LoadedTrace._(this.traceUri, this.loader, this.snapshotServer);

  /// Reads the archive at [path] and wires a [SnapshotServer] over it.
  static Future<LoadedTrace> open(String path, {bool live = false}) async {
    final loader = await loadTraceFile(path, live: live);
    final server = SnapshotServer(
      loader.storage(),
      (file) async => (await loader.resourceEntry(file))?.bytes,
    );
    return LoadedTrace._(path, loader, server);
  }

  /// The model, rebuilt on demand.
  ///
  /// Building one mutates the contexts' timestamps onto a single clock, so it
  /// must happen exactly once; the server builds it lazily and keeps it.
  TraceModel? _model;

  TraceModel get model =>
      _model ??= TraceModel(traceUri, loader.contextEntries);
}

/// Serves one trace over HTTP.
class TraceViewerServer {
  final LoadedTrace trace;
  final ViewerAssets assets;

  HttpServer? _httpServer;

  TraceViewerServer(this.trace, this.assets);

  /// The origin the viewer is reachable at, once [start] has run.
  String get origin => 'http://${_httpServer!.address.host}:${_httpServer!.port}';

  /// The URL to open, which carries the trace name for the page title.
  String get url => '$origin/';

  int get port => _httpServer!.port;

  /// Binds and starts answering.
  ///
  /// [host] defaults to loopback: a trace is a recording of someone's browser
  /// session and has no business being reachable from the network.
  Future<void> start({String host = '127.0.0.1', int port = 0}) async {
    _httpServer = await HttpServer.bind(host, port);
    unawaited(_serve());
  }

  Future<void> close() async {
    await _httpServer?.close(force: true);
    _httpServer = null;
  }

  Future<void> _serve() async {
    final server = _httpServer;
    if (server == null) return;
    await for (final request in server) {
      // One bad request must not take the server down with it: a snapshot
      // asks for whatever the recorded page asked for, and some of that is
      // malformed by the time it gets here.
      unawaited(_handle(request).catchError((Object error) async {
        try {
          request.response.statusCode = HttpStatus.internalServerError;
          request.response.write('$error');
          await request.response.close();
        } on Object {
          // The socket is already gone; nothing left to say.
        }
      }));
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final uri = request.uri;
    final path = uri.path;
    final params = uri.queryParameters;

    // The viewer shell.
    if (path == '/' || path == '/index.html') {
      return _sendAsset(request, 'index.html');
    }
    // The popout window of a single snapshot, which upstream also serves.
    if (path == '/snapshot.html') {
      return _sendAsset(request, 'snapshot.html');
    }
    // The service worker must be served from the root to claim the root
    // scope; everything else it needs lives under /app/.
    if (path == '/sw.js') {
      return _sendAsset(request, 'sw.js', serviceWorker: true);
    }
    if (path.startsWith('/app/')) {
      return _sendAsset(request, path.substring('/app/'.length));
    }

    // The model, as the UI's one bulk read.
    if (path == '/contexts') {
      return _sendJson(
          request,
          contextEntriesToJson(trace.loader.contextEntries,
              traceUri: trace.traceUri));
    }

    // The snapshot routes, answered by the model's own server.
    if (path.startsWith('/snapshot/')) {
      final callId = Uri.decodeComponent(path.substring('/snapshot/'.length));
      // The URL this document is served at is the key the snapshot's own
      // subresource requests are later looked up by, so it has to be the
      // absolute one the browser used.
      final snapshotUrl = '$origin${uri.toString()}';
      return _send(
          request, trace.snapshotServer.serveSnapshot(callId, params, snapshotUrl));
    }
    if (path.startsWith('/snapshotInfo/')) {
      final callId =
          Uri.decodeComponent(path.substring('/snapshotInfo/'.length));
      return _send(
          request, trace.snapshotServer.serveSnapshotInfo(callId, params));
    }
    if (path.startsWith('/closest-screenshot/')) {
      final callId =
          Uri.decodeComponent(path.substring('/closest-screenshot/'.length));
      return _send(request,
          await trace.snapshotServer.serveClosestScreenshot(callId, params));
    }

    // A blob of the archive by its trace-relative path: sources, attachments,
    // screencast frames and screenshots all come through here.
    if (path.startsWith('/file/')) {
      final file = Uri.decodeComponent(path.substring('/file/'.length));
      return _sendTraceFile(request, file, params);
    }

    // One source file, by the path the stack recorded.
    //
    // Upstream's viewer hashes the path in the browser to find
    // `src/<sha1><ext>` in the archive, because its service worker has no
    // other way to ask. This port's server holds the archive, so the UI asks
    // for the path and the lookup happens here — the same file, one hash
    // implementation instead of two.
    if (path == '/source') {
      final file = params['path'];
      if (file == null) return _sendStatus(request, HttpStatus.badRequest);
      return _sendSource(request, file);
    }

    // What the service worker forwarded, because the snapshot asked an origin
    // this server does not own.
    if (path == kResourceRoute) {
      final url = params['url'];
      if (url == null) return _sendStatus(request, HttpStatus.badRequest);
      return _send(
          request,
          await trace.snapshotServer.serveResource(
            _urlAlternatives(url),
            params['method'] ?? 'GET',
            params['sw'] ?? '',
          ));
    }

    return _sendStatus(request, HttpStatus.notFound);
  }

  /// The several ways the recorder and the renderer may spell one URL.
  ///
  /// Upstream tries the request URL and then the same URL downgraded from
  /// https to http, because a page served over http may be replayed under a
  /// `upgrade-insecure-requests` policy.
  List<String> _urlAlternatives(String url) => [
        url,
        if (url.startsWith('https://')) 'http://${url.substring(8)}',
      ];

  /// The recorded text of one source file, or 404 when the trace has none.
  Future<void> _sendSource(HttpRequest request, String file) async {
    final extension = _extension(file);
    final entry = 'src/${sha1OfPath(file)}$extension';
    final resource = await trace.loader.resourceEntry(entry);
    if (resource == null) return _sendStatus(request, HttpStatus.notFound);
    final response = request.response;
    response.statusCode = HttpStatus.ok;
    response.headers
        .set(HttpHeaders.contentTypeHeader, 'text/plain; charset=utf-8');
    response.headers.set(HttpHeaders.cacheControlHeader, _immutable);
    response.add(resource.bytes);
    await response.close();
  }

  /// The extension of a path, including the dot, or the empty string.
  String _extension(String path) {
    final name = path.split(RegExp(r'[/\\]')).last;
    final dot = name.lastIndexOf('.');
    return dot <= 0 ? '' : name.substring(dot);
  }

  Future<void> _sendTraceFile(
      HttpRequest request, String file, Map<String, String> params) async {
    final resource = await trace.loader.resourceEntry(file);
    if (resource == null) return _sendStatus(request, HttpStatus.notFound);
    final response = request.response;
    response.statusCode = HttpStatus.ok;
    response.headers
        .set(HttpHeaders.contentTypeHeader, resource.contentType ?? _octet);
    // `dn` is the download name and `dct` the disposition type, the two
    // parameters upstream's `/file/` route takes for an attachment the user
    // asked to save.
    final downloadName = params['dn'];
    if (downloadName != null) {
      final type = params['dct'] ?? 'attachment';
      response.headers.set('content-disposition',
          '$type; filename="${downloadName.replaceAll('"', '')}"');
    }
    response.headers.set(HttpHeaders.cacheControlHeader, _immutable);
    response.add(resource.bytes);
    await response.close();
  }

  Future<void> _sendAsset(HttpRequest request, String name,
      {bool serviceWorker = false}) async {
    final asset = assets.read(name);
    if (asset == null) return _sendStatus(request, HttpStatus.notFound);
    final response = request.response;
    response.statusCode = HttpStatus.ok;
    response.headers.set(HttpHeaders.contentTypeHeader, asset.contentType);
    if (serviceWorker) {
      // Without this the browser refuses a root scope for a worker that is
      // not itself at the root of the path it claims.
      response.headers.set('Service-Worker-Allowed', '/');
    }
    // The bundle changes whenever the viewer is rebuilt and the process is
    // short-lived, so caching it only makes a stale viewer harder to notice.
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    response.add(asset.bytes);
    await response.close();
  }

  Future<void> _sendJson(HttpRequest request, Object? json) async {
    final response = request.response;
    response.statusCode = HttpStatus.ok;
    response.headers
        .set(HttpHeaders.contentTypeHeader, 'application/json; charset=utf-8');
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    response.add(utf8.encode(jsonEncode(json)));
    await response.close();
  }

  Future<void> _sendStatus(HttpRequest request, int status) async {
    request.response.statusCode = status;
    await request.response.close();
  }

  /// Turns one [SnapshotResponse] into bytes on the wire.
  ///
  /// This is the whole reason the model's server answers with plain data:
  /// the same [SnapshotResponse] a service worker would turn into a `Response`
  /// becomes an `HttpResponse` here, with nothing in between.
  Future<void> _send(HttpRequest request, SnapshotResponse snapshot) async {
    final response = request.response;
    response.statusCode = snapshot.status;
    if (snapshot.statusText != null) {
      response.reasonPhrase = snapshot.statusText!;
    }
    snapshot.headers.entries.forEach((name, value) {
      // `dart:io` computes these two itself, and setting them by hand either
      // truncates the body or makes it unreadable.
      if (name == 'content-length' || name == 'content-encoding') return;
      try {
        response.headers.set(name, value);
      } on Object {
        // A recorded response may carry a header `dart:io` refuses; dropping
        // it is better than failing the whole resource.
      }
    });
    final body = snapshot.body;
    if (body != null && body.isNotEmpty) response.add(body);
    await response.close();
  }
}

/// How the recorder names a source file inside the archive: the sha1 of the
/// path as UTF-8, hex encoded.
String sha1OfPath(String path) => sha1.convert(utf8.encode(path)).toString();

const String _octet = 'application/octet-stream';
const String _immutable = 'public, max-age=31536000';

/// An asset of the compiled viewer, ready to serve.
class ViewerAsset {
  final Uint8List bytes;
  final String contentType;

  const ViewerAsset(this.bytes, this.contentType);
}

// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/isomorphic/trace/snapshotServer.ts

/// Serves the pages and the resources of a trace, without owning a transport.
///
/// Upstream's copy lives in a service worker and answers with `Response`
/// objects of the fetch API. That is one transport of two this port needs:
/// `show-trace` has to answer from an `HttpServer` of `dart:io`, and the web
/// build has to answer from a service worker compiled by dart2js. So the
/// answers are plain data — [SnapshotResponse] — and whoever holds the socket
/// turns them into bytes on the wire.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'snapshot_renderer.dart';
import 'snapshot_storage.dart';
import 'trace.dart';

/// Loads one blob of the trace archive by its trace-relative path.
typedef ResourceLoader = Future<Uint8List?> Function(String file);

/// A set of HTTP headers, keyed case-insensitively as HTTP requires.
class SnapshotHeaders {
  final Map<String, String> _headers = <String, String>{};

  SnapshotHeaders([Map<String, String>? initial]) {
    initial?.forEach(set);
  }

  /// The headers, with lowercased names.
  Map<String, String> get entries => Map<String, String>.unmodifiable(_headers);

  String? operator [](String name) => _headers[name.toLowerCase()];

  void set(String name, String value) => _headers[name.toLowerCase()] = value;

  void remove(String name) => _headers.remove(name.toLowerCase());

  bool contains(String name) => _headers.containsKey(name.toLowerCase());
}

/// One answer, ready for any transport.
class SnapshotResponse {
  final int status;
  final String? statusText;
  final SnapshotHeaders headers;

  /// The body, or null for a status that must not have one.
  final Uint8List? body;

  SnapshotResponse({
    required this.status,
    this.statusText,
    SnapshotHeaders? headers,
    this.body,
  }) : headers = headers ?? SnapshotHeaders();

  /// `new Response(null, { status: 404 })`.
  factory SnapshotResponse.notFound() => SnapshotResponse(status: 404);

  /// An HTML document served under a `script-src` that only its own nonce
  /// satisfies.
  factory SnapshotResponse.html(String html, {required String scriptNonce}) =>
      SnapshotResponse(
        status: 200,
        headers: SnapshotHeaders({
          'Content-Type': 'text/html; charset=utf-8',
          // Only allow our own bootstrap script.
          'Content-Security-Policy':
              "script-src 'nonce-$scriptNonce'; object-src 'none'",
        }),
        body: Uint8List.fromList(utf8.encode(html)),
      );

  /// A JSON answer the viewer may cache forever.
  factory SnapshotResponse.json(Object? object) => SnapshotResponse(
        status: 200,
        headers: SnapshotHeaders({
          'Cache-Control': 'public, max-age=31536000',
          'Content-Type': 'application/json',
        }),
        body: Uint8List.fromList(utf8.encode(jsonEncode(object))),
      );

  /// Raw bytes, with no headers of their own.
  factory SnapshotResponse.bytes(Uint8List? bytes) =>
      SnapshotResponse(status: 200, body: bytes ?? Uint8List(0));

  /// The body decoded as UTF-8, for a caller that wants text.
  String get bodyAsString => body == null ? '' : utf8.decode(body!);
}

/// Answers the four requests a rendered snapshot makes.
class SnapshotServer {
  final SnapshotStorage _snapshotStorage;
  final ResourceLoader _resourceLoader;

  /// Which renderer produced the document at a given snapshot URL.
  ///
  /// A resource request arrives with no idea which snapshot it came from; the
  /// referrer — the URL the document itself was served at — is the link.
  final Map<String, SnapshotRenderer> _snapshotIds =
      <String, SnapshotRenderer>{};

  SnapshotServer(this._snapshotStorage, this._resourceLoader);

  /// `GET /snapshot/<callId>?phase=&frameId=`: the page itself.
  ///
  /// [snapshotUrl] is the URL this document is being served at, remembered so
  /// [serveResource] can find its way back here.
  SnapshotResponse serveSnapshot(
    String callId,
    Map<String, String> searchParams,
    String snapshotUrl,
  ) {
    final snapshot = _snapshot(callId, searchParams);
    if (snapshot == null) return SnapshotResponse.notFound();

    final renderedSnapshot = snapshot.render();
    _snapshotIds[snapshotUrl] = snapshot;
    return SnapshotResponse.html(renderedSnapshot.html,
        scriptNonce: renderedSnapshot.scriptNonce);
  }

  /// `GET /closest-screenshot/<callId>`: the filmstrip frame nearest this
  /// snapshot, which the page draws into its canvases.
  Future<SnapshotResponse> serveClosestScreenshot(
    String callId,
    Map<String, String> searchParams,
  ) async {
    final snapshot = _snapshot(callId, searchParams);
    final file = snapshot?.closestScreenshot();
    if (file == null) return SnapshotResponse.notFound();
    return SnapshotResponse.bytes(await _resourceLoader(file));
  }

  /// `GET /snapshotInfo/<callId>`: the viewport, the URL and the times, so
  /// the panel can size its iframe before the page loads.
  SnapshotResponse serveSnapshotInfo(
    String callId,
    Map<String, String> searchParams,
  ) {
    final snapshot = _snapshot(callId, searchParams);
    return SnapshotResponse.json(snapshot != null
        ? {
            'viewport': snapshot.viewport().toJson(),
            'url': snapshot.snapshot().frameUrl,
            'timestamp': snapshot.snapshot().timestamp,
            'wallTime': snapshot.snapshot().wallTime,
          }
        : {'error': 'No snapshot found'});
  }

  SnapshotRenderer? _snapshot(String callId, Map<String, String> params) {
    final frameId = params['frameId'];
    return _snapshotStorage.snapshotForCall(
      callId,
      ActionPhase.fromWire(params['phase']),
      frameId != null && frameId.isNotEmpty ? frameId : null,
    );
  }

  /// A request the rendered page made, answered from the trace.
  ///
  /// [requestUrlAlternatives] is the same URL written the several ways the
  /// recording and the rendering may spell it; the first one that matches a
  /// recorded resource wins.
  Future<SnapshotResponse> serveResource(
    List<String> requestUrlAlternatives,
    String method,
    String snapshotUrl,
  ) async {
    ResourceSnapshot? resource;
    final snapshot = _snapshotIds[snapshotUrl];
    for (final requestUrl in requestUrlAlternatives) {
      resource = snapshot?.resourceByUrl(_removeHash(requestUrl), method);
      if (resource != null) break;
    }
    if (resource == null) return SnapshotResponse.notFound();

    final file = resource.response.content.file;
    final content = file != null
        ? await _resourceLoader(file) ?? Uint8List(0)
        : Uint8List(0);

    var contentType = resource.response.content.mimeType;
    final isTextEncoding = _textEncoding.hasMatch(contentType);
    if (isTextEncoding && !contentType.contains('charset')) {
      contentType = '$contentType; charset=utf-8';
    }

    final headers = SnapshotHeaders();
    // "x-unknown" in the har means "no content type".
    if (contentType != 'x-unknown') headers.set('Content-Type', contentType);
    for (final header in resource.response.headers) {
      headers.set(header.name, header.value);
    }
    headers.remove('Content-Encoding');
    headers.set('Access-Control-Allow-Origin', '*');
    headers.set('Content-Length', '${content.length}');
    if (_snapshotStorage.hasResourceOverride(resource.request.url)) {
      headers.set('Cache-Control', 'no-store, no-cache, max-age=0');
    } else {
      headers.set('Cache-Control', 'public, max-age=31536000');
    }
    final status = resource.response.status;
    final isNullBodyStatus =
        status == 101 || status == 204 || status == 205 || status == 304;
    return SnapshotResponse(
      status: status,
      statusText: resource.response.statusText,
      headers: headers,
      body: isNullBodyStatus ? null : content,
    );
  }
}

final RegExp _textEncoding = RegExp(r'^text/|^application/(javascript|json)');

String _removeHash(String url) {
  try {
    final uri = Uri.parse(url);
    if (!uri.hasScheme) return url;
    return uri.removeFragment().toString();
  } on FormatException {
    return url;
  }
}

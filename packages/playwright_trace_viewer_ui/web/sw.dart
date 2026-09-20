// Part of the Dart port of the Playwright trace viewer UI.

/// The one piece of the viewer that has to be a service worker.
///
/// A rendered snapshot is a real document: it asks for
/// `https://example.com/style.css` because that is what the recorded page
/// asked for. The `show-trace` server cannot answer that — it does not own
/// that origin, and no URL rewrite can make it — but a service worker sees
/// every request a page in its scope makes, including cross-origin ones.
///
/// So this worker holds no model, reads no archive and renders nothing. It
/// forwards the requests the server cannot otherwise see, tagged with the URL
/// of the document that made them, which is the key `SnapshotServer` looks a
/// resource up by. Everything else it lets straight through.
///
/// Upstream's worker is the whole viewer backend. This one is a proxy of
/// about forty lines, because the backend here is a real server.
library;

import 'dart:js_interop';

/// The route on the viewer's own origin that answers a forwarded request.
const String _resourceRoute = '/_pwresource';

@JS('self')
external _ServiceWorkerGlobalScope get _self;

extension type _ServiceWorkerGlobalScope._(JSObject _) implements JSObject {
  external void addEventListener(String type, JSFunction listener);
  external _Clients get clients;
  external void skipWaiting();
  external _Location get location;
}

extension type _Clients._(JSObject _) implements JSObject {
  external JSPromise<JSAny?> get(String id);
  external JSPromise<JSAny?> claim();
}

extension type _Client._(JSObject _) implements JSObject {
  external String get url;
}

extension type _Location._(JSObject _) implements JSObject {
  external String get origin;
}

extension type _FetchEvent._(JSObject _) implements JSObject {
  external _Request get request;
  external String? get clientId;
  external void respondWith(JSPromise<JSAny?> response);
}

extension type _Request._(JSObject _) implements JSObject {
  external String get url;
  external String get method;
}

@JS('fetch')
external JSPromise<JSAny?> _fetch(String input);

void main() {
  // Take over the open snapshot frames as soon as this worker installs,
  // rather than waiting for the next navigation.
  _self.addEventListener('install', ((JSObject _) {
    _self.skipWaiting();
  }).toJS);
  _self.addEventListener('activate', ((JSObject _) {
    _self.clients.claim();
  }).toJS);
  _self.addEventListener('fetch', ((_FetchEvent event) {
    final url = event.request.url;
    // Anything the viewer serves itself goes straight to the network; only
    // what the snapshot asked of another origin needs rewriting.
    if (url.startsWith(_self.location.origin)) return;
    event.respondWith(_proxy(event).toJS);
  }).toJS);
}

Future<JSAny?> _proxy(_FetchEvent event) async {
  // The document that made the request is what tells the server which
  // snapshot to resolve the resource against; without it a page that loaded
  // the same URL in two snapshots would be ambiguous.
  var client = '';
  final clientId = event.clientId;
  if (clientId != null && clientId.isNotEmpty) {
    final resolved = await _self.clients.get(clientId).toDart;
    if (resolved != null) client = (resolved as _Client).url;
  }
  final target = '${_self.location.origin}$_resourceRoute'
      '?url=${Uri.encodeQueryComponent(event.request.url)}'
      '&method=${Uri.encodeQueryComponent(event.request.method)}'
      '&sw=${Uri.encodeQueryComponent(client)}';
  return _fetch(target).toDart;
}

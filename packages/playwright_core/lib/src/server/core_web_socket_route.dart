import 'dart:async';
import 'dart:convert';

import 'package:playwright_protocol/playwright_protocol.dart';

import 'core_browser.dart';
import 'core_page.dart';
import 'injected/injected_web_socket_mock_source.dart';

export 'injected/injected_web_socket_mock_source.dart'
    show kInjectedWebSocketMockSource, kWebSocketBindingName;

/// One payload crossing a routed socket, in the shape the injected mock
/// speaks: text as it stands, binary as base64.
class CoreWebSocketData {
  final String data;
  final bool isBase64;

  const CoreWebSocketData(this.data, this.isBase64);

  /// The payload as bytes.
  List<int> get bytes => isBase64 ? base64Decode(data) : utf8.encode(data);

  Map<String, dynamic> toJson() => {'data': data, 'isBase64': isBase64};

  static CoreWebSocketData fromJson(dynamic value) {
    if (value is! Map) return const CoreWebSocketData('', false);
    return CoreWebSocketData(
        value['data'] as String? ?? '', value['isBase64'] == true);
  }
}

/// What `routeWebSocket` hands the caller for each intercepted socket.
typedef CoreWebSocketRouteHandler = FutureOr<void> Function(
    CoreWebSocketRoute route);

/// Everything one intercepted socket owns, shared by its page side and its
/// server side.
///
/// Upstream splits these across a dispatcher and two client objects; the
/// split that matters — page side versus server side — is kept, and the state
/// they share lives here.
class _RouteState {
  final String id;
  final String url;
  final List<String> protocols;
  final CorePage page;
  final CoreFrame frame;
  final Future<void> Function(Map<String, dynamic> request) dispatch;

  bool connected = false;
  bool gone = false;

  void Function(CoreWebSocketData message)? onPageMessage;
  void Function(int? code, String? reason)? onPageClose;
  void Function(CoreWebSocketData message)? onServerMessage;
  void Function(int? code, String? reason)? onServerClose;

  _RouteState({
    required this.id,
    required this.url,
    required this.protocols,
    required this.page,
    required this.frame,
    required this.dispatch,
  });

  Future<void> send(String type, CoreWebSocketData data) =>
      dispatch({'id': id, 'type': type, 'data': data.toJson()});

  Future<void> closeSide(
          String type, int? code, String? reason, bool wasClean) =>
      dispatch({
        'id': id,
        'type': type,
        'code': code,
        'reason': reason,
        'wasClean': wasClean,
      });

  // The four default behaviours, straight from `client/network.ts:512`: an
  // unhandled message or close is forwarded to the other side, which is what
  // makes a route that only watches one direction transparent.

  void messageFromPage(CoreWebSocketData data) {
    final handler = onPageMessage;
    if (handler != null) {
      handler(data);
    } else if (connected) {
      send('sendToServer', data).ignore();
    }
  }

  void messageFromServer(CoreWebSocketData data) {
    final handler = onServerMessage;
    if (handler != null) {
      handler(data);
    } else {
      send('sendToPage', data).ignore();
    }
  }

  void closePage(int? code, String? reason, bool wasClean) {
    final handler = onPageClose;
    if (handler != null) {
      handler(code, reason);
    } else {
      closeSide('closeServer', code, reason, wasClean).ignore();
    }
  }

  void closeServer(int? code, String? reason, bool wasClean) {
    final handler = onServerClose;
    if (handler != null) {
      handler(code, reason);
    } else {
      closeSide('closePage', code, reason, wasClean).ignore();
    }
  }

  /// Port of `WebSocketRoute._afterHandle`: a handler that never connected to
  /// a server means a fully mocked socket, so the page's socket has to be
  /// told to open by itself or it stays in CONNECTING forever.
  Future<void> afterHandle() async {
    if (connected) return;
    await dispatch({'id': id, 'type': 'ensureOpened'});
  }
}

/// A WebSocket the page opened and a `routeWebSocket` handler took over.
///
/// The object handed to the handler is the **page side**: [send] reaches the
/// page and [onMessage] sees what the page sends. [connectToServer] opens the
/// real connection and returns its **server side**, where the two are
/// mirrored.
class CoreWebSocketRoute {
  final _RouteState _state;

  /// Whether this object is the server side of the route.
  final bool isServerSide;

  CoreWebSocketRoute._(this._state, this.isServerSide);

  /// The URL the page asked for, resolved against the document.
  String get url => _state.url;

  /// The subprotocols the page asked for.
  List<String> get protocols => List.unmodifiable(_state.protocols);

  /// Sends a text message to this side.
  void send(String message) {
    _state.send(_sendType, CoreWebSocketData(message, false)).ignore();
  }

  /// Sends a binary message to this side.
  void sendBinary(List<int> message) {
    _state
        .send(_sendType, CoreWebSocketData(base64Encode(message), true))
        .ignore();
  }

  /// Closes this side of the socket.
  Future<void> close({int? code, String? reason}) async {
    await _state.closeSide(_closeType, code, reason, true);
  }

  /// Handles messages coming from this side.
  ///
  /// Installing a handler stops the default forwarding, exactly as upstream:
  /// what the handler does not pass on does not reach the other side.
  void onMessage(void Function(CoreWebSocketData message) handler) {
    if (isServerSide) {
      _state.onServerMessage = handler;
    } else {
      _state.onPageMessage = handler;
    }
  }

  /// Handles this side closing.
  void onClose(void Function(int? code, String? reason) handler) {
    if (isServerSide) {
      _state.onServerClose = handler;
    } else {
      _state.onPageClose = handler;
    }
  }

  /// Connects to the real server and returns the server side of the route.
  ///
  /// Only valid on the page side, and only once.
  CoreWebSocketRoute connectToServer() {
    if (isServerSide) {
      throw PlaywrightException(
          'connectToServer must be called on the page-side WebSocketRoute');
    }
    if (_state.connected) {
      throw PlaywrightException('Already connected to the server');
    }
    _state.connected = true;
    _state.dispatch({'id': _state.id, 'type': 'connect'}).ignore();
    return CoreWebSocketRoute._(_state, true);
  }

  String get _sendType => isServerSide ? 'sendToServer' : 'sendToPage';
  String get _closeType => isServerSide ? 'closeServer' : 'closePage';
}

/// One registered `routeWebSocket` handler.
class _HandlerEntry {
  final String pattern;
  final CoreWebSocketRouteHandler handler;

  /// The page this handler belongs to, or null for a context-level one.
  final CorePage? page;

  _HandlerEntry(this.pattern, this.handler, this.page);
}

/// The `routeWebSocket` machinery of one browser context.
///
/// Port of `webSocketRouteDispatcher.ts` minus its dispatcher half: the
/// binding, the injected mock and the request/response protocol between them
/// are upstream's; the channel that carried them is not, because this port
/// has none.
///
/// It lives on the context because the binding does: upstream exposes
/// `__pwWebSocketBinding` on the context even when only one page is routed,
/// and refuses a second client that tries to route the same context.
class CoreWebSocketRouteManager {
  final CoreBrowserContext context;

  final List<_HandlerEntry> _handlers = <_HandlerEntry>[];
  final Map<String, _RouteState> _routes = <String, _RouteState>{};
  final Set<CorePage> _watchedPages = <CorePage>{};

  bool _bindingInstalled = false;
  bool _mockInstalled = false;

  CoreWebSocketRouteManager(this.context);

  /// Routes the sockets matching [pattern]. With [page], only that page's.
  ///
  /// The newest handler wins, which is what upstream's `unshift` into
  /// `_webSocketRoutes` buys it (`client/page.ts:588`).
  Future<void> route(String pattern, CoreWebSocketRouteHandler handler,
      {CorePage? page}) async {
    _handlers.insert(0, _HandlerEntry(pattern, handler, page));
    await _install();
  }

  Future<void> _install() async {
    if (!_bindingInstalled) {
      _bindingInstalled = true;
      try {
        await (context as CoreBrowserContextBindings)
            .exposeBinding(kWebSocketBindingName, _onBinding);
      } catch (error) {
        _bindingInstalled = false;
        rethrow;
      }
    }
    if (!_mockInstalled) {
      _mockInstalled = true;
      try {
        await (context as CoreBrowserContextBindings)
            .addInitScript(kInjectedWebSocketMockSource);
      } catch (error) {
        _mockInstalled = false;
        rethrow;
      }
    }
  }

  _HandlerEntry? _handlerFor(CorePage page, String url) {
    // Page-level handlers win over context-level ones, which is the order
    // upstream checks the two dispatchers in.
    for (final entry in _handlers) {
      if (entry.page != page) continue;
      if (CorePageRoutes.matchesPattern(entry.pattern, url)) return entry;
    }
    for (final entry in _handlers) {
      if (entry.page != null) continue;
      if (CorePageRoutes.matchesPattern(entry.pattern, url)) return entry;
    }
    return null;
  }

  Future<dynamic> _onBinding(CoreBindingSource source, List<dynamic> args) {
    final payload = args.isEmpty ? null : args.first;
    if (payload is! Map) return Future<dynamic>.value();
    final id = payload['id'] as String?;
    if (id == null) return Future<dynamic>.value();

    if (payload['type'] == 'onCreate') {
      return _onCreate(source, id, payload);
    }

    final state = _routes[id];
    if (state == null) return Future<dynamic>.value();
    switch (payload['type']) {
      case 'onMessageFromPage':
        state.messageFromPage(CoreWebSocketData.fromJson(payload['data']));
      case 'onMessageFromServer':
        state.messageFromServer(CoreWebSocketData.fromJson(payload['data']));
      case 'onClosePage':
        state.closePage(_asInt(payload['code']), payload['reason'] as String?,
            payload['wasClean'] == true);
      case 'onCloseServer':
        state.closeServer(_asInt(payload['code']), payload['reason'] as String?,
            payload['wasClean'] == true);
    }
    return Future<dynamic>.value();
  }

  Future<dynamic> _onCreate(CoreBindingSource source, String id,
      Map<dynamic, dynamic> payload) async {
    final page = source.page;
    final frame = source.frame ?? page.mainFrame;
    final url = payload['url'] as String? ?? '';

    Future<void> dispatch(Map<String, dynamic> request) async {
      try {
        await page.evaluateInFrame(frame,
            'globalThis.$kWebSocketDispatchName(${jsonEncode(request)})');
      } catch (_) {
        // The document went away; there is no mock left to steer.
      }
    }

    final entry = _handlerFor(page, url);
    if (entry == null) {
      // Nothing claims it: tell the mock to behave like the native socket.
      await dispatch({'id': id, 'type': 'passthrough'});
      return null;
    }

    final state = _RouteState(
      id: id,
      url: url,
      protocols: [
        for (final protocol in payload['protocols'] as List? ?? const [])
          '$protocol',
      ],
      page: page,
      frame: frame,
      dispatch: dispatch,
    );
    _routes[id] = state;
    _watch(page);

    await entry.handler(CoreWebSocketRoute._(state, false));
    await state.afterHandle();
    return null;
  }

  /// Tears down the routes of a page whose mock can no longer answer.
  ///
  /// Port of `_executionContextGone`: a navigation, a detach, a crash or a
  /// close all mean no more messages will arrive, so both sides are told the
  /// socket closed cleanly instead of being left hanging.
  void _watch(CorePage page) {
    if (!_watchedPages.add(page)) return;
    page.on('frameNavigated', (dynamic frame) {
      _gone(page, frame is CoreFrame ? frame : null);
    });
    page.on('frameDetached', (dynamic frame) {
      _gone(page, frame is CoreFrame ? frame : null);
    });
    page.on('close', ([dynamic _]) {
      _gone(page, null);
      // Nothing more can come from this page; stop holding on to it.
      _watchedPages.remove(page);
    });
    page.on('crash', ([dynamic _]) => _gone(page, null));
  }

  void _gone(CorePage page, CoreFrame? frame) {
    for (final state in _routes.values.toList()) {
      if (state.page != page) continue;
      if (frame != null && state.frame != frame) continue;
      if (state.gone) continue;
      state.gone = true;
      _routes.remove(state.id);
      state.closePage(null, null, true);
      state.closeServer(null, null, true);
    }
  }

  static int? _asInt(dynamic value) => (value as num?)?.toInt();
}

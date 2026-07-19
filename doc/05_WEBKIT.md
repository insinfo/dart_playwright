# 05 — Port Detalhado do Motor WebKit (Inspector Protocol)

## 1. Visão Geral

O WebKit no Playwright usa o **WebKit Inspector Protocol**, uma versão patcheada do protocolo nativo do WebKit. O WebKit tem a arquitetura mais complexa dos três motores por causa do conceito de **PageProxy**.

### 1.1. Arquivos Fonte (TypeScript)

```
packages/playwright-core/src/server/webkit/
├── webkit.ts                (7.1 KB) — BrowserType para WebKit
├── wkBrowser.ts            (16.2 KB) — Implementação do Browser
├── wkConnection.ts          (6.4 KB) — Conexão Inspector
├── wkPage.ts               (62.1 KB) — Implementação de Page (MAIOR DE TODOS)
├── wkInput.ts               (6.3 KB) — Keyboard, Mouse, Touchscreen
├── wkExecutionContext.ts    (5.9 KB) — Contexto de execução JS
├── wkInterceptableRequest.ts (8.1 KB) — Interceptação de request
├── wkProvisionalPage.ts     (5.0 KB) — Páginas provisórias (cross-origin nav)
├── wkWorkers.ts             (4.4 KB) — Workers
├── protocol.d.ts          (312.2 KB) — Tipos do Inspector Protocol
├── webview/                            — WebView support (Electron-like)
└── DEPS.list                (155 B)  — Dependências de import
```

**Total**: ~434 KB de código TypeScript

### 1.2. Conceitos Únicos do WebKit

| Conceito | Descrição |
|---|---|
| **PageProxy** | Proxy intermediário entre browser e page. Cada page tem seu pageProxyId |
| **ProvisionalPage** | Page temporária criada durante navegação cross-origin |
| **BrowserContext isolation** | Contextos são gerenciados pelo domínio Playwright custom |
| **Dual sessions** | Cada page tem session do browser E session da page |

---

## 2. WkConnection — Conexão Inspector

### 2.1. Modelo de Conexão

O WebKit Inspector tem um modelo multi-camada:
1. **Browser connection** — Comandos de nível browser (Playwright domain)
2. **Page sessions** — Cada pageProxy tem sua própria session
3. Os comandos são roteados por `pageProxyId`

```dart
// lib/src/server/webkit/wk_connection.dart

/// Conexão com o WebKit Inspector Protocol.
/// Diferente do CDP e Juggler, o WebKit usa pageProxyId para rotear mensagens.
class WkConnection {
  final ConnectionTransport _transport;
  int _lastId = 0;
  bool _closed = false;
  
  final _callbacks = <int, Completer<Map<String, dynamic>>>{};
  final _sessions = <String, WkSession>{};
  
  final _eventController = StreamController<WkEvent>.broadcast();
  
  WkConnection(this._transport) {
    _transport.onMessage.listen(_onMessage);
    _transport.onClose.listen((_) => _onClose());
  }
  
  /// Enviar comando no escopo do browser (sem pageProxyId)
  Future<Map<String, dynamic>> browserSend(
    String method, [Map<String, dynamic>? params]
  ) async {
    return _send(method, params: params);
  }
  
  /// Enviar comando no escopo de uma page (com pageProxyId)
  Future<Map<String, dynamic>> pageSend(
    String pageProxyId,
    String method, [Map<String, dynamic>? params]
  ) async {
    return _send(method, params: params, pageProxyId: pageProxyId);
  }
  
  Future<Map<String, dynamic>> _send(
    String method, {
    Map<String, dynamic>? params,
    String? pageProxyId,
  }) async {
    if (_closed) throw StateError('Connection is closed');
    
    final id = ++_lastId;
    final completer = Completer<Map<String, dynamic>>();
    _callbacks[id] = completer;
    
    final message = <String, dynamic>{
      'id': id,
      'method': method,
    };
    if (params != null) message['params'] = params;
    if (pageProxyId != null) message['pageProxyId'] = pageProxyId;
    
    _transport.send(ProtocolRequest(
      id: id,
      method: method,
      params: params,
    ));
    
    return completer.future;
  }
  
  void _onMessage(ProtocolResponse response) {
    if (response.id != null) {
      // Resposta a um comando
      final completer = _callbacks.remove(response.id);
      if (completer == null) return;
      
      if (response.error != null) {
        completer.completeError(ProtocolException(response.error!.message));
      } else {
        completer.complete(response.result ?? {});
      }
    } else if (response.method != null) {
      // Evento
      final event = WkEvent(
        method: response.method!,
        params: response.params ?? {},
        pageProxyId: response.pageProxyId,
        browserContextId: response.browserContextId,
      );
      
      // Despachar para session da page se aplicável
      if (response.pageProxyId != null) {
        final session = _sessions[response.pageProxyId!];
        session?._handleEvent(event);
      }
      
      _eventController.add(event);
    }
  }
  
  /// Criar session para uma page
  WkSession createPageSession(String pageProxyId) {
    final session = WkSession(this, pageProxyId);
    _sessions[pageProxyId] = session;
    return session;
  }
  
  void _onClose() {
    _closed = true;
    for (final completer in _callbacks.values) {
      completer.completeError(StateError('Connection closed'));
    }
    _callbacks.clear();
    for (final session in _sessions.values) {
      session.dispose();
    }
    _sessions.clear();
  }
  
  Stream<WkEvent> get onEvent => _eventController.stream;
  
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _transport.close();
  }
}

/// Session para uma page específica do WebKit
class WkSession {
  final WkConnection _connection;
  final String pageProxyId;
  final _eventController = StreamController<WkEvent>.broadcast();
  bool _disposed = false;
  
  WkSession(this._connection, this.pageProxyId);
  
  Future<Map<String, dynamic>> send(String method, [Map<String, dynamic>? params]) {
    if (_disposed) throw StateError('Session disposed');
    return _connection.pageSend(pageProxyId, method, params);
  }
  
  Stream<Map<String, dynamic>> on(String method) {
    return _eventController.stream
        .where((e) => e.method == method)
        .map((e) => e.params);
  }
  
  void _handleEvent(WkEvent event) {
    if (!_disposed) _eventController.add(event);
  }
  
  void dispose() {
    _disposed = true;
    _eventController.close();
  }
}

class WkEvent {
  final String method;
  final Map<String, dynamic> params;
  final String? pageProxyId;
  final String? browserContextId;
  
  WkEvent({
    required this.method,
    required this.params,
    this.pageProxyId,
    this.browserContextId,
  });
}
```

---

## 3. WkBrowser — Implementação do Browser

```dart
// lib/src/server/webkit/wk_browser.dart

class WkBrowser extends Browser {
  final WkConnection _connection;
  final Process? _process;
  
  final _contexts = <String, WkBrowserContext>{};
  final _pageProxies = <String, WkPage>{};
  
  WkBrowser._(this._connection, {Process? process}) : _process = process;
  
  static Future<WkBrowser> connect(
    WkConnection connection, {
    Process? process,
    BrowserOptions? options,
  }) async {
    final browser = WkBrowser._(connection, process: process);
    await browser._initialize(options);
    return browser;
  }
  
  Future<void> _initialize(BrowserOptions? options) async {
    // WebKit usa o domínio custom "Playwright" para gestão de browser
    await _connection.browserSend('Playwright.enable');
    
    // Escutar eventos de page proxy
    _connection.onEvent.listen((event) {
      switch (event.method) {
        case 'Playwright.pageProxyCreated':
          _onPageProxyCreated(event.params);
          break;
        case 'Playwright.pageProxyDestroyed':
          _onPageProxyDestroyed(event.params);
          break;
        case 'Playwright.provisionalLoadFailed':
          _onProvisionalLoadFailed(event.params);
          break;
        case 'Playwright.downloadCreated':
          _onDownloadCreated(event.params);
          break;
        case 'Playwright.downloadFinished':
          _onDownloadFinished(event.params);
          break;
      }
    });
  }
  
  @override
  Future<BrowserContext> newContext({/* options */}) async {
    final result = await _connection.browserSend('Playwright.createContext', {
      // Configurações do contexto
      if (options?.proxy != null) 'proxyServer': options!.proxy!.server,
      if (options?.bypassCSP == true) 'bypassCSP': true,
      if (options?.javaScriptEnabled == false) 'javaScriptDisabled': true,
      // ... mais opções
    });
    
    final browserContextId = result['browserContextId'] as String;
    
    final context = WkBrowserContext(
      browser: this,
      connection: _connection,
      browserContextId: browserContextId,
    );
    
    _contexts[browserContextId] = context;
    return context;
  }
  
  void _onPageProxyCreated(Map<String, dynamic> params) {
    final pageProxyInfo = params['pageProxyInfo'] as Map<String, dynamic>;
    final pageProxyId = pageProxyInfo['pageProxyId'] as String;
    final browserContextId = pageProxyInfo['browserContextId'] as String;
    
    final context = _contexts[browserContextId];
    if (context == null) return;
    
    // Criar session para esta page
    final session = _connection.createPageSession(pageProxyId);
    
    final page = WkPage(
      session: session,
      browser: this,
      context: context,
      pageProxyId: pageProxyId,
    );
    
    _pageProxies[pageProxyId] = page;
    context._onPageCreated(page);
  }
  
  void _onPageProxyDestroyed(Map<String, dynamic> params) {
    final pageProxyId = params['pageProxyId'] as String;
    final page = _pageProxies.remove(pageProxyId);
    page?._onClosed();
  }
  
  @override
  Future<void> close() async {
    for (final context in _contexts.values.toList()) {
      await context.close();
    }
    await _connection.close();
    _process?.kill();
  }
}
```

---

## 4. WkPage — Implementação da Page

O `wkPage.ts` é o **maior arquivo** do Playwright (62.1 KB). As responsabilidades incluem:

```dart
// lib/src/server/webkit/wk_page.dart

class WkPage extends PageDelegate {
  final WkSession _session;
  final WkBrowser _browser;
  final WkBrowserContext _context;
  final String _pageProxyId;
  
  late final WkInput _input;
  final _executionContexts = <int, WkExecutionContext>{};
  WkProvisionalPage? _provisionalPage;
  
  WkPage({
    required WkSession session,
    required WkBrowser browser,
    required WkBrowserContext context,
    required String pageProxyId,
  }) : _session = session,
       _browser = browser,
       _context = context,
       _pageProxyId = pageProxyId;
  
  Future<void> initialize() async {
    // Habilitar domínios
    await Future.wait([
      _session.send('Page.enable'),
      _session.send('Runtime.enable'),
      _session.send('Network.enable'),
      _session.send('Console.enable'),
      _session.send('Dialog.enable'),
    ]);
    
    _input = WkInput(_session);
    
    _setupEventListeners();
    await _applyContextSettings();
  }
  
  void _setupEventListeners() {
    // Page lifecycle
    _session.on('Page.loadEventFired').listen((_) {
      _onLoadEventFired();
    });
    
    _session.on('Page.domContentEventFired').listen((_) {
      _onDomContentEventFired();
    });
    
    _session.on('Page.frameNavigated').listen((params) {
      _onFrameNavigated(params);
    });
    
    _session.on('Page.frameAttached').listen((params) {
      _onFrameAttached(params);
    });
    
    _session.on('Page.frameDetached').listen((params) {
      _onFrameDetached(params);
    });
    
    // Runtime
    _session.on('Runtime.executionContextCreated').listen((params) {
      _onExecutionContextCreated(params);
    });
    
    // Console
    _session.on('Console.messageAdded').listen((params) {
      _onConsoleMessage(params);
    });
    
    // Dialog
    _session.on('Dialog.javascriptDialogOpening').listen((params) {
      _onDialog(params);
    });
    
    // Network
    _session.on('Network.requestWillBeSent').listen((params) {
      _onRequestWillBeSent(params);
    });
    
    _session.on('Network.responseReceived').listen((params) {
      _onResponseReceived(params);
    });
    
    // ProvisionalPage — CONCEITO ÚNICO DO WEBKIT
    // Quando há navegação cross-origin, o WebKit cria uma "provisional page"
    // que substitui a page atual após o commit da navegação
    _session.on('Page.provisionalLoadStarted').listen((params) {
      _onProvisionalLoadStarted(params);
    });
  }
  
  // === ProvisionalPage handling ===
  
  void _onProvisionalLoadStarted(Map<String, dynamic> params) {
    // WebKit cria uma nova page para navegação cross-origin
    // Precisamos transferir os event listeners para a nova page
    final provisionalPageProxyId = params['provisionalPageProxyId'] as String?;
    if (provisionalPageProxyId == null) return;
    
    _provisionalPage = WkProvisionalPage(
      connection: _session._connection,
      pageProxyId: provisionalPageProxyId,
      parentPage: this,
    );
  }
  
  // === Navegação ===
  
  @override
  Future<Response?> navigate(String url, {
    Duration? timeout,
    WaitUntil? waitUntil,
    String? referer,
  }) async {
    final result = await _session.send('Page.navigate', {
      'url': url,
      if (referer != null) 'referrer': referer,
    });
    
    // Esperar pela navegação
    await _waitForLifecycle(
      waitUntil: waitUntil ?? WaitUntil.load,
      timeout: timeout,
    );
    
    return _lastResponse;
  }
  
  // === Screenshot ===
  
  @override
  Future<Uint8List> screenshot({
    ScreenshotType type = ScreenshotType.png,
    int? quality,
    bool? fullPage,
    Rect? clip,
    bool? omitBackground,
  }) async {
    // WebKit requer Page.snapshotRect para screenshots
    final result = await _session.send('Page.snapshotRect', {
      if (clip != null) ...{
        'x': clip.left,
        'y': clip.top,
        'width': clip.width,
        'height': clip.height,
      },
      if (fullPage == true) 'coordinateSystem': 'Page',
    });
    
    return base64Decode(result['dataURL'] as String);
  }
  
  // === Evaluate ===
  
  @override
  Future<dynamic> evaluate(String expression, {List<dynamic>? args}) async {
    final context = _mainExecutionContext;
    if (context == null) throw StateError('No execution context');
    return context.evaluate(expression, args: args);
  }
}
```

---

## 5. WkProvisionalPage — Páginas Provisórias

### 5.1. Conceito

Quando o WebKit navega para um URL cross-origin, ele:
1. Cria uma **ProvisionalPage** com novo contexto de execução
2. Carrega o conteúdo na provisional page
3. Faz **commit** da navegação — a provisional page substitui a original
4. Todos os event listeners são transferidos

Isso é **único do WebKit** e não existe no Chromium nem no Firefox.

```dart
// lib/src/server/webkit/wk_provisional_page.dart

/// Página provisória criada durante navegação cross-origin no WebKit.
/// 
/// Quando uma navegação cross-origin acontece no WebKit, o motor cria
/// uma página temporária para carregar o novo conteúdo. Após o commit,
/// esta página provisória substitui a página original.
class WkProvisionalPage {
  final WkConnection _connection;
  final String _pageProxyId;
  final WkPage _parentPage;
  
  late final WkSession _session;
  final _executionContexts = <int, WkExecutionContext>{};
  
  bool _committed = false;
  
  WkProvisionalPage({
    required WkConnection connection,
    required String pageProxyId,
    required WkPage parentPage,
  }) : _connection = connection,
       _pageProxyId = pageProxyId,
       _parentPage = parentPage {
    _session = _connection.createPageSession(_pageProxyId);
    _initialize();
  }
  
  Future<void> _initialize() async {
    // Habilitar domínios na provisional page
    await Future.wait([
      _session.send('Page.enable'),
      _session.send('Runtime.enable'),
      _session.send('Network.enable'),
    ]);
    
    // Escutar eventos
    _session.on('Runtime.executionContextCreated').listen((params) {
      _onExecutionContextCreated(params);
    });
    
    _session.on('Network.requestWillBeSent').listen((params) {
      // Redirecionar eventos de rede para a parent page
      _parentPage._onRequestWillBeSent(params);
    });
  }
  
  /// Commit da navegação — esta page substitui a parent page
  void commit() {
    _committed = true;
    // Transferir execution contexts para a parent page
    for (final entry in _executionContexts.entries) {
      _parentPage._executionContexts[entry.key] = entry.value;
    }
  }
  
  void dispose() {
    if (!_committed) {
      _session.dispose();
    }
  }
}
```

---

## 6. WebKit BrowserType (Lançamento)

```dart
// lib/src/server/webkit/webkit.dart

class WebKitBrowserType extends BrowserType {
  @override
  String get name => 'webkit';
  
  @override
  Future<WkBrowser> launch({/* options */}) async {
    final executable = executablePath ?? 
        registry.executablePath('webkit');
    
    if (executable == null) {
      throw PlaywrightException(
        'WebKit is not installed. Run: dart run playwright install webkit',
      );
    }
    
    // WebKit usa um launcher específico por plataforma
    // Windows: Playwright.exe
    // macOS/Linux: pw_run.sh
    final args = _buildArgs(
      headless: headless ?? true,
    );
    
    final process = await Process.start(executable, args);
    
    final transport = PipeTransport.fromProcess(process);
    final connection = WkConnection(transport);
    
    return WkBrowser.connect(connection, process: process, options: browserOptions);
  }
  
  List<String> _buildArgs({required bool headless}) {
    final args = <String>[
      '--inspector-pipe',  // Comunicação via pipe
    ];
    
    if (headless) {
      args.add('--headless');
    }
    
    return args;
  }
}
```

---

## 7. Protocolo WebKit Inspector — Referência de Domínios

### 7.1. Playwright Domain (Custom)

```
Playwright.enable()
Playwright.createContext({ ... }) → { browserContextId }
Playwright.deleteContext({ browserContextId })
Playwright.createPage({ browserContextId }) → { pageProxyId }
Playwright.navigate({ url, pageProxyId, ... })
Playwright.setGeolocationOverride({ browserContextId, ... })
Playwright.grantPermissions({ browserContextId, permissions })
Playwright.resetPermissions({ browserContextId })

Events:
  Playwright.pageProxyCreated({ pageProxyInfo })
  Playwright.pageProxyDestroyed({ pageProxyId })
  Playwright.provisionalLoadFailed({ pageProxyId, ... })
  Playwright.downloadCreated({ ... })
  Playwright.downloadFinished({ ... })
```

### 7.2. Page Domain

```
Page.enable()
Page.navigate({ url }) → { loaderId }
Page.reload() → { loaderId }
Page.goBack()
Page.goForward()
Page.snapshotRect({ x, y, width, height, coordinateSystem }) → { dataURL }
Page.setInterceptFileChooserDialog({ enabled })
Page.handleJavaScriptDialog({ accept, promptText? })
Page.overrideUserAgent({ value })
Page.setEmulatedMedia({ media })

Events:
  Page.loadEventFired({ timestamp })
  Page.domContentEventFired({ timestamp })
  Page.frameNavigated({ frame })
  Page.frameAttached({ frameId, parentFrameId })
  Page.frameDetached({ frameId })
  Page.frameScheduledNavigation({ ... })
  Page.frameClearedScheduledNavigation({ ... })
  Page.provisionalLoadStarted({ ... })
```

### 7.3. Network Domain

```
Network.enable()
Network.disable()
Network.setRequestInterception({ enabled, interceptRequests })
Network.interceptRequest({ requestId })
Network.interceptContinue({ requestId, url?, method?, headers?, postData? })
Network.interceptResponse({ requestId, status, statusText, headers })
Network.getResponseBody({ requestId }) → { body, base64Encoded }

Events:
  Network.requestWillBeSent({ requestId, frameId, ... })
  Network.responseReceived({ requestId, ... })
  Network.loadingFinished({ requestId })
  Network.loadingFailed({ requestId, errorText })
  Network.requestIntercepted({ requestId, request })
```

### 7.4. Runtime Domain

```
Runtime.enable()
Runtime.evaluate({ expression, objectGroup?, ... }) → { result, wasThrown }
Runtime.callFunctionOn({ functionDeclaration, objectId?, arguments? }) → { result, wasThrown }
Runtime.getProperties({ objectId, ownProperties? }) → { properties, internalProperties }
Runtime.releaseObject({ objectId })
Runtime.releaseObjectGroup({ objectGroup })

Events:
  Runtime.executionContextCreated({ context })
  Runtime.executionContextDestroyed({ executionContextId })
```

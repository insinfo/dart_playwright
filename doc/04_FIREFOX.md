# 04 — Port Detalhado do Motor Firefox (Juggler)

## 1. Visão Geral

O Firefox no Playwright usa o protocolo **Juggler**, um protocolo de automação customizado mantido pelo time do Playwright. Diferente do CDP que é padrão do Chromium, o Juggler é implementado como patches aplicados ao código-fonte do Firefox (Gecko).

### 1.1. Arquivos Fonte (TypeScript)

```
packages/playwright-core/src/server/firefox/
├── firefox.ts              (5.5 KB) — BrowserType para Firefox
├── ffBrowser.ts           (18.6 KB) — Implementação do Browser
├── ffConnection.ts         (6.4 KB) — Conexão Juggler
├── ffPage.ts              (27.6 KB) — Implementação de Page
├── ffNetworkManager.ts    (11.5 KB) — Gerenciador de rede
├── ffInput.ts              (6.5 KB) — Keyboard, Mouse, Touchscreen
├── ffExecutionContext.ts   (6.0 KB) — Contexto de execução JS
└── protocol.d.ts          (40.9 KB) — Tipos do protocolo Juggler
```

**Total**: ~123 KB de código TypeScript

### 1.2. Diferenças fundamentais em relação ao Chromium

| Aspecto | Chromium (CDP) | Firefox (Juggler) |
|---|---|---|
| Protocolo | Chrome DevTools Protocol | Juggler (custom) |
| Session model | Target → Session (1:1) | Sem sessions; usa `browsingContextId` |
| Binário | Chrome for Testing padrão | Firefox patcheado (Nightly + patches) |
| Interceptação | Fetch domain | Network domain custom |
| Screenshot | Page.captureScreenshot | Page.screenshot (custom) |
| Dialogs | Page.javascriptDialogOpening | Page.dialogOpened |
| Downloads | Browser.downloadWillBegin | Page.downloadCreated |

---

## 2. FfConnection — Conexão Juggler

### 2.1. Diferenças do CDP

O Juggler não usa "sessions" como o CDP. Em vez disso:
- Comandos são enviados com `browsingContextId` para target específico
- Eventos vêm com `browsingContextId` para identificar a origem
- O handshake inicial requer `Browser.enable`

### 2.2. Port para Dart

```dart
// lib/src/server/firefox/ff_connection.dart

/// Conexão Juggler com o Firefox.
/// Não usa sessions como o CDP — usa browsingContextId.
class FfConnection {
  final ConnectionTransport _transport;
  int _lastId = 0;
  bool _closed = false;
  
  final _callbacks = <int, Completer<Map<String, dynamic>>>{};
  final _eventController = StreamController<JugglerEvent>.broadcast();
  
  FfConnection(this._transport) {
    _transport.onMessage.listen(_onMessage);
    _transport.onClose.listen((_) => _onClose());
  }
  
  /// Iniciar conexão — o Juggler requer Browser.enable
  Future<void> initialize() async {
    // O Firefox Playwright espera que o cliente chame Browser.enable
    // para começar a receber eventos
    await send('Browser.enable');
  }
  
  /// Enviar comando Juggler
  Future<Map<String, dynamic>> send(
    String method, [Map<String, dynamic>? params]
  ) async {
    if (_closed) throw StateError('Connection is closed');
    
    final id = ++_lastId;
    final completer = Completer<Map<String, dynamic>>();
    _callbacks[id] = completer;
    
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
      // Evento do Juggler
      _eventController.add(JugglerEvent(
        method: response.method!,
        params: response.params ?? {},
      ));
    }
  }
  
  void _onClose() {
    _closed = true;
    for (final completer in _callbacks.values) {
      completer.completeError(StateError('Connection closed'));
    }
    _callbacks.clear();
  }
  
  /// Escutar eventos de um método específico
  Stream<Map<String, dynamic>> on(String method) {
    return _eventController.stream
        .where((e) => e.method == method)
        .map((e) => e.params);
  }
  
  Stream<JugglerEvent> get onEvent => _eventController.stream;
  
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _transport.close();
  }
}

class JugglerEvent {
  final String method;
  final Map<String, dynamic> params;
  JugglerEvent({required this.method, required this.params});
}
```

---

## 3. FfBrowser — Implementação do Browser

```dart
// lib/src/server/firefox/ff_browser.dart

class FfBrowser extends Browser {
  final FfConnection _connection;
  final Process? _process;
  
  final _contexts = <String, FfBrowserContext>{};
  final _pages = <String, FfPage>{};
  
  FfBrowser._(this._connection, {Process? process}) : _process = process;
  
  static Future<FfBrowser> connect(
    FfConnection connection, {
    Process? process,
    BrowserOptions? options,
  }) async {
    final browser = FfBrowser._(connection, process: process);
    await browser._initialize(options);
    return browser;
  }
  
  Future<void> _initialize(BrowserOptions? options) async {
    // Handshake Juggler
    await _connection.initialize();
    
    // Escutar eventos de browser
    _connection.on('Browser.attachedToTarget').listen(_onAttachedToTarget);
    _connection.on('Browser.detachedFromTarget').listen(_onDetachedFromTarget);
    _connection.on('Browser.downloadCreated').listen(_onDownloadCreated);
    _connection.on('Browser.downloadFinished').listen(_onDownloadFinished);
    _connection.on('Browser.videoRecordingStarted').listen(_onVideoRecordingStarted);
  }
  
  @override
  Future<BrowserContext> newContext({/* ... options ... */}) async {
    final result = await _connection.send('Browser.createBrowserContext', {
      if (options?.removeOnDetach == true) 'removeOnDetach': true,
    });
    
    final browserContextId = result['browserContextId'] as String;
    
    final context = FfBrowserContext(
      browser: this,
      connection: _connection,
      browserContextId: browserContextId,
    );
    
    _contexts[browserContextId] = context;
    
    // Aplicar configurações
    await context._initialize(options);
    
    return context;
  }
  
  void _onAttachedToTarget(Map<String, dynamic> params) {
    final targetInfo = params['targetInfo'] as Map<String, dynamic>;
    final type = targetInfo['type'] as String;
    
    if (type == 'page') {
      final targetId = targetInfo['targetId'] as String;
      final browserContextId = targetInfo['browserContextId'] as String;
      final openerId = targetInfo['openerId'] as String?;
      
      final context = _contexts[browserContextId];
      if (context != null) {
        final page = FfPage(
          connection: _connection,
          targetId: targetId,
          context: context,
          openerId: openerId,
        );
        _pages[targetId] = page;
        context._onPageCreated(page);
      }
    }
  }
  
  void _onDetachedFromTarget(Map<String, dynamic> params) {
    final targetId = params['targetId'] as String;
    final page = _pages.remove(targetId);
    if (page != null) {
      page._onDetached();
    }
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

## 4. Firefox BrowserType (Lançamento)

```dart
// lib/src/server/firefox/firefox.dart

class Firefox extends BrowserType {
  @override
  String get name => 'firefox';
  
  @override
  Future<FfBrowser> launch({/* ... options ... */}) async {
    final executable = executablePath ?? 
        registry.executablePath('firefox');
    
    if (executable == null) {
      throw PlaywrightException(
        'Firefox is not installed. Run: dart run playwright install firefox',
      );
    }
    
    // Criar perfil temporário
    final profileDir = await _createProfile(options);
    
    // Construir argumentos
    final args = _buildArgs(
      headless: headless ?? true,
      profileDir: profileDir,
    );
    
    // Lançar processo
    final process = await Process.start(executable, args, environment: {
      ...?env,
      // Firefox Juggler requer variáveis de ambiente especiais
      'MOZ_CRASHREPORTER_AUTO_SUBMIT': '1',
      'MOZ_CRASHREPORTER_DISABLE': '1',
    });
    
    // Transporte via pipe
    final transport = PipeTransport.fromProcess(process);
    
    // Conexão Juggler
    final connection = FfConnection(transport);
    
    // Browser
    return FfBrowser.connect(connection, process: process, options: browserOptions);
  }
  
  List<String> _buildArgs({
    required bool headless,
    required String profileDir,
  }) {
    final args = <String>[
      '--no-remote',
      '--profile', profileDir,
      '--juggler-pipe',  // Habilitar Juggler via pipe
    ];
    
    if (headless) {
      args.add('--headless');
    }
    
    args.add('about:blank');
    
    return args;
  }
  
  Future<String> _createProfile(LaunchOptions? options) async {
    final profileDir = await Directory.systemTemp.createTemp('playwright_firefox_');
    
    // Criar prefs.js com configurações de automação
    final prefsFile = File(path.join(profileDir.path, 'user.js'));
    await prefsFile.writeAsString(_defaultPrefs);
    
    return profileDir.path;
  }
  
  static const _defaultPrefs = '''
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.startup.homepage_override.mstone", "ignore");
user_pref("browser.tabs.warnOnClose", false);
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("dom.disable_open_during_load", false);
user_pref("dom.file.createInChild", true);
user_pref("dom.max_script_run_time", 0);
user_pref("network.cookie.lifetimePolicy", 0);
user_pref("network.http.max-connections-per-server", 256);
user_pref("toolkit.startup.max_resumed_crashes", -1);
// ... muitas outras prefs para automação
''';
}
```

---

## 5. FfPage — Implementação de Page

```dart
// lib/src/server/firefox/ff_page.dart

class FfPage extends PageDelegate {
  final FfConnection _connection;
  final String _targetId;
  final FfBrowserContext _context;
  
  late final FfNetworkManager _networkManager;
  late final FfInput _input;
  late final FfExecutionContext _mainExecutionContext;
  
  FfPage({
    required FfConnection connection,
    required String targetId,
    required FfBrowserContext context,
    String? openerId,
  }) : _connection = connection,
       _targetId = targetId,
       _context = context;
  
  Future<void> initialize() async {
    // Habilitar domínios necessários
    await Future.wait([
      _send('Runtime.enable'),
      _send('Network.enable'),
      _send('Page.enable'),
    ]);
    
    // Setup network manager
    _networkManager = FfNetworkManager(_connection, _targetId, _context);
    await _networkManager.initialize();
    
    // Setup input
    _input = FfInput(_connection, _targetId);
    
    // Escutar eventos
    _setupEventListeners();
    
    // Aplicar configurações
    await _applyContextSettings();
  }
  
  /// Enviar comando no contexto deste target
  Future<Map<String, dynamic>> _send(String method, [Map<String, dynamic>? params]) {
    final enrichedParams = <String, dynamic>{
      ...?params,
      'browsingContextId': _targetId,
    };
    return _connection.send(method, enrichedParams);
  }
  
  void _setupEventListeners() {
    _connection.on('Page.eventFired').listen((params) {
      if (params['browsingContextId'] != _targetId) return;
      _onEventFired(params);
    });
    
    _connection.on('Page.navigationCommitted').listen((params) {
      if (params['browsingContextId'] != _targetId) return;
      _onNavigationCommitted(params);
    });
    
    _connection.on('Page.navigationStarted').listen((params) {
      if (params['browsingContextId'] != _targetId) return;
      _onNavigationStarted(params);
    });
    
    _connection.on('Page.sameDocumentNavigation').listen((params) {
      if (params['browsingContextId'] != _targetId) return;
      _onSameDocumentNavigation(params);
    });
    
    _connection.on('Runtime.executionContextCreated').listen((params) {
      if (params['browsingContextId'] != _targetId) return;
      _onExecutionContextCreated(params);
    });
    
    _connection.on('Runtime.executionContextDestroyed').listen((params) {
      _onExecutionContextDestroyed(params);
    });
    
    _connection.on('Page.dialogOpened').listen((params) {
      if (params['browsingContextId'] != _targetId) return;
      _onDialog(params);
    });
    
    _connection.on('Runtime.console').listen((params) {
      if (params['browsingContextId'] != _targetId) return;
      _onConsole(params);
    });
  }
  
  @override
  Future<Response?> navigate(String url, {
    Duration? timeout,
    WaitUntil? waitUntil,
    String? referer,
  }) async {
    final result = await _send('Page.navigate', {
      'url': url,
      if (referer != null) 'referer': referer,
    });
    
    final navigationId = result['navigationId'] as String?;
    
    if (navigationId == null) {
      // Same-document navigation
      return null;
    }
    
    // Esperar pela navegação completar
    await _waitForNavigation(
      navigationId: navigationId,
      waitUntil: waitUntil ?? WaitUntil.load,
      timeout: timeout,
    );
    
    return _networkManager.responseForNavigation(navigationId);
  }
  
  @override
  Future<Uint8List> screenshot({
    ScreenshotType type = ScreenshotType.png,
    int? quality,
    bool? fullPage,
    Rect? clip,
    bool? omitBackground,
  }) async {
    final result = await _send('Page.screenshot', {
      'mimeType': type == ScreenshotType.png ? 'image/png' : 'image/jpeg',
      if (quality != null) 'quality': quality,
      if (fullPage == true) 'fullPage': true,
      if (clip != null) 'clip': {
        'x': clip.left,
        'y': clip.top,
        'width': clip.width,
        'height': clip.height,
      },
    });
    
    return base64Decode(result['data'] as String);
  }
  
  @override
  Future<dynamic> evaluate(String expression, {List<dynamic>? args}) async {
    final context = _mainExecutionContext;
    return context.evaluate(expression, args: args);
  }
}
```

---

## 6. FfNetworkManager

```dart
// lib/src/server/firefox/ff_network_manager.dart

class FfNetworkManager {
  final FfConnection _connection;
  final String _browsingContextId;
  final FfBrowserContext _context;
  
  final _requests = <String, Request>{};
  
  FfNetworkManager(this._connection, this._browsingContextId, this._context);
  
  Future<void> initialize() async {
    _connection.on('Network.requestWillBeSent').listen((params) {
      if (params['browsingContextId'] != _browsingContextId) return;
      _onRequestWillBeSent(params);
    });
    
    _connection.on('Network.responseReceived').listen((params) {
      if (params['browsingContextId'] != _browsingContextId) return;
      _onResponseReceived(params);
    });
    
    _connection.on('Network.requestFinished').listen((params) {
      if (params['browsingContextId'] != _browsingContextId) return;
      _onRequestFinished(params);
    });
    
    _connection.on('Network.requestFailed').listen((params) {
      if (params['browsingContextId'] != _browsingContextId) return;
      _onRequestFailed(params);
    });
  }
  
  /// Habilitar interceptação
  Future<void> setRequestInterception(bool enabled) async {
    await _connection.send('Network.setRequestInterception', {
      'enabled': enabled,
      'browsingContextId': _browsingContextId,
    });
  }
  
  void _onRequestWillBeSent(Map<String, dynamic> params) {
    // Criar Request e notificar
  }
  
  void _onResponseReceived(Map<String, dynamic> params) {
    // Associar Response ao Request
  }
}
```

---

## 7. Protocolo Juggler — Referência de Domínios

### 7.1. Browser Domain

```
Browser.enable()
Browser.createBrowserContext({ removeOnDetach? }) → { browserContextId }
Browser.removeBrowserContext({ browserContextId })
Browser.newPage({ browserContextId }) → { targetId, type }
Browser.close()

Events:
  Browser.attachedToTarget({ targetInfo })
  Browser.detachedFromTarget({ targetId })
  Browser.downloadCreated({ ... })
  Browser.downloadFinished({ ... })
```

### 7.2. Page Domain

```
Page.enable()
Page.navigate({ url, browsingContextId, referer? }) → { navigationId?, frameId }
Page.reload({ browsingContextId }) → { navigationId }
Page.goBack({ browsingContextId }) → { navigationId? }
Page.goForward({ browsingContextId }) → { navigationId? }
Page.screenshot({ browsingContextId, mimeType, ... }) → { data }
Page.setFileInputFiles({ browsingContextId, frameId, objectId, files })
Page.adoptNode({ browsingContextId, frameId, objectId, executionContextId }) → { remoteObject }
Page.setEmulatedMedia({ browsingContextId, ... })
Page.setInterceptFileChooserDialog({ browsingContextId, enabled })
Page.handleDialog({ browsingContextId, accept, promptText? })
Page.dispatchKeyEvent({ browsingContextId, type, key, ... })
Page.dispatchMouseEvent({ browsingContextId, type, x, y, button, ... })
Page.insertText({ browsingContextId, text })

Events:
  Page.eventFired({ browsingContextId, frameId, name })
  Page.frameAttached({ browsingContextId, frameId, parentFrameId })
  Page.frameDetached({ browsingContextId, frameId })
  Page.navigationStarted({ browsingContextId, frameId, navigationId, url })
  Page.navigationCommitted({ browsingContextId, frameId, navigationId, url, name })
  Page.navigationAborted({ browsingContextId, frameId, navigationId, errorText })
  Page.sameDocumentNavigation({ browsingContextId, frameId, url })
  Page.dialogOpened({ browsingContextId, dialogId, type, message, defaultValue? })
  Page.dialogClosed({ browsingContextId, dialogId })
  Page.fileChooserOpened({ browsingContextId, ... })
  Page.screencastFrame({ browsingContextId, data, ... })
  Page.crashed({ browsingContextId })
```

### 7.3. Network Domain

```
Network.enable()
Network.setRequestInterception({ enabled, browsingContextId })
Network.setExtraHTTPHeaders({ browsingContextId, headers })
Network.getResponseBody({ requestId }) → { base64body, evicted }
Network.resumeInterceptedRequest({ requestId, url?, method?, headers?, postData?, authResponse? })
Network.abortInterceptedRequest({ requestId, errorCode })
Network.fulfillInterceptedRequest({ requestId, status, statusText, headers, base64body? })

Events:
  Network.requestWillBeSent({ requestId, browsingContextId, ... })
  Network.responseReceived({ requestId, browsingContextId, ... })
  Network.requestFinished({ requestId, browsingContextId })
  Network.requestFailed({ requestId, browsingContextId, errorCode })
```

### 7.4. Runtime Domain

```
Runtime.enable()
Runtime.evaluate({ expression, executionContextId, returnByValue? }) → { exceptionDetails?, result }
Runtime.callFunction({ functionDeclaration, args, executionContextId, returnByValue? }) → { exceptionDetails?, result }
Runtime.getObjectProperties({ executionContextId, objectId }) → { properties }
Runtime.disposeObject({ executionContextId, objectId })

Events:
  Runtime.executionContextCreated({ executionContextId, auxData })
  Runtime.executionContextDestroyed({ executionContextId })
  Runtime.console({ executionContextId, args, type, location })
```

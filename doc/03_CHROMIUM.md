# 03 — Port Detalhado do Motor Chromium (CDP)

## 1. Visão Geral

O motor Chromium é o mais completo e bem documentado do Playwright. Ele usa o **Chrome DevTools Protocol (CDP)** padrão, que é o mesmo protocolo usado por ferramentas como Chrome DevTools, Puppeteer e Selenium.

### 1.1. Arquivos Fonte (TypeScript)

```
packages/playwright-core/src/server/chromium/
├── chromium.ts              (24.2 KB) — BrowserType para Chromium
├── chromiumSwitches.ts       (4.6 KB) — Flags de linha de comando
├── crBrowser.ts             (24.4 KB) — Implementação do Browser
├── crConnection.ts           (9.3 KB) — Conexão CDP
├── crCoverage.ts            (10.3 KB) — Coverage de JS e CSS
├── crDevTools.ts             (3.7 KB) — DevTools frontend
├── crDragDrop.ts             (5.2 KB) — Drag and drop
├── crExecutionContext.ts     (6.1 KB) — Contexto de execução JS
├── crInput.ts                (6.7 KB) — Keyboard, Mouse, Touchscreen
├── crNetworkManager.ts      (43.4 KB) — Gerenciador de rede (MAIOR)
├── crPage.ts                (53.6 KB) — Implementação de Page (MAIOR)
├── crPdf.ts                  (4.0 KB) — Geração de PDF
├── crProtocolHelper.ts       (4.4 KB) — Helpers do protocolo
├── crServiceWorker.ts        (5.7 KB) — Service Workers
├── defaultFontFamilies.ts    (4.1 KB) — Fontes padrão
└── protocol.d.ts           (823.3 KB) — Tipos CDP gerados
```

**Total**: ~1 MB de código TypeScript a ser portado

---

## 2. Chromium BrowserType

### 2.1. Lançamento do Navegador

O `chromium.ts` implementa a lógica de lançamento:

```dart
// lib/src/server/chromium/chromium.dart

class Chromium extends BrowserType {
  @override
  String get name => 'chromium';
  
  @override
  Future<CrBrowser> launch({
    bool? headless,
    String? executablePath,
    List<String>? args,
    String? channel,
    Map<String, String>? env,
    bool? handleSIGINT,
    bool? handleSIGTERM,
    bool? handleSIGHUP,
    Duration? timeout,
    int? slowMo,
    String? downloadsPath,
    String? tracesDir,
    String? proxy,
    bool? chromiumSandbox,
    List<String>? ignoreDefaultArgs,
  }) async {
    final browserOptions = _createBrowserOptions(/* ... */);
    final launchOptions = _createLaunchOptions(/* ... */);
    
    // 1. Resolver caminho do executável
    final executable = executablePath ?? 
        registry.executablePath('chromium') ??
        registry.executablePath('chromium', channel: channel);
    
    if (executable == null) {
      throw PlaywrightException(
        'Chromium is not installed. Run: dart run playwright install chromium',
      );
    }
    
    // 2. Construir argumentos de linha de comando
    final chromeArgs = _buildArgs(
      headless: headless ?? true,
      args: args,
      userDataDir: launchOptions.userDataDir,
      proxy: proxy,
      sandbox: chromiumSandbox ?? true,
    );
    
    // 3. Lançar o processo
    final process = await Process.start(
      executable,
      chromeArgs,
      environment: env,
    );
    
    // 4. Criar transporte via pipe
    final transport = PipeTransport.fromProcess(process);
    
    // 5. Criar conexão
    final connection = CrConnection(transport);
    
    // 6. Criar browser
    final browser = await CrBrowser.connect(
      connection,
      process: process,
      options: browserOptions,
    );
    
    return browser;
  }
  
  /// Construir argumentos do Chromium
  List<String> _buildArgs({
    required bool headless,
    List<String>? args,
    String? userDataDir,
    String? proxy,
    required bool sandbox,
  }) {
    final result = <String>[
      // Sempre usar pipe para comunicação
      '--remote-debugging-pipe',
      // Desabilitar features que interferem na automação
      ...ChromiumSwitches.defaultArgs,
    ];
    
    if (headless) {
      result.add('--headless=new');
    }
    
    if (!sandbox) {
      result.add('--no-sandbox');
    }
    
    if (userDataDir != null) {
      result.add('--user-data-dir=$userDataDir');
    }
    
    if (proxy != null) {
      result.add('--proxy-server=$proxy');
    }
    
    if (args != null) {
      result.addAll(args);
    }
    
    result.add('about:blank'); // Página inicial
    
    return result;
  }
}
```

### 2.2. Switches (Flags de Linha de Comando)

```dart
// lib/src/server/chromium/chromium_switches.dart

/// Flags padrão de linha de comando do Chromium para automação
class ChromiumSwitches {
  static const List<String> defaultArgs = [
    '--disable-background-networking',
    '--disable-background-timer-throttling',
    '--disable-backgrounding-occluded-windows',
    '--disable-breakpad',
    '--disable-client-side-phishing-detection',
    '--disable-component-extensions-with-background-pages',
    '--disable-component-update',
    '--disable-default-apps',
    '--disable-dev-shm-usage',
    '--disable-extensions',
    '--disable-features=TranslateUI',
    '--disable-hang-monitor',
    '--disable-ipc-flooding-protection',
    '--disable-popup-blocking',
    '--disable-prompt-on-repost',
    '--disable-renderer-backgrounding',
    '--disable-search-engine-choice-screen',
    '--disable-sync',
    '--enable-features=NetworkService,NetworkServiceInProcess',
    '--force-color-profile=srgb',
    '--metrics-recording-only',
    '--no-first-run',
    '--password-store=basic',
    '--use-mock-keychain',
    '--enable-use-zoom-for-dsf=false',
  ];
}
```

---

## 3. CrConnection — Conexão CDP

### 3.1. Estrutura

A `CrConnection` gerencia a conexão CDP e as sessions por target:

```dart
// lib/src/server/chromium/cr_connection.dart

/// Conexão CDP com o Chromium.
/// Gerencia sessions por target (página, worker, etc.)
class CrConnection {
  final ConnectionTransport _transport;
  int _lastId = 0;
  bool _closed = false;
  
  final _callbacks = <int, Completer<Map<String, dynamic>>>{};
  final _sessions = <String, CrSession>{};
  
  final _eventController = StreamController<CrEvent>.broadcast();
  final _disconnectedController = StreamController<void>.broadcast();
  
  CrConnection(this._transport) {
    _transport.onMessage.listen(_onMessage);
    _transport.onClose.listen((_) => _onTransportClose());
  }
  
  /// Enviar comando no escopo root (sem session)
  Future<Map<String, dynamic>> rootSession(
    String method, [Map<String, dynamic>? params]
  ) async {
    return _send(method, params: params);
  }
  
  Future<Map<String, dynamic>> _send(
    String method, {
    Map<String, dynamic>? params,
    String? sessionId,
  }) async {
    if (_closed) throw StateError('Connection is closed');
    
    final id = ++_lastId;
    final completer = Completer<Map<String, dynamic>>();
    _callbacks[id] = completer;
    
    _transport.send(ProtocolRequest(
      id: id,
      method: method,
      params: params,
      sessionId: sessionId,
    ));
    
    return completer.future;
  }
  
  /// Criar uma nova session CDP para um target
  CrSession createSession(String sessionId) {
    final session = CrSession(this, sessionId);
    _sessions[sessionId] = session;
    return session;
  }
  
  void _onMessage(ProtocolResponse response) {
    if (response.id != null) {
      final completer = _callbacks.remove(response.id);
      if (completer == null) return;
      
      if (response.error != null) {
        completer.completeError(ProtocolException(
          response.error!.message,
          code: response.error!.code,
        ));
      } else {
        completer.complete(response.result ?? {});
      }
    } else if (response.method != null) {
      // Evento — despachar para session correta
      if (response.sessionId != null) {
        final session = _sessions[response.sessionId!];
        if (session != null) {
          session._handleEvent(response.method!, response.params ?? {});
        }
      } else {
        _eventController.add(CrEvent(response.method!, response.params ?? {}));
      }
      
      // Eventos especiais de session management
      if (response.method == 'Target.attachedToTarget') {
        final sessionId = response.params?['sessionId'] as String?;
        if (sessionId != null) {
          createSession(sessionId);
        }
      } else if (response.method == 'Target.detachedFromTarget') {
        final sessionId = response.params?['sessionId'] as String?;
        if (sessionId != null) {
          _sessions.remove(sessionId)?.dispose();
        }
      }
    }
  }
  
  void _onTransportClose() {
    _closed = true;
    for (final completer in _callbacks.values) {
      completer.completeError(StateError('Connection closed'));
    }
    _callbacks.clear();
    for (final session in _sessions.values) {
      session.dispose();
    }
    _sessions.clear();
    _disconnectedController.add(null);
  }
  
  Stream<CrEvent> get onEvent => _eventController.stream;
  Stream<void> get onDisconnected => _disconnectedController.stream;
  
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _transport.close();
  }
}

/// Session CDP para um target
class CrSession {
  final CrConnection _connection;
  final String sessionId;
  final _eventController = StreamController<CrEvent>.broadcast();
  bool _disposed = false;
  
  CrSession(this._connection, this.sessionId);
  
  /// Enviar comando nesta session
  Future<Map<String, dynamic>> send(
    String method, [Map<String, dynamic>? params]
  ) {
    if (_disposed) throw StateError('Session has been disposed');
    return _connection._send(method, params: params, sessionId: sessionId);
  }
  
  /// Escutar eventos de um método específico
  Stream<Map<String, dynamic>> on(String method) {
    return _eventController.stream
        .where((e) => e.method == method)
        .map((e) => e.params);
  }
  
  void _handleEvent(String method, Map<String, dynamic> params) {
    if (!_disposed) {
      _eventController.add(CrEvent(method, params));
    }
  }
  
  void dispose() {
    _disposed = true;
    _eventController.close();
  }
}

class CrEvent {
  final String method;
  final Map<String, dynamic> params;
  CrEvent(this.method, this.params);
}
```

---

## 4. CrBrowser — Implementação do Browser

### 4.1. Inicialização

```dart
// lib/src/server/chromium/cr_browser.dart

class CrBrowser extends Browser {
  final CrConnection _connection;
  final Process? _process;
  
  final _contexts = <String, CrBrowserContext>{};
  CrBrowserContext? _defaultContext;
  
  CrBrowser._(this._connection, {Process? process}) : _process = process;
  
  static Future<CrBrowser> connect(
    CrConnection connection, {
    Process? process,
    BrowserOptions? options,
  }) async {
    final browser = CrBrowser._(connection, process: process);
    await browser._initialize(options);
    return browser;
  }
  
  Future<void> _initialize(BrowserOptions? options) async {
    // 1. Escutar eventos de target
    _connection.onEvent.listen((event) {
      switch (event.method) {
        case 'Target.targetCreated':
          _onTargetCreated(event.params);
          break;
        case 'Target.targetDestroyed':
          _onTargetDestroyed(event.params);
          break;
        case 'Target.targetInfoChanged':
          _onTargetInfoChanged(event.params);
          break;
      }
    });
    
    // 2. Configurar auto-attach
    await _connection.rootSession('Target.setAutoAttach', {
      'autoAttach': true,
      'waitForDebuggerOnStart': true,
      'flatten': true,
    });
    
    // 3. Descobrir targets existentes
    await _connection.rootSession('Target.setDiscoverTargets', {
      'discover': true,
    });
  }
  
  @override
  Future<BrowserContext> newContext({
    bool? acceptDownloads,
    bool? bypassCSP,
    ColorScheme? colorScheme,
    double? deviceScaleFactor,
    Map<String, String>? extraHTTPHeaders,
    Geolocation? geolocation,
    bool? hasTouch,
    bool? httpCredentials,
    bool? ignoreHTTPSErrors,
    bool? isMobile,
    bool? javaScriptEnabled,
    Locale? locale,
    bool? offline,
    List<String>? permissions,
    ProxySettings? proxy,
    bool? recordHarEnabled,
    bool? recordVideoEnabled,
    ScreenSize? screenSize,
    StorageState? storageState,
    String? timezoneId,
    String? userAgent,
    ViewportSize? viewportSize,
  }) async {
    // 1. Criar browser context via CDP
    final result = await _connection.rootSession(
      'Target.createBrowserContext',
      {
        if (proxy != null) 'proxyServer': proxy.server,
        if (proxy?.bypass != null) 'proxyBypassList': proxy!.bypass,
      },
    );
    
    final browserContextId = result['browserContextId'] as String;
    
    // 2. Criar CrBrowserContext
    final context = CrBrowserContext(
      browser: this,
      browserContextId: browserContextId,
      options: ContextOptions(
        acceptDownloads: acceptDownloads,
        bypassCSP: bypassCSP,
        colorScheme: colorScheme,
        deviceScaleFactor: deviceScaleFactor,
        extraHTTPHeaders: extraHTTPHeaders,
        // ... all options
      ),
    );
    
    _contexts[browserContextId] = context;
    
    // 3. Aplicar configurações
    await context._initialize();
    
    return context;
  }
  
  @override
  Future<void> close() async {
    // 1. Fechar todos os contextos
    for (final context in _contexts.values.toList()) {
      await context.close();
    }
    
    // 2. Fechar conexão
    await _connection.close();
    
    // 3. Matar processo
    _process?.kill();
  }
  
  @override
  String get version => _version;
  String _version = '';
  
  void _onTargetCreated(Map<String, dynamic> params) {
    final targetInfo = params['targetInfo'] as Map<String, dynamic>;
    final type = targetInfo['type'] as String;
    final browserContextId = targetInfo['browserContextId'] as String?;
    
    if (type == 'page') {
      final context = browserContextId != null 
          ? _contexts[browserContextId] 
          : _defaultContext;
      context?._onPageTargetCreated(targetInfo);
    }
  }
  
  void _onTargetDestroyed(Map<String, dynamic> params) {
    final targetId = params['targetId'] as String;
    // Notificar contextos
    for (final context in _contexts.values) {
      context._onTargetDestroyed(targetId);
    }
  }
  
  void _onTargetInfoChanged(Map<String, dynamic> params) {
    final targetInfo = params['targetInfo'] as Map<String, dynamic>;
    // Atualizar informações do target
  }
}
```

---

## 5. CrPage — Implementação da Page

### 5.1. Estrutura (Resumida)

O `crPage.ts` original tem **53.6 KB** e é o maior arquivo. As principais responsabilidades:

```dart
// lib/src/server/chromium/cr_page.dart

class CrPage extends PageDelegate {
  final CrSession _session;
  final CrBrowserContext _context;
  
  late final CrNetworkManager _networkManager;
  late final CrInput _input;
  
  final _workers = <String, Worker>{};
  final _frameManager = FrameManager();
  
  CrPage(this._session, this._context);
  
  Future<void> initialize() async {
    // Habilitar domínios CDP necessários
    await Future.wait([
      _session.send('Page.enable'),
      _session.send('Runtime.enable'),
      _session.send('Network.enable'),
      _session.send('DOM.enable'),
      _session.send('Log.enable'),
      _session.send('Performance.enable'),
    ]);
    
    // Configurar network manager
    _networkManager = CrNetworkManager(_session, _context);
    await _networkManager.initialize();
    
    // Configurar input
    _input = CrInput(_session);
    
    // Escutar eventos
    _setupEventListeners();
    
    // Aplicar configurações do contexto
    await _applyContextSettings();
  }
  
  void _setupEventListeners() {
    // Lifecycle events
    _session.on('Page.lifecycleEvent').listen((params) {
      _onLifecycleEvent(params);
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
    
    // Console messages
    _session.on('Runtime.consoleAPICalled').listen((params) {
      _onConsoleAPI(params);
    });
    
    // JavaScript dialogs
    _session.on('Page.javascriptDialogOpening').listen((params) {
      _onDialog(params);
    });
    
    // Page errors
    _session.on('Runtime.exceptionThrown').listen((params) {
      _onExceptionThrown(params);
    });
    
    // File chooser
    _session.on('Page.fileChooserOpened').listen((params) {
      _onFileChooserOpened(params);
    });
    
    // Download
    _session.on('Page.downloadWillBegin').listen((params) {
      _onDownloadWillBegin(params);
    });
  }
  
  // === Navegação ===
  
  Future<Response?> navigate(String url, {
    Duration? timeout,
    WaitUntil? waitUntil,
    String? referer,
  }) async {
    final result = await _session.send('Page.navigate', {
      'url': url,
      if (referer != null) 'referrer': referer,
    });
    
    final frameId = result['frameId'] as String;
    final loaderId = result['loaderId'] as String?;
    final errorText = result['errorText'] as String?;
    
    if (errorText != null) {
      throw NavigationException(errorText);
    }
    
    // Esperar pelo lifecycle event
    await _waitForLifecycle(
      frameId: frameId,
      loaderId: loaderId,
      waitUntil: waitUntil ?? WaitUntil.load,
      timeout: timeout,
    );
    
    return _networkManager.responseForRequest(frameId, loaderId);
  }
  
  // === Screenshot ===
  
  Future<Uint8List> screenshot({
    ScreenshotType type = ScreenshotType.png,
    int? quality,
    bool? fullPage,
    Rect? clip,
    bool? omitBackground,
  }) async {
    if (fullPage == true) {
      // Capturar página inteira: precisamos ajustar viewport
      final metrics = await _session.send('Page.getLayoutMetrics');
      final contentSize = metrics['cssContentSize'] as Map<String, dynamic>;
      
      // Temporariamente ajustar viewport
      await _session.send('Emulation.setDeviceMetricsOverride', {
        'width': (contentSize['width'] as num).ceil(),
        'height': (contentSize['height'] as num).ceil(),
        'deviceScaleFactor': 1,
        'mobile': false,
      });
    }
    
    final result = await _session.send('Page.captureScreenshot', {
      'format': type == ScreenshotType.png ? 'png' : 'jpeg',
      if (quality != null) 'quality': quality,
      if (clip != null) 'clip': {
        'x': clip.left,
        'y': clip.top,
        'width': clip.width,
        'height': clip.height,
        'scale': 1,
      },
      if (omitBackground == true) 'captureBeyondViewport': true,
    });
    
    return base64Decode(result['data'] as String);
  }
  
  // === Evaluate ===
  
  Future<dynamic> evaluate(String expression, {
    List<dynamic>? args,
  }) async {
    final result = await _session.send('Runtime.evaluate', {
      'expression': expression,
      'returnByValue': true,
      'awaitPromise': true,
    });
    
    return _deserializeValue(result['result'] as Map<String, dynamic>);
  }
}
```

---

## 6. CrNetworkManager — Gerenciador de Rede

### 6.1. Responsabilidades

O `crNetworkManager.ts` (43.4 KB) gerencia:
- Interceptação de requests
- Tracking de responses
- Cookies
- HTTP authentication
- Service workers
- Fetch interception (Route)

```dart
// lib/src/server/chromium/cr_network_manager.dart

class CrNetworkManager {
  final CrSession _session;
  final CrBrowserContext _context;
  
  final _requests = <String, Request>{};
  final _responseWaiters = <String, Completer<Response>>{};
  
  final _requestController = StreamController<Request>.broadcast();
  final _responseController = StreamController<Response>.broadcast();
  final _requestFailedController = StreamController<Request>.broadcast();
  
  CrNetworkManager(this._session, this._context);
  
  Future<void> initialize() async {
    // Habilitar Fetch domain para interceptação
    _session.on('Fetch.requestPaused').listen(_onRequestPaused);
    _session.on('Fetch.authRequired').listen(_onAuthRequired);
    
    // Eventos de rede
    _session.on('Network.requestWillBeSent').listen(_onRequestWillBeSent);
    _session.on('Network.responseReceived').listen(_onResponseReceived);
    _session.on('Network.loadingFinished').listen(_onLoadingFinished);
    _session.on('Network.loadingFailed').listen(_onLoadingFailed);
    _session.on('Network.requestWillBeSentExtraInfo').listen(_onRequestWillBeSentExtraInfo);
    _session.on('Network.responseReceivedExtraInfo').listen(_onResponseReceivedExtraInfo);
  }
  
  /// Habilitar interceptação de rede
  Future<void> setRequestInterception(bool enabled) async {
    if (enabled) {
      await _session.send('Fetch.enable', {
        'patterns': [{'urlPattern': '*'}],
        'handleAuthRequests': true,
      });
    } else {
      await _session.send('Fetch.disable');
    }
  }
  
  void _onRequestWillBeSent(Map<String, dynamic> params) {
    final requestId = params['requestId'] as String;
    final request = Request.fromCDP(params);
    _requests[requestId] = request;
    _requestController.add(request);
  }
  
  void _onResponseReceived(Map<String, dynamic> params) {
    final requestId = params['requestId'] as String;
    final request = _requests[requestId];
    if (request == null) return;
    
    final response = Response.fromCDP(params['response'] as Map<String, dynamic>, request);
    request.setResponse(response);
    _responseController.add(response);
  }
  
  void _onRequestPaused(Map<String, dynamic> params) {
    // Request interceptada — decidir se continua, modifica ou bloqueia
    final requestId = params['requestId'] as String;
    final networkId = params['networkId'] as String?;
    
    // Verificar se há um Route handler registrado
    // Se sim, chamar o handler
    // Se não, continuar a request
  }
  
  Stream<Request> get onRequest => _requestController.stream;
  Stream<Response> get onResponse => _responseController.stream;
  Stream<Request> get onRequestFailed => _requestFailedController.stream;
}
```

---

## 7. CrInput — Keyboard, Mouse, Touchscreen

```dart
// lib/src/server/chromium/cr_input.dart

class CrKeyboard implements RawKeyboard {
  final CrSession _session;
  CrKeyboard(this._session);
  
  @override
  Future<void> press(String key, {Duration? delay}) async {
    await down(key);
    if (delay != null) await Future.delayed(delay);
    await up(key);
  }
  
  @override
  Future<void> down(String key) async {
    final keyDef = _keyDefinitions[key];
    await _session.send('Input.dispatchKeyEvent', {
      'type': 'keyDown',
      'key': keyDef?.key ?? key,
      'code': keyDef?.code ?? '',
      'windowsVirtualKeyCode': keyDef?.keyCode ?? 0,
      'text': keyDef?.text ?? '',
    });
  }
  
  @override
  Future<void> up(String key) async {
    final keyDef = _keyDefinitions[key];
    await _session.send('Input.dispatchKeyEvent', {
      'type': 'keyUp',
      'key': keyDef?.key ?? key,
      'code': keyDef?.code ?? '',
      'windowsVirtualKeyCode': keyDef?.keyCode ?? 0,
    });
  }
  
  @override
  Future<void> type(String text, {Duration? delay}) async {
    for (final char in text.split('')) {
      if (_keyDefinitions.containsKey(char)) {
        await press(char, delay: delay);
      } else {
        await _session.send('Input.dispatchKeyEvent', {
          'type': 'char',
          'text': char,
        });
        if (delay != null) await Future.delayed(delay);
      }
    }
  }
}

class CrMouse implements RawMouse {
  final CrSession _session;
  double _x = 0;
  double _y = 0;
  int _button = 0;
  
  CrMouse(this._session);
  
  @override
  Future<void> move(double x, double y, {int? steps}) async {
    final fromX = _x;
    final fromY = _y;
    final stepsCount = steps ?? 1;
    
    for (int i = 1; i <= stepsCount; i++) {
      final currentX = fromX + (x - fromX) * (i / stepsCount);
      final currentY = fromY + (y - fromY) * (i / stepsCount);
      
      await _session.send('Input.dispatchMouseEvent', {
        'type': 'mouseMoved',
        'x': currentX,
        'y': currentY,
        'button': 'none',
        'buttons': _button,
      });
    }
    
    _x = x;
    _y = y;
  }
  
  @override
  Future<void> click(double x, double y, {
    MouseButton button = MouseButton.left,
    int? clickCount,
    Duration? delay,
  }) async {
    await move(x, y);
    await down(button: button, clickCount: clickCount ?? 1);
    if (delay != null) await Future.delayed(delay);
    await up(button: button, clickCount: clickCount ?? 1);
  }
  
  @override
  Future<void> down({MouseButton button = MouseButton.left, int clickCount = 1}) async {
    await _session.send('Input.dispatchMouseEvent', {
      'type': 'mousePressed',
      'x': _x,
      'y': _y,
      'button': button.name,
      'clickCount': clickCount,
      'buttons': _button | _buttonBit(button),
    });
    _button |= _buttonBit(button);
  }
  
  @override
  Future<void> up({MouseButton button = MouseButton.left, int clickCount = 1}) async {
    _button &= ~_buttonBit(button);
    await _session.send('Input.dispatchMouseEvent', {
      'type': 'mouseReleased',
      'x': _x,
      'y': _y,
      'button': button.name,
      'clickCount': clickCount,
      'buttons': _button,
    });
  }
}

class CrTouchscreen implements RawTouchscreen {
  final CrSession _session;
  CrTouchscreen(this._session);
  
  @override
  Future<void> tap(double x, double y) async {
    await _session.send('Input.dispatchTouchEvent', {
      'type': 'touchStart',
      'touchPoints': [{'x': x, 'y': y}],
    });
    await _session.send('Input.dispatchTouchEvent', {
      'type': 'touchEnd',
      'touchPoints': [],
    });
  }
}
```

---

## 8. CrExecutionContext — Execução JavaScript

```dart
// lib/src/server/chromium/cr_execution_context.dart

class CrExecutionContext implements ExecutionContext {
  final CrSession _session;
  final int _contextId;
  
  CrExecutionContext(this._session, this._contextId);
  
  @override
  Future<JsHandle> evaluateHandle(String expression, {List<dynamic>? args}) async {
    final result = await _rawEvaluate(
      expression,
      args: args,
      returnByValue: false,
    );
    return _createHandle(result);
  }
  
  @override
  Future<dynamic> evaluate(String expression, {List<dynamic>? args}) async {
    final result = await _rawEvaluate(
      expression,
      args: args,
      returnByValue: true,
    );
    return _deserializeRemoteObject(result);
  }
  
  Future<Map<String, dynamic>> _rawEvaluate(
    String expression, {
    List<dynamic>? args,
    required bool returnByValue,
  }) async {
    if (args != null && args.isNotEmpty) {
      // Usar callFunctionOn para passar argumentos
      final serializedArgs = args.map(_serializeArg).toList();
      
      final result = await _session.send('Runtime.callFunctionOn', {
        'functionDeclaration': expression,
        'arguments': serializedArgs,
        'executionContextId': _contextId,
        'returnByValue': returnByValue,
        'awaitPromise': true,
        'userGesture': true,
      });
      
      _checkException(result);
      return result['result'] as Map<String, dynamic>;
    } else {
      final result = await _session.send('Runtime.evaluate', {
        'expression': expression,
        'contextId': _contextId,
        'returnByValue': returnByValue,
        'awaitPromise': true,
        'userGesture': true,
      });
      
      _checkException(result);
      return result['result'] as Map<String, dynamic>;
    }
  }
  
  Map<String, dynamic> _serializeArg(dynamic arg) {
    if (arg is JsHandle) {
      return {'objectId': (arg as CrJsHandle).remoteObjectId};
    }
    return {'value': arg};
  }
  
  dynamic _deserializeRemoteObject(Map<String, dynamic> remoteObject) {
    final type = remoteObject['type'] as String?;
    final subtype = remoteObject['subtype'] as String?;
    final value = remoteObject['value'];
    
    if (subtype == 'null') return null;
    if (type == 'undefined') return null;
    if (type == 'number') {
      final unserializable = remoteObject['unserializableValue'] as String?;
      if (unserializable != null) {
        return switch (unserializable) {
          'NaN' => double.nan,
          'Infinity' => double.infinity,
          '-Infinity' => double.negativeInfinity,
          '-0' => -0.0,
          _ => double.parse(unserializable),
        };
      }
      return value;
    }
    return value;
  }
}
```

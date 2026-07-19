# 07 — API Pública do Pacote Playwright

## 1. Visão Geral

A API pública é o que o desenvolvedor Dart importa e usa. Deve ser **idiomática em Dart** enquanto mantém **compatibilidade conceitual** com a API oficial do Playwright.

---

## 2. Uso Principal

```dart
import 'package:playwright/playwright.dart';

void main() async {
  // Criar instância do Playwright
  final playwright = await Playwright.create();
  
  // Lançar navegador
  final browser = await playwright.chromium.launch(headless: true);
  
  // Criar contexto isolado
  final context = await browser.newContext(
    viewport: ViewportSize(width: 1280, height: 720),
    userAgent: 'Custom Agent',
  );
  
  // Criar página
  final page = await context.newPage();
  
  // Navegar
  await page.goto('https://example.com');
  
  // Locator (recomendado)
  final heading = page.locator('h1');
  await heading.click();
  final text = await heading.textContent();
  print('Heading: $text');
  
  // Screenshot
  final screenshot = await page.screenshot(
    type: ScreenshotType.png,
    fullPage: true,
  );
  await File('screenshot.png').writeAsBytes(screenshot);
  
  // Fechar
  await browser.close();
  await playwright.dispose();
}
```

---

## 3. Classes Principais

### 3.1. Playwright (Root)

```dart
/// Ponto de entrada principal do Playwright.
/// Fornece acesso aos BrowserTypes e gerencia o lifecycle.
class Playwright {
  /// BrowserType para Chromium (Chrome, Edge, etc.)
  BrowserType get chromium;
  
  /// BrowserType para Firefox
  BrowserType get firefox;
  
  /// BrowserType para WebKit (Safari)
  BrowserType get webkit;
  
  /// Selectors customizados
  Selectors get selectors;
  
  /// Criar instância do Playwright
  static Future<Playwright> create() async;
  
  /// Liberar recursos
  Future<void> dispose();
}
```

### 3.2. BrowserType

```dart
/// Representa um tipo de navegador (chromium, firefox, webkit).
/// Usado para lançar ou conectar a instâncias de navegador.
abstract class BrowserType {
  /// Nome do navegador
  String get name;
  
  /// Caminho do executável
  String? get executablePath;
  
  /// Lançar uma nova instância do navegador
  Future<Browser> launch({
    bool? headless,
    String? executablePath,
    List<String>? args,
    String? channel,
    bool? chromiumSandbox,
    String? downloadsPath,
    Map<String, String>? env,
    List<String>? ignoreDefaultArgs,
    String? proxy,
    int? slowMo,
    Duration? timeout,
    String? tracesDir,
  });
  
  /// Lançar navegador com contexto persistente
  Future<BrowserContext> launchPersistentContext(
    String userDataDir, {
    // ... todas as opções de launch + context
  });
  
  /// Conectar a navegador existente via CDP (somente Chromium)
  Future<Browser> connectOverCDP(
    String endpointURL, {
    Map<String, String>? headers,
    int? slowMo,
    Duration? timeout,
  });
}
```

### 3.3. Browser

```dart
/// Uma instância de navegador em execução.
abstract class Browser {
  /// Nome do navegador
  String get browserType;
  
  /// Versão do navegador
  String get version;
  
  /// Se está conectado
  bool get isConnected;
  
  /// Criar novo contexto de navegação isolado
  Future<BrowserContext> newContext({
    bool? acceptDownloads,
    String? baseURL,
    bool? bypassCSP,
    ColorScheme? colorScheme,
    double? deviceScaleFactor,
    Map<String, String>? extraHTTPHeaders,
    bool? forcedColors,
    Geolocation? geolocation,
    bool? hasTouch,
    HttpCredentials? httpCredentials,
    bool? ignoreHTTPSErrors,
    bool? isMobile,
    bool? javaScriptEnabled,
    Locale? locale,
    bool? offline,
    List<String>? permissions,
    ProxySettings? proxy,
    RecordHarOptions? recordHar,
    RecordVideoOptions? recordVideo,
    ReducedMotion? reducedMotion,
    ScreenSize? screen,
    ServiceWorkerPolicy? serviceWorkers,
    StorageState? storageState,
    String? timezoneId,
    String? userAgent,
    ViewportSize? viewport,
  });
  
  /// Criar nova página (atalho: cria contexto + página)
  Future<Page> newPage({/* mesmas opções de newContext */});
  
  /// Listar todos os contextos
  List<BrowserContext> get contexts;
  
  /// Fechar o navegador
  Future<void> close();
  
  /// Evento de desconexão
  Stream<void> get onDisconnected;
}
```

### 3.4. BrowserContext

```dart
/// Contexto de navegação isolado (equivalente a perfil/incógnito).
/// Páginas dentro do mesmo contexto compartilham cookies e storage.
abstract class BrowserContext {
  /// Browser dono deste contexto
  Browser get browser;
  
  /// Páginas abertas neste contexto
  List<Page> get pages;
  
  /// Criar nova página
  Future<Page> newPage();
  
  /// Fechar o contexto (e todas as páginas)
  Future<void> close();
  
  // === Cookies ===
  Future<List<Cookie>> cookies([List<String>? urls]);
  Future<void> addCookies(List<Cookie> cookies);
  Future<void> clearCookies({String? name, String? domain, String? path});
  
  // === Permissions ===
  Future<void> grantPermissions(List<String> permissions, {String? origin});
  Future<void> clearPermissions();
  
  // === Geolocation ===
  Future<void> setGeolocation(Geolocation? geolocation);
  
  // === Extra headers ===
  Future<void> setExtraHTTPHeaders(Map<String, String> headers);
  
  // === Offline ===
  Future<void> setOffline(bool offline);
  
  // === Network interception ===
  Future<void> route(dynamic url, RouteHandler handler);
  Future<void> routeFromHAR(String har, {HarOptions? options});
  Future<void> unroute(dynamic url, [RouteHandler? handler]);
  
  // === Storage State ===
  Future<StorageState> storageState({String? path});
  
  // === Tracing ===
  Tracing get tracing;
  
  // === Events ===
  Stream<Page> get onPage;
  Stream<void> get onClose;
  Stream<Request> get onRequest;
  Stream<Response> get onResponse;
  Stream<Request> get onRequestFailed;
  Stream<Request> get onRequestFinished;
}
```

### 3.5. Page

```dart
/// Uma página (tab) do navegador.
/// Principal interface de interação com o conteúdo web.
abstract class Page {
  /// URL atual
  String get url;
  
  /// Contexto dono desta página
  BrowserContext get context;
  
  /// Frame principal
  Frame get mainFrame;
  
  /// Todos os frames
  List<Frame> get frames;
  
  /// Keyboard
  Keyboard get keyboard;
  
  /// Mouse
  Mouse get mouse;
  
  /// Touchscreen
  Touchscreen get touchscreen;
  
  // === Navegação ===
  Future<Response?> goto(String url, {
    Duration? timeout,
    WaitUntil? waitUntil,
    String? referer,
  });
  Future<Response?> goBack({Duration? timeout, WaitUntil? waitUntil});
  Future<Response?> goForward({Duration? timeout, WaitUntil? waitUntil});
  Future<Response?> reload({Duration? timeout, WaitUntil? waitUntil});
  
  // === Conteúdo ===
  Future<String> title();
  Future<String> content();
  Future<void> setContent(String html, {Duration? timeout, WaitUntil? waitUntil});
  
  // === Locator (Recomendado) ===
  Locator locator(String selector, {LocatorOptions? options});
  Locator getByRole(AriaRole role, {String? name, bool? exact});
  Locator getByText(dynamic text, {bool? exact});
  Locator getByLabel(dynamic text, {bool? exact});
  Locator getByPlaceholder(dynamic text, {bool? exact});
  Locator getByAltText(dynamic text, {bool? exact});
  Locator getByTitle(dynamic text, {bool? exact});
  Locator getByTestId(dynamic testId);
  
  // === Ações (via selector — uso legado, prefira Locator) ===
  Future<void> click(String selector, {/* options */});
  Future<void> dblclick(String selector, {/* options */});
  Future<void> fill(String selector, String value, {/* options */});
  Future<void> type(String selector, String text, {/* options */});
  Future<void> press(String selector, String key, {/* options */});
  Future<void> check(String selector, {/* options */});
  Future<void> uncheck(String selector, {/* options */});
  Future<void> selectOption(String selector, dynamic values, {/* options */});
  Future<void> hover(String selector, {/* options */});
  Future<void> focus(String selector, {/* options */});
  Future<void> tap(String selector, {/* options */});
  
  // === Esperas ===
  Future<ElementHandle?> waitForSelector(String selector, {
    WaitForSelectorState? state,
    Duration? timeout,
    bool? strict,
  });
  Future<Response?> waitForNavigation({
    dynamic url,
    WaitUntil? waitUntil,
    Duration? timeout,
  });
  Future<void> waitForLoadState({LoadState? state, Duration? timeout});
  Future<void> waitForURL(dynamic url, {Duration? timeout, WaitUntil? waitUntil});
  Future<void> waitForTimeout(Duration timeout);
  Future<JSHandle> waitForFunction(String expression, {
    dynamic arg,
    Duration? timeout,
    PollingOption? polling,
  });
  
  // === JavaScript ===
  Future<dynamic> evaluate(String expression, {dynamic arg});
  Future<JSHandle> evaluateHandle(String expression, {dynamic arg});
  Future<void> addInitScript(String script);
  Future<void> addScriptTag({String? url, String? content, String? path, String? type});
  Future<void> addStyleTag({String? url, String? content, String? path});
  Future<ElementHandle> addElement(String tagName, {Map<String, String>? attributes});
  
  // === Screenshot / PDF ===
  Future<Uint8List> screenshot({
    ScreenshotType? type,
    int? quality,
    bool? fullPage,
    Rect? clip,
    bool? omitBackground,
    ScreenshotAnimations? animations,
    ScreenshotCaret? caret,
    ScreenshotScale? scale,
    Duration? timeout,
    String? path,
    String? mask,
    String? style,
  });
  Future<Uint8List> pdf({/* options */});
  
  // === Network ===
  Future<void> route(dynamic url, RouteHandler handler);
  Future<void> unroute(dynamic url, [RouteHandler? handler]);
  Future<void> setExtraHTTPHeaders(Map<String, String> headers);
  
  // === Viewport / Emulação ===
  ViewportSize? get viewportSize;
  Future<void> setViewportSize(ViewportSize size);
  Future<void> emulateMedia({MediaType? media, ColorScheme? colorScheme, ReducedMotion? reducedMotion, ForcedColors? forcedColors});
  
  // === Dialogs ===
  Stream<Dialog> get onDialog;
  
  // === Console ===
  Stream<ConsoleMessage> get onConsoleMessage;
  
  // === Downloads ===
  Stream<Download> get onDownload;
  
  // === File Chooser ===
  Stream<FileChooser> get onFileChooser;
  
  // === Page lifecycle ===
  Stream<void> get onLoad;
  Stream<void> get onDOMContentLoaded;
  Stream<void> get onClose;
  Stream<void> get onCrash;
  Stream<PageError> get onPageError;
  Stream<Request> get onRequest;
  Stream<Response> get onResponse;
  Stream<Request> get onRequestFailed;
  Stream<Request> get onRequestFinished;
  Stream<WebSocket> get onWebSocket;
  Stream<Worker> get onWorker;
  Stream<Popup> get onPopup;
  
  // === Fechar ===
  Future<void> close({bool? runBeforeUnload});
  bool get isClosed;
  
  // === Video ===
  Video? get video;
  
  // === Accessibility ===
  Future<AccessibilitySnapshot> accessibility({String? root});
}
```

### 3.6. Locator

```dart
/// Localizador de elementos — a forma recomendada de interagir com elementos.
/// Locators são sempre "auto-waiting" e "auto-retrying".
abstract class Locator {
  // === Refinamento ===
  Locator first;
  Locator last;
  Locator nth(int index);
  Locator filter({String? hasText, String? hasNotText, Locator? has, Locator? hasNot});
  Locator locator(String selector, {LocatorOptions? options});
  Locator getByRole(AriaRole role, {String? name, bool? exact});
  Locator getByText(dynamic text, {bool? exact});
  Locator getByLabel(dynamic text, {bool? exact});
  Locator getByPlaceholder(dynamic text, {bool? exact});
  Locator getByAltText(dynamic text, {bool? exact});
  Locator getByTitle(dynamic text, {bool? exact});
  Locator getByTestId(dynamic testId);
  Locator or(Locator locator);
  Locator and(Locator locator);
  
  // === Ações ===
  Future<void> click({/* options */});
  Future<void> dblclick({/* options */});
  Future<void> fill(String value, {/* options */});
  Future<void> type(String text, {/* options */});
  Future<void> press(String key, {/* options */});
  Future<void> check({/* options */});
  Future<void> uncheck({/* options */});
  Future<void> setChecked(bool checked, {/* options */});
  Future<void> selectOption(dynamic values, {/* options */});
  Future<void> hover({/* options */});
  Future<void> focus({/* options */});
  Future<void> tap({/* options */});
  Future<void> clear({/* options */});
  Future<void> setInputFiles(dynamic files, {/* options */});
  Future<void> dragTo(Locator target, {/* options */});
  Future<void> scrollIntoViewIfNeeded({/* options */});
  Future<void> highlight();
  
  // === Consultas ===
  Future<String?> textContent({Duration? timeout});
  Future<String> innerText({Duration? timeout});
  Future<String> innerHTML({Duration? timeout});
  Future<String?> getAttribute(String name, {Duration? timeout});
  Future<String> inputValue({Duration? timeout});
  Future<bool> isChecked({Duration? timeout});
  Future<bool> isDisabled({Duration? timeout});
  Future<bool> isEditable({Duration? timeout});
  Future<bool> isEnabled({Duration? timeout});
  Future<bool> isHidden({Duration? timeout});
  Future<bool> isVisible({Duration? timeout});
  Future<Rect> boundingBox({Duration? timeout});
  Future<int> count();
  Future<List<String>> allTextContents();
  Future<List<String>> allInnerTexts();
  Future<List<Locator>> all();
  
  // === Esperas ===
  Future<void> waitFor({
    WaitForSelectorState? state,
    Duration? timeout,
  });
  
  // === Screenshot ===
  Future<Uint8List> screenshot({/* options */});
  
  // === Evaluate ===
  Future<dynamic> evaluate(String expression, {dynamic arg});
  Future<JSHandle> evaluateHandle(String expression, {dynamic arg});
  Future<List<dynamic>> evaluateAll(String expression, {dynamic arg});
  
  // === Assertions (para testes) ===
  LocatorAssertions expect();
}
```

### 3.7. Frame

```dart
/// Um frame dentro de uma página (main frame ou iframe).
abstract class Frame {
  /// URL do frame
  String get url;
  
  /// Nome do frame
  String? get name;
  
  /// Frame pai
  Frame? get parentFrame;
  
  /// Frames filhos
  List<Frame> get childFrames;
  
  /// Página dona do frame
  Page get page;
  
  /// Se é o frame principal
  bool get isDetached;
  
  // Mesmos métodos de navegação, locator e avaliação que Page
  Locator locator(String selector, {LocatorOptions? options});
  Future<Response?> goto(String url, {/* options */});
  Future<String> title();
  Future<String> content();
  Future<dynamic> evaluate(String expression, {dynamic arg});
  // ... etc
}
```

---

## 4. Tipos e Enums

```dart
// === Viewport e Screen ===
class ViewportSize {
  final int width;
  final int height;
  const ViewportSize({required this.width, required this.height});
}

class ScreenSize {
  final int width;
  final int height;
  const ScreenSize({required this.width, required this.height});
}

// === Enums ===
enum WaitUntil { load, domContentLoaded, networkIdle, commit }
enum LoadState { load, domContentLoaded, networkIdle }
enum ScreenshotType { png, jpeg }
enum ColorScheme { light, dark, noPreference }
enum ReducedMotion { reduce, noPreference }
enum ForcedColors { active, none }
enum MediaType { screen, print }
enum MouseButton { left, right, middle }
enum WaitForSelectorState { attached, detached, visible, hidden }
enum ServiceWorkerPolicy { allow, block }

// === Network ===
class Cookie {
  final String name;
  final String value;
  final String domain;
  final String path;
  final double expires;
  final bool httpOnly;
  final bool secure;
  final SameSiteAttribute sameSite;
  // ...
}

class Geolocation {
  final double latitude;
  final double longitude;
  final double? accuracy;
  const Geolocation({required this.latitude, required this.longitude, this.accuracy});
}

class ProxySettings {
  final String server;
  final String? bypass;
  final String? username;
  final String? password;
  const ProxySettings({required this.server, this.bypass, this.username, this.password});
}

class HttpCredentials {
  final String username;
  final String password;
  final String? origin;
  const HttpCredentials({required this.username, required this.password, this.origin});
}

// === Handlers ===
typedef RouteHandler = Future<void> Function(Route route);
```

---

## 5. Padrões Idiomáticos Dart

### 5.1. Eventos como Streams (não callbacks)

```dart
// ❌ Padrão Node.js (não fazer)
page.on('load', () => print('loaded'));

// ✅ Padrão Dart (fazer assim)
page.onLoad.listen((_) => print('loaded'));

// ✅ Ou com await
await page.onLoad.first;
```

### 5.2. Options como named parameters (não Maps)

```dart
// ❌ Padrão Node.js (não fazer)
await page.goto('https://example.com', {'waitUntil': 'networkidle'});

// ✅ Padrão Dart (fazer assim)
await page.goto('https://example.com', waitUntil: WaitUntil.networkIdle);
```

### 5.3. Tipos fortes (não dynamic)

```dart
// ❌ Não fazer
Future<dynamic> evaluate(String expression);

// ✅ Fazer
Future<T> evaluate<T>(String expression, {dynamic arg});
```

### 5.4. Disposable pattern

```dart
// Suportar try-with-resources via extensão
final playwright = await Playwright.create();
try {
  // ...
} finally {
  await playwright.dispose();
}
```

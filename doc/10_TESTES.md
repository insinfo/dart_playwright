# 10 — Estratégia de Testes

## 1. Visão Geral

A estratégia de testes do Playwright Dart é organizada em camadas, garantindo cobertura desde o nível de unidade até integração com navegadores reais.

---

## 2. Camadas de Teste

### 2.1. Testes Unitários (sem navegador)

**Alvo**: Lógica interna sem precisar de navegador real.

```dart
// test/unit/protocol/
├── validator_test.dart          // Validação de mensagens
├── serializers_test.dart        // Serialização/desserialização
├── channel_types_test.dart      // Tipos gerados

// test/unit/transport/
├── pipe_transport_test.dart     // Parsing de null-byte messages
├── web_socket_transport_test.dart

// test/unit/registry/
├── host_platform_test.dart      // Detecção de plataforma
├── browser_descriptor_test.dart // Parsing de browsers.json
├── registry_test.dart           // Resolução de URLs

// test/unit/connection/
├── connection_test.dart         // Despacho de mensagens
├── channel_owner_test.dart      // Lifecycle de objetos
├── event_emitter_test.dart      // Sistema de eventos

// test/unit/helpers/
├── timeout_settings_test.dart
├── waiter_test.dart
```

**Exemplo**:
```dart
// test/unit/transport/pipe_transport_test.dart

import 'dart:async';
import 'dart:convert';
import 'package:test/test.dart';
import 'package:playwright_core/src/transport/pipe_transport.dart';

void main() {
  group('PipeTransport', () {
    test('should parse single message', () async {
      final controller = StreamController<List<int>>();
      final transport = PipeTransport(
        pipeWrite: MockIOSink(),
        pipeRead: controller.stream,
      );
      
      final messages = <ProtocolResponse>[];
      transport.onMessage.listen(messages.add);
      
      // Simular mensagem do navegador
      final msg = jsonEncode({'id': 1, 'result': {'success': true}});
      controller.add(utf8.encode('$msg\x00'));
      
      await Future.delayed(Duration.zero);
      
      expect(messages, hasLength(1));
      expect(messages.first.id, equals(1));
      expect(messages.first.result?['success'], isTrue);
    });
    
    test('should handle split messages', () async {
      final controller = StreamController<List<int>>();
      final transport = PipeTransport(
        pipeWrite: MockIOSink(),
        pipeRead: controller.stream,
      );
      
      final messages = <ProtocolResponse>[];
      transport.onMessage.listen(messages.add);
      
      // Mensagem dividida em dois chunks
      final msg = jsonEncode({'id': 1, 'result': {}});
      final bytes = utf8.encode('$msg\x00');
      final mid = bytes.length ~/ 2;
      
      controller.add(bytes.sublist(0, mid));
      await Future.delayed(Duration.zero);
      expect(messages, isEmpty);
      
      controller.add(bytes.sublist(mid));
      await Future.delayed(Duration.zero);
      expect(messages, hasLength(1));
    });
    
    test('should handle multiple messages in one chunk', () async {
      final controller = StreamController<List<int>>();
      final transport = PipeTransport(
        pipeWrite: MockIOSink(),
        pipeRead: controller.stream,
      );
      
      final messages = <ProtocolResponse>[];
      transport.onMessage.listen(messages.add);
      
      final msg1 = jsonEncode({'id': 1, 'result': {}});
      final msg2 = jsonEncode({'id': 2, 'result': {}});
      controller.add(utf8.encode('$msg1\x00$msg2\x00'));
      
      await Future.delayed(Duration(milliseconds: 10));
      expect(messages, hasLength(2));
    });
  });
}
```

### 2.2. Testes de Integração com Mock (sem navegador real)

**Alvo**: Testar a API client com servidor mock.

```dart
// test/integration/mock/
├── mock_browser_server.dart     // Servidor mock do protocolo
├── browser_test.dart            // Browser API com mock
├── page_test.dart               // Page API com mock
├── locator_test.dart            // Locator com mock
├── network_test.dart            // Network com mock
```

**Exemplo**:
```dart
// test/integration/mock/mock_browser_server.dart

class MockBrowserServer {
  final _transport = MockTransport();
  
  MockBrowserServer() {
    _transport.onClientMessage.listen(_handleMessage);
  }
  
  void _handleMessage(Map<String, dynamic> message) {
    final method = message['method'] as String;
    final id = message['id'] as int;
    
    switch (method) {
      case 'initialize':
        _reply(id, {
          'playwright': {'guid': 'playwright-1'},
        });
        // Emitir criação do Playwright
        _emit('__create__', {
          'type': 'Playwright',
          'guid': 'playwright-1',
          'initializer': {
            'chromium': {'guid': 'browser-type-chromium'},
            'firefox': {'guid': 'browser-type-firefox'},
            'webkit': {'guid': 'browser-type-webkit'},
          },
        });
        break;
      // ... mais handlers
    }
  }
  
  void _reply(int id, Map<String, dynamic> result) {
    _transport.emitToClient({'id': id, 'result': result});
  }
  
  void _emit(String method, Map<String, dynamic> params) {
    _transport.emitToClient({
      'method': method,
      'params': params,
    });
  }
}
```

### 2.3. Testes de Integração com Navegador Real

**Alvo**: Testar com navegadores reais (Chromium, Firefox, WebKit).

```dart
// test/integration/browser/
├── chromium/
│   ├── launch_test.dart
│   ├── page_test.dart
│   ├── navigation_test.dart
│   ├── locator_test.dart
│   ├── network_test.dart
│   ├── screenshot_test.dart
│   ├── evaluate_test.dart
│   ├── input_test.dart
│   └── dialog_test.dart
├── firefox/
│   └── ... (mesmos testes)
├── webkit/
│   └── ... (mesmos testes)
└── cross_browser/
    ├── api_parity_test.dart     // Verificar paridade entre navegadores
    └── locator_cross_test.dart
```

**Exemplo**:
```dart
// test/integration/browser/chromium/navigation_test.dart

import 'package:test/test.dart';
import 'package:playwright/playwright.dart';
import '../test_server.dart';

void main() {
  late Playwright playwright;
  late Browser browser;
  late BrowserContext context;
  late Page page;
  late TestServer server;
  
  setUpAll(() async {
    server = await TestServer.start();
    playwright = await Playwright.create();
    browser = await playwright.chromium.launch();
  });
  
  setUp(() async {
    context = await browser.newContext();
    page = await context.newPage();
  });
  
  tearDown(() async {
    await context.close();
  });
  
  tearDownAll(() async {
    await browser.close();
    await playwright.dispose();
    await server.stop();
  });
  
  group('Navigation', () {
    test('should navigate to a URL', () async {
      final response = await page.goto(server.url('/hello'));
      expect(response, isNotNull);
      expect(response!.status, equals(200));
      expect(page.url, equals(server.url('/hello')));
    });
    
    test('should get page title', () async {
      await page.goto(server.url('/title'));
      expect(await page.title(), equals('Test Page Title'));
    });
    
    test('should wait for load event', () async {
      await page.goto(server.url('/slow-page'), 
        waitUntil: WaitUntil.load,
        timeout: Duration(seconds: 10),
      );
      expect(await page.title(), isNotEmpty);
    });
    
    test('should navigate back and forward', () async {
      await page.goto(server.url('/page1'));
      await page.goto(server.url('/page2'));
      
      await page.goBack();
      expect(page.url, contains('/page1'));
      
      await page.goForward();
      expect(page.url, contains('/page2'));
    });
    
    test('should handle navigation error', () async {
      expect(
        () => page.goto('http://nonexistent.invalid/'),
        throwsA(isA<PlaywrightException>()),
      );
    });
  });
  
  group('Locator', () {
    test('should click element', () async {
      await page.goto(server.url('/button'));
      await page.locator('#clickMe').click();
      expect(
        await page.evaluate('() => window.__clicked'),
        isTrue,
      );
    });
    
    test('should fill input', () async {
      await page.goto(server.url('/input'));
      await page.locator('input[name="search"]').fill('hello world');
      expect(
        await page.locator('input[name="search"]').inputValue(),
        equals('hello world'),
      );
    });
    
    test('should get text content', () async {
      await page.goto(server.url('/text'));
      final text = await page.locator('#content').textContent();
      expect(text, equals('Hello, World!'));
    });
    
    test('should wait for element', () async {
      await page.goto(server.url('/delayed-element'));
      // Elemento aparece após 500ms
      await page.locator('#delayed').waitFor(
        state: WaitForSelectorState.visible,
        timeout: Duration(seconds: 5),
      );
      expect(await page.locator('#delayed').isVisible(), isTrue);
    });
  });
  
  group('Screenshot', () {
    test('should take page screenshot', () async {
      await page.goto(server.url('/visual'));
      final screenshot = await page.screenshot();
      expect(screenshot, isNotEmpty);
      // Verificar que é um PNG válido
      expect(screenshot.sublist(0, 8), equals([137, 80, 78, 71, 13, 10, 26, 10]));
    });
    
    test('should take full page screenshot', () async {
      await page.goto(server.url('/long-page'));
      final screenshot = await page.screenshot(fullPage: true);
      expect(screenshot, isNotEmpty);
    });
  });
  
  group('Network', () {
    test('should capture requests', () async {
      final requests = <Request>[];
      page.onRequest.listen(requests.add);
      
      await page.goto(server.url('/with-resources'));
      
      expect(requests, isNotEmpty);
      expect(requests.first.url, contains(server.url('')));
    });
    
    test('should capture responses', () async {
      final responses = <Response>[];
      page.onResponse.listen(responses.add);
      
      await page.goto(server.url('/hello'));
      
      expect(responses, isNotEmpty);
      expect(responses.first.status, equals(200));
    });
  });
  
  group('Evaluate', () {
    test('should evaluate expression', () async {
      await page.goto(server.url('/hello'));
      final result = await page.evaluate('() => 2 + 2');
      expect(result, equals(4));
    });
    
    test('should evaluate with arguments', () async {
      await page.goto(server.url('/hello'));
      final result = await page.evaluate(
        '(a, b) => a + b',
        arg: [3, 4],
      );
      expect(result, equals(7));
    });
    
    test('should return complex objects', () async {
      await page.goto(server.url('/hello'));
      final result = await page.evaluate('''
        () => ({ name: 'test', value: 42, nested: { ok: true } })
      ''');
      expect(result, isA<Map>());
      expect(result['name'], equals('test'));
      expect(result['nested']['ok'], isTrue);
    });
  });
}
```

### 2.4. Servidor de Teste

```dart
// test/integration/test_server.dart

import 'dart:io';

class TestServer {
  final HttpServer _server;
  final int port;
  
  TestServer._(this._server) : port = _server.port;
  
  static Future<TestServer> start({int? port}) async {
    final server = await HttpServer.bind('127.0.0.1', port ?? 0);
    final testServer = TestServer._(server);
    
    server.listen((request) {
      testServer._handleRequest(request);
    });
    
    return testServer;
  }
  
  String url(String path) => 'http://127.0.0.1:$port$path';
  
  void _handleRequest(HttpRequest request) {
    final path = request.uri.path;
    
    switch (path) {
      case '/hello':
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.html
          ..write('<html><body>Hello</body></html>');
        break;
      
      case '/title':
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.html
          ..write('<html><head><title>Test Page Title</title></head><body></body></html>');
        break;
      
      case '/button':
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.html
          ..write('''
            <html><body>
              <button id="clickMe" onclick="window.__clicked = true">Click</button>
            </body></html>
          ''');
        break;
      
      case '/input':
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.html
          ..write('''
            <html><body>
              <input name="search" type="text" />
            </body></html>
          ''');
        break;
      
      case '/text':
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.html
          ..write('<html><body><div id="content">Hello, World!</div></body></html>');
        break;
      
      case '/delayed-element':
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.html
          ..write('''
            <html><body>
              <script>
                setTimeout(() => {
                  const el = document.createElement('div');
                  el.id = 'delayed';
                  el.textContent = 'Appeared!';
                  document.body.appendChild(el);
                }, 500);
              </script>
            </body></html>
          ''');
        break;
      
      default:
        request.response
          ..statusCode = 404
          ..write('Not found');
    }
    
    request.response.close();
  }
  
  Future<void> stop() async {
    await _server.close();
  }
}
```

---

## 3. CI/CD Matrix

### 3.1. Matriz de Teste

| OS | Chromium | Firefox | WebKit |
|---|---|---|---|
| Windows x64 | ✅ | ✅ | ✅ |
| macOS x64 | ✅ | ✅ | ✅ |
| macOS ARM64 | ✅ | ✅ | ✅ |
| Ubuntu 22.04 | ✅ | ✅ | ✅ |
| Ubuntu 24.04 | ✅ | ✅ | ✅ |

### 3.2. GitHub Actions

```yaml
# .github/workflows/test.yml
name: Tests
on: [push, pull_request]

jobs:
  unit-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: dart-lang/setup-dart@v1
      - run: dart pub get
      - run: dart test test/unit/

  integration-tests:
    strategy:
      matrix:
        os: [ubuntu-latest, macos-latest, windows-latest]
        browser: [chromium, firefox, webkit]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - uses: dart-lang/setup-dart@v1
      - run: dart pub get
      - run: dart run playwright install ${{ matrix.browser }}
      - run: dart test test/integration/browser/${{ matrix.browser }}/
```

---

## 4. Conformidade com Playwright Oficial

### 4.1. Testes de Paridade

Portar os testes oficiais do Playwright TypeScript adaptados para Dart:

```
playwright-typescript/tests/
├── page/                    → Testes de Page
├── browsercontext/          → Testes de BrowserContext  
├── chromium/               → Testes específicos Chromium
├── firefox/                → Testes específicos Firefox
├── webkit/                 → Testes específicos WebKit
├── locator/                → Testes de Locator
├── network/                → Testes de Network
└── ...
```

Os testes oficiais servem como especificação comportamental.

### 4.2. Métricas de Cobertura

| Marco | Cobertura Alvo |
|---|---|
| v0.1 | >80% dos testes de Page/Frame/Locator básicos |
| v0.2 | >70% dos testes oficiais para Chromium |
| v0.3 | >60% dos testes de tracing/video/emulation |
| v0.4 | >70% dos testes oficiais para Firefox |
| v0.5 | >70% dos testes oficiais para WebKit |
| v1.0 | >85% de todos os testes oficiais |

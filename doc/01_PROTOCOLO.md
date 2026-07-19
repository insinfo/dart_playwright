# 01 — Protocolo RPC e Geração de Código

## 1. Visão Geral do Protocolo Playwright

O Playwright define seu protocolo de comunicação interna em arquivos YAML localizados em:
```
packages/protocol/spec/
├── android.yml          # Android automation
├── api.yml              # API raiz
├── artifact.yml         # Artefatos (downloads, traces)
├── browser.yml          # Browser interface
├── browserContext.yml    # BrowserContext interface
├── browserType.yml      # BrowserType interface
├── core.yml             # Tipos core (Metadata, SDKLanguage)
├── electron.yml         # Electron support
├── frame.yml            # Frame interface (16.7 KB — grande)
├── handles.yml          # JSHandle e ElementHandle
├── localUtils.yml       # Utilitários locais
├── mixins.yml           # Mixins (LaunchOptions, ContextOptions)
├── network.yml          # Network (Request, Response, Route)
├── page.yml             # Page interface (15.1 KB — grande)
├── playwright.yml       # Playwright root interface
├── serialized.yml       # Tipos serializados
├── structs.yml          # Estruturas auxiliares
├── tracing.yml          # Tracing interface
└── worker.yml           # Worker interface
```

### 1.1. Estrutura do YAML

Cada arquivo YML define **interfaces** com:
- `type: interface` — Objeto do protocolo com identidade (tem GUID)
- `initializer` — Dados enviados quando o objeto é criado
- `commands` — Métodos RPC que podem ser chamados
- `events` — Eventos que o objeto pode emitir
- `type: object` — Tipo auxiliar sem identidade

**Exemplo** — `browserType.yml`:
```yaml
BrowserType:
  type: interface
  
  initializer:
    executablePath: string
    name: string
  
  commands:
    launch:
      title: Launch browser
      parameters:
        $mixin: LaunchOptions
        slowMo: float?
      returns:
        browser: Browser
    
    launchPersistentContext:
      parameters:
        $mixin1: LaunchOptions
        $mixin2: ContextOptions
        userDataDir: string
        slowMo: float?
      returns:
        browser: Browser
        context: BrowserContext
```

### 1.2. Tipos do Protocolo

| Tipo YAML | Tipo Dart |
|---|---|
| `string` | `String` |
| `int` | `int` |
| `float` | `double` |
| `boolean` | `bool` |
| `binary` | `Uint8List` |
| `json` | `dynamic` (JSON) |
| `string?` | `String?` (nullable) |
| `array` com `items: T` | `List<T>` |
| `object` com `properties` | Classe gerada |
| `enum` com `literals` | Dart `enum` |
| `$mixin: Name` | Merge dos parâmetros do mixin |
| `Channel` (e.g., `Browser`, `Page`) | Referência a objeto por GUID |

---

## 2. Gerador de Código de Protocolo

### 2.1. O que será gerado

O gerador vai ler os 19 arquivos YAML e produzir:

```
lib/src/protocol/
├── generated/
│   ├── channels.dart           # Interfaces de canal (client-side)
│   ├── channel_types.dart      # Enums e tipos auxiliares
│   ├── initializers.dart       # Classes de inicialização
│   ├── params.dart             # Classes de parâmetros de comandos
│   ├── results.dart            # Classes de resultados de comandos
│   ├── events.dart             # Classes de eventos
│   ├── mixins.dart             # Mixins (LaunchOptions, ContextOptions)
│   ├── validators.dart         # Validadores de mensagens
│   └── protocol_metainfo.dart  # Metadados do protocolo
```

### 2.2. Exemplo de Geração

**Entrada YAML** — `browser.yml` (parcial):
```yaml
Browser:
  type: interface
  initializer:
    version: string
    name: string
    browserName:
      type: enum
      literals: [chromium, firefox, webkit]
  commands:
    newContext:
      parameters:
        $mixin: ContextOptions
        proxy:
          type: object?
          properties:
            server: string
            bypass: string?
      returns:
        context: BrowserContext
    close:
      parameters:
        reason: string?
  events:
    context:
      parameters:
        context: BrowserContext
    close:
```

**Saída Dart** gerada:

```dart
// === channels.dart ===

/// Canal do Browser — interface para comunicação RPC
abstract class BrowserChannel extends Channel {
  /// Criar novo contexto
  Future<BrowserNewContextResult> newContext(BrowserNewContextParams params);
  
  /// Fechar browser
  Future<void> close(BrowserCloseParams params);
  
  /// Stream de eventos de novo contexto
  Stream<BrowserContextEvent> get onContext;
  
  /// Stream de evento de fechamento
  Stream<void> get onClose;
}

// === initializers.dart ===

class BrowserInitializer {
  final String version;
  final String name;
  final BrowserName browserName;
  
  BrowserInitializer({
    required this.version,
    required this.name,
    required this.browserName,
  });
  
  factory BrowserInitializer.fromJson(Map<String, dynamic> json) => /* ... */;
  Map<String, dynamic> toJson() => /* ... */;
}

enum BrowserName { chromium, firefox, webkit }

// === params.dart ===

class BrowserNewContextParams {
  // Merged from ContextOptions mixin:
  final bool? acceptDownloads;
  final bool? bypassCSP;
  final ColorScheme? colorScheme;
  final String? baseURL;
  // ... outros campos do mixin
  
  // Campos próprios:
  final ProxySettings? proxy;
  
  BrowserNewContextParams({/* ... */});
  
  factory BrowserNewContextParams.fromJson(Map<String, dynamic> json) => /* ... */;
  Map<String, dynamic> toJson() => /* ... */;
}

class ProxySettings {
  final String server;
  final String? bypass;
  final String? username;
  final String? password;
  
  ProxySettings({required this.server, this.bypass, this.username, this.password});
}

class BrowserCloseParams {
  final String? reason;
  BrowserCloseParams({this.reason});
}

// === results.dart ===

class BrowserNewContextResult {
  final BrowserContextChannel context;
  BrowserNewContextResult({required this.context});
}

// === events.dart ===

class BrowserContextEvent {
  final BrowserContextChannel context;
  BrowserContextEvent({required this.context});
}
```

### 2.3. Implementação do Gerador

```dart
// tool/generate_protocol.dart

import 'dart:io';
import 'package:yaml/yaml.dart';
import 'package:path/path.dart' as path;

class ProtocolGenerator {
  final String specDir;
  final String outputDir;
  
  final Map<String, InterfaceSpec> interfaces = {};
  final Map<String, ObjectSpec> objects = {};
  final Map<String, EnumSpec> enums = {};
  final Map<String, MixinSpec> mixins = {};
  
  ProtocolGenerator({required this.specDir, required this.outputDir});
  
  Future<void> generate() async {
    // 1. Ler todos os arquivos YML
    await _parseAllSpecs();
    
    // 2. Resolver mixins ($mixin references)
    _resolveMixins();
    
    // 3. Gerar código Dart
    await _generateChannels();
    await _generateInitializers();
    await _generateParams();
    await _generateResults();
    await _generateEvents();
    await _generateEnums();
    await _generateValidators();
    await _generateMetainfo();
    
    // 4. Formatar código
    await Process.run('dart', ['format', outputDir]);
  }
  
  Future<void> _parseAllSpecs() async {
    final dir = Directory(specDir);
    for (final file in dir.listSync().whereType<File>()) {
      if (!file.path.endsWith('.yml')) continue;
      final content = await file.readAsString();
      final yaml = loadYaml(content) as YamlMap;
      _parseYamlMap(yaml);
    }
  }
  
  void _parseYamlMap(YamlMap yaml) {
    for (final entry in yaml.entries) {
      final name = entry.key as String;
      final spec = entry.value as YamlMap;
      final type = spec['type'] as String?;
      
      switch (type) {
        case 'interface':
          interfaces[name] = _parseInterface(name, spec);
          break;
        case 'object':
          objects[name] = _parseObject(name, spec);
          break;
        case 'enum':
          enums[name] = _parseEnum(name, spec);
          break;
        case 'mixin':
          mixins[name] = _parseMixin(name, spec);
          break;
      }
    }
  }
  
  // ... métodos de parsing e geração detalhados
}
```

---

## 3. Chrome DevTools Protocol (CDP)

### 3.1. Fonte dos Tipos CDP

O protocolo CDP é definido pelo Chromium e disponível em:
- Fonte TS: `packages/playwright-core/src/server/chromium/protocol.d.ts` (823 KB!)
- Fonte oficial: `https://chromedevtools.github.io/devtools-protocol/`

### 3.2. Geração de Tipos CDP para Dart

O CDP é organizado em **domínios** (Page, Network, DOM, Runtime, Target, etc.):

```dart
// Gerado automaticamente
abstract class CDPProtocol {
  PageDomain get page;
  NetworkDomain get network;
  RuntimeDomain get runtime;
  DOMDomain get dom;
  TargetDomain get target;
  InputDomain get input;
  EmulationDomain get emulation;
  // ... ~80 domínios
}

abstract class PageDomain {
  Future<void> enable();
  Future<void> navigate(String url, {String? referrer, String? transitionType, String? frameId});
  Future<CaptureScreenshotResult> captureScreenshot({String? format, int? quality, Viewport? clip});
  Future<PrintToPDFResult> printToPDF({/* ... */});
  
  Stream<FrameNavigatedEvent> get onFrameNavigated;
  Stream<LifecycleEvent> get onLifecycleEvent;
  Stream<LoadEventFiredEvent> get onLoadEventFired;
  // ...
}
```

### 3.3. Gerador CDP

O gerador CDP irá:
1. Baixar o JSON schema do CDP de `https://raw.githubusercontent.com/nicepage/nicepage-protocol/main/json/browser_protocol.json`
2. Ou usar o `protocol.d.ts` como referência para gerar tipos Dart
3. Produzir classes para cada domínio com métodos e eventos

```
lib/src/cdp/
├── generated/
│   ├── protocol.dart           # Todos os domínios
│   ├── domains/
│   │   ├── page.dart
│   │   ├── network.dart
│   │   ├── runtime.dart
│   │   ├── dom.dart
│   │   ├── target.dart
│   │   ├── input.dart
│   │   ├── emulation.dart
│   │   └── ... (~80 domínios)
│   └── types/
│       ├── page_types.dart
│       ├── network_types.dart
│       └── ...
```

---

## 4. Juggler Protocol (Firefox)

### 4.1. Definição do Protocolo

O Juggler é definido em `packages/playwright-core/src/server/firefox/protocol.d.ts` (40.9 KB):

```typescript
// Domínios do Juggler:
export module Protocol {
  export module Browser { /* ... */ }
  export module Page { /* ... */ }
  export module Network { /* ... */ }
  export module Runtime { /* ... */ }
}
```

Principais domínios Juggler:
- **Browser** — Criar/fechar contextos e páginas
- **Page** — Navegação, conteúdo, screenshot
- **Network** — Interceptação, cookies
- **Runtime** — Execução de JavaScript

### 4.2. Geração para Dart

```dart
abstract class JugglerProtocol {
  JugglerBrowserDomain get browser;
  JugglerPageDomain get page;
  JugglerNetworkDomain get network;
  JugglerRuntimeDomain get runtime;
}
```

---

## 5. WebKit Inspector Protocol

### 5.1. Definição do Protocolo

Definido em `packages/playwright-core/src/server/webkit/protocol.d.ts` (312 KB):

Principais domínios:
- **Playwright** — Domínio custom do Playwright (criação de contextos)
- **Page** — Navegação, lifecycle
- **Network** — Requests, interceptação
- **Runtime** — JavaScript execution
- **DOM** — Manipulação do DOM
- **Console** — Mensagens do console
- **Dialog** — Alertas e prompts

### 5.2. Geração para Dart

Similar ao CDP, com domínios específicos do WebKit Inspector.

---

## 6. Validação de Mensagens

### 6.1. Validador Original (TS)

O validador original em `packages/protocol/src/validator.ts` (101 KB!) valida cada mensagem do protocolo. Ele verifica tipos, campos obrigatórios e valores de enum.

### 6.2. Validador Dart

```dart
/// Validador de mensagens do protocolo
class ProtocolValidator {
  /// Validar parâmetros de um comando
  static Map<String, dynamic> validateParams(
    String type,      // e.g., "BrowserType"  
    String method,    // e.g., "launch"
    Map<String, dynamic> params,
  ) {
    final schema = _schemas['${type}.${method}.Params'];
    if (schema == null) throw ValidationError('Unknown: $type.$method');
    return schema.validate(params);
  }
  
  /// Validar resultado de um comando
  static Map<String, dynamic> validateResult(
    String type,
    String method,
    Map<String, dynamic> result,
  ) {
    final schema = _schemas['${type}.${method}.Result'];
    if (schema == null) throw ValidationError('Unknown: $type.$method');
    return schema.validate(result);
  }
}
```

---

## 7. Serialização

### 7.1. Serialização de Canais

Quando um objeto é referenciado no protocolo, ele é serializado como `{ guid: "..." }`:

```dart
/// Serializar referência de canal para wire
dynamic channelToWire(ChannelOwner object) {
  return {'guid': object.guid};
}

/// Desserializar referência de canal do wire
ChannelOwner channelFromWire(Map<String, dynamic> data, Connection connection) {
  final guid = data['guid'] as String;
  final object = connection.getObject(guid);
  if (object == null) throw StateError('Object with guid $guid not found');
  return object;
}
```

### 7.2. Serialização de Binários

```dart
/// Binários podem ser enviados como base64 ou como buffer direto
String binaryToBase64(Uint8List data) => base64Encode(data);
Uint8List binaryFromBase64(String data) => base64Decode(data);
```

### 7.3. Serialização de Handles

```dart
/// Handles JavaScript são serializados com informações de tipo
class SerializedValue {
  final String? n;      // number
  final String? s;      // string
  final bool? b;        // boolean
  final String? v;      // special value: "null", "undefined", "NaN", "Infinity", "-Infinity", "-0"
  final String? d;      // Date ISO string
  final String? u;      // URL string
  final String? bi;     // BigInt
  final int? ref;       // Object reference
  final int? h;         // Handle ID
  final List<SerializedListItem>? a; // Array
  final List<SerializedObjectItem>? o; // Object
  
  SerializedValue({/* ... */});
}
```

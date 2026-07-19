# Playwright Dart — Plano Mestre de Portabilidade

> **Data**: 2026-07-19  
> **Versão do plano**: 1.0  
> **Baseado no Playwright TypeScript**: `main` branch (Julho 2026)  
> **Alvo**: Port nativo completo do Playwright para Dart, sem dependência de Node.js

---

## 1. Visão Estratégica

### 1.1. O que é este projeto

Um port completo do **núcleo do Playwright** (originalmente escrito em TypeScript/Node.js) para **Dart puro**, criando uma implementação nativa que controla diretamente os navegadores Chromium, Firefox e WebKit sem qualquer dependência de Node.js, npm, npx, JavaScript em execução, ou o driver Node "escondido".

### 1.2. Diferença para wrappers existentes

| Abordagem | Dependência de Node | Navegadores | Complexidade |
|---|---|---|---|
| **playwright-dotnet/python/java** | Sim (usa driver Node.js) | Todos via driver | Wrapper RPC |
| **puppeteer dart** | Não | Somente Chromium | Port direto do CDP |
| **playwright_dart (este projeto)** | **Não** | **Chromium + Firefox + WebKit** | **Port completo** |

### 1.3. Cadeia de execução final

```
Código Dart do Usuário
       ↓
playwright_dart (API pública)
       ↓
playwright_protocol (serialização/mensagens)
       ↓
Transporte (Pipe/WebSocket/Stdio)
       ↓
Protocolo nativo do navegador:
  ├── Chromium → Chrome DevTools Protocol (CDP)
  ├── Firefox  → Juggler Protocol (patches Playwright)
  └── WebKit   → WebKit Inspector Protocol (patches Playwright)
       ↓
Navegador (binário oficial do Playwright via CDN)
```

### 1.4. O que NÃO estará presente

- `node.exe` / `npm` / `npx`
- `node_modules` / `package.json`
- JavaScript em execução como runtime
- Driver Node.js escondido
- Qualquer dependência de TypeScript

---

## 2. Arquitetura de Pacotes

O projeto será organizado em **4 pacotes Dart** independentes:

```
playwright_dart/
├── packages/
│   ├── playwright_protocol/      # Pacote 1: Protocolo e serialização
│   │   ├── lib/
│   │   │   ├── src/
│   │   │   │   ├── protocol/          # Definições do protocolo Playwright
│   │   │   │   │   ├── channels.dart  # Interfaces de canal geradas
│   │   │   │   │   ├── validator.dart # Validação de mensagens
│   │   │   │   │   ├── serializers.dart
│   │   │   │   │   └── types.dart
│   │   │   │   ├── cdp/               # Chrome DevTools Protocol
│   │   │   │   │   ├── protocol.dart  # Tipos CDP gerados
│   │   │   │   │   └── domains/       # Domínios CDP (Page, Network, etc.)
│   │   │   │   ├── juggler/           # Firefox Juggler Protocol
│   │   │   │   │   └── protocol.dart
│   │   │   │   └── webkit/            # WebKit Inspector Protocol
│   │   │   │       └── protocol.dart
│   │   │   └── playwright_protocol.dart
│   │   ├── tool/
│   │   │   └── generate_protocol.dart # Gerador de código a partir dos YML
│   │   └── pubspec.yaml
│   │
│   ├── playwright_core/              # Pacote 2: Implementação do servidor
│   │   ├── lib/
│   │   │   ├── src/
│   │   │   │   ├── server/
│   │   │   │   │   ├── browser.dart
│   │   │   │   │   ├── browser_context.dart
│   │   │   │   │   ├── browser_type.dart
│   │   │   │   │   ├── page.dart
│   │   │   │   │   ├── frame.dart
│   │   │   │   │   ├── dom.dart
│   │   │   │   │   ├── input.dart
│   │   │   │   │   ├── network.dart
│   │   │   │   │   ├── screenshotter.dart
│   │   │   │   │   ├── selectors.dart
│   │   │   │   │   ├── javascript.dart
│   │   │   │   │   ├── progress.dart
│   │   │   │   │   ├── instrumentation.dart
│   │   │   │   │   ├── chromium/
│   │   │   │   │   │   ├── cr_browser.dart
│   │   │   │   │   │   ├── cr_connection.dart
│   │   │   │   │   │   ├── cr_page.dart
│   │   │   │   │   │   ├── cr_network_manager.dart
│   │   │   │   │   │   ├── cr_input.dart
│   │   │   │   │   │   ├── cr_execution_context.dart
│   │   │   │   │   │   └── chromium.dart
│   │   │   │   │   ├── firefox/
│   │   │   │   │   │   ├── ff_browser.dart
│   │   │   │   │   │   ├── ff_connection.dart
│   │   │   │   │   │   ├── ff_page.dart
│   │   │   │   │   │   ├── ff_network_manager.dart
│   │   │   │   │   │   ├── ff_input.dart
│   │   │   │   │   │   ├── ff_execution_context.dart
│   │   │   │   │   │   └── firefox.dart
│   │   │   │   │   └── webkit/
│   │   │   │   │       ├── wk_browser.dart
│   │   │   │   │       ├── wk_connection.dart
│   │   │   │   │       ├── wk_page.dart
│   │   │   │   │       ├── wk_input.dart
│   │   │   │   │       ├── wk_execution_context.dart
│   │   │   │   │       └── webkit.dart
│   │   │   │   ├── transport/
│   │   │   │   │   ├── transport.dart
│   │   │   │   │   ├── pipe_transport.dart
│   │   │   │   │   └── web_socket_transport.dart
│   │   │   │   ├── registry/
│   │   │   │   │   ├── browser_fetcher.dart
│   │   │   │   │   ├── registry.dart
│   │   │   │   │   ├── host_platform.dart
│   │   │   │   │   └── dependencies.dart
│   │   │   │   └── dispatchers/
│   │   │   │       ├── dispatcher.dart
│   │   │   │       ├── browser_dispatcher.dart
│   │   │   │       ├── browser_context_dispatcher.dart
│   │   │   │       ├── page_dispatcher.dart
│   │   │   │       ├── frame_dispatcher.dart
│   │   │   │       └── ...
│   │   │   └── playwright_core.dart
│   │   └── pubspec.yaml
│   │
│   ├── playwright/                   # Pacote 3: API pública (o que o usuário importa)
│   │   ├── lib/
│   │   │   ├── src/
│   │   │   │   ├── api/
│   │   │   │   │   ├── playwright.dart
│   │   │   │   │   ├── browser_type.dart
│   │   │   │   │   ├── browser.dart
│   │   │   │   │   ├── browser_context.dart
│   │   │   │   │   ├── page.dart
│   │   │   │   │   ├── frame.dart
│   │   │   │   │   ├── locator.dart
│   │   │   │   │   ├── element_handle.dart
│   │   │   │   │   ├── js_handle.dart
│   │   │   │   │   ├── request.dart
│   │   │   │   │   ├── response.dart
│   │   │   │   │   ├── route.dart
│   │   │   │   │   ├── dialog.dart
│   │   │   │   │   ├── console_message.dart
│   │   │   │   │   ├── download.dart
│   │   │   │   │   ├── file_chooser.dart
│   │   │   │   │   ├── tracing.dart
│   │   │   │   │   ├── video.dart
│   │   │   │   │   ├── web_socket.dart
│   │   │   │   │   ├── worker.dart
│   │   │   │   │   ├── clock.dart
│   │   │   │   │   ├── coverage.dart
│   │   │   │   │   ├── selectors.dart
│   │   │   │   │   └── errors.dart
│   │   │   │   ├── connection/
│   │   │   │   │   ├── connection.dart
│   │   │   │   │   ├── channel_owner.dart
│   │   │   │   │   └── event_emitter.dart
│   │   │   │   └── helpers/
│   │   │   │       ├── timeout_settings.dart
│   │   │   │       ├── waiter.dart
│   │   │   │       └── client_helper.dart
│   │   │   └── playwright.dart
│   │   ├── bin/
│   │   │   └── playwright.dart        # CLI: playwright install, etc.
│   │   └── pubspec.yaml
│   │
│   └── playwright_mcp/               # Pacote 4: Servidor MCP
│       ├── lib/
│       │   ├── src/
│       │   │   ├── mcp_server.dart
│       │   │   ├── tools/
│       │   │   │   ├── navigate.dart
│       │   │   │   ├── click.dart
│       │   │   │   ├── fill.dart
│       │   │   │   ├── screenshot.dart
│       │   │   │   ├── snapshot.dart
│       │   │   │   └── evaluate.dart
│       │   │   └── context_manager.dart
│       │   └── playwright_mcp.dart
│       ├── bin/
│       │   └── playwright_mcp.dart
│       └── pubspec.yaml
│
├── tool/
│   ├── generate_protocol.dart         # Gerador principal
│   └── generate_cdp.dart             # Gerador CDP
│
├── browsers.json                      # Versões dos navegadores compatíveis
├── pubspec.yaml                       # Workspace root (Dart workspaces)
└── doc/                               # Documentação (este plano)
```

---

## 3. Decisões Arquiteturais Fundamentais

### 3.1. Modelo de Execução: In-Process vs. Out-of-Process

O Playwright TypeScript original opera em dois modos:

1. **In-Process**: Cliente e servidor no mesmo processo Node.js
2. **Out-of-Process**: Cliente se comunica com servidor via pipe/WebSocket

**Decisão para Dart**: Começar com **In-Process** (tudo no mesmo processo Dart), pois:
- Simplifica o desenvolvimento inicial
- Dart não precisa do modelo out-of-process para isolar JavaScript
- Performance máxima (sem overhead de serialização IPC)
- Ainda é possível adicionar modo remoto depois via WebSocket

### 3.2. Mapeamento de Conceitos TypeScript → Dart

| TypeScript | Dart |
|---|---|
| `class extends EventEmitter` | `class with EventEmitterMixin` ou `StreamController` |
| `Promise<T>` | `Future<T>` |
| `async/await` | `async/await` (idêntico) |
| `EventEmitter.on()` | `Stream<T>` + `StreamSubscription` |
| `Proxy` (canal) | Classe concreta com chamadas de método |
| `Buffer` | `Uint8List` |
| `Map<string, any>` | `Map<String, dynamic>` |
| `interface` | `abstract class` |
| `type union (A | B)` | `sealed class` ou union types |
| `process.spawn()` | `Process.start()` (dart:io) |
| `WebSocket (ws)` | `WebSocket` (dart:io) |
| `fs` module | `dart:io` (File, Directory) |
| `path` module | `package:path` |
| `child_process` | `dart:io Process` |

### 3.3. Sistema de Eventos

O Playwright usa `EventEmitter` extensivamente. Em Dart, temos duas opções:

**Opção escolhida**: Padrão híbrido
```dart
// EventEmitter customizado que suporta tanto listeners quanto Streams
abstract class PlaywrightEventEmitter {
  /// Escutar evento por nome (compatível com API do Playwright)
  void on(String event, Function listener);
  void once(String event, Function listener);
  void off(String event, Function listener);
  
  /// Escutar evento como Stream (idiomático Dart)
  Stream<T> onEvent<T>(String event);
  
  /// Emitir evento
  void emit(String event, [dynamic data]);
}
```

### 3.4. Gerenciamento de Processos do Navegador

```dart
/// Equivalente ao BrowserType.launch() do TS
class BrowserProcess {
  final Process _process;
  final PipeTransport _transport;
  
  static Future<BrowserProcess> launch({
    required String executablePath,
    required List<String> args,
    bool headless = true,
  }) async {
    final process = await Process.start(
      executablePath,
      args,
      // Chromium usa pipe: --remote-debugging-pipe
      // Firefox/WebKit usam stdio
    );
    // ...
  }
}
```

---

## 4. Repositórios de Referência Clonados

Os seguintes repositórios foram clonados em `C:\MyDartProjects\playwright\referencias\`:

| Diretório | Fonte | Propósito |
|---|---|---|
| `playwright-typescript/` | `microsoft/playwright` | Código-fonte principal a ser portado |
| `playwright-dotnet/` | `microsoft/playwright-dotnet` | Referência de como outro port (C#) estrutura a API |

### 4.1. Mapeamento de Diretórios de Referência

```
playwright-typescript/
├── packages/protocol/spec/           → Definições YML do protocolo RPC
├── packages/protocol/src/            → Validadores e serializadores
├── packages/playwright-core/src/
│   ├── client/                       → API pública (nosso pacote playwright/)
│   │   ├── channelOwner.ts          → channel_owner.dart
│   │   ├── connection.ts            → connection.dart
│   │   ├── page.ts                  → page.dart
│   │   ├── browser.ts              → browser.dart
│   │   ├── browserContext.ts        → browser_context.dart
│   │   ├── browserType.ts          → browser_type.dart
│   │   ├── frame.ts                → frame.dart
│   │   ├── locator.ts              → locator.dart
│   │   ├── elementHandle.ts        → element_handle.dart
│   │   ├── network.ts              → network.dart (Request, Response, Route, WebSocket)
│   │   └── ...52 arquivos total
│   ├── server/                       → Implementação core (nosso pacote playwright_core/)
│   │   ├── chromium/                 → Motor Chromium via CDP
│   │   ├── firefox/                  → Motor Firefox via Juggler
│   │   ├── webkit/                   → Motor WebKit via Inspector
│   │   ├── dispatchers/              → Bridge RPC server→client
│   │   ├── registry/                 → Download e cache de binários
│   │   ├── transport.ts             → WebSocket transport
│   │   ├── pipeTransport.ts         → Pipe transport (stdio)
│   │   ├── frames.ts               → Lógica principal de Frame
│   │   ├── page.ts                  → Lógica principal de Page
│   │   ├── dom.ts                   → Manipulação DOM
│   │   ├── network.ts              → Interceptação de rede
│   │   └── ...53 arquivos + 11 dirs
│   └── common/                       → Utilitários compartilhados
└── browser_patches/                  → Patches para Firefox e WebKit
    ├── firefox/
    └── webkit/
```

---

## 5. Protocolo de Comunicação com Navegadores

### 5.1. Chromium — Chrome DevTools Protocol (CDP)

- **Protocolo**: CDP padrão (JSON-RPC sobre WebSocket ou Pipe)
- **Transporte**: `--remote-debugging-pipe` (pipes stdio) ou `--remote-debugging-port` (WebSocket)
- **Referência TS**: `packages/playwright-core/src/server/chromium/`
- **Arquivos-chave a portar**:
  - `crConnection.ts` → `cr_connection.dart` (9.2 KB)
  - `crBrowser.ts` → `cr_browser.dart` (24.4 KB)
  - `crPage.ts` → `cr_page.dart` (53.6 KB — maior arquivo)
  - `crNetworkManager.ts` → `cr_network_manager.dart` (43.4 KB)
  - `crInput.ts` → `cr_input.dart` (6.7 KB)
  - `crExecutionContext.ts` → `cr_execution_context.dart` (6.1 KB)
  - `protocol.d.ts` → Gerado automaticamente (823 KB de tipos CDP)

### 5.2. Firefox — Juggler Protocol

- **Protocolo**: Juggler (protocolo customizado do Playwright)
- **Transporte**: Pipe stdio com delimitador `\0` (null byte)
- **Binário**: Firefox patcheado pelo Playwright (não é Firefox padrão!)
- **Referência TS**: `packages/playwright-core/src/server/firefox/`
- **Arquivos-chave a portar**:
  - `ffConnection.ts` → `ff_connection.dart` (6.4 KB)
  - `ffBrowser.ts` → `ff_browser.dart` (18.6 KB)
  - `ffPage.ts` → `ff_page.dart` (27.6 KB)
  - `ffNetworkManager.ts` → `ff_network_manager.dart` (11.5 KB)
  - `ffInput.ts` → `ff_input.dart` (6.5 KB)
  - `ffExecutionContext.ts` → `ff_execution_context.dart` (6.0 KB)
  - `protocol.d.ts` → Tipos Juggler (40.9 KB)

### 5.3. WebKit — WebKit Inspector Protocol

- **Protocolo**: Protocolo proprietário do WebKit Inspector
- **Transporte**: Pipe + conceito de "Page Proxy" (cada página tem conexão separada)
- **Binário**: WebKit patcheado pelo Playwright
- **Referência TS**: `packages/playwright-core/src/server/webkit/`
- **Arquivos-chave a portar**:
  - `wkConnection.ts` → `wk_connection.dart` (6.4 KB)
  - `wkBrowser.ts` → `wk_browser.dart` (16.2 KB)
  - `wkPage.ts` → `wk_page.dart` (62.1 KB — segundo maior)
  - `wkInput.ts` → `wk_input.dart` (6.3 KB)
  - `wkExecutionContext.ts` → `wk_execution_context.dart` (5.9 KB)
  - `wkInterceptableRequest.ts` → `wk_interceptable_request.dart` (8.1 KB)
  - `wkProvisionalPage.ts` → `wk_provisional_page.dart` (5.0 KB)
  - `wkWorkers.ts` → `wk_workers.dart` (4.4 KB)
  - `protocol.d.ts` → Tipos Inspector (312.2 KB)

---

## 6. Sistema de Download de Binários

### 6.1. CDN do Playwright

Os binários são hospedados no CDN da Microsoft. O Playwright Dart irá baixá-los diretamente:

**CDN Mirrors** (em ordem de prioridade):
1. `https://cdn.playwright.dev/dbazure/download/playwright`
2. `https://playwright.download.prss.microsoft.com/dbazure/download/playwright`
3. `https://cdn.playwright.dev`

### 6.2. Padrões de URL por Navegador

| Navegador | Padrão de URL |
|---|---|
| **Chromium** | `builds/cft/{browserVersion}/{platform}/chrome-{platform}.zip` |
| **Chromium HS** | `builds/cft/{browserVersion}/{platform}/chrome-headless-shell-{platform}.zip` |
| **Firefox** | `builds/firefox/{revision}/firefox-{os}.zip` |
| **WebKit** | `builds/webkit/{revision}/webkit-{os}.zip` |
| **FFmpeg** | `builds/ffmpeg/{revision}/ffmpeg-{os}.zip` |

### 6.3. Diretório de Cache

| SO | Caminho padrão |
|---|---|
| Windows | `%USERPROFILE%\AppData\Local\ms-playwright` |
| macOS | `~/Library/Caches/ms-playwright` |
| Linux | `~/.cache/ms-playwright` |

**Variáveis de ambiente suportadas**:
- `PLAYWRIGHT_BROWSERS_PATH` — Caminho personalizado para cache
- `PLAYWRIGHT_DOWNLOAD_HOST` — Mirror alternativo
- `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD` — Pular download

### 6.4. browsers.json (Versões atuais)

```json
{
  "browsers": [
    { "name": "chromium", "revision": "1234", "browserVersion": "151.0.7922.34" },
    { "name": "chromium-headless-shell", "revision": "1234", "browserVersion": "151.0.7922.34" },
    { "name": "firefox", "revision": "1535", "browserVersion": "152.0.4" },
    { "name": "webkit", "revision": "2333", "browserVersion": "26.5" },
    { "name": "ffmpeg", "revision": "1011" }
  ]
}
```

### 6.5. Executáveis por Plataforma

| Navegador | Windows | macOS | Linux |
|---|---|---|---|
| Chromium | `chrome-win64/chrome.exe` | `chrome-mac-arm64/...Google Chrome for Testing` | `chrome-linux64/chrome` |
| Firefox | `firefox/firefox.exe` | `firefox/Nightly.app/.../firefox` | `firefox/firefox` |
| WebKit | `Playwright.exe` | `pw_run.sh` | `pw_run.sh` |

---

## 7. Roadmap de Versões

### v0.1.0 — Fundação + Chromium Básico
- Infraestrutura de protocolo e transporte
- Connection, ChannelOwner, EventEmitter
- Registry + download de binários
- Chromium: launch, newContext, newPage
- Page: goto, content, title, close
- Frame: básico
- Locator: básico (click, fill, textContent)
- Screenshot (page e element)
- Console events
- Network: request/response básico
- CLI: `dart run playwright install chromium`

### v0.2.0 — Chromium Completo
- Downloads e uploads
- Dialogs (alert, confirm, prompt)
- Interceptação de rede (Route)
- Cookies e storage state
- File chooser
- Keyboard e Mouse completos
- Evaluate e evaluateHandle
- waitForSelector, waitForNavigation
- Input: type, press, click, dblclick
- Seletores avançados (CSS, text, XPath, role)

### v0.3.0 — Tracing, Vídeo e Emulação
- Tracing: start, stop, zip
- Video recording
- Emulação: viewport, userAgent, geolocation, permissions
- PDF generation
- HAR recording/playback
- Accessibility snapshot
- Clock manipulation

### v0.4.0 — Firefox
- Juggler protocol implementation
- ffBrowser, ffPage, ffConnection
- ffNetworkManager, ffInput, ffExecutionContext
- Todos os testes adaptados para Firefox

### v0.5.0 — WebKit
- WebKit Inspector protocol implementation
- wkBrowser, wkPage, wkConnection
- PageProxy e provisional pages
- Workers
- Todos os testes adaptados para WebKit

### v0.6.0 — MCP Server
- playwright_mcp package
- Tools: navigate, click, fill, screenshot, snapshot, evaluate
- Integração com Codex/Claude/AI agents

### v1.0.0 — Release Estável
- Paridade de API com Playwright oficial
- Documentação completa
- Testes de conformidade
- Publicação no pub.dev
- CI/CD para todos os navegadores × plataformas

---

## 8. Dependências Dart

### 8.1. playwright_protocol
```yaml
dependencies:
  yaml: ^3.0.0          # Parse dos .yml de protocolo
  json_annotation: ^4.0.0
  
dev_dependencies:
  build_runner: ^2.0.0
  json_serializable: ^6.0.0
```

### 8.2. playwright_core
```yaml
dependencies:
  playwright_protocol:
    path: ../playwright_protocol
  web_socket_channel: ^2.0.0  # WebSocket transport
  archive: ^3.0.0              # Descompactar browsers
  http: ^1.0.0                 # Download de browsers
  path: ^1.8.0                 # Manipulação de caminhos
  crypto: ^3.0.0               # SHA1 para verificação
  logging: ^1.0.0              # Logger estruturado
  collection: ^1.18.0          # Estruturas de dados
  async: ^2.11.0               # Utilitários async
```

### 8.3. playwright
```yaml
dependencies:
  playwright_core:
    path: ../playwright_core
  args: ^2.0.0                 # CLI argument parsing
  
dev_dependencies:
  test: ^1.0.0
  mockito: ^5.0.0
```

### 8.4. playwright_mcp
```yaml
dependencies:
  playwright:
    path: ../playwright
  shelf: ^1.0.0                # HTTP server
  json_rpc_2: ^3.0.0           # JSON-RPC
```

---

## 9. Estimativa de Esforço

### 9.1. Métricas do Código-Fonte Original

| Componente | Arquivos | Tamanho Total |
|---|---|---|
| client/ (API pública) | 52 | ~450 KB |
| server/ (implementação) | 53 + 11 dirs | ~850 KB |
| server/chromium/ | 17 | ~250 KB |
| server/firefox/ | 8 | ~125 KB |
| server/webkit/ | 12 | ~440 KB |
| server/dispatchers/ | 25 | ~150 KB |
| server/registry/ | 6 | ~140 KB |
| protocol/ | 5 | ~120 KB |
| protocol/spec/ (YML) | 19 | ~90 KB |
| **Total** | **~200** | **~2.6 MB** |

### 9.2. Estimativa de Esforço por Marco

| Marco | Arquivos Dart | Complexidade | Tempo Estimado |
|---|---|---|---|
| v0.1.0 (Fundação + Chromium básico) | ~60 | Alta | 8-12 semanas |
| v0.2.0 (Chromium completo) | ~30 | Média | 4-6 semanas |
| v0.3.0 (Tracing/Vídeo/Emulação) | ~20 | Média | 3-4 semanas |
| v0.4.0 (Firefox) | ~15 | Alta | 4-6 semanas |
| v0.5.0 (WebKit) | ~15 | Alta | 4-6 semanas |
| v0.6.0 (MCP) | ~10 | Média | 2-3 semanas |
| v1.0.0 (Release) | ~20 | Média | 4-6 semanas |

---

## 10. Documentos Detalhados

Este plano é complementado por documentos técnicos detalhados:

| Documento | Conteúdo |
|---|---|
| [01_PROTOCOLO.md](./01_PROTOCOLO.md) | Detalhamento do protocolo RPC e geração de código |
| [02_TRANSPORTE.md](./02_TRANSPORTE.md) | Camada de transporte (Pipe, WebSocket, stdio) |
| [03_CHROMIUM.md](./03_CHROMIUM.md) | Port detalhado do motor Chromium (CDP) |
| [04_FIREFOX.md](./04_FIREFOX.md) | Port detalhado do motor Firefox (Juggler) |
| [05_WEBKIT.md](./05_WEBKIT.md) | Port detalhado do motor WebKit (Inspector) |
| [06_REGISTRY.md](./06_REGISTRY.md) | Download e gerenciamento de binários |
| [07_API_PUBLICA.md](./07_API_PUBLICA.md) | API pública do pacote playwright |
| [08_MAPEAMENTO_ARQUIVOS.md](./08_MAPEAMENTO_ARQUIVOS.md) | Mapeamento arquivo-a-arquivo TS→Dart |
| [09_MCP.md](./09_MCP.md) | Servidor MCP para AI agents |
| [10_TESTES.md](./10_TESTES.md) | Estratégia de testes |

# Relatório de gaps para paridade com o Playwright original

Data da análise: 2026-07-19

Referências locais usadas:

- `referencias/playwright-typescript` - Playwright upstream TypeScript, versão `1.62.0-next`.
- `referencias/playwright-dotnet` - binding .NET, usado como referência auxiliar de API fortemente tipada.
- `packages/playwright`, `packages/playwright_core`, `packages/playwright_protocol` e `packages/playwright_mcp` - port Dart atual.

## Resumo executivo

O port atual já tem uma fundação rara e valiosa: ele não é apenas um wrapper sobre o driver Node. Ele implementa em Dart o registry de browsers, launch, transporte e adaptadores de protocolo para Chromium, Firefox e WebKit. Isso é a maior vantagem arquitetural do projeto.

O que ainda falta para ficar tão completo quanto o Playwright original é principalmente superfície de API, modelo de eventos, opções completas de contexto/page/locator, artefatos de teste e ferramentas de ecossistema.

Em termos práticos:

| Área | Status atual |
| --- | --- |
| Launch Chromium/Firefox/WebKit | Parcialmente implementado e testado |
| Navegação, evaluate, screenshot, locator básico | Implementado |
| Keyboard real, cookies, `storageState`, dialogs, route básico | Implementado |
| API pública completa de `Page`, `Locator`, `Frame`, `BrowserContext` | Ainda muito incompleta |
| Eventos Playwright completos | Quase todos ausentes na API pública |
| Downloads, videos, tracing, HAR, WebSocket, workers | Ausentes ou não expostos |
| APIRequest/APIResponse | Ausente na API pública |
| Test runner `@playwright/test`, expect, reporters | Ausente; exige implementação Dart própria |
| Codegen, UI mode, trace viewer, inspector, VS Code extension | Ausentes; ferramentas grandes e separadas |
| Android/Electron/WebView | Ausentes |

## Base comparativa de API

Os arquivos `docs/src/api/class-*.md` do upstream indicam uma superfície muito maior que a disponível hoje no pacote Dart.

| Classe upstream | Métodos documentados no upstream | Situação no port Dart |
| --- | ---: | --- |
| `Page` | 124 | Cerca de 20 métodos públicos principais |
| `Locator` | 70 | 17 métodos públicos |
| `Frame` | 61 | 7 métodos públicos |
| `BrowserContext` | 39 | 6 métodos públicos |
| `ElementHandle` | 37 | 4 métodos públicos |
| `Browser` | 13 | 3 métodos públicos |
| `BrowserType` | 7 | `name` e `launch` |
| `Route` | 6 | `continue_`, `fulfill`, `abort` |
| `Request` | 22 | Interface mínima |
| `Response` | 21 | Interface mínima |
| `JSHandle` | 7 | `evaluate`, `getProperties`, `dispose` |
| `Keyboard` | 5 | Implementado no core, exposto via `Page.keyboard` |
| `Mouse` | 6 | Ausente |
| `Touchscreen` | 1 | Ausente |
| `Tracing` | 8 | Ausente |
| `APIRequestContext` | 11 | Ausente |
| `Download` | 9 | Ausente |
| `WebSocket` | 7 + eventos | Ausente |
| `Worker` | 7 + eventos | Ausente |
| `Clock` | 7 | Ausente |
| `Coverage` | 4 | Ausente |
| `FrameLocator` | 13 | Ausente |
| Assertions | dezenas de métodos | Ausentes |

Esses números não significam que todos os métodos devem ser copiados imediatamente. Eles mostram onde está a diferença real entre um núcleo nativo funcional e uma API compatível com Playwright completo.

## O que já está bem encaminhado

### Fundação nativa

O port atual já possui:

- Workspace Dart com pacotes separados para API pública, core, protocolo e MCP.
- Registry de browsers em Dart.
- Instalação de Chromium, Firefox e WebKit via `dart run playwright install`.
- Transporte por pipe/WebSocket.
- Transporte fd3/fd4 cross-platform, incluindo Windows via named pipes e POSIX via FIFO.
- Implementações separadas para Chromium/CDP, Firefox/Juggler e WebKit.
- CI multi-OS em Ubuntu, Windows e macOS.

### Automação essencial

Já existe suporte para:

- `Playwright.create()`.
- `chromium.launch`, `firefox.launch`, `webkit.launch`.
- `browser.newContext()`, `browser.close()`, `browser.version()`.
- `context.newPage()`, cookies, `clearCookies()`, `storageState()`, `close()`.
- `page.goto`, `title`, `content`, `url`, `evaluate`, `evaluateHandle`, `screenshot`.
- `page.click`, `fill`, `press`, `type`, `waitForSelector`, `waitForLoadState`, `waitForNavigation`.
- `page.route` com `Route.continue_`, `fulfill` e `abort`.
- `Locator` básico para interação e inspeção.
- Dialogs com `accept` e `dismiss`.
- Keyboard real no core.
- Teste de paridade E2E nos três motores.

## Gaps prioritários

### P0 - Necessário para paridade estrutural

1. Criar um modelo de protocolo gerado ou fortemente tipado

O upstream gera canais e tipos a partir de definições de protocolo. O port atual usa bastante `Map<String, dynamic>` e métodos manuais por engine. Para crescer sem ficar frágil, falta uma etapa equivalente a:

- importar/normalizar definições de protocolo do upstream;
- gerar tipos Dart;
- gerar envelopes de mensagens;
- gerar stubs de canais quando fizer sentido;
- validar diferenças de protocolo por revisão.

2. Desacoplar `JSHandle` e `ElementHandle` de Chromium

Hoje `packages/playwright/lib/src/js_handle.dart` e `packages/playwright/lib/src/element_handle.dart` dependem de `CrJSHandle` e `CrElementHandle`. Para paridade multi-engine real, esses wrappers precisam depender de interfaces core neutras, por exemplo `CoreJSHandle` e `CoreElementHandle`, implementadas por Chromium, Firefox e WebKit.

3. Implementar eventos de primeira classe

O Playwright original é fortemente orientado a eventos. Faltam streams/listeners públicos para:

- `Page`: `close`, `console`, `crash`, `dialog`, `download`, `fileChooser`, `frameAttached`, `frameDetached`, `frameNavigated`, `load`, `DOMContentLoaded`, `pageError`, `popup`, `request`, `requestFailed`, `requestFinished`, `response`, `webSocket`, `worker`.
- `BrowserContext`: `page`, `close`, `console`, `dialog`, `download`, `request`, `response`, `serviceWorker`, `webError` e demais eventos.
- `Browser`: `disconnected`, `context`.
- `WebSocket` e `Worker`: eventos próprios.

4. Implementar `waitForEvent` e esperas especializadas

Faltam APIs fundamentais para sincronização:

- `page.waitForRequest`
- `page.waitForResponse`
- `page.waitForDownload`
- `page.waitForFileChooser`
- `page.waitForPopup`
- `page.waitForWebSocket`
- `page.waitForWorker`
- `page.waitForURL`
- `page.waitForFunction`
- `context.waitForPage`
- `context.waitForConsoleMessage`
- `worker.waitForEvent`
- suporte a cancelamento/timeout consistente

### P1 - API pública principal

1. Completar `BrowserType`

Faltam:

- `executablePath`
- `connect`
- `connectOverCDP`
- `launchPersistentContext`
- `launchServer`
- opções completas de `launch`, como `channel`, `executablePath`, `downloadsPath`, `env`, `proxy`, `slowMo`, `timeout`, `tracesDir`, `chromiumSandbox`, `firefoxUserPrefs`, `ignoreDefaultArgs`, `handleSIGINT`, `handleSIGTERM`, `handleSIGHUP`.

2. Completar `Browser`

Faltam:

- `browserType`
- `contexts`
- `isConnected`
- `newPage`
- `newBrowserCDPSession`
- `startTracing` e `stopTracing` legados
- `removeAllListeners`
- opções de `close(reason)`

3. Completar `BrowserContext`

Faltam:

- `pages`
- `browser`
- `isClosed`
- `backgroundPages`
- `serviceWorkers`
- `request`
- `tracing`
- `clock`
- `addInitScript`
- `exposeBinding`
- `exposeFunction`
- `grantPermissions`
- `clearPermissions`
- `setDefaultTimeout`
- `setDefaultNavigationTimeout`
- `setExtraHTTPHeaders`
- `setGeolocation`
- `setHTTPCredentials`
- `setOffline`
- `route`, `unroute`, `unrouteAll`
- `routeFromHAR`
- `routeWebSocket`
- `newCDPSession`
- `setStorageState`
- opções completas de `newContext`, incluindo viewport, user agent, locale, timezone, geolocation, permissions, color scheme, reduced motion, forced colors, device scale factor, proxy, HTTP credentials, videos, downloads, service workers, storage state e client certificates.

4. Completar `Page`

Além do que já existe, faltam blocos grandes:

- Navegação: `reload`, `goBack`, `goForward`, `setContent`, `waitForURL`.
- Frames: `mainFrame`, `frames`, `frame`, `frameByUrl`, `frameLocator`, eventos de frame.
- Seletores rápidos: `getByRole`, `getByText`, `getByLabel`, `getByPlaceholder`, `getByAltText`, `getByTitle`, `getByTestId`.
- DOM antigo: `querySelector`, `querySelectorAll`, `evalOnSelector`, `evalOnSelectorAll`.
- Input: `dblclick`, `hover`, `tap`, `dragAndDrop`, `dispatchEvent`, `setInputFiles`, `selectOption`, `setChecked`, `uncheck`, `check`, `focus`.
- Estado: `isVisible`, `isHidden`, `isEnabled`, `isDisabled`, `isEditable`, `isChecked`, `inputValue`, `innerText`, `innerHTML`, `textContent`, `getAttribute`.
- Rede: eventos request/response, `requests()`, `routeFromHAR`, `routeWebSocket`, `unroute`, `unrouteAll`.
- Artefatos: `pdf`, `video`, `coverage`, `screencast`, `pageErrors`, `consoleMessages`.
- Devtools/diagnóstico: `pause`, `requestGC`, `bringToFront`, locator highlight/picker.
- Handlers: `addLocatorHandler`, `removeLocatorHandler`.
- Configuração: `setViewportSize`, `setExtraHTTPHeaders`, default timeouts.

5. Completar `Locator`

Faltam muitos métodos modernos e recomendados:

- Composição: `first`, `last`, `nth`, `and`, `or`, `filter`, `locator`, `frameLocator`, `contentFrame`, `page`.
- Getters semânticos: `getByRole`, `getByText`, `getByLabel`, `getByPlaceholder`, `getByAltText`, `getByTitle`, `getByTestId`.
- Ações: `dblclick`, `hover`, `tap`, `dragTo`, `dispatchEvent`, `setInputFiles`, `setChecked`, `clear`, `blur`, `focus`, `type`, `scrollIntoViewIfNeeded`, `selectText`.
- Avaliação: `evaluate`, `evaluateAll`, `evaluateHandle`, `elementHandle`, `elementHandles`.
- Estado: `isHidden`, `isDisabled`, `isEditable`, `boundingBox`, `screenshot`, `ariaSnapshot`, `waitForFunction`.
- Debuggability: `describe`, `description`, `toString`, `highlight`, `hideHighlight`.

6. Completar `Frame` e `FrameLocator`

`Frame` hoje é mínimo. Faltam praticamente os mesmos métodos de interação de `Page`, além de:

- `goto`
- `content`
- `setContent`
- `title`
- `frameElement`
- `waitForFunction`
- `waitForURL`
- `isDetached`
- `FrameLocator` completo

7. Completar `ElementHandle`

Faltam:

- `boundingBox`
- `contentFrame`
- `ownerFrame`
- `querySelector`
- `querySelectorAll`
- `evalOnSelector`
- `evalOnSelectorAll`
- `screenshot`
- `scrollIntoViewIfNeeded`
- `waitForElementState`
- `waitForSelector`
- ações completas de input
- métodos de estado (`isVisible`, `isHidden`, etc.)

### P2 - Rede, artefatos e ferramentas de debugging

1. Completar `Request`, `Response` e `Route`

Faltam:

- `Request.allHeaders`, `headersArray`, `headerValue`, `postDataBuffer`, `postDataJSON`, `response`, `sizes`, `timing`, `failure`, `resourceType`, `redirectedFrom`, `redirectedTo`, `serviceWorker`.
- `Response.body`, `text`, `json`, `finished`, `allHeaders`, `headersArray`, `headerValue`, `headerValues`, `serverAddr`, `securityDetails`, `fromServiceWorker`.
- `Route.request`, `fallback`, `fetch`, opções completas de `continue` e `fulfill`.

2. Implementar download, upload e file chooser

Faltam classes e eventos para:

- `Download`
- `FileChooser`
- `page.waitForDownload`
- `page.waitForFileChooser`
- `page.setInputFiles`
- aceitação/controle de downloads por contexto.

3. Implementar tracing, screenshots avançados e video

Faltam:

- `Tracing.start`, `stop`, `startChunk`, `stopChunk`, `group`, `groupEnd`.
- gravação de video por contexto/página.
- classe `Video`.
- screenshot com opções completas: `fullPage`, `clip`, `mask`, `scale`, `animations`, `caret`, `style`, etc.
- `page.pdf` no Chromium.

4. Implementar WebSocket, WebSocketRoute e Worker

Faltam:

- classe `WebSocket`
- eventos de frames enviados/recebidos
- `routeWebSocket`
- classe `WebSocketRoute`
- classe `Worker` com `evaluate`, `evaluateHandle` e eventos.

5. Implementar APIRequest

O upstream possui `playwright.request` e `APIRequestContext`. Faltam:

- `APIRequest.newContext`
- `APIRequestContext.get/post/put/patch/delete/head/fetch`
- `APIResponse`
- form data multipart
- `storageState` para API request
- integração com `BrowserContext.request`.

6. Implementar `Clock`, `Coverage`, `Selectors`, `Devices`

Faltam:

- `Clock` para controle determinístico de tempo.
- `Coverage` JS/CSS.
- `Selectors.register` e `setTestIdAttribute`.
- catálogo `devices`.
- propriedades `playwright.selectors`, `playwright.devices`, `playwright.request`, `playwright.errors`.

### P3 - Playwright Test e ecossistema

Estas partes são enormes no upstream e não são apenas browser automation:

- Test runner estilo `@playwright/test`.
- `test`, fixtures, projects, retries, sharding, annotations, attachments.
- `expect` e assertions: `LocatorAssertions`, `PageAssertions`, `APIResponseAssertions`, snapshots e screenshot assertions.
- Reporters: list, line, dot, json, junit, html.
- Trace viewer.
- UI mode.
- Codegen.
- Inspector.
- VS Code extension.
- Component testing React/Vue/Svelte.
- Web server management no config.
- `playwright.config` equivalente para Dart.

Para o port Dart, isso deve virar um pacote separado ou uma camada sobre `package:test`, não uma cópia direta do código Node.

### P4 - Plataformas especiais

Faltam áreas grandes do upstream:

- Android.
- Electron.
- WebView.
- BrowserServer remoto.
- Reuso de browser/server (`run-server`, websocket server).
- BiDi experimental.
- Browser patches e tooling de roll de browsers.

Esses itens devem ficar depois da API de browser desktop estar madura.

## Lacunas de opções

Mesmo quando um método existe no port Dart, normalmente ele aceita poucas opções. Exemplos importantes:

- `page.goto` tem `waitUntil`, mas faltam `timeout`, `referer` e cancelamento.
- `page.click` e `locator.click` não expõem `button`, `clickCount`, `delay`, `force`, `modifiers`, `position`, `trial`, `timeout`, `strict`.
- `page.fill` e `locator.fill` não expõem `force`, `timeout`, `strict`.
- `page.screenshot` basicamente aceita `path`; faltam as opções completas.
- `browser.newContext` não recebe o grande conjunto de opções de contexto.
- `route.fulfill` é mínimo; faltam `json`, `path`, `contentType`, `response`, status text e headers avançados.

Completar opções é menos visível que adicionar métodos, mas é essencial para compatibilidade real com exemplos do Playwright.

## Lacunas de arquitetura interna

### EventEmitter e ciclo de vida

O core atual tem `EventEmitter`, mas a API pública ainda não reflete o modelo completo de eventos e waiters do upstream. É preciso padronizar:

- inscrição e remoção de listeners;
- `once`;
- `waitForEvent`;
- comportamento de erros em listeners;
- `removeAllListeners` com opção `behavior`;
- descarte/fechamento de objetos.

### Separação client/core/engine

Há uma boa separação inicial, mas alguns wrappers públicos ainda conhecem classes de Chromium. Para crescer, a camada pública deve falar com interfaces core neutras, e cada engine deve implementar essas interfaces.

### Auto-waiting e actionability

O Playwright original tem regras sofisticadas antes de clicar, preencher, arrastar e interagir:

- visibilidade;
- estabilidade;
- recebimento de eventos;
- enabled/editable;
- scroll;
- retry até timeout;
- strict mode.

O port atual já dispara input real, mas ainda precisa reproduzir o modelo completo de actionability para ser tão confiável quanto o original.

### Serialização JS

Faltam recursos completos de serialização entre Dart e runtime da página:

- argumentos estruturados em `evaluate`;
- retorno de handles;
- `jsonValue`;
- `getProperty`;
- `evaluateHandle`;
- tratamento completo de promises, exceptions e previews.

## Plano recomendado

### Milestone 1 - API pública consistente e multi-engine

- Criar interfaces core neutras para `JSHandle`, `ElementHandle`, `Request`, `Response`, `Route`.
- Remover dependência direta de Chromium dos wrappers públicos.
- Expor streams/eventos básicos de `Page`, `BrowserContext` e `Browser`.
- Adicionar `waitForEvent` e waiters especializados mais usados.
- Ampliar testes de paridade para eventos e rede.

### Milestone 2 - Locator/Page compatíveis com uso real

- Implementar getBy* em `Page`, `Frame`, `Locator` e `FrameLocator`.
- Completar ações de `Locator`.
- Completar métodos de estado e inspeção.
- Adicionar opções essenciais de actionability (`timeout`, `strict`, `force`, `position`).
- Implementar auto-waiting mais próximo do upstream.

### Milestone 3 - Rede e artefatos

- Completar `Request`, `Response`, `Route`.
- Implementar downloads e file chooser.
- Implementar upload.
- Implementar `APIRequestContext`.
- Implementar tracing e video.
- Implementar `page.pdf` para Chromium.

### Milestone 4 - Paridade de contexto e configuração

- Completar opções de `Browser.newContext`.
- Implementar permissions, geolocation, offline, headers, credentials, proxy e emulação.
- Implementar `devices`.
- Implementar `Selectors`.
- Implementar `Clock` e `Coverage`.

### Milestone 5 - Test runner Dart

- Criar pacote separado, por exemplo `playwright_test`.
- Integrar com `package:test`.
- Implementar fixtures de browser/context/page.
- Implementar assertions.
- Implementar reporters.
- Adicionar trace/screenshot/video on failure.

## Critério de "pronto"

Para considerar o port tão completo quanto o Playwright original na camada de biblioteca, recomendo estes critérios:

1. Todos os exemplos básicos da documentação oficial conseguem ser traduzidos para Dart sem workaround.
2. `Page`, `Locator`, `Frame`, `BrowserContext`, `Request`, `Response` e `Route` têm pelo menos 80% da superfície pública.
3. Os eventos principais funcionam nos três motores.
4. Os testes de paridade cobrem Chromium, Firefox e WebKit em Linux, Windows e macOS.
5. A API pública não depende de classes específicas de Chromium.
6. As opções principais de actionability e timeout estão disponíveis.
7. Downloads, uploads, network interception, tracing e API request funcionam.

## Conclusão

O port atual tem uma vantagem forte sobre wrappers baseados em Node: ele controla o caminho nativo em Dart. Para alcançar o Playwright original, o trabalho principal agora é transformar essa base em uma API ampla e estável.

A ordem mais eficiente é: primeiro corrigir as abstrações multi-engine e eventos; depois expandir `Page`/`Locator`/`Frame`; depois completar rede, artefatos e contexto; por último, construir o ecossistema de testes e ferramentas.

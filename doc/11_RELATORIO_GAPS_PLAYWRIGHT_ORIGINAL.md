# Relatório de gaps para paridade com o Playwright original

Data da análise: 2026-07-19
Última atualização: 2026-07-19 (fim do dia) — ver "Progresso da rodada de 2026-07-19".

Referências locais usadas:

- `referencias/playwright-typescript` - Playwright upstream TypeScript, versão `1.62.0-next`.
- `referencias/playwright-dotnet` - binding .NET, usado como referência auxiliar de API fortemente tipada.
- `packages/playwright`, `packages/playwright_core`, `packages/playwright_protocol` e `packages/playwright_mcp` - port Dart atual.

## Progresso da rodada de 2026-07-19

Onze commits (`146c69a`..`11d0c7a`) levaram a suíte de paridade de "toda em timeout" para 90 testes verdes nos três engines (Chromium, Firefox, WebKit) cobrindo navegação completa com timeout, input com opções (botão/posição/delay), teclado com comandos macOS, rede de ponta a ponta (eventos, waiters, corpo, interceptação rica, unroute) e agora emulação básica de contexto (viewport/userAgent). Os CIs dos últimos commits rodam nos três SOs.

### Correções estruturais

- **Árvore de frames semeada na inicialização** (`146c69a`): Chromium (`Page.getFrameTree`) e WebKit (`Page.getResourceTree`) só reportam frames criados depois do `Page.enable`; sem o seed, `waitForMainFrame()` nunca completava e todo `goto` estourava timeout — causa raiz da quebra dos CIs #10–#13.
- **Dialogs WebKit**: o evento é `Dialog.javascriptDialogOpening` no pageProxy, não `Page.javascriptDialogOpening`.
- **`macEditingCommands` portado** (`51deb64`, `63f777f`): no macOS o WebKit aplica teclas de edição via seletores NSResponder; sem `macCommands` no `Input.dispatchKeyEvent`, Backspace/Delete não editavam e caíam em atalhos do app (voltar histórico) — era o flake do CI macOS. `fill('')` passou a usar `keyboard.press('Delete')`.
- **Robustez de shutdown** (`63f777f`, `8b284a1`): continues de interceptação fire-and-forget com `catchError` tipado (sessão pode morrer durante o close); waiter de navegação com erro pré-tratado para `goto(timeout:)` não gerar unhandled async error.

### API portada nesta rodada

- **Navegação**: `reload`, `goBack`, `goForward` (histórico via `getNavigationHistory`/`navigateToHistoryEntry` no Chromium, `Page.goBack {frameId}` no Juggler, detecção de "Failed to go" no WebKit), `setContent`, `waitForFunction`, `waitForURL` (glob/regex/same-document), `goto(timeout:)`.
- **Input**: `dblclick`, `hover`; opções de click `button`/`clickCount`/`delay`/`position` em `Page` e `Locator`, com mapeamento por protocolo.
- **Locator**: `isHidden`, `isDisabled`, `isEditable`, `clear`, `focus`, `blur`; `focus` do core com verificação de `activeElement` e retry.
- **Rede**: eventos de primeira classe (`onRequest`/`onResponse`/`onRequestFinished`/`onRequestFailed`) nos três engines via network managers novos para Firefox e WebKit; `waitForRequest`/`waitForResponse`; `Response.body/text/json` via `Network.getResponseBody` (Firefox devolve `base64body`; Chromium/WebKit `{body, base64Encoded}`); `Route.fulfill(json:, contentType:)`; `Request.postData` (base64-decodificado no Firefox/WebKit); `Page.unroute`/`unrouteAll` com desligamento da interceptação por engine.
- **Contexto**: `newContext(viewport:, userAgent:)` (início do Milestone 4). A aplicação correta é feita por engine:
  - **Chromium**: por página, `Emulation.setDeviceMetricsOverride` + `Emulation.setUserAgentOverride` logo após criar o target.
  - **Firefox**: em nível de contexto no Juggler (`Browser.setDefaultViewport` com o shape `{viewport: {viewportSize: {...}}}` e `Browser.setUserAgentOverride`), aplicados antes de existir qualquer página — idêntico ao upstream (`ffBrowser.ts:191`).
  - **WebKit**: `Emulation.setDeviceMetricsOverride` no pageProxy + `Page.overrideUserAgent` no target (`wkPage.ts:713`).
  - *Teste de paridade*: cria um contexto 640×480 com UA customizado e verifica `window.innerWidth`/`innerHeight` e `navigator.userAgent` nos três engines — passou de primeira em todos.

## Resumo executivo

O port atual já tem uma fundação rara e valiosa: ele não é apenas um wrapper sobre o driver Node. Ele implementa em Dart o registry de browsers, launch, transporte e adaptadores de protocolo para Chromium, Firefox e WebKit. Isso é a maior vantagem arquitetural do projeto.

O que ainda falta para ficar tão completo quanto o Playwright original é principalmente superfície de API, modelo de eventos, opções completas de contexto/page/locator, artefatos de teste e ferramentas de ecossistema.

Em termos práticos:

| Área | Status atual |
| --- | --- |
| Launch Chromium/Firefox/WebKit | Implementado e testado (CI 3 SOs) |
| Navegação (goto/reload/histórico/setContent, timeout), evaluate, screenshot, locator | Implementado |
| Keyboard real (com macCommands), mouse com opções, cookies, `storageState`, dialogs | Implementado |
| Rede: eventos, waiters, corpo de resposta, interceptação com fulfill/unroute/postData | Implementado nos 3 engines |
| Emulação de contexto: viewport, userAgent | Implementado; faltam locale, timezone, colorScheme etc. |
| API pública completa de `Page`, `Locator`, `Frame`, `BrowserContext` | Parcial; `Frame` ainda mínimo |
| Eventos Playwright completos | Rede e lifecycle expostos; faltam popup, download, console, worker |
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
- `browser.newContext(viewport:, userAgent:)`, `browser.close()`, `browser.version()`.
- `context.newPage()`, cookies, `clearCookies()`, `storageState()`, `close()`.
- `page.goto` (com `waitUntil` e `timeout`), `reload`, `goBack`, `goForward`, `setContent`, `title`, `content`, `url`, `evaluate`, `evaluateHandle`, `screenshot`.
- `page.click`/`dblclick`/`hover` com `button`, `clickCount`, `delay`, `position`; `fill`, `press`, `type`.
- Waiters: `waitForSelector`, `waitForLoadState`, `waitForNavigation`, `waitForURL`, `waitForFunction`, `waitForRequest`, `waitForResponse`, `waitForEvent`.
- Eventos de página: close, load, domcontentloaded, frames, request/response/requestFinished/requestFailed.
- `page.route`/`unroute`/`unrouteAll` com `Route.continue_`, `fulfill` (status, headers, body, `json`, `contentType`) e `abort`; `Request.postData`; `Response.body/text/json`.
- `Locator` com ações, estados (`isVisible/isHidden/isEnabled/isDisabled/isChecked/isEditable`), `clear`, `focus`, `blur`, `count`, `getAttribute`, `inputValue`, `innerText`, `innerHTML`, `textContent`, `check`/`uncheck`, `selectOption`, `waitFor`.
- Dialogs com `accept` e `dismiss` (evento correto por engine).
- Keyboard real no core, incluindo `macEditingCommands` no WebKit macOS.
- 90 testes de paridade E2E nos três motores, CI em Ubuntu, Windows e macOS.

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

FEITO (2026-07-19): `Page.onClose/onLoad/onDomContentLoaded/onFrame*/onRequest/onResponse/onRequestFinished/onRequestFailed` funcionam nos três engines (network managers próprios para Firefox e WebKit).

Ainda faltam streams/listeners públicos para:

- `Page`: `console`, `crash`, `dialog` (como stream), `download`, `fileChooser`, `pageError`, `popup`, `webSocket`, `worker`.
- `BrowserContext`: `page`, `close`, `console`, `dialog`, `download`, `request`, `response`, `serviceWorker`, `webError` e demais eventos.
- `Browser`: `disconnected`, `context`.
- `WebSocket` e `Worker`: eventos próprios.

4. Implementar `waitForEvent` e esperas especializadas

FEITO (2026-07-19): `page.waitForRequest`, `page.waitForResponse`, `page.waitForURL`, `page.waitForFunction`, `page.waitForEvent` com timeout.

Faltam:

- `page.waitForDownload`
- `page.waitForFileChooser`
- `page.waitForPopup`
- `page.waitForWebSocket`
- `page.waitForWorker`
- `context.waitForPage`
- `context.waitForConsoleMessage`
- `worker.waitForEvent`
- cancelamento consistente entre todas as esperas

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

FEITO (2026-07-19): navegação (`reload`, `goBack`, `goForward`, `setContent`, `waitForURL`), `dblclick`, `hover`, `unroute`/`unrouteAll`.

Além do que já existe, faltam blocos grandes:
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

FEITO (2026-07-19): `Request.postData`, `Response.body/text/json`, `Route.request`, `fulfill` com `json`/`contentType`/status/headers/body.

Faltam:

- `Request.allHeaders`, `headersArray`, `headerValue`, `postDataBuffer`, `postDataJSON`, `response`, `sizes`, `timing`, `failure`, `resourceType`, `redirectedFrom`, `redirectedTo`, `serviceWorker`.
- `Response.finished`, `allHeaders`, `headersArray`, `headerValue`, `headerValues`, `serverAddr`, `securityDetails`, `fromServiceWorker`.
- `Route.fallback`, `fetch`, opções de `continue` (headers/method/postData overrides).

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

Mesmo quando um método existe no port Dart, normalmente ele aceita poucas opções. Estado atual:

- `page.goto`: tem `waitUntil` e `timeout` (FEITO); faltam `referer` e cancelamento.
- `page.click`/`locator.click`: têm `button`, `clickCount`, `delay`, `position` (FEITO); faltam `force`, `modifiers`, `trial`, `timeout`, `strict`.
- `page.fill` e `locator.fill` não expõem `force`, `timeout`, `strict`.
- `page.screenshot` basicamente aceita `path`; faltam as opções completas.
- `browser.newContext`: tem `viewport` e `userAgent` (FEITO); faltam locale, timezone, geolocation, permissions, color scheme, device scale factor, proxy, credentials, videos, downloads, storage state etc.
- `route.fulfill`: tem `json` e `contentType` (FEITO); faltam `path`, `response`, status text customizado.

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

### Próximos passos imediatos (fila para a próxima rodada)

1. `page.waitForPopup` e `context.waitForPage` — exige rastrear novos targets/pageProxies por engine e emitir o evento `page` no contexto (P0.4 restante).
2. `Frame` público completo — exige execution context por frame em cada engine (`goto`, `content`, `title`, `evaluate` e interações por frame).
3. Mais opções de contexto: `locale`, `timezoneId`, `colorScheme`, `deviceScaleFactor`, `geolocation`, `permissions`.
4. `Route.continue_` com overrides (headers/method/postData) e `Route.fallback`.
5. Eventos `console`/`pageError` e `context.waitForConsoleMessage`.
6. `page.setViewportSize` e `page.setExtraHTTPHeaders`.

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

- Completar opções de `Browser.newContext` (iniciado: `viewport` e `userAgent` suportados).
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

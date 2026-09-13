# Relatório de gaps para paridade com o Playwright original

Data da análise: 2026-07-19
Última atualização: 2026-09-13 — ver "Progresso da rodada de 2026-09-13".

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

## Progresso da rodada de 2026-09-13 (Milestone 2)

Quatro commits fecharam o item 2 de "Próximos passos imediatos" (`Frame`
público completo) e o Milestone 2 (`getBy*`, `FrameLocator`, `Locator`
completo, opções de actionability). A suíte de paridade saiu de 91 para 202
testes verdes, todos rodados de fato em **Chromium, Firefox e WebKit** nesta
máquina (Windows).

### Fundação: contexto de execução por frame

Era o pré-requisito de tudo. Cada frame passou a ter o próprio contexto JS,
rastreado por um registry compartilhado (`server/context_registry.dart`)
alimentado pelo evento de criação de contexto de cada motor:

- **Chromium**: `Runtime.executionContextCreated` → `context.auxData.frameId`,
  mundo principal quando `auxData.isDefault != false`; `Runtime.evaluate`
  com `contextId`.
- **Firefox/Juggler**: `Runtime.executionContextCreated` →
  `auxData.frameId`; o mundo principal é o que não tem `auxData.name`;
  `Runtime.evaluate` com `executionContextId`.
- **WebKit**: `Runtime.executionContextCreated` → `context.frameId` com
  `type == 'normal'`; `Runtime.evaluate` com `contextId`.

Para o main frame, a falta do evento cai num contexto padrão sem id, que é o
que os três protocolos resolvem sozinhos — assim um motor que não reemita o
evento não derruba a página.

`CoreFrame` deixou de ser um registro passivo: ganhou `evaluate`,
`evaluateHandle`, `goto`, `title`, `content`, `setContent`,
`waitForFunction` e `isDetached`. `CorePage` ganhou `executionContextFor`,
`gotoFrame`, `contentFrame` (via `DOM.describeNode` no Chromium/WebKit e
`Page.describeNode` no Firefox) e as variantes `*Target` de input, que
recebem o frame mais uma expressão JS que resolve o elemento.

**Coordenadas entre frames**: o ponto de clique é calculado no contexto do
frame e depois somado à borda de cada `iframe` dono subindo até o topo
(`getBoundingClientRect` + `borderLeftWidth`/`paddingLeft` do owner), porque
os eventos de mouse são despachados no viewport do topo. A subida usa
`window.frameElement` e para numa fronteira cross-origin, que a página não
consegue atravessar.

### Motor de seletores injetado

Novo: `server/injected/injected_script_source.dart` (~1500 linhas de JS) e o
modelo em Dart que o alimenta (`server/selectors.dart`). É um porte à mão de
`packages/injected/src/domUtils.ts`, `selectorUtils.ts`, `roleUtils.ts`,
`roleSelectorEngine.ts` e dos motores `internal:*` de `injectedScript.ts`,
mais `normalizeWhiteSpace` de `stringUtils.ts`.

Os seletores chegam como JSON estruturado construído em Dart, não como a
sintaxe de string do Playwright, então `selectorParser.ts` e o tokenizador
CSS não foram portados; tudo o que vem *depois* do parsing é o upstream.
Diferenças deliberadas, documentadas no cabeçalho do arquivo:

- o motor `css` usa `querySelectorAll` nativo, logo não fura shadow DOM nem
  entende as extensões CSS do Playwright (`:has-text()`, `:visible`,
  seletores de layout). Os motores `text`, `label` e `role` **entram** em
  shadow roots abertas, como o upstream;
- `getCSSContent` usa um scanner pequeno em vez do tokenizador CSS: cobre
  strings entre aspas, `attr()` e a forma `/ "texto alternativo"`;
- a computação de nome acessível devolve texto puro (o upstream também
  coleciona os elementos que contribuíram, coisa que só os aria snapshots
  usam);
- estabilidade (`stable`) é amostrada entre *polls* sucessivos do laço de
  actionability em Dart, guardando o último retângulo num `WeakMap`, em vez
  de entre `requestAnimationFrame` dentro de uma chamada assíncrona — as
  chamadas injetadas são todas síncronas porque o Juggler não espera
  promises por nós.

### API pública

- **`Frame`**: de 7 para ~45 métodos. `goto`, `content`, `setContent`,
  `title`, `url`, `name`, `parentFrame`, `childFrames`, `isDetached`,
  `frameElement`, `evaluate`, `evaluateHandle`, `waitForSelector`,
  `waitForFunction`, `waitForLoadState`, `waitForNavigation`, `waitForURL`,
  as interações por frame (`click`, `dblclick`, `hover`, `fill`, `press`,
  `type`, `focus`, `check`, `uncheck`, `selectOption`), os estados
  (`isVisible`/`isHidden`/`isEnabled`/`isDisabled`/`isEditable`/`isChecked`,
  `textContent`, `innerText`, `innerHTML`, `inputValue`, `getAttribute`), o
  DOM antigo (`querySelector`, `querySelectorAll`, `evalOnSelector`,
  `evalOnSelectorAll`, `dispatchEvent`), `locator`, `frameLocator` e os
  `getBy*`.
- **`FrameLocator`**: novo, com `owner`, `first`, `last`, `nth`, `locator`,
  `frameLocator` e os sete `getBy*` — os 13 métodos do upstream. A travessia
  de fronteira é uma parte de seletor resolvida na hora da ação.
- **`getBy*`** em `Page`, `Frame`, `Locator` e `FrameLocator`, com a
  semântica do upstream: normalização de espaço em branco, `exact:` e
  substring case-insensitive por padrão; `getByRole` com `name`,
  `description`, `checked`, `pressed`, `selected`, `expanded`, `level`,
  `disabled` e `includeHidden`.
- **`Locator`**: passou a ser (frame, seletor estruturado). Ganhou
  composição (`first`, `last`, `nth`, `filter`, `and`, `or`, `visible`,
  `all`, `contentFrame`, `page`, `frame`), ações (`dragTo`, `setChecked`,
  `selectText`, `scrollIntoViewIfNeeded`, `dispatchEvent`, `clear`, `blur`),
  estado (`boundingBox`, `ariaRole`, `accessibleName`) e avaliação
  (`evaluate`, `evaluateAll`, `evaluateHandle`, `elementHandle`,
  `elementHandles`), além de `waitFor` com
  `attached`/`detached`/`visible`/`hidden`.
- **Actionability**: as ações agora esperam de verdade. Os estados do
  upstream (`visible`, `stable`, `enabled`, `editable`) são verificados em
  laço até o timeout; `force` pula as verificações; `strict` (padrão `true`
  no `Locator`, `false` nos métodos por seletor de `Page`/`Frame`) reproduz
  a violação de modo estrito.
- **`Mouse`**: saiu de "ausente". `move` (com `steps`), `down`, `up`,
  `click`, `dblclick` e `wheel`, rastreando posição e máscara de botões.
  Cada motor fornece apenas um `RawMouse`; o despacho de click/hover, antes
  repetido nos três, vive uma vez só em `CorePageInputHelpers`.
- **`ElementHandle`**: `innerText`, `innerHTML`, `inputValue`,
  `getAttribute`, `boundingBox`, `scrollIntoViewIfNeeded`, os estados e
  `contentFrame`/`ownerFrame`.
- **`evaluateHandle`** deixou de ser `UnsupportedError` em Firefox e WebKit:
  cada um ganhou execution context, `JSHandle` e `ElementHandle` próprios.

### Defeitos encontrados e corrigidos

1. **Firefox promovia iframes a main frame.** `Page.navigationCommitted` do
   Juggler não carrega `parentFrameId`, e `CoreFrameManager.frameNavigated`
   confiava no parâmetro do evento: toda navegação de iframe reescrevia
   `_mainFrameId` para o filho. Sem contexto por frame isso passava
   despercebido (todo `evaluate` ia para o contexto padrão); com ele,
   `page.evaluate` passou a rodar dentro do último iframe carregado. O pai
   agora vem do frame registrado no `frameAttached`.
2. **WebKit deixava iframes sem ciclo de vida.** `Page.loadEventFired` e
   `Page.domContentEventFired` informam qual frame disparou o evento, e o
   port atribuía os dois sempre ao main frame. Consequência:
   `frame.goto()`/`waitForLoadState()` num iframe nunca completavam.
3. **`wrapEvaluationExpression` embrulhava IIFEs.** Uma fonte que começa com
   `(() => { ... })();` casava com a heurística de "é uma função" e virava
   `((() => {...})();)()`, erro de sintaxe. O script injetado começa com um
   comentário justamente para não cair nisso.
4. **`chromium/frame_manager.dart` era código morto** que duplicava, com
   handlers concorrentes, o que `CrPage` já faz inline. Removido.

### O que ficou de fora nesta rodada, e por quê

- **`Locator.tap` e `Touchscreen`**: dependem de emulação de toque
  (`hasTouch` no contexto), que é Milestone 4. Sem ela o evento seria
  dispensado pela página.
- **`setInputFiles`**: precisa de `DOM.setFileInputFiles` e equivalentes por
  motor, mais o objeto `FileChooser`. É Milestone 3 (artefatos), junto com
  downloads.
- **`Locator.screenshot` e opções completas de screenshot**
  (`fullPage`, `clip`, `mask`, `scale`, `animations`): Milestone 3. O recorte
  por elemento exige acertar o sistema de coordenadas de cada motor
  (documento vs viewport) — é trabalho real, não uma opção a mais.
- **`ariaSnapshot` / assertions**: dependem de portar
  `injected/ariaSnapshot.ts` e o renderizador YAML, que só fazem sentido
  junto com `LocatorAssertions` (Milestone 5).
- **`highlight`/`hideHighlight`**: exigem o overlay de
  `injected/highlight.ts`, ferramenta de depuração sem valor em teste
  automatizado hoje.
- **Drag-and-drop HTML5 nativo**: `Locator.dragTo` faz um arraste real de
  ponteiro (press, moves, release), que é o que bibliotecas modernas de
  drag escutam. O DnD nativo do HTML5 exige interceptação de drag no
  protocolo (`Input.setInterceptDrags` no Chromium) e equivalentes; ficou
  para depois.
- **Extensões CSS do Playwright** (`:has-text()`, `:visible`, seletores de
  layout) e shadow-piercing no motor `css`: exigem portar
  `selectorEvaluator.ts` + `cssParser.ts` + `cssTokenizer.ts` (~1500 linhas).
  Os casos de uso mais comuns já estão cobertos por `filter(hasText:)`,
  `visible()` e pelos `getBy*`.

### Cobertura de teste desta rodada

`packages/playwright/test/integration/locator_frames_parity_test.dart`: 36
testes por motor (108 no total), somados aos 91 anteriores e a mais 3 de
`mouse.wheel` — **202 testes verdes nos três motores**. Cobrem árvore de
frames com pais e filhos, avaliação isolada por frame, clique e
preenchimento confiáveis (`event.isTrusted`) dentro de iframe e de iframe
aninhado, `Frame.goto`/`setContent` sem afetar o host, detecção de detach,
`page.frame` por nome e URL, `FrameLocator` simples/encadeado/por índice,
`getBy*` com nome acessível vindo de `<label for>`, de `<label>` envolvente
e de `aria-label`, nível de heading, `checked`, `disabled`, normalização de
espaço em branco, `exact` e regex, composição de `Locator`, violação de
`strict`, auto-waiting de elemento que aparece e só então estabiliza,
`timeout` e `force`, `boundingBox`, `ariaRole`, `accessibleName`, handles,
esperas por `hidden`/`detached`, `dragTo`, `mouse.move/down/up/wheel`,
`frameElement` e os atalhos de DOM.

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
| API pública completa de `Page`, `Locator`, `Frame`, `BrowserContext` | `Frame`, `Locator` e `FrameLocator` completos com `getBy*` e actionability; `BrowserContext` ainda mínimo |
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
| `Page` | 124 | Cerca de 35 métodos públicos principais |
| `Locator` | 70 | ~55 métodos públicos |
| `Frame` | 61 | ~45 métodos públicos |
| `BrowserContext` | 39 | 6 métodos públicos |
| `ElementHandle` | 37 | 17 métodos públicos |
| `Browser` | 13 | 3 métodos públicos |
| `BrowserType` | 7 | `name` e `launch` |
| `Route` | 6 | `continue_`, `fulfill`, `abort` |
| `Request` | 22 | Interface mínima |
| `Response` | 21 | Interface mínima |
| `JSHandle` | 7 | `evaluate`, `getProperties`, `dispose` (nos 3 motores) |
| `Keyboard` | 5 | Implementado no core, exposto via `Page.keyboard` |
| `Mouse` | 6 | `move`, `down`, `up`, `click`, `dblclick`, `wheel` |
| `Touchscreen` | 1 | Ausente |
| `Tracing` | 8 | Ausente |
| `APIRequestContext` | 11 | Ausente |
| `Download` | 9 | Ausente |
| `WebSocket` | 7 + eventos | Ausente |
| `Worker` | 7 + eventos | Ausente |
| `Clock` | 7 | Ausente |
| `Coverage` | 4 | Ausente |
| `FrameLocator` | 13 | 13 métodos (completo) |
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

FEITO em quase tudo (2026-09-13): composição, getters semânticos, avaliação,
estado e as ações, exceto os itens abaixo.

Faltam:

- `tap` (depende de `hasTouch`/`Touchscreen`, Milestone 4).
- `setInputFiles` (Milestone 3).
- `screenshot` e `ariaSnapshot` (Milestone 3 e 5).
- `highlight`/`hideHighlight` (overlay de depuração).

6. Completar `Frame` e `FrameLocator`

FEITO (2026-09-13). `Frame` tem `goto`, `content`, `setContent`, `title`,
`frameElement`, `waitForFunction`, `waitForURL`, `waitForSelector`,
`isDetached`, as interações e estados por frame, o DOM antigo (`$`/`$$`/
`$eval`/`$$eval`) e os `getBy*`; `FrameLocator` está completo (13 métodos).

Faltam de `Frame`: `addScriptTag`, `addStyleTag`, `dragAndDrop`,
`setInputFiles`, `tap` e `waitForTimeout`.

7. Completar `ElementHandle`

FEITO (2026-09-13): `boundingBox`, `contentFrame`, `ownerFrame`,
`scrollIntoViewIfNeeded`, `innerText`, `innerHTML`, `inputValue`,
`getAttribute` e os métodos de estado.

Faltam `querySelector`, `querySelectorAll`, `evalOnSelector`,
`evalOnSelectorAll`, `screenshot`, `waitForElementState`, `waitForSelector` e
as ações completas de input. O upstream desaconselha handles em favor de
`Locator`, que já cobre tudo isso — a prioridade é baixa de propósito.

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
- `locator.click`: tem `button`, `clickCount`, `delay`, `position`, `force`, `timeout`, `strict` (FEITO); faltam `modifiers` e `trial`. `page.click` continua sem auto-waiting nem essas opções: é o caminho direto por seletor no main frame, mantido como estava.
- `locator.fill` expõe `force`, `timeout` e `strict` (FEITO); `page.fill` não.
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

- visibilidade — FEITO;
- estabilidade — FEITO (amostragem entre polls, ver a rodada de 2026-09-13);
- recebimento de eventos — PARCIAL: `receivesPointerEvents` (o teste de
  `elementFromPoint`/`pointer-events`) ainda não é verificado, então um
  elemento coberto por outro é clicado assim mesmo;
- enabled/editable — FEITO;
- scroll — FEITO (`scrollIntoView` antes de calcular o ponto);
- retry até timeout — FEITO;
- strict mode — FEITO.

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
2. ~~`Frame` público completo~~ — FEITO em 2026-09-13, com contexto de execução por frame nos três motores.
3. Mais opções de contexto: `locale`, `timezoneId`, `colorScheme`, `deviceScaleFactor`, `geolocation`, `permissions`, `hasTouch` (este último destrava `tap`/`Touchscreen`).
4. `Route.continue_` com overrides (headers/method/postData) e `Route.fallback`.
5. Eventos `console`/`pageError` e `context.waitForConsoleMessage`.
6. `page.setViewportSize` e `page.setExtraHTTPHeaders`.
7. `setInputFiles` + `FileChooser`, e `Locator.screenshot` com recorte por elemento (ambos Milestone 3).
8. Portar `selectorEvaluator`/`cssParser` para destravar as extensões CSS (`:has-text()`, `:visible`, layout) e shadow-piercing no motor `css`.

### Milestone 1 - API pública consistente e multi-engine

- Criar interfaces core neutras para `JSHandle`, `ElementHandle`, `Request`, `Response`, `Route`.
- Remover dependência direta de Chromium dos wrappers públicos.
- Expor streams/eventos básicos de `Page`, `BrowserContext` e `Browser`.
- Adicionar `waitForEvent` e waiters especializados mais usados.
- Ampliar testes de paridade para eventos e rede.

### Milestone 2 - Locator/Page compatíveis com uso real — CONCLUÍDO (2026-09-13)

- ~~Implementar getBy* em `Page`, `Frame`, `Locator` e `FrameLocator`.~~ FEITO.
- ~~Completar ações de `Locator`.~~ FEITO, menos `tap` (precisa de `hasTouch`) e `setInputFiles` (Milestone 3).
- ~~Completar métodos de estado e inspeção.~~ FEITO, menos `screenshot` e `ariaSnapshot`.
- ~~Adicionar opções essenciais de actionability (`timeout`, `strict`, `force`, `position`).~~ FEITO.
- ~~Implementar auto-waiting mais próximo do upstream.~~ FEITO: estados `visible`/`stable`/`enabled`/`editable` em laço até o timeout.

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

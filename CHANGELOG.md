# Changelog

## [0.4.0] - Frames, FrameLocator, getBy* e actionability

### Added
- **Contexto de execução por frame nos três motores**: cada frame tem o próprio contexto JS, rastreado por um registry compartilhado alimentado por `Runtime.executionContextCreated` (CDP `auxData.frameId`, Juggler `auxData.frameId` do mundo sem nome, WebKit `context.frameId` do tipo `normal`). Destrava tudo o que segue.
- **`Frame` público completo**: `goto`, `content`, `setContent`, `title`, `url`, `name`, `parentFrame`, `childFrames`, `isDetached`, `frameElement`, `evaluate`, `evaluateHandle`, `waitForSelector/Function/LoadState/Navigation/URL`, as interações e estados por frame, os atalhos de DOM (`querySelector`, `querySelectorAll`, `evalOnSelector`, `evalOnSelectorAll`, `dispatchEvent`), `locator`, `frameLocator` e os `getBy*`.
- **`FrameLocator`** com os 13 métodos do upstream, encadeável através de frames aninhados.
- **`getBy*`** (`getByRole`, `getByText`, `getByLabel`, `getByPlaceholder`, `getByAltText`, `getByTitle`, `getByTestId`) em `Page`, `Frame`, `Locator` e `FrameLocator`, sobre um motor de seletores injetado portado de `domUtils.ts`, `selectorUtils.ts`, `roleUtils.ts`, `roleSelectorEngine.ts` e dos motores `internal:*` do `injectedScript.ts` — inclusive normalização de espaço em branco, `exact:` e computação de papel/nome acessível.
- **`Locator` completo**: composição (`first`, `last`, `nth`, `filter`, `and`, `or`, `visible`, `all`, `contentFrame`), ações (`dragTo`, `setChecked`, `selectText`, `scrollIntoViewIfNeeded`, `dispatchEvent`, `clear`, `blur`), estado (`boundingBox`, `ariaRole`, `accessibleName`), avaliação (`evaluate`, `evaluateAll`, `evaluateHandle`, `elementHandle`, `elementHandles`) e `waitFor` com `attached`/`detached`/`visible`/`hidden`.
- **Actionability de verdade**: as ações esperam `visible`/`stable`/`enabled`/`editable` em laço até o timeout; opções `timeout`, `strict` e `force`.
- **`Mouse`**: `move` (com `steps`), `down`, `up`, `click`, `dblclick` e `wheel`, com rastreamento de posição e máscara de botões; `Page.mouse`.
- **`evaluateHandle` em Firefox e WebKit**, com execution context, `JSHandle` e `ElementHandle` próprios.
- **`ElementHandle`**: `innerText`, `innerHTML`, `inputValue`, `getAttribute`, `boundingBox`, `scrollIntoViewIfNeeded`, estados e `contentFrame`/`ownerFrame`.
- **Suíte de paridade**: 202 testes E2E verdes em Chromium, Firefox e WebKit.

### Fixed
- **Firefox**: `Page.navigationCommitted` não traz `parentFrameId`, e o frame manager confiava no parâmetro do evento — toda navegação de iframe promovia o filho a main frame. O pai passa a vir do frame registrado no `frameAttached`.
- **WebKit**: `Page.loadEventFired`/`Page.domContentEventFired` informam o frame de origem; atribuí-los sempre ao main frame deixava iframes sem ciclo de vida e travava `frame.goto()` num iframe.
- Removido `chromium/frame_manager.dart`, código morto que duplicava com handlers concorrentes o que `CrPage` já faz.

## [0.3.0] - Teclado, cookies e dialogs

### Added
- **Teclado real**: layout US completo (`us_keyboard_layout.dart`) e classe `Keyboard` com estado de modificadores. `Page.keyboard`, `Page.press/type`, `Locator.press/pressSequentially` disparam eventos de tecla reais (CDP `Input.dispatchKeyEvent`, Juggler `Page.dispatchKeyEvent`, WebKit `Input.dispatchKeyEvent`) com `insertText` para caracteres fora do layout. Suporta chords (`Control+A`, `Shift+ArrowLeft`) e `ControlOrMeta` sensível à plataforma.
- **Cookies e storageState**: `BrowserContext.cookies/addCookies/clearCookies` e `storageState()` (cookies + localStorage por origem) nos três motores — CDP `Storage.*`, Juggler `Browser.*Cookies`, WebKit `Playwright.*Cookies`.
- **Dialogs**: `Page.onDialog` recebe alert/confirm/prompt/beforeunload com `accept([texto])`/`dismiss()`; sem handler, o diálogo é auto-descartado. Eventos por motor: CDP `Page.javascriptDialogOpening`, Juggler `Page.dialogOpened`, WebKit `Dialog.javascriptDialogOpening`.

## [0.2.0] - Paridade multi-motor e multiplataforma

### Added
- **Firefox (Juggler) e WebKit**: motores completos com launch, navegação, evaluate, screenshot e interceptação de rede (`FfRoute`, `WkRoute`). WebKit com roteamento de duas camadas (pageProxy + `Target.sendMessageToTarget`), `Playwright.navigate` e `Target.resume`.
- **Transporte fd3/fd4 unificado nos 3 SOs**: no Windows via Named Pipes injetadas por `lpReserved2` (emulação do libuv, sem `FILE_FLAG_OVERLAPPED` na ponta do filho); no Linux/macOS via FIFOs (`mkfifo` por `stdlibc`) + `sh -c 'exec … 3<fifo 4>fifo'`. Moldura `\0` compartilhada (`NullDelimitedFramer`).
- **Chromium sobre `--remote-debugging-pipe`**: CDP agora usa o mesmo transporte fd3/fd4 em todas as plataformas — a limitação anterior de `--remote-debugging-port=0` no Windows foi removida.
- **Input confiável por protocolo**: `click`/`fill`/`check` disparam eventos reais (CDP `Input.*`, Juggler `Page.dispatch*`, WebKit `Input.*`); testes validam `event.isTrusted` nos três motores.
- **Contextos reais**: `BrowserContext` cria/descarta contextos isolados por protocolo (`Target.createBrowserContext`/`disposeBrowserContext`, `Browser.createBrowserContext`/`removeBrowserContext`, `Playwright.createContext`/`deleteContext`), com teste de isolamento de `localStorage`.
- **API pública ampliada**: `Page.content/url/waitForSelector/click/fill`; `Locator` com `innerText`, `innerHTML`, `inputValue`, `getAttribute`, `count`, `isVisible`, `isEnabled`, `isChecked`, `check/uncheck`, `selectOption`, `waitFor` — seletores com escape seguro via `jsonEncode`.
- **CI multi-OS**: GitHub Actions (ubuntu-22.04, windows-latest, macos-15) com analyze + suíte de paridade E2E (33 testes × 3 SOs), cache de browsers e cancelamento por concorrência.

### Changed
- `goto` do Chromium aguarda `Page.loadEventFired` real (removido atraso fixo de 1500 ms).
- Fechamento gracioso dos browsers via protocolo (`Browser.close`/`Playwright.close`) antes do kill.
- WebKit lançado com `--no-startup-window` (evita abort em Linux sem display); `-foreground` do Firefox restrito ao macOS.
- Extração de browsers no POSIX usa `unzip` do sistema (preserva bits de execução); progresso de instalação limitado a variações de 1%/10% (logs de CI enxutos).

### Fixed
- CLI `playwright install` não encerrava após o download (`HttpClient` keep-alive + falta de `exit()` explícito).
- Erros assíncronos "User initiated close" após teardown (futures abandonados agora usam `ignore()`).
- Diversos literais `\$` em strings que deveriam interpolar valores.

## [0.1.0] - Fundação e Suporte Inicial ao Chromium

### Added
- **Monorepo (Workspace)**: Estrutura inicial do projeto dividida em três pacotes (`playwright_protocol`, `playwright_core` e `playwright`).
- **Registry**: Sistema de download e extração de binários oficiais do Playwright (Chromium) nativo em Dart sem dependência de Node.js, com suporte nativo multiplataforma (Windows/Linux/macOS).
- **Transporte**: `PipeTransport` e `WebSocketTransport` criados para lidar com a comunicação do Chrome DevTools Protocol (CDP).
- **Chromium Motor**: Inicialização de instâncias locais do Chromium via `Process.start` e detecção de WS/Pipes.
- **Domínios CDP**: Implementação das conexões `CrConnection`, sessões `CDPSession`, manipulação de contextos, páginas, frames e gerência de rede (`CrNetworkManager`), execução remota (`CrExecutionContext`, `CrJSHandle`, `CrElementHandle`).
- **API Pública**: Primeira versão orientada a objetos exposta para os usuários (`Playwright`, `BrowserType`, `Browser`, `BrowserContext`, `Page`, `Locator`, `Frame`, `Request`, `Response`, `JSHandle`, `ElementHandle`, `ConsoleMessage`, `Dialog`).
- **Exemplo E2E**: Script `example.dart` capaz de iniciar o navegador, acessar um site e extrair informações remotas (`h1` e `title`).

### Changed
- Configuração do SDK para `^3.6.2` para permitir suporte a _Dart Workspaces_.
- Injeção de pipes do CDP no Windows usou `--remote-debugging-port=0` temporariamente (limitação removida na 0.2.0 com o transporte fd3/fd4 via `lpReserved2`).

### Fixed
- Avisos de linter e _unused imports_ através do projeto base.

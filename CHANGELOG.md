# Changelog

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

# Changelog

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
- Modificação na injeção de pipes de comunicação do CDP no Windows (`--remote-debugging-port=0` temporariamente) para evitar limitações nativas com _File Descriptors_.

### Fixed
- Avisos de linter e _unused imports_ através do projeto base.

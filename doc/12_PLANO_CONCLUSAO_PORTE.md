# 12 — Plano de conclusao do porte

Data: 2026-09-19.

Este documento existe porque a tarefa passou a ser "terminar de portar o que
falta de `referencias/playwright-typescript`", e o que falta nao cabe numa
rodada. Ele diz o que sobrou, em que ordem atacar e por que essa ordem.

O estado de partida esta no `11_RELATORIO_GAPS_PLAYWRIGHT_ORIGINAL.md`: cinco
pacotes publicaveis, os tres motores, a API de browser praticamente completa,
tracing gravando o formato v9 do upstream e video com screencast.

## A decisao que organiza o resto

O visualizador de trace sera **portado de verdade**, como aplicacao web em
Dart compilada por dart2js. Nao sera embutido o bundle compilado do
visualizador oficial.

O custo e alto e vale a pena dizer qual e: no upstream sao cerca de 7.2 mil
linhas de React/TSX em `packages/trace-viewer/src/ui`, mais o service worker
que le o zip, mais cerca de 13 mil linhas de `packages/isomorphic` (modelo do
trace e modernizador) e 3.2 mil de componentes web compartilhados em
`packages/web`.

O que torna isso viavel e que a metade cara nao e a UI: e o **modelo**, e ele
e puro Dart, sem DOM. Por isso a primeira onda separa os dois, e a UI so
comeca quando o modelo tiver superficie publica estavel e testada.

## Onda 1 — em andamento

Quatro frentes que nao se cruzam em arquivo, cada uma no seu worktree.

| Frente | Branch | O que fecha |
| --- | --- | --- |
| WebSocket, WebSocketRoute e Worker | `feat/websocket-worker` | A ultima lacuna grande da API de browser |
| `tracing.group`/`groupEnd`, HAR, anexos, tira de filme do WebKit | `feat/tracing-group-har` | O que faltava do gravador |
| Modelo do trace, modernizador v3..v10, snapshot renderer | `feat/trace-viewer-model` | A metade sem UI do visualizador |
| Codegen: `locatorGenerators` e os geradores por linguagem, mais um gerador Dart | `feat/codegen` | Base do recorder e da aba de codegen |

## Onda 2 — depende da Onda 1

- **UI do visualizador**, em Dart web compilado por dart2js, sobre o modelo da
  Onda 1: lista de acoes, timeline, tira de filme, abas de network, console,
  source, **stack trace**, attachments e o painel de snapshot. Mais o
  `show-trace` que serve tudo isso de um `HttpServer` do `dart:io`.
  Porte de `packages/trace-viewer/src/ui` e `packages/web/src/components`.
- **Recorder e inspector**, sobre o codegen da Onda 1. Porte de
  `packages/recorder/src` e `server/recorder/`.
- **Reporter HTML** do `playwright_test`, porte de `packages/html-reporter`.
  Divide base com a UI do visualizador, entao vem depois dela.
- **UI mode**, que e o visualizador em modo `live` mais a lista de testes.

## Onda 3 — plataformas especiais

Ficam por ultimo porque nenhuma delas bloqueia as outras e cada uma e um
motor novo por si.

- **BrowserServer / `connect` / `run-server`**: o protocolo de dispatcher do
  upstream. Este porte nunca teve a camada de canal, entao aqui e construcao,
  nao traducao — e a decisao de desenho precisa ser tomada antes.
- **Android**, **Electron** e **WebView**.
- **BiDi**, que no upstream ainda e experimental.

## O que continua fora, e por que

- `browser_patches/` e o tooling de roll de navegador: nao e biblioteca, e
  infraestrutura de build do upstream.
- A extensao de VS Code e o component testing de React/Vue/Svelte: dependem
  do ecossistema Node, nao da biblioteca.

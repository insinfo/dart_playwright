# Relatório de gaps para paridade com o Playwright original

Data da análise: 2026-07-19
Última atualização: 2026-09-14 — ver "Progresso da rodada de 2026-09-14 (árvore de acessibilidade)".

Referências locais usadas:

- `referencias/playwright-typescript` - Playwright upstream TypeScript, versão `1.62.0-next`.
- `referencias/playwright-dotnet` - binding .NET, usado como referência auxiliar de API fortemente tipada.
- `packages/playwright`, `packages/playwright_core`, `packages/playwright_protocol` e `packages/playwright_mcp` - port Dart atual.

## Progresso da rodada de 2026-09-14 (árvore de acessibilidade)

Fecha a lacuna que a rodada anterior apontou como a primeira a atacar:
`accessibilitySnapshot` respondia de verdade só no Chromium, e o Firefox e o
WebKit devolviam um esqueleto de um nó.

Contagem medida nesta máquina, com `dart test -j1`: **559 testes verdes** —
493 em `packages/playwright/test`, 32 em `packages/playwright_core/test`
(dos quais 25 são os de unidade do parser de template, sem navegador) e 34 em
`packages/playwright_test/test`. Tudo o que precisa de navegador rodou nos
três motores.

Duas falhas continuam de pé, e **não são desta rodada**: `timezoneId inválido
deve ser recusado` estoura o timeout de 30 s no Chromium e no WebKit. Foi
conferido rodando o mesmo teste no commit anterior a esta rodada
(`ecbf547`), onde falha igual. O teste não aguarda o `expect(..., throwsA)`
que devolve um `Future`, e o motor que rejeita cedo demais deixa a rejeição
sem ninguém escutando — o mesmo padrão que já mordeu o CI deste repositório
antes. Fica registrado aqui em vez de corrigido de passagem: é outro assunto.

### O upstream mudou de estratégia, e isso muda o alvo

A tarefa pedia para seguir o upstream "em cada motor": Chromium por
`Accessibility.getFullAXTree` do CDP, Firefox pelo Juggler, WebKit pelo
protocolo do inspetor. **Esses três caminhos não existem mais.** No
`referencias/playwright-typescript` em `1.62.0-next` não há
`crAccessibility.ts`, `ffAccessibility.ts` nem `wkAccessibility.ts`, não há
`docs/src/api/class-accessibility.md`, e `Accessibility.getFullAXTree` só
aparece no `protocol.d.ts` gerado — nenhum código do servidor o chama. A
classe `Accessibility` inteira foi removida.

O que o upstream tem no lugar é `packages/injected/src/ariaSnapshot.ts`: uma
árvore ARIA calculada **dentro da página**, a partir do DOM, pelo script
injetado, com os papéis e nomes de `roleUtils.ts`. O mesmo código nos três
motores. Foi essa a troca: a árvore de acessibilidade de cada navegador dava
três respostas diferentes para a mesma página, e o upstream parou de expor
isso.

Logo, o porte fiel aqui não é escrever três backends de protocolo — seria
reconstruir de memória código que o upstream apagou, que é exatamente o
"inventar formato" que a tarefa proíbe. É portar a árvore injetada. É o que
esta rodada fez, e é por isso que os três motores concordam.

### O que foi portado

- `injected/ariaSnapshot.ts`: `generateAriaTree` e `renderAriaTree`, no modo
  `default`.
- `injected/ariaSnapshotDistiller.ts`: os `normalizePlugins`
  (`mergeStringChildren` e `unwrapSingleChildGenerics`).
- `isomorphic/yaml.ts`: `yamlEscapeKeyIfNeeded` e `yamlEscapeValueIfNeeded`.
- De `roleUtils.ts`, o que faltava: `kAriaInvalidRoles`, `getAriaInvalid` e
  `truncateDataUrl`. O resto (papéis implícitos e explícitos, nome acessível,
  `checked`/`disabled`/`expanded`/`level`/`pressed`/`selected`,
  `getCSSContent`, `isElementHiddenForAria`) já estava portado desde o
  Milestone 2, o que é a razão de isto ter cabido numa rodada.

`CorePageAccessibility`, um mixin só, substituiu as três implementações por
motor. `AccessibilityNode` ganhou os estados e `props`; os papéis agora são
ARIA (`heading`, `textbox`, `checkbox`) e não mais o vocabulário de plataforma
do CDP (`RootWebArea`, `StaticText`, `InlineTextBox`, `LabelText`).
`page.ariaSnapshot()` e `Locator.ariaSnapshot()` entregam o YAML.

### O que os motores legitimamente não entregam

A pergunta "o que o leitor de tela anunciaria" **não tem resposta aqui, em
motor nenhum**, e agora está dito na documentação do método em vez de
preenchido por aproximação. A árvore diz o que a marcação significa segundo a
WAI-ARIA e a HTML-AAM; a árvore interna do navegador pode divergir disso, e é
justamente essa divergência que o upstream deixou de expor.

Ficaram de fora, por serem do modo `ai` do upstream e não do formato de
snapshot: `[ref=e1]` (as âncoras que permitem clicar no que se leu),
`[active]`, `[box=x,y,w,h]`, `depth`, descida em iframes e os cinco
`aiPlugins` do destilador. O `playwright_mcp` continua com o passeio de DOM
próprio por causa exatamente disso: ele precisa carimbar `data-pw-ref`, e a
árvore ARIA portada é de valores, não de handles.

Uma divergência real entre motores foi encontrada e está registrada num teste
em vez de escondida: `<input type=color>` começa com `value` `"#000000"` no
Chromium e no Firefox e vazio no WebKit. Não é diferença de acessibilidade —
a árvore pergunta o `value` ao DOM. Nos outros widgets nativos que foram
sondados (file, range, number, date, time, progress, meter, select múltiplo,
textarea, table, `aria-pressed=mixed`, `indeterminate`, `<search>`,
`<dialog>`, `<hgroup>`, `<fieldset>`, `<output>`) os três concordam —
inclusive no rótulo "Choose File" do input de arquivo, que vem do `roleUtils`
do upstream e não do navegador.

### `toMatchAriaSnapshot`

O `ariaSnapshot` só ganha sentido pleno com a assertion que o consome, então
ela veio junto. `packages/playwright_core/lib/src/aria_template.dart` porta o
`parseAriaSnapshot` e o `KeyParser` do `isomorphic/ariaSnapshot.ts` mais o
casador (`matchesNode`, `listEqual`, `containsList`, `matchesNodeDeep`) do
`injected/ariaSnapshot.ts`. Duas diferenças deliberadas:

- o casamento roda em Dart sobre a árvore já trazida, não dentro da página. O
  upstream casa na página porque precisa devolver os elementos casados para o
  seletor `aria-ref`; aqui não há refs, então não há motivo;
- `[active]` é **recusado** com erro, não ignorado. Este porte não calcula o nó
  focado; aceitar o atributo e não conferi-lo faria a assertion passar em
  qualquer nó, que é a falha silenciosa que esta rodada inteira existe para
  evitar.

Um template que não parseia falha na hora, sem consumir o timeout: erro de
sintaxe é bug de quem escreveu o teste, e relatá-lo como "a página nunca
casou" depois de cinco segundos manda a pessoa depurar o lugar errado.

### Cobertura de teste desta rodada

- `packages/playwright_core/test/aria_template_test.dart`: 25 testes de
  unidade, sem navegador, sobre o parser e o casador.
- `packages/playwright_test/test/playwright_test_test.dart`: 15 testes de
  `toMatchAriaSnapshot` (5 casos × 3 motores).
- `packages/playwright/test/integration/accessibility_parity_test.dart`: 24
  testes. Papéis, nomes acessíveis das três origens (`aria-label`,
  `<label for>`, `<label>` envolvente), `checked`/`disabled`/`expanded`,
  `level`, `value`, `description`, `props['url']`, aninhamento,
  `interestingOnly: false`, a comparação direta das três árvores e a
  divergência do `type=color`.
- `packages/playwright/test/integration/aria_snapshot_parity_test.dart`: 93
  testes (31 casos × 3 motores) com os fixtures e o YAML esperado **do próprio
  upstream**, transcritos de `tests/page/page-aria-snapshot.spec.ts`: escape
  de YAML, normalização de espaço, `aria-owns` com ciclo, slots e shadow DOM,
  pseudo-elementos `::before`/`::after` (inline, `display:none`,
  `visibility:hidden`, `display:block`), `presentation`/`none`, textarea,
  filhos visíveis de pais escondidos, placeholder e iframes.

O teste que provou a lacuna antes da correção está no commit
`test: provar que accessibilitySnapshot mente no Firefox e no WebKit`: 1 nó no
Firefox, 1 nó no WebKit, e no Chromium uma árvore crua do CDP que também não
era a do upstream.

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

## Progresso da rodada de 2026-09-14 (Milestones 3, 4 e 5)

Fecha os Milestones 3, 4 e 5, mais o defeito de hit target. A suíte saiu de
209 para **410 testes verdes**, todos rodados de fato em Chromium, Firefox e
WebKit nesta máquina. O repositório passou de quatro para **cinco pacotes, os
cinco publicáveis**.

### Correção de correção: hit target

Era o item mais grave em aberto, e não era falta de recurso: um elemento
coberto por outro era clicado assim mesmo, porque a actionability checava
`visible`/`stable`/`enabled`/`editable` e nunca perguntava se o ponteiro
chegava lá. O clique ia para o overlay e o teste passava achando que tinha
clicado no botão.

Novo estado `receivesEvents`, porte de `injectedScript.ts#expectHitTarget`:
desce pelos shadow roots de fora para dentro com `elementsFromPoint` e aceita
o hit quando quem responde é o próprio elemento, um descendente dele, ou um
`<label>` que aponta para ele. O ponto testado é o mesmo que a ação vai mirar,
e a mensagem de timeout diz o que interceptou o clique.

### Milestone 3 — rede e artefatos

- **`Route`**: `continue_` com overrides de url/método/headers/corpo (cada
  motor quer um shape diferente: array de `{name,value}` no Chromium e no
  Firefox, objeto no WebKit); `fallback`, que transforma os handlers numa
  cadeia rodando do mais novo para o mais antigo e não toca em protocolo
  nenhum; `abort` com as tabelas de erro por motor — o WebKit só distingue
  quatro resultados, e o Juggler não tem tabela.
- **`Request`**: `resourceType` (o Firefox é o único sem campo `type` e deriva
  de `cause`/`internalCause`), `failure`, `isNavigationRequest`, `response`,
  `redirectedFrom`/`redirectedTo`, `allHeaders`/`headersArray`/`headerValue`,
  `postDataBuffer`, `postDataJSON`, `timing` e `sizes`.
- **`Response`**: `headers`, `allHeaders`, `headersArray`, `headerValue`,
  `headerValues`, `serverAddr`, `securityDetails`, `fromServiceWorker`,
  `finished`.
- **Upload**: `Locator.setInputFiles`, `Page.setInputFiles` e `FileChooser`.
- **Download**: `Download` com `path`/`saveAs`/`failure`/`cancel`/`delete`,
  eventos na página e no contexto, opções `acceptDownloads` e `downloadsPath`.
- **Screenshot**: `type`, `quality`, `fullPage`, `clip`, `scale` e
  `Locator.screenshot`.
- **`page.pdf`** no Chromium, lido pelo stream `IO`.
- **`APIRequestContext`**: `playwright.request.newContext()` e
  `context.request`, compartilhando o pote de cookies nos dois sentidos.

Onde o motor não mede, o valor é `-1`, não zero: o Firefox não reporta tamanho
de header e o WebKit não reporta transfer size. Inventar zero seria pior que
admitir a lacuna.

### Milestone 4 — contexto e configuração

`locale`, `timezoneId`, `colorScheme`, `reducedMotion`, `forcedColors`,
`deviceScaleFactor`, `isMobile`, `hasTouch`, `offline`, `extraHTTPHeaders`,
`httpCredentials`, `geolocation` e `permissions`; `Touchscreen`, `Page.tap` e
`Locator.tap`; catálogo `devices`; `setTestIdAttribute`.

Cada motor aplica isso numa camada diferente, e errar a camada dá
`'<cmd>' wasn't found`:

| Opção | Chromium | Firefox | WebKit |
| --- | --- | --- | --- |
| locale | página | contexto | browser (`Playwright.setLanguages`) |
| timezoneId | página | contexto | target |
| colorScheme / reducedMotion | página (`setEmulatedMedia`) | contexto | target (`overrideUserPreference`) |
| deviceScaleFactor / isMobile | página | contexto | pageProxy + target |
| hasTouch | página | contexto | target |
| offline | página | contexto | target |
| httpCredentials | interceptação `Fetch` | contexto | pageProxy |
| geolocation | página | contexto | browser |
| permissions | contexto | contexto | pageProxy, por página |
| tap | página | página | pageProxy |

As tabelas de permissão têm os tamanhos que os motores de fato têm: 17 no
Chromium, 6 no WebKit, 5 no Firefox. Pedir uma que o motor não conhece lança,
em vez de passar calada — passar calada deixaria um teste verde pelo motivo
errado.

### Milestone 5 — `playwright_test`

Pacote novo, camada sobre `package:test` e não runner próprio: o `dart test` já
roda, reporta, filtra, repete e paraleliza. `playwrightTest` roda o corpo uma
vez por motor, com navegador compartilhado por arquivo e contexto/página novos
por teste; 18 assertions que repetem até passar ou estourar o prazo, todas com
`.not`; screenshot de página inteira na falha.

### `playwright_mcp` deixou de ser interno

Era interno com bom motivo — sem biblioteca pública, sem teste, seis
ferramentas sobre uma API que se mexia. Agora: servidor **dual-era** (revisão
moderna `2026-07-28` com versão por requisição no `_meta` e `server/discover`
obrigatório, mais o handshake `initialize` das revisões `2025-11-25` e
anteriores), 22 ferramentas, biblioteca pública e 6 testes que sobem o servidor
como processo e falam JSON-RPC pelo pipe.

`browser_snapshot` percorre o DOM na página em vez de usar
`page.accessibilitySnapshot()`. Quando isto foi escrito o motivo era que só o
Chromium respondia de verdade; **isso foi corrigido na rodada de 2026-09-14** e
os três motores respondem. O passeio próprio continua por outro motivo: ele
carimba `data-pw-ref` em cada elemento listado, e a árvore ARIA portada é de
valores, sem âncoras para agir depois.

### Defeitos encontrados e corrigidos

1. **`Runtime.runIfWaitingForDebugger` faltava no Chromium.** Com auto-attach
   ligado, o renderer do opener fica preso dentro de `window.open` até o
   target novo ser retomado — o clique ou o `evaluate` que abriu o popup nunca
   retornava. `target=_blank` funcionava, o que escondia o problema.
2. **`page.evaluate` não resolvia promise no WebKit.** Só o Chromium mandava
   `awaitPromise`. Agora passa por `Runtime.awaitPromise`. **O Firefox não tem
   equivalente nenhum** e continua sem: o Juggler não tem `awaitPromise` nem
   em `evaluate` nem em `callFunction`. Está documentado no README.
3. **A biblioteca escrevia diagnóstico no stdout.** O launcher POSIX usava
   `print` para `[browser stdout]`, `[browser stderr]` e `[browser exit]`.
   Para um servidor de protocolo por stdio — o nosso próprio `playwright_mcp`
   — o stdout *é* o canal, e uma linha dessas corrompe a sessão inteira. Só
   aparecia no Linux e no macOS, e só com `PLAYWRIGHT_DEBUG=1`, que é o que o
   CI liga.
4. **Firefox não ligava um redirect cujo hop anterior já tinha terminado**: o
   request terminado saía do mapa antes do próximo chegar.
5. **`DOM.setFileInputFiles` do Chromium ignora lista vazia**, então limpar um
   input passa pelo DOM.
6. **Caminhos de arquivo precisam ser absolutos e nativos**: o Firefox monta
   um `nsIFile` e recusa caminho do Windows com barra normal.
7. **Dois testes só passavam no Windows** (achados pelo CI): um anexava a
   expectativa depois do `close`, e a rejeição chegava sem ninguém escutando;
   o outro exigia que uma animação tivesse terminado, o que um runner macOS
   carregado não garante porque estrangula o `setInterval` da página.

### O que ficou de fora, e por quê

- **Tracing e vídeo.** O tracing exige escrever o formato de trace do upstream
  (um zip com `trace.trace` mais recursos) para ser útil de verdade, e esse
  formato é alvo móvel; o vídeo exige o binário do ffmpeg, que nem está
  instalado nesta máquina (`dart run playwright list` mostra `❌ ffmpeg`) e um
  pipeline de screencast por motor. Os dois são trabalho real, não pequeno, e
  eu preferi entregar o resto verificado a entregar isso sem rodar.
- **Opções de screenshot `mask`, `caret`, `animations`, `omitBackground`,
  `style`.** São script injetado mais `setDefaultBackgroundColorOverride`;
  cabem numa rodada curta.
- **Multipart no `APIRequestContext`** e `storageState` num contexto avulso.
- **`WebSocket`, `WebSocketRoute`, `Worker`.**
- ~~**`Clock` e `Coverage`.**~~ — FEITOS em 2026-09-14. O `clock.ts` está
  portado inteiro (`injected/injected_clock_source.dart`) e responde igual nos
  três motores. O `Coverage` é mesmo CDP-only, e por isso Firefox e WebKit
  lançam `UnsupportedError` explicando a razão em vez de devolver lista vazia:
  os contadores saem do V8 e do motor de CSS do Blink, e nem o Juggler nem o
  inspector do WebKit têm equivalente — o upstream expõe `page.coverage` só no
  tipo de página do Chromium.
- ~~**`addInitScript`, `exposeFunction`, `exposeBinding`.**~~ — FEITOS em
  2026-09-14, nos três motores:
  `Page.addScriptToEvaluateOnNewDocument` (Chromium), `Page.setInitScripts`
  (Juggler) e `Page.setBootstrapScript` (WebKit), com o canal de binding em
  `Runtime.addBinding` / `Page.addBinding`.
- ~~**`BrowserType.connectOverCDP` e `launchPersistentContext`**~~ — FEITO em
  2026-09-14, junto com as opcoes de `launch` que faltavam (`channel`,
  `executablePath`, `downloadsPath`, `env`, `slowMo`, `timeout`, `tracesDir`,
  `chromiumSandbox`, `firefoxUserPrefs`, `ignoreDefaultArgs`,
  `handleSIGINT`/`SIGTERM`/`SIGHUP`). `connectOverCDP` e so Chromium: CDP e o
  protocolo do Chromium, e nem Juggler nem o inspetor do WebKit o
  implementam.
- **`BrowserType.connect` e `launchServer`.** Sao os dois que sobraram, e
  sobraram juntos por um motivo: os dois falam o *protocolo do Playwright*,
  nao o protocolo do motor. O upstream tem uma camada de RPC por canais
  (`channels`, `dispatchers`, `connection.ts`) que serializa cada objeto da
  API — `Browser`, `BrowserContext`, `Page`, `Locator`, `Route` — como um
  canal remoto. Esta porta nao tem essa camada: ela fala CDP, Juggler e
  WebKit direto, sem nenhum dispatcher no meio. `launchServer` teria de
  expor essa camada num WebSocket e `connect` teria de consumi-la, entao os
  dois sao "portar a camada de RPC do Playwright", nao "adicionar dois
  metodos".
- ~~**Proxy por contexto.**~~ — FEITO em 2026-09-14 nos tres motores, alem do
  proxy no launch.
- ~~**Extensões CSS do Playwright** (`:has-text()`, `:visible`, seletores de
  layout) e shadow-piercing no motor `css`~~ — FEITO em 2026-09-13:
  `cssTokenizer.ts`, `cssParser.ts`, `layoutSelectorUtils.ts` e
  `selectorEvaluator.ts` estão portados no script injetado.
- ~~**`ariaSnapshot`** e a assertion `toMatchAriaSnapshot`~~ — FEITOS em
  2026-09-14. Falta `toHaveScreenshot`, que depende de baseline em disco e de
  comparação de imagem.
- ~~**`accessibilitySnapshot` real no Firefox e no WebKit.**~~ — FEITO em
  2026-09-14, e não do jeito que a linha original imaginava: o upstream
  removeu os três backends por protocolo, e o porte seguiu a árvore injetada
  que os substituiu.

## Progresso da rodada de 2026-09-13 (eventos P0)

Fecha o item 3 (eventos de primeira classe) e o item 4 (esperas
especializadas) de "P0 - Necessário para paridade estrutural", mais os itens
1, 5 e 6 de "Próximos passos imediatos". A suíte saiu de 209 para **276
testes verdes**, todos rodados de fato nos três motores nesta máquina.

### Fundação: o emissor mentia

`EventEmitter.stream` criava um `StreamController` novo a cada leitura do
getter e registrava nele um listener permanente. Duas consequências:

1. `listenerCount` contava getters lidos, não assinantes. A regra do upstream
   — um dialog que ninguém observa é dispensado, porque um modal bloqueia o
   renderer — não tinha como ser implementada em cima disso.
2. Eventos sem payload (`emit('load')`, `emit('close')`) chamavam o listener
   com zero argumentos e estouravam `NoSuchMethodError`. Ou seja,
   `page.onLoad.listen(...)` estava quebrado desde sempre, e nenhum teste
   assinava esses streams para perceber.

Agora há um controller por nome de evento, o listener do emissor só existe
enquanto o stream tem assinante (via `onListen`/`onCancel`), e `disposeStreams`
fecha tudo quando o objeto morre — que é o que faz uma espera pendente ser
cancelada em vez de ficar pendurada.

### Rastreamento de novos targets por motor

Era o item apontado como o primeiro da fila. Toda página passa por um único
caminho de adoção, e `newPage` usa o mesmo caminho que um popup — então
`context.pages` e o evento `page` não podem divergir:

- **Chromium**: `Target.setAutoAttach {autoAttach: true, flatten: true}` na
  sessão do browser. `Target.createTarget` devolve um id; a página é
  construída pelo handler de `Target.attachedToTarget`, e `newPage` espera por
  ela. `openerId` no `targetInfo` dá o opener.
- **Firefox**: `Browser.attachedToTarget` já existia para `newPage`; passou a
  ser a única porta de entrada, com `openerId` e `browserContextId` do
  `targetInfo`.
- **WebKit**: `Playwright.pageProxyCreated` no nível do browser, com
  `pageProxyId`, `browserContextId` e `openerId`. A sessão de pageProxy já era
  criada avidamente pela conexão, então nenhum evento se perde entre a criação
  e o `Playwright.createPage` responder.

`waitForDebuggerOnStart` ficou desligado no Chromium de propósito: com ele,
todo target novo nasce pausado e qualquer um que a gente não modele (OOPIF,
worker) trava a página se esquecermos de retomá-lo.

### O defeito que custou a rodada

No Chromium, `page.evaluate("window.open(...)")` e o clique num botão que
chama `window.open` **nunca retornavam**, embora o popup fosse criado e
adotado corretamente. `target=_blank` funcionava.

Causa: com auto-attach ligado, o renderer do opener fica bloqueado dentro da
chamada síncrona de `window.open` até o target novo ser retomado. O upstream
manda `Runtime.runIfWaitingForDebugger` no fim da inicialização da página
(`crPage.ts:548`) — o que se lê como "retome se estiver pausado", mas na
prática é também o sinal que destrava o opener. Sem ele o `Input.dispatchMouseEvent`
do clique nunca recebia ack e a espera do teste estourava.

### Eventos por motor

| Evento | Chromium | Firefox | WebKit |
| --- | --- | --- | --- |
| console | `Runtime.consoleAPICalled` (descartando `executionContextId == 0`, que é o replay do CDP ao habilitar `Runtime`) + `Log.entryAdded` sem `source == 'worker'` | `Runtime.console` | `Console.messageAdded`, com `type == 'log'` usando o `level` e `timing` virando `timeEnd` |
| pageerror | `Runtime.exceptionThrown` | `Page.uncaughtError`, com o stack do SpiderMonkey reescrito para o formato V8 | `Console.messageAdded` com `level == 'error' && source == 'javascript'` |
| crash | `Inspector.targetCrashed` | `Page.crashed` | campo `crashed` de `Target.targetDestroyed` |
| popup | `openerId` do `targetInfo` | `openerId` do `targetInfo` | `openerId` do `pageProxyCreated` |

A única normalização de nome de tipo em todo o upstream é o `warn` do Juggler
virando `warning`; o resto passa cru, e aqui também.

### API pública

- **`Page`**: `onConsole`, `onPageError`, `onPopup`, `onCrash`, `onDialog`
  (agora `Stream<Dialog>`), `waitForPopup`, `waitForConsoleMessage`,
  `waitForDialog`, `opener()`, `context()`, `isClosed()`,
  `setViewportSize`, `setExtraHTTPHeaders`.
- **`BrowserContext`**: `onPage`, `onClose`, `onConsole`, `onPageError`,
  `onDialog`, `onRequest`, `onResponse`, `onRequestFinished`,
  `onRequestFailed`, `waitForPage`, `waitForConsoleMessage`, `waitForEvent`.
- **Cancelamento consistente** (`lib/src/waiter.dart`): toda espera desiste no
  timeout, no fechamento do alvo (o stream fecha) e, nas de página, no crash —
  os mesmos dois `rejectOnEvent` que o `Waiter` do upstream registra.
- **Identidade de wrappers**: `PageImpl.forCore`/`BrowserContextImpl.forCore`
  guardam o wrapper num `Expando`, então `context.pages()`, `popup.opener()` e
  o evento `page` devolvem o mesmo objeto. Sem isso, `expect(popup.opener(),
  same(page))` seria falso e o usuário não teria como comparar páginas.

### Quebra de API

`page.onDialog` deixou de ser o método que recebia um handler e virou um
`Stream<Dialog>`, como todos os outros eventos. O auto-dismiss continua: sem
assinante na página nem no contexto, o dialog é dispensado.

### O que ficou de fora desta rodada, e por quê

- **`onCrash` só foi provado no Chromium** (`chrome://crash`). Firefox só tem
  `about:crashcontent` em build de debug e o WebKit não tem equivalente
  suportado; a fiação dos dois está no lugar e não foi exercitada de ponta a
  ponta.
- **`ConsoleMessage.args()`**: o upstream monta um `JSHandle` por argumento e
  chama `preview()` neles. Aqui o texto vem do `description` do RemoteObject,
  que dá a mesma string para tudo que um teste costuma asserir, mas não
  devolve handles.
- **`WebError` no contexto**: o upstream emite `weberror` (com um wrapper que
  carrega a página de origem) em vez de `pageerror` no `BrowserContext`. Aqui
  o contexto emite `pageerror` com o mesmo payload da página; a página de
  origem ainda não viaja junto.
- **`download`, `fileChooser`, `webSocket`, `worker`, `serviceWorker`,
  `backgroundPage`**: dependem das classes correspondentes, que são Milestone
  3. Sem a classe, o evento não teria o que carregar.
- **`removeAllListeners` com `behavior`** e `setDefaultTimeout` /
  `setDefaultNavigationTimeout`: cada espera ainda recebe o timeout por
  parâmetro.

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

A *sintaxe de string* do seletor (encadeamento com `>>`, prefixos de motor) é
parseada em Dart e chega como JSON estruturado, então `selectorParser.ts` não
foi portado; o corpo CSS de uma parte `css=` é parseado na página pelo
`cssParser`/`cssTokenizer` portados. Diferenças deliberadas, documentadas no
cabeçalho do arquivo:

- o motor `css` roda o `selectorEvaluator` portado: entende as extensões CSS
  do Playwright (`:has-text()`, `:text()`, `:text-is()`, `:text-matches()`,
  `:visible`, `:has()`, `:is()`/`:where()`, `:not()`, `:scope`,
  `:nth-match()`, `:left-of()`, `:right-of()`, `:above()`, `:below()`,
  `:near()`, `:light()`) e **entra** em shadow roots abertas, como os motores
  `text`, `label` e `role`. Shadow roots fechadas continuam invisíveis, como
  no upstream;
- um seletor malformado vira `InvalidSelectorError` na hora, em vez de ser
  repetido até o timeout do locator;
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
- ~~**Extensões CSS do Playwright** e shadow-piercing no motor `css`~~ —
  FEITO em 2026-09-13. Ficaram de fora, por dependerem do `selectorParser`
  que não é portado: os motores CSS registrados pelo usuário
  (`selectors.register`) e o sufixo `:light` em outros motores
  (`text:light=`, `id:light=`).

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
| Eventos Playwright completos | Rede, lifecycle, console, pageError, popup, dialog, crash e os eventos de contexto expostos nos 3 motores; faltam download, fileChooser, webSocket, worker |
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
| `BrowserContext` | 39 | 8 métodos + 9 streams de evento + 3 esperas |
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
| `Clock` | 7 | 7 métodos (completo) |
| `Coverage` | 4 | 4 métodos, Chromium only (CDP) |
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

FEITO (2026-09-13, eventos P0): `Page.onConsole/onPageError/onPopup/onCrash/onDialog`; `BrowserContext.onPage/onClose/onConsole/onPageError/onDialog/onRequest/onResponse/onRequestFinished/onRequestFailed`; `Browser.onDisconnected`.

Ainda faltam streams/listeners públicos para:

- `Page`: `download`, `fileChooser`, `webSocket`, `worker` — dependem das classes correspondentes (Milestone 3).
- `BrowserContext`: `download`, `serviceWorker`, `backgroundPage`, e `webError` no formato do upstream (hoje o contexto emite `pageerror` com o payload da página, sem a página de origem junto).
- `Browser`: `context`.
- `WebSocket` e `Worker`: eventos próprios.

4. Implementar `waitForEvent` e esperas especializadas

FEITO (2026-07-19): `page.waitForRequest`, `page.waitForResponse`, `page.waitForURL`, `page.waitForFunction`, `page.waitForEvent` com timeout.

FEITO (2026-09-13, eventos P0): `page.waitForPopup`, `page.waitForConsoleMessage`, `page.waitForDialog`, `context.waitForPage`, `context.waitForConsoleMessage`, `context.waitForEvent`, e o cancelamento consistente (timeout, fechamento do alvo, crash da página) em `packages/playwright/lib/src/waiter.dart`.

Faltam:

- `page.waitForDownload`
- `page.waitForFileChooser`
- `page.waitForWebSocket`
- `page.waitForWorker`
- `worker.waitForEvent`

### P1 - API pública principal

1. Completar `BrowserType`

Faltam:

- `connect` e `launchServer` (ver acima: dependem da camada de RPC do
  Playwright, que esta porta nao tem)

Feito em 2026-09-14: `connectOverCDP` (só Chromium), `launchPersistentContext`,
`executablePath` e as opções de `launch` (`channel`, `downloadsPath`, `env`,
`proxy`, `slowMo`, `timeout`, `tracesDir`, `chromiumSandbox`,
`firefoxUserPrefs`, `ignoreDefaultArgs`, `handleSIGINT`, `handleSIGTERM`,
`handleSIGHUP`).

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
- Configuração: ~~`setViewportSize`, `setExtraHTTPHeaders`~~ (FEITO em 2026-09-13), default timeouts.

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

1. ~~`page.waitForPopup` e `context.waitForPage`~~ — FEITO em 2026-09-13, com rastreamento de targets/pageProxies nos três motores.
2. ~~`Frame` público completo~~ — FEITO em 2026-09-13, com contexto de execução por frame nos três motores.
3. Mais opções de contexto: `locale`, `timezoneId`, `colorScheme`, `deviceScaleFactor`, `geolocation`, `permissions`, `hasTouch` (este último destrava `tap`/`Touchscreen`).
4. `Route.continue_` com overrides (headers/method/postData) e `Route.fallback`.
5. ~~Eventos `console`/`pageError` e `context.waitForConsoleMessage`~~ — FEITO em 2026-09-13.
6. ~~`page.setViewportSize` e `page.setExtraHTTPHeaders`~~ — FEITO em 2026-09-13.
7. `setInputFiles` + `FileChooser`, e `Locator.screenshot` com recorte por elemento (ambos Milestone 3).
8. ~~Portar `selectorEvaluator`/`cssParser` para destravar as extensões CSS (`:has-text()`, `:visible`, layout) e shadow-piercing no motor `css`~~ — FEITO em 2026-09-13.

### Milestone 1 - API pública consistente e multi-engine

- Criar interfaces core neutras para `JSHandle`, `ElementHandle`, `Request`, `Response`, `Route`.
- Remover dependência direta de Chromium dos wrappers públicos.
- ~~Expor streams/eventos básicos de `Page`, `BrowserContext` e `Browser`.~~ FEITO em 2026-09-13.
- ~~Adicionar `waitForEvent` e waiters especializados mais usados.~~ FEITO em 2026-09-13 (faltam os que dependem de classes do Milestone 3).
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

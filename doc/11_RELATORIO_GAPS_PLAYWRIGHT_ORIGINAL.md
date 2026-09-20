# Relatório de gaps para paridade com o Playwright original

Data da análise: 2026-07-19
Última atualização: 2026-09-14 — ver "Progresso da rodada de 2026-09-14 (tracing)".

Referências locais usadas:

- `referencias/playwright-typescript` - Playwright upstream TypeScript, versão `1.62.0-next`.
- `referencias/playwright-dotnet` - binding .NET, usado como referência auxiliar de API fortemente tipada.
- `packages/playwright`, `packages/playwright_core`, `packages/playwright_protocol` e `packages/playwright_mcp` - port Dart atual.

## Progresso da rodada de 2026-09-14 (tracing)

Fecha a lacuna de maior valor que restava: uma falha de integração que não
reproduz local agora se resolve abrindo o trace no visualizador oficial.

`context.tracing.start/startChunk/stopChunk/stop` grava um zip com
`trace.trace`, `trace.network` e `resources/<sha1>.<ext>`, e
**`npx playwright show-trace` abre o arquivo**. Não há visualizador próprio
neste porte, e não deve haver — o custo inteiro está no gravador, e o
retorno de escrever o formato do upstream é justamente poder usar o
visualizador dele.

### O que foi portado

De `packages/playwright-core/src/server`:

- `trace/recorder/tracing.ts` para `server/trace/tracing.dart`: o gravador, o
  estado por trecho, os arquivos de recurso por sha1 e o zip;
- `trace/recorder/snapshotter.ts` e `snapshotterInjected.ts` para
  `server/trace/snapshotter.dart` e `snapshotter_injected.dart`: o snapshot
  de DOM, com o cache de sub-árvore (`[[n, i]]`) que faz um trace de cem
  ações não guardar cem cópias da mesma página;
- `har/harTracer.ts` e o formato de `versions/har.ts` para
  `server/trace/har_tracer.dart`: as entradas de rede, com o corpo da
  resposta anexado por sha1;
- `utils/serializedFS.ts` para `server/trace/serialized_fs.dart`;
- `instrumentation.ts` para `server/trace/instrumentation.dart`.

De `packages/isomorphic/trace/versions/traceV9.ts`:
`server/trace/trace_events.dart`, que é o contrato — as formas exatas de
`context-options`, `before`, `input`, `after`, `log`, `event`, `console`,
`screenshot`, `frame-snapshot` e `resource-snapshot`.

### De onde vêm as ações

O upstream cunha um `CallMetadata` por mensagem de protocolo, porque lá toda
chamada atravessa um fio. Aqui as chamadas são Dart puro, então a camada
pública é o único lugar que sabe que uma chamada aconteceu, e é de lá que
ela é anunciada (`instrumented.dart`). Os nomes de classe e método gravados
são os do **protocolo do upstream** (`Frame.click`, `Page.reload`), não os
nomes Dart, porque é por esse par que o visualizador decide como rotular a
linha; o seletor viaja em `params['selector']` na sintaxe do Playwright e
o visualizador o renderiza como locator.

Com nada gravando, a instrumentação custa uma verificação booleana por
chamada.

### O que grava

Ações de `Page`, `Locator` e `BrowserContext` como pares `before`/`after`,
com `error` quando a chamada falhou e `parentId` quando uma chamada pública
chamou outra; requisições como entradas HAR com o corpo; mensagens de
console; erros de página; diálogos; downloads; abertura e fechamento de
página; o DOM de cada frame antes e depois de cada ação, com o elemento
alvo marcado; e, com `sources`, a pilha Dart de cada ação mais os arquivos
`.dart` que ela aponta.

### O que não grava, e por quê

- **Screencast (o filmstrip do topo do visualizador).** Gravado: a opção
  `screenshots` liga a tira de filme de verdade, com entradas
  `screencast-frame` e os recursos JPEG que elas apontam. O PNG por fase de
  ação continua disponível como `actionScreenshots`. O que ainda não há é a
  tira para o WebKit, cujo screencast grava direto num arquivo em vez de
  entregar quadros.
- **`tracing.group`/`groupEnd`**, `startHar`/`stopHar` e o modo `live` da UI.
- **`aria-snapshot` por ação.** O `ariaSnapshot` existe no porte desde a
  rodada anterior; o que falta é gravá-lo no trace e o modo do visualizador
  que o consome junto com o screenshot.
- **Anexos** (`attachments`) nos eventos `after`, que no upstream vêm do
  test runner.

### Duas diferenças no snapshot, por falta de primitiva

- **O streamer é instalado na primeira captura de cada documento**, não
  antes dos scripts da página, porque `addInitScript` ainda não existe neste
  porte (está em andamento em outro ramo). A captura é uma travessia
  completa, então o que ela vê é o mesmo; o que se perde é a interceptação
  do CSSOM na janela entre o documento carregar e a primeira captura — uma
  folha de estilo editada por `insertRule`/`replaceSync` nesse intervalo não
  é sobrescrita no snapshot. Folha servida pela rede não é afetada: vem do
  próprio `trace.network`. Quando `addInitScript` entrar, trocar é questão
  de poucas linhas.
- **A captura é uma avaliação com prazo, não uma que não trava.** O upstream
  avalia sem travar para que uma página parada num `alert()` ou num XHR
  síncrono não segure a captura. Aqui a página parada perde o snapshot em
  cinco segundos em vez de segurar a ação.

### A versão de formato é a 9, e isso é deliberado

O formato é versionado com modernizador (`traceV3..V10` mais
`traceModernizer.ts`), o que fixa o **piso**, não o teto: um visualizador
recusa, com `TraceVersionError`, um trace cuja versão ele não conhece. A 10
só existe na árvore não publicada do upstream (`1.64.0-next`); o
visualizador mais novo que dá para instalar do npm é o `1.63.0`, e o
`latestVersion` dele é 9 — conferido no `sw.bundle.js` do pacote instalado.

Não é downgrade: o `_modernize_9_to_10` só reescreve o `stepId` que o test
runner cunhava, e este gravador nunca emite `stepId`. O 9 que sai daqui
passa pelo modernizador de um visualizador que conheça a 10 sem mudar nada.

### A armadilha de sempre, multiplicada

O gravador é todo movido a evento, e `EventEmitter.emit` descarta o future
que um listener devolve — um erro nascido ali sumiria com o erro dentro.
Então **nada que roda em manipulador de evento aqui é assíncrono**: as
escritas entram numa fila serializada (`SerializedFs`, porte do
`serializedFS.ts`) e a falha reaparece no `stopChunk`, que tem quem a
espere. O único trabalho que realmente precisa da rede — ler o corpo de uma
resposta — vira um future que não pode falhar, estacionado num conjunto de
barreiras que o `stopChunk` aguarda.

Um defeito real desse desenho foi encontrado pelo teste e corrigido: o
`stopChunk` listava as entradas do zip **antes** de esperar os corpos, e
todo corpo que chegasse depois ficava fora do arquivo embora referenciado
pelo `trace.network`. O teste de rede pegou isso no Chromium e no WebKit.

### Como isto foi conferido

Não por inspeção do zip: **o visualizador oficial foi aberto**. O
`playwright@1.63.0` do npm serve o trace com
`show-trace --host 127.0.0.1 --port`, e o `tool/open_trace_in_viewer.dart`
abre essa URL com o Chromium deste porte e lê de volta o que a interface
renderizou. Nos três motores a lista de ações apareceu ("Create page",
"Navigate", "Click", "Wait for selector", com os locators renderizados), a
aba *Network* contou as requisições, a aba *Console* mostrou a mensagem da
página, a aba *Source* mostrou o arquivo `.dart` com a linha da ação
destacada, e o painel de snapshot renderizou a página — com o elemento alvo
destacado e o conteúdo do `<iframe>` desenhado dentro dele.

### Cobertura de teste desta rodada

`packages/playwright/test/integration/tracing_test.dart`, 24 testes: a
estrutura do zip, o nome sha1 de cada recurso conferido contra o conteúdo,
a linha `context-options` campo a campo, o casamento de `before`/`after`, o
seletor em `params`, a entrada HAR com o corpo, o console, o erro de uma
ação que falhou, o DOM antes e depois com `__playwright_value_` e
`__playwright_target__`, o `<iframe>` apontando para o snapshot do filho,
`sources` com o `src/<sha1-do-caminho>.dart` e a pilha, os trechos de
`startChunk`/`stopChunk` com a rede compartilhada entre eles, e a remoção
do diretório temporário no `stop`. Os seis primeiros rodam nos três
motores; o resto roda no Chromium, porque não depende do motor e esta
máquina não tem memória para provar a mesma coisa três vezes.

Suíte inteira medida nesta máquina com `dart test -j1`, por pacote: **648
testes verdes, 1 pulado** — 582 em `packages/playwright`, 32 em
`packages/playwright_core` e 34 em `packages/playwright_test`.

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
- ~~Implementar tracing~~ FEITO em 2026-09-14, com a tira de filme.
- ~~Implementar vídeo~~ `recordVideo` e `page.video()` FEITOS; o screencast
  dos motores e o muxer ffmpeg entram por contrato separado.
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

## Progresso da rodada de 2026-09-19 (codegen)

Frente `feat/codegen` da Onda 1 do `12_PLANO_CONCLUSAO_PORTE.md`: a geracao de
codigo que o recorder e a aba de codegen do visualizador de trace consomem.

### Onde o codigo ficou, e por que

Pacote novo: `packages/playwright_isomorphic`. Ele espelha o
`packages/isomorphic` do upstream e nao importa `dart:io` nem
`dart:html`/`package:web` -- so `dart:convert`. Isso e requisito, nao detalhe
de estilo: o mesmo codigo vai rodar dentro do visualizador compilado por
dart2js e dentro do CLI do recorder.

As alternativas foram descartadas assim:

- `playwright_core` esta amarrado a `dart:io` (processo, transporte, registry).
- `playwright_protocol` e puro, mas o que ele descreve e o protocolo; codegen
  nao e protocolo, e o pacote e dependencia de todos os outros.
- Um diretorio dentro de `playwright` faria a UI web arrastar a API de browser
  inteira.

### O que foi portado

De `packages/isomorphic/`:

- `stringUtils.ts` para `lib/src/string_utils.dart`.
- `cssTokenizer.ts` e `cssParser.ts` para `lib/src/css_tokenizer.dart` e
  `lib/src/css_parser.dart`.
- `selectorParser.ts` para `lib/src/selector_parser.dart`.
- `locatorUtils.ts` para `lib/src/locator_utils.dart`.
- `locatorGenerators.ts` para `lib/src/locator_generators.dart`.
- `locatorParser.ts` para `lib/src/locator_parser.dart`.
- `codegen/types.ts`, `codegen/language.ts`, `codegen/languages.ts` e
  `codegen/actions.d.ts` para `lib/src/codegen/`.
- `codegen/javascript.ts`, `python.ts`, `java.ts`, `csharp.ts` e `jsonl.ts`
  para `lib/src/codegen/`.

Mais um gerador novo, `lib/src/codegen/dart.dart`, que o upstream nao tem
porque nao existe binding Dart oficial.

O `cssParser`/`cssTokenizer` entraram porque **nao estavam portados como
Dart**: o que existe e uma traducao para JavaScript dentro de
`injected_css_engine_source.dart`, uma string que so roda na pagina. E
`parseSelector` depende de `parseCSS` para distinguir um seletor de uma
expressao de locator -- e exatamente isso que faz
`locatorOrSelectorAsSelector('javascript', "getByTestId('x')")` devolver o
seletor em vez do texto cru. Sem ele o caminho inverso nao funciona. Fica a
duplicacao: a mesma gramatica existe agora em Dart (aqui) e em JavaScript (no
script injetado). Unifica-las exigiria compilar o Dart para a pagina, o que e
outro contrato.

O `selectors.dart` de `playwright_core` **nao foi duplicado**: ele e um
*builder* de partes de seletor em JSON, com um parser simplificado; o que esta
aqui e o parser fiel do upstream, que produz `ParsedSelectorPart` com
`name`/`body`/`source`. Sao camadas diferentes e nenhuma chama a outra.

### Superficie publica

Um unico barrel, `package:playwright_isomorphic/playwright_isomorphic.dart`.
O que o recorder e a UI do visualizador vao usar:

- `asLocator(lang, selector)` e `asLocators(lang, selector, ...)`: seletor
  para locator idiomatico. `asLocators` devolve todas as grafias fieis, que e
  o que alimenta o seletor de alternativas do recorder.
- `asLocatorDescription(lang, selector)` e `locatorCustomDescription(selector)`,
  para `internal:describe`.
- `locatorOrSelectorAsSelector(lang, texto, testIdAttr)`: o caminho inverso,
  usado a cada tecla na caixa "pick locator". Devolve `''` quando o texto nao
  e nem seletor nem locator valido.
- `parseSelector`, `stringifySelector`, `splitSelectorByFrame`,
  `visitAllSelectorParts`, `parseAttributeSelector`.
- `parseCss`, `serializeCssSelector`, `tokenizeCss`.
- `getByRoleSelector`, `getByTestIdSelector`, `getByTextSelector` e o resto do
  `locatorUtils`.
- `languageSet()`, `generateCode(actions, gerador, opcoes)`, a hierarquia
  `Action`/`Signal`/`ActionInContext`, e `LanguageGenerator` com
  `JavaScriptLanguageGenerator`, `PythonLanguageGenerator`,
  `JavaLanguageGenerator`, `CSharpLanguageGenerator`, `JsonlLanguageGenerator`
  e `DartLanguageGenerator`.
- `JsRegExp`, que substitui o `RegExp` do JavaScript nas assinaturas.

### Diferencas deliberadas

- **`JsRegExp`.** O `RegExp` do Dart nao guarda o source nem a string de
  flags, entao `/a/im` nao sobrevive a uma ida e volta por ele. `JsRegExp`
  guarda os dois. `JsRegExp.fromPattern` reproduz o `EscapeRegExpPattern` do
  ECMA-262 (a barra vira barra escapada), sem o qual `getByText` com regex
  contendo barra nao volta a ser o mesmo seletor -- foi o unico ponto em que
  a semantica do JavaScript precisou ser imitada de proposito.
- **Tabela de dispositivos.** O upstream importa um JSON de 80 KB dentro do
  proprio codegen. Aqui `deviceDescriptors` e um mapa vazio que o embedder
  preenche: o visualizador nao tem uso para a lista, e este porte ainda nao
  implementa `devices` (Milestone 4).
- **Ordem do `languageSet()`.** Dart vem primeiro. E o porte Dart.
- **`or_`/`and_` do Python.** O upstream troca `.or_(` por `or(` e perde o
  ponto separador, entao `locatorOrSelectorAsSelector('python', ...)` nao
  fecha o ciclo para esses dois. Portado como esta, com comportamento
  identico ao do upstream; nao ha teste upstream cobrindo o caso.
- **U+2028 e U+2029** nao sao escapados em `JsRegExp.fromPattern`. O V8
  escapa; nenhum seletor consegue carrega-los e nenhum caso upstream
  exercita isso.

### O gerador Dart

Dois sabores: `DartLanguageMode.test` (emite `package:playwright_test`,
`playwrightTest`, `expectLocator`) e `DartLanguageMode.library` (emite
`package:playwright`, `Playwright.create()` e um `main()` proprio, com as
assertions comentadas, como o sabor "Library" do JavaScript faz).

Onde a API deste porte difere, e o que foi feito:

- `first` e `last` sao getters, entao saem sem parenteses.
- Locator aninhado (`has`, `hasNot`, `and`, `or`) sai prefixado com `page.`:
  Dart nao tem uma funcao `locator()` solta como as cadeias fluentes das
  outras linguagens sugerem. O codigo gerado sempre tem um `page` em escopo.
- `internal:control=any-frame` e `internal:chain` nao tem equivalente
  (`frameLocator()` sem seletor e `locator(Locator)` nao existem aqui), entao
  o gerador lanca e `asLocator` cai no seletor cru -- o mesmo caminho que o
  upstream usa para entrada invalida.
- `click` deste porte nao aceita modificadores, entao eles saem como
  comentario no fim da linha em vez de sumirem calados.
- O aria snapshot sai como string de uma linha com quebra escapada, nao como
  bloco de tres aspas: no sabor library a assertion esta comentada e um bloco
  vazaria do comentario, e o formatador reindentaria as linhas, mudando o
  proprio snapshot.

### Testes, numeros medidos

`cd packages/playwright_isomorphic && timeout-cli.exe 10m -- dart.exe test -j 1`
resultou em **89 testes, todos verdes, 7 segundos**. Nenhum precisa de
navegador.

- `test/locator_generator_test.dart` (29): transcricao de
  `tests/library/locator-generator.spec.ts` do upstream. Alem do valor
  esperado por linguagem, cada caso faz a ida e volta de `asLocator` para
  `locatorOrSelectorAsSelector` e de volta ao seletor original, como o
  upstream faz.
- `test/codegen_test.dart` (18): cabecalhos e acoes transcritos de
  `tests/library/inspector/cli-codegen-javascript`, `-python`,
  `-python-async`, `-pytest`, `-java` e `-csharp`.
- `test/css_parser_test.dart` (3): transcricao de
  `tests/library/css-parser.spec.ts`, incluindo os 22 seletores malformados.
- `test/selector_parser_test.dart` (28): `parseSelector`,
  `splitSelectorByFrame`, `parseAttributeSelector`, `stringUtils` e
  `JsRegExp`.
- `test/dart_locator_test.dart` (10): o `DartLocatorFactory`.
- `test/dart_codegen_compiles_test.dart` (1): gera um arquivo com uma acao de
  cada tipo nos dois sabores, escreve dentro do workspace e roda
  `dart analyze` sobre ele. E o teste que prova que a saida do gerador Dart
  compila de verdade contra `package:playwright` e `package:playwright_test`,
  em vez de ser conferida a olho. Pegou dois defeitos reais durante o porte.

`dart format` limpo e `dart analyze` sem issues na arvore inteira.

### O que ficou para tras

- **Recorder e inspector** (`packages/recorder/src`, `server/recorder/`): Onda
  2 do plano. Esta frente e a base deles, nao eles.
- **`internal:chain` e `frameLocator()` sem seletor no gerador Dart**:
  dependem de `Locator.locator(Locator)` e de um `frameLocator()` sem
  argumento na API publica deste porte. Sao dois metodos novos em
  `packages/playwright`, fora do escopo desta frente.
- **`deviceDescriptors`**: o mapa existe e fica vazio ate `devices` ser
  implementado.
- **`ariaSnapshot.ts` e `ariaSnapshotRenderer.ts`** do `packages/isomorphic`:
  ja portados noutro lugar (`aria_template.dart` e o script injetado), nao
  foram movidos para ca.
- **Unificar o parser de CSS** com a copia JavaScript do script injetado.

## Progresso da rodada de 2026-09-19 (modelo do trace)

Primeira metade do visualizador de trace portado de verdade, que e a decisao
do `12_PLANO_CONCLUSAO_PORTE.md`: o **modelo**, puro Dart e sem UI. Outro
agente constroi a interface em cima do que esta aqui, entao a superficie
publica deste pacote e um contrato, e o `README.md` dele a descreve inteira.

Pacote novo: `packages/playwright_trace_viewer`, no `workspace:` da raiz.

### O que foi portado

De `referencias/playwright-typescript/packages/isomorphic/trace` (4697 linhas
de TypeScript):

- `versions/traceV3.ts` .. `traceV10.ts` e `trace.ts` para
  `lib/src/versions/trace_v3.dart` .. `trace_v10.dart` e `lib/src/trace.dart`;
- `versions/har.ts` para `lib/src/versions/har.dart`, agora com o lado leitor
  que faltava — o gravador ja escrevia o formato desde a rodada do tracing;
- `traceModernizer.ts` para `lib/src/trace_modernizer.dart`, a cadeia inteira;
- `traceModel.ts`, `traceLoader.ts`, `entries.ts` e `traceUtils.ts` para
  `trace_model.dart`, `trace_loader.dart`, `entries.dart` e
  `trace_utils.dart`;
- `snapshotStorage.ts`, `snapshotRenderer.ts` e `snapshotServer.ts` para
  `snapshot_storage.dart`, `snapshot_renderer.dart`, `snapshot_script.dart` e
  `snapshot_server.dart`;
- `lruCache.ts` e os dois escapadores de `stringUtils.ts`.

Mais duas dependencias que o `traceModel.ts` tem e que nao estavam na lista:
`protocolMetainfo.ts` (as 327 linhas da tabela que o upstream gera do
`protocol.yml`) e `protocolFormatter.ts`, sem as quais a lista de acoes
mostraria `Frame.click` em vez de "Click" e nao teria como filtrar por grupo.

### A versao corrente do leitor e a 10, e a do gravador continua 9

A rodada do tracing decidiu emitir a **9** porque o visualizador mais novo
instalavel do npm tem `latestVersion` 9 e recusaria uma 10. Essa razao
continua valendo e nada mudou no gravador.

O leitor e o outro lado da mesma moeda e a escolha e oposta: a versao corrente
dele e a **10**, como a do upstream. Modernizar so ate a 9 nao economizaria
nada — o `_modernize_9_to_10` teria de existir de qualquer jeito para ler o
trace de um Playwright 1.64 — e pararia na 9 um leitor que ja sabe ler a 10.
Entao `kLatestTraceVersion = 10` e o `kRecorderTraceVersion = 9` fica ao lado,
documentando o que este porte escreve.

Os dois se encontram no meio: a 9 que sai do gravador sobe pela cadeia e cai
na mesma forma de memoria que a 10 de um trace futuro. O `_modernize_9_to_10`
so adota o `stepId` como `callId`, e este gravador nunca emite `stepId`, entao
para o trace deste porte o passo e a identidade — o que o teste de ponta a
ponta confirma.

### A cadeia, passo a passo

Cada `_modernize_N_to_M` existe porque algum trace no mundo tem aquela forma,
e nenhum foi resumido:

| Passo | O que conserta |
| --- | --- |
| 0 -> 1 | o erro da acao era uma string solta |
| 1 -> 2 | o snapshot do frame principal vinha com o viewport errado |
| 2 -> 3 | o recurso ainda nao era uma entrada HAR |
| 3 -> 4 | abre o envelope `CallMetadata` e descarta o que e interno |
| 4 -> 5 | a mensagem de console vinha partida em `object` mais `event` |
| 5 -> 6 | o log sai do `after` e vira eventos `log`, com tempo -1 |
| 6 -> 7 | o contexto declara `origin` e `monotonicTime`; a acao ganha `stepId` |
| 7 -> 8 | `apiName` vira o `title` ja renderizado |
| 8 -> 9 | o nome do snapshot vira fase; todo `sha1` vira caminho `file` |
| 9 -> 10 | o `stepId` e adotado como `callId`, em tudo que o referencia |

Duas consequencias que so aparecem quando se roda a cadeia inteira, e que os
testes fixam:

- num trace de versao 3 a 8 sem `stepId` proprio, o `6 -> 7` cunha
  `apiName@wallTime` e o `9 -> 10` o adota, entao o `callId` final de uma acao
  velha e `page.click@1700000000000`. O `frame-snapshot` e o `.stacks` passam
  pelo mesmo remapeamento, senao o painel de snapshot e a aba Source nao acham
  mais nada;
- a pilha que vinha dentro do `CallMetadata` da versao 3 **nao** sobrevive: o
  `3 -> 4` nao a copia, e quem passa a fornece-la e o arquivo `.stacks`. E o
  comportamento do upstream, e esta anotado no teste.

### O nucleo nao pode tocar a plataforma

O pacote sera compilado por dart2js junto com a UI, entao nada em `lib/src`
importa `dart:io`, `dart:html` ou `package:web`. O unico trabalho de
plataforma e chegar ao arquivo, e ele fica atras de `TraceLoaderBackend`:

- `ZipTraceLoaderBackend` le um zip que ja esta na memoria, com o
  `package:archive`, que e Dart puro e compila para a web;
- `lib/io.dart` acrescenta o lado `dart:io` — `openTraceFile`,
  `loadTraceFile` e `DirectoryTraceLoaderBackend` para um trace ao vivo — e e
  o unico arquivo que o CLI importa.

Pela mesma razao o `snapshotServer.ts` ficou **agnostico de transporte**. O
upstream devolve `Response` da fetch API porque vive num service worker; aqui
a resposta e dado puro (`SnapshotResponse`: status, cabecalhos e bytes), entao
o mesmo codigo serve um `HttpServer` do `dart:io` e um service worker
compilado. Essa separacao e o ponto: o modelo nao sabe qual dos dois esta do
outro lado.

Conferido de duas formas: um teste barato que varre `lib/` atras de
importacao proibida, e uma compilacao de verdade —
`dart compile js tool/web_smoke.dart` gera 765 KB de JavaScript sem um aviso.

### O que so a juncao revelou

- **O `.toString()` da funcao nao existe em Dart.** O upstream embute o
  bootstrap do snapshot chamando `.toString()` na propria funcao, entao o que
  vai para o navegador e o JavaScript que o TypeScript compilou. Aqui a funcao
  virou texto em `snapshot_script.dart`, com as anotacoes de TypeScript
  retiradas a mao e nada mais mudado — se fossem mantidas, o navegador
  recusaria `const scrollTops: Element[] = []` e o snapshot nao desenharia.
- **`new URL` e `Uri` discordam sobre caminho opaco.** O
  `rewriteURLForCustomProtocol` troca protocolo e hostname; no navegador esses
  dois setters sao no-op numa URL de caminho opaco, como `blob:https://x/y`.
  Com `Uri` isso precisa ser dito: sem autoridade, devolve a URL como veio.
- **O tipo numerico do JSON vaza para o id.** O `6 -> 7` monta o `stepId` com
  `${apiName}@${wallTime}`. Uma fixture que escrevesse `wallTime` como
  `double` produziria `page.click@1700000000000.0` e nenhum snapshot seria
  encontrado depois. Os escritores das versoes velhas declaram `num`, que e o
  que o JSON tem.
- **`Number.MIN_VALUE` nao e o menor negativo.** O `endTime` do modelo comeca
  em `Number.MIN_VALUE`, que em JavaScript e o menor positivo. Virou
  `double.minPositive`, nao `-double.maxFinite`.

### O que ficou para tras, e por que

- **O gerador de locator.** `renderTitleForCall` renderiza um seletor como
  locator chamando `asLocatorDescription` do `locatorGenerators.ts`, que e a
  frente `feat/codegen`. Aqui ele entra como `LocatorDescriber`, uma funcao
  injetavel cujo padrao mostra o seletor como foi gravado. Quando o codegen
  entrar, a UI passa a de verdade e nada mais muda.
- **`ariaSnapshotRenderer.ts`.** O modelo ja carrega os eventos
  `aria-snapshot` e responde por chamada e fase; desenhar a arvore de
  acessibilidade e trabalho da UI, e o gravador ainda nao emite esses eventos.
- **O modo `live`.** O `TraceLoaderBackend` ja tem `isLive()` e o
  `DirectoryTraceLoaderBackend` existe, mas nao ha quem releia o diretorio
  enquanto ele cresce; isso pertence ao `show-trace` da Onda 2.
- **`multiTraceModel` e a fusao de varios arquivos de trace num so
  visualizador.** O `TraceModel` ja junta os contextos de um arquivo; juntar
  arquivos diferentes e da UI.

### Numeros

81 testes de unidade, que nao precisam de navegador e rodam em menos de um
segundo, mais 8 testes de ponta a ponta que gravam um trace de verdade no
Chromium com `context.tracing` e o abrem com o `TraceLoader`/`TraceModel`:
saem as acoes com os titulos renderizados, a rede com o corpo de cada
resposta, a mensagem de console da pagina, o arquivo `.dart` da acao, a tira
de filme, os snapshots de DOM das duas fases e a pagina redesenhada, com o
alvo marcado e a folha de estilo servida do proprio trace.

## Progresso da rodada de 2026-09-19 (grupos e har)

Fecha o que faltava do gravador de trace, na lista que a rodada de 2026-09-14
deixou escrita: `tracing.group`/`groupEnd`, o HAR autonomo, os anexos nos
eventos `after` e a tira de filme do WebKit.

### `tracing.group` e `tracing.groupEnd`

`context.tracing.group('login')` abre uma linha na arvore de acoes do
visualizador, e tudo o que for gravado ate o `groupEnd` aparece pendurado
nela. Grupos aninham.

Nao ha evento de grupo no formato: o par que sai e um `before`/`after` comum
com `class: Tracing` e `method: tracingGroup`, e o aninhamento vem do
`parentId` — e assim que o `tracing.ts` do upstream faz, e e por esse par que
o visualizador decide desenhar a linha como grupo em vez de chamada. Duas
consequencias diretas: um grupo vazio e uma linha, nao um erro; e o `step()`
do `playwright_test`, que ja escrevia esse mesmo par, passou a ser o mesmo
mecanismo por baixo em vez de uma coincidencia.

Tres decisoes valem registro:

- O `parentId` de uma acao e `metadata.parentId ?? grupo corrente`. A ordem
  importa: uma chamada publica que chama outra ja tem pai, e sobrescrever
  isso achataria a arvore justamente onde ela e mais util.
- `stopChunk` fecha os grupos que sobraram. Um `before` sem `after` o
  visualizador desenha como acao que nunca terminou, e um `groupEnd` perdido
  num caminho de erro nao pode sujar o trace inteiro.
- Sem `location`, a pilha do grupo so e escrita com `sources` ligado. Um
  `stack` apontando para um arquivo que o zip nao carrega daria a aba
  *Source* uma linha que ela nao abre.

### HAR autonomo: `recordHar` e `startHar`/`stopHar`

`browser.newContext(recordHar: RecordHarOptions(path: 'sessao.har'))` grava
todas as requisicoes do contexto num documento HAR, escrito quando o contexto
fecha. `context.tracing.startHar(path)`/`stopHar()` fazem o mesmo com comeco
e fim proprios, para quando so um trecho da sessao interessa.

O `har_tracer.dart` ja estava portado desde a rodada anterior; o que faltava
era a ponta publica — o `harRecorder.ts` do upstream — e as opcoes que ele
passa ao tracer. Entrou tudo:

- `path`: terminando em `.zip` sai um arquivo com `har.har` mais os corpos
  como arquivos irmaos; qualquer outro caminho sai um `.har` puro.
- `content`: `embed` poe o corpo dentro do documento (base64 para o que nao e
  texto), `attach` o escreve ao lado e aponta por `_file`, `omit` descarta.
  O padrao segue a regra do upstream — `attach` para `.zip`, `embed` para
  `.har` — porque um `.har` sozinho nao tem onde por um arquivo irmao que
  viaje com ele.
- `mode`: `minimal` e o `slimMode` do upstream. Some com cookies, tempos,
  enderecos, tamanhos e a lista de paginas, e sobra o que um HAR e
  reproduzido a partir de.
- `urlFilter`: glob (o mesmo dialeto curto que `page.route` aceita neste
  porte) ou `RegExp`.

Duas coisas que o tracer nao tinha e o documento exige entraram junto: o
envelope `log` (`version`, `creator`, `browser`) e o array `pages`. O
`pageref` de uma entrada tem de nomear uma pagina desse array — antes o
gravador escrevia o `pageref` sem nunca emitir a pagina, o que so nao
aparecia porque o `trace.network` nao carrega o envelope.

O documento e escrito campo a campo e entrada por entrada pelo
`SerializedFs`, nao serializado inteiro de uma vez, pela mesma razao do
upstream: uma sessao longa tem mais entradas do que e confortavel segurar
como uma string so.

### Anexos nos eventos `after`

`attach('foto', body: await page.screenshot(), contentType: 'image/png')`
dentro de um `step()` do `playwright_test` vira um item da aba *Attachments*
do visualizador, no `after` do passo.

O relatorio anterior listava os anexos como ausentes "porque no upstream vem
do test runner", e e exatamente esse o ponto: la existe um `TestInfo` com uma
lista de anexos que o runner drena para o `after` do passo; aqui a camada de
teste e `package:test`, que nao tem esse objeto. O que substitui o `TestInfo`
e a zona que a instrumentacao ja mantinha — `currentCallMetadata` devolve a
chamada publica que esta rodando, e o anexo se pendura nela.

Isso tem um limite que vale dizer em vez de esconder: **`attach` so faz
sentido dentro de um `step`**. Na biblioteca pura o codigo do usuario nunca
roda *dentro* de uma chamada instrumentada — as chamadas sao folhas — entao
nao ha chamada corrente a que se pendurar, e `attach` fora de um passo nao
faz nada. E a mesma restricao do upstream, onde anexo e coisa de step, por
uma razao diferente.

O que vai para o trace e `name`, `contentType`, `path` (quando o anexo veio
de um arquivo) e `file`. O `file` e o que faz a coisa funcionar: aponta um
`resources/<sha1>.<ext>` dentro do zip, entao o anexo sobrevive ao trace
mudar de maquina. O upstream escreve `path` e `base64`; `path` so resolve num
visualizador servido da maquina que gravou, e `base64` incha o
`trace.trace`. O `file` e o que o modernizador do proprio upstream produz ao
ler um trace antigo (`'resources/' + attachment.sha1`), entao e forma do
contrato, nao invencao.

Um `path` e lido no quadro assincrono de quem chama `attach`, nunca no
gravador: o gravador roda em manipulador de evento e nao pode esperar por
disco.

### A tira de filme do WebKit ja existia

O relatorio anterior dizia que faltava a tira para o WebKit, "cujo screencast
grava direto num arquivo em vez de entregar quadros". **Isso nao vale mais**,
e nao por trabalho desta rodada: a frente de video ja tinha descoberto que o
`Screencast.startVideo` nao existe no WebKit 26.5 que este porte baixa (o
comando responde `'Screencast.startVideo' was not found`) e portado o WebKit
para `Screencast.startScreencast`, com evento `screencastFrame` e ack por
`generation`. Os tres motores sao `ScreencastKind.frames`, e nenhuma
implementacao devolve `directFile` hoje.

Medido nesta rodada, nao deduzido: o teste `screenshots deve gravar a tira de
filme em screencast-frame` passa no WebKit, e um trace de sonda gravado com
`tracing_example.dart webkit` saiu com **3 quadros** `screencast-frame` de
798x532, todos com o JPEG correspondente dentro do zip. O mesmo exemplo no
Chromium saiu com **1** — nao por defeito do Chromium, mas porque a pagina de
sonda e estatica e Chromium e WebKit so emitem quadro quando a pagina pinta,
que e a licao que a rodada anterior ja tinha registrado.

O que sobra e cosmetico e fica anotado: `ScreencastKind.directFile` continua
no contrato sem implementacao. Tirar e mecanico; ficou porque gravar direto
em arquivo pode voltar num roll de navegador.

### Como isto foi conferido

Pelo visualizador oficial, como sempre. O `tool/open_trace_in_viewer.dart`
ganhou duas leituras novas, porque as antigas nao respondiam a pergunta desta
rodada:

- **A arvore de acoes com a profundidade de cada linha.** Ler so os titulos
  diria que um grupo existe e nada sobre haver algo embaixo dele; a
  profundidade e quantos `.tree-view-indent` o visualizador desenhou antes da
  linha. E foi preciso **expandir**: o visualizador abre todo grupo fechado
  (`autoExpandDepth` e 0 sem filtro), entao os filhos nem estao no DOM ate
  alguem clicar no chevron — o script clica, em rodadas, ate nao sobrar linha
  fechada. Sem isso a leitura volta vazia, que foi o primeiro resultado desta
  rodada e por pouco passou por "o grupo nao aparece".
- **A aba *Attachments***, que so existe quando alguma acao carrega anexo:
  aba ausente e aba vazia sao respostas diferentes, e o script as distingue.

E consertou duas leituras que estavam mentindo em silencio. A aba *Network*
era lida por `.network-request-title-url` e a aba *Source* por `.source-tab`;
nenhuma das duas classes existe no visualizador publicado. As requisicoes hoje
sao um `GridView` e a URL e a celula `.grid-view-column-name`; o painel de
fonte e `[data-testid=source-code]`. O script relatava zero requisicoes para
um trace com quatro, e nenhuma fonte para um trace gravado com `sources:
true` — e como o resultado vazio e exatamente o que um trace sem rede ou sem
fontes produziria, ninguem notaria. Isto e o risco de conferir pela interface
e vale ficar escrito: uma leitura que quebra em silencio nao vira falha, vira
uma prova que passou a nao provar nada. Agora a leitura de rede distingue tres
casos — linhas, grade vazia, e o painel de "No network calls" que o
visualizador desenha quando nao ha grade nenhuma — e a de fonte diz quando nao
ha painel em vez de devolver `null`.

O que o visualizador oficial desenhou, com o trace de sonda do
`tracing_example.dart`:

```
- Create page
- open the page
  - Navigate 127.0.0.1:62966/
- load the items
  - click and wait
    - Click locator('#load')
    - Wait for selector locator('li').first()
- Wait for timeout
```

A aba *Network* contou as quatro requisicoes, a *Console* mostrou a mensagem
da pagina e a *Source* abriu o `tracing_example.dart` na regiao da acao.

E, com o trace de
`packages/playwright_test/example/step_attachments_example.dart`, a aba
*Attachments* com os dois itens: a imagem renderizada e o texto com link de
download. Esse exemplo existe para que a conferencia dos anexos seja
repetivel — o `attach` so vale dentro de um `step`, entao nao havia como
gravar um trace com anexos a partir dos exemplos da biblioteca pura.

### Cobertura de teste desta rodada

Onze testes novos, todos medidos nesta maquina.

`packages/playwright/test/integration/tracing_test.dart`, nove no grupo
`[chromium]`: o par `class`/`method` do grupo e o `parentId` das acoes de
dentro dele (e a ausencia de `parentId` no que rodou depois), grupos
aninhados, o grupo deixado aberto que o `stopChunk` fecha, a `location`
explicita na pilha; o `.har` com envelope, paginas e `pageref` casando, o
`.zip` com `har.har` e o corpo apontado por `_file` presente no arquivo, o
`minimal` sem cookies/tempos/paginas/`_transferSize`, o `urlFilter` deixando
passar uma entrada so, e o `startHar`/`stopHar` escrevendo com o contexto
ainda aberto (mais o `StateError` de parar duas vezes).

`packages/playwright_test/test/step_trace_test.dart`, dois: o anexo por
`body` com o `file` presente no zip, e o anexo por `path` que guarda o
caminho e poe a copia dentro do arquivo.

O arquivo de tracing passou a ter 24 testes: 9 por motor nos tres, mais 15 so
no Chromium.

Suite inteira medida nesta maquina com `dart test -j1`, por pacote: **1028
testes verdes, 1 pulado** — 855 em `packages/playwright` (1 pulado), 80 em
`packages/playwright_core` e 93 em `packages/playwright_test`.

Uma nota de ambiente que custou duas execucoes inteiras e vale para quem vier
depois: com varias sessoes rodando neste repositorio ao mesmo tempo, a limpeza
de TEMP de uma apaga o `dart_test.kernel.<hash>` da outra no meio da corrida,
e a suite morre com `Failed to load`. Isso nao e falha de teste, e o
`tool/test_clean.ps1` ja avisa disso no cabecalho. O jeito de nao depender de
sorte e dar um `TEMP`/`TMP` proprio a execucao — foi assim que esta contagem
saiu.
## Progresso da rodada de 2026-09-19 (websocket e worker)

Branch `feat/websocket-worker`. Fecha a ultima lacuna grande da API de
browser listada no plano da Onda 1: `WebSocket`, `WebSocketRoute` e `Worker`,
nos tres motores.

A suite nova e
`packages/playwright/test/integration/websocket_worker_parity_test.dart`:
**63 testes verdes**, 21 por motor, rodados de fato em Chromium, Firefox e
WebKit nesta maquina.

### O que foi portado

- **`WebSocket`**: `url()`, `isClosed()`, os eventos `framesent`,
  `framereceived`, `socketerror` e `close` com as grafias do upstream, e
  `page.waitForWebSocket` no estilo dos waiters que ja existiam. O frame
  chega como bytes mais o texto UTF-8 desses bytes, que e a forma do binding
  .NET - Dart nao tem a uniao `string | Buffer` do TypeScript.
- **`WebSocketRoute`**: `page.routeWebSocket` e `context.routeWebSocket`, com
  o `webSocketMock.ts` do upstream portado inteiro para
  `injected/injected_web_socket_mock_source.dart` e instalado pelo
  `addInitScript` que este porte ja tinha. O objeto entregue ao handler e o
  lado da pagina; `connectToServer()` abre a conexao real e devolve o lado do
  servidor. O repasse padrao e o do upstream: o que um lado nao trata vai
  para o outro, e um handler que nunca conecta deixa o socket inteiramente
  mockado (o `ensureOpened`, que abre o socket sem servidor nenhum).
- **`Worker`**: `url()`, `evaluate`, `evaluateHandle`, evento `close`,
  `page.workers()`, `page.onWorker` e `page.waitForWorker`. O contexto de
  execucao do worker reusa o `CoreExecutionContext` de cada motor.

### Como cada motor entrega, e onde eles divergem

| | Chromium | Firefox (Juggler) | WebKit |
| --- | --- | --- | --- |
| eventos de socket | `Network.webSocket*` | `Page.webSocket*` mais o `Network.requestWillBeSent` com `cause: TYPE_WEBSOCKET` | `Network.webSocket*` |
| identidade do socket | `requestId` | `frameId---wsid` | `requestId` |
| wall time do handshake | `wallTime` | **nao reporta** | `walltime` (t minusculo) |
| erro de frame | `Network.webSocketFrameError` | **nao existe**; so o campo `error` do `Page.webSocketClosed` | `Network.webSocketFrameError` |
| sessao do worker | sub-alvo CDP com `sessionId` proprio | tunel `Page.sendMessageToWorker` | tunel `Worker.sendMessageToWorker` |
| contexto do worker | `Runtime.executionContextCreated` | `Runtime.executionContextCreated` | **nenhum**: usa-se o contexto implicito |

Divergencias que o teste prova em vez de esconder:

1. **O `wallTimeMs` do handshake e nulo no Firefox**, e nao zero. O
   `Page.webSocketOpened` do Juggler nao carrega timestamp nenhum, e o
   handshake dele chega pela camada de rede, que tambem nao tem. Chromium e
   WebKit dao o valor; o campo fica `null` no Firefox, seguindo a mesma regra
   do `-1` de tamanho de header.
2. **Um handshake recusado vira dois sockets no Firefox.** A camada de rede
   ve a resposta >= 400 e sintetiza o socket inteiro (`ffPage.ts:143`),
   enquanto o Juggler reporta separadamente `Page.webSocketCreated` e um
   `Page.webSocketClosed` com `error: CLOSE_ABNORMAL`. Os dois erros sao
   reais e o upstream tambem reporta os dois. Chromium reporta um socket com
   um erro so (`Error during WebSocket handshake: Unexpected response code:
   404`) e WebKit reporta um socket com dois (`Not Found: 404`, vindo da
   resposta, e `Unexpected response code: 404`, vindo do frame error). O
   teste `Handshake recusado vira socketerror e close` afirma exatamente isso
   por motor.
3. **No Firefox o handshake deixou de aparecer como request comum.** Ele era
   o unico motor que reportava a requisicao de upgrade em `page.onRequest`;
   o upstream filtra isso "para alinhar com Chromium e WebKit"
   (`ffNetworkManager.ts:71`) e agora este porte tambem. E uma mudanca de
   comportamento visivel, e e a fiel.
4. **`close()` sem codigo chega ao handler como nulo**, nao como 1000. O
   `undefined` do upstream e o que `WebSocketRoute.onClose` recebe; 1000 e o
   que o browser poria no fio. O teste `Fechamento sem codigo chega como
   nulo` existe para que ninguem "conserte" isso depois.

### Decisoes de desenho que fogem do upstream

- **O stream de `websocket` e de `worker` da pagina e sincrono.** O
  `EventEmitter` do Node entrega na hora, entao
  `page.on("websocket", ws => ws.on("socketerror", ...))` do upstream nunca
  perde nada. Com a entrega assincrona padrao dos `Stream` do Dart, um socket
  que erra no mesmo turno em que nasce - exatamente o handshake recusado -
  ficava invisivel: a primeira versao deste teste media o proprio porte, nao
  o motor. O `EventEmitter.stream` ganhou um parametro `sync`, usado so
  nesses dois eventos.
- **Nao ha camada de dispatcher.** O `webSocketRouteDispatcher.ts` foi
  portado como comportamento, nao como RPC: o binding
  `__pwWebSocketBinding` e o `__pwWebSocketDispatch` sao os do upstream; o
  canal que os ligava nao existe aqui.
- **O auto-attach de worker no Chromium usa
  `waitForDebuggerOnStart: false`**, onde o upstream usa `true`. A razao e a
  mesma ja registrada para o auto-attach de nivel de browser: um alvo pausado
  que ninguem retoma trava a pagina, e o `Runtime.enable` reapresenta o
  contexto de execucao de qualquer forma. O preco e o mesmo que o upstream
  paga nos Chromium anteriores a 143: mensagens de console emitidas antes de
  a sessao do worker existir se perdem.
- **`WkExecutionContext` e `FfExecutionContext` passaram a aceitar uma
  interface de sessao** (`WkTargetSession`, `FfProtocolSession`) em vez da
  sessao concreta da pagina, porque a sessao do worker e um tunel com
  despacho proprio. O upstream resolve isso com um `rawSend` injetado no
  construtor da sessao; o efeito e o mesmo.

### O que ficou de fora, e por que

- **Console do worker.** O upstream encaminha as mensagens do worker para
  `page.addConsoleMessage(worker, ...)` e expoe `worker.on("console")`
  apenas para o `chromium._connectToWorker`. O pipeline de console deste
  porte e por pagina e monta o texto a partir do objeto remoto, sem
  atribuicao a worker; ligar os dois e uma mudanca no console, nao no worker,
  e nao cabia nesta rodada.
- **Service workers**: `context.serviceWorkers()` e o evento
  `serviceworker`. No upstream isso e so Chromium e depende do alvo de
  service worker em nivel de browser, com um `crServiceWorker` proprio que
  tem network manager separado. E uma frente inteira.
- **`chromium._connectToWorker`** e `worker.waitForEvent("console")`, pelo
  mesmo motivo do console.
- **Remover uma rota de websocket.** O upstream nao tem `unrouteWebSocket`
  publico e o `unrouteAll` dele nao mexe em `_webSocketRoutes`, entao nao ha
  o que portar; vale registrar mesmo assim que este porte nao sabe remover um
  init script, logo o mock injetado fica instalado ate a pagina morrer. Sem
  handler que case, todo socket segue em `passthrough`, que e o que um socket
  nao roteado faz de qualquer jeito.
- **O casamento de URL e o glob simplificado deste porte**
  (`CorePageRoutes.matchesPattern`), o mesmo que `page.route` ja usava, e nao
  o `URLPattern` completo do upstream. A limitacao e anterior a esta rodada.

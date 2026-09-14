# Changelog

## Unreleased

### Fixtures proprias

- `defineFixture(name, setUp, tearDown:, scope:)` declara uma fixture. O objeto
  devolvido e a chave tipada: `t.use(chave)` devolve `Future<T>`, sem cast e
  sem geracao de codigo.
- `FixtureScope.test` (padrao) e `FixtureScope.worker` (uma vez por arquivo e
  motor, desfeita pelo `playwrightGroup`).
- O teardown roda na ordem inversa do setup, **inclusive quando o teste falha**.
- `FixtureContext` da as fixtures embutidas mais `use` e `onTeardown`, entao uma
  fixture compoe com outra.
- `defineOption(name, padrao)` e `opcao.overrideWith(valor)` para fixtures de
  opcao; `fixture.asAuto` para as automaticas. Ambos entram em
  `PlaywrightTestOptions.fixtures`.

### storageState

- `StorageState(path:, logIn:, verify:, maxAge:)` loga uma vez e reaplica o
  estado a cada contexto, via `PlaywrightTestOptions.storageState`.
- Estado vencido e detectado por cookie expirado no arquivo, por idade do
  arquivo e por `verify`, que refaz o login uma unica vez.

### test.step

- `step(titulo, corpo)` grava um par `before`/`after` como
  `Tracing.tracingGroup`, que o visualizador oficial desenha. As acoes de
  dentro aninham embaixo do passo, e passos aninham entre si.

### Assertions

- Novos matchers de locator: `toHaveCSS`, `toHaveId`, `toHaveJSProperty`,
  `toHaveValues`, `toBeInViewport`, `toHaveAccessibleName`,
  `toHaveAccessibleDescription` e `toHaveRole`.
- `expectPoll(funcao, matcher)` repete uma funcao ate a condicao valer.
- `.soft` nas classes de assertion acumula a falha e derruba o teste no fim com
  todas juntas.
- Argumento invalido (um `toHaveValues` sobre um `<select>` sem `multiple`)
  sobe na hora em vez de esperar o prazo inteiro.

### Web server

- `PlaywrightWebServer.start(...)` starts the server that serves the app under
  test and `stop()` takes it down. Port-only and URL probes follow upstream's
  `webServer` plugin; `readyUrl` and `readyBody` add what upstream has no
  reason to: a wait that measures the dart2js build instead of the socket.
- Shutdown kills the whole process tree (`taskkill /T` on Windows, children
  first on POSIX) and does not return until the port is free.
- `reuseExistingServer` defaults to upstream's rule: reuse outside CI, refuse
  on CI.
- `playwrightGroup(..., webServer: ...)` starts one for the group and hands it
  to the bodies as `PlaywrightFixtures.webServer`, stopping it after the
  browsers close.

### Dart stack traces from the browser

- `translateDartStackTrace` / `DartSourceMapResolver` rewrite dart2js frames
  (`main.dart.js:4821:3`) to `main.dart:11:3` using the source map the
  compiler emits, folding runtime frames with `Trace.terse`.
- Source maps are cached per URL, and a missing or unreadable one degrades to
  the original trace with a note instead of failing.
- A failing `playwrightTest` gets the page's uncaught errors appended already
  translated. `PlaywrightTestOptions.translateDartStackTraces` turns it off.

## 0.1.0

First release.

### Fixtures

- `playwrightTest(description, body, options:)` runs a body once per engine
  named in the options, each as its own `dart test` case.
- `playwrightGroup(description, body)` closes the browsers the group opened.
- `PlaywrightFixtures` carries `browserName`, `browser`, `context` and `page`.
  The browser is shared per file and engine; the context and page are created
  fresh for each test and closed after it.
- `PlaywrightTestOptions` carries `browsers`, `headless`, `viewport`,
  `locale`, `timezoneId`, `colorScheme`, `hasTouch` and `artifactsPath`.
- A full-page screenshot is written when a test fails, and its path is added
  to the error.

### Assertions

All locator and page assertions retry until they pass or their timeout runs
out, and every one accepts `.not`.

- Locator: `toBeVisible`, `toBeHidden`, `toBeAttached`, `toBeEnabled`,
  `toBeDisabled`, `toBeEditable`, `toBeChecked`, `toBeFocused`, `toBeEmpty`,
  `toHaveText`, `toContainText`, `toHaveValue`, `toHaveAttribute`,
  `toHaveClass`, `toHaveCount`.
- Page: `toHaveTitle`, `toHaveURL`.
- API response: `toBeOK`.
- A failure reports both what was expected and what was last seen.

### Not included

This is a layer over `package:test`, not a runner: `dart test` keeps its CLI,
its reporters, its filtering and its parallelism. Video and trace on failure,
snapshot and screenshot assertions, projects, sharding and custom fixtures are
not here; the README says why for each.

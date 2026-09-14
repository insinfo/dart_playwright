# playwright_test

[![CI](https://github.com/insinfo/dart_playwright/actions/workflows/ci.yml/badge.svg)](https://github.com/insinfo/dart_playwright/actions/workflows/ci.yml)
[![AI Assisted](https://img.shields.io/badge/AI-Assisted-purple.svg)](https://github.com/insinfo/dart_playwright#how-this-package-was-built)

Browser fixtures and retrying assertions for
[Playwright for Dart](https://pub.dev/packages/playwright), on top of
`package:test`.

```dart
import 'package:playwright_test/playwright_test.dart';

void main() {
  playwrightGroup('example.com', () {
    playwrightTest('the heading is there', (t) async {
      await t.page.goto('https://example.com');
      await expectLocator(t.page.getByRole('heading')).toBeVisible();
      await expectPage(t.page).toHaveTitle(RegExp('Example'));
    });
  });
}
```

```bash
dart test
```

## This is a layer, not a runner

`@playwright/test` in Node is a test runner of its own: its own CLI, its own
config, its own reporters, its own parallelism. This is deliberately not
that. `dart test` already runs tests, reports them, filters them by name and
tag, retries them and runs them in parallel, and a second runner competing
with it would be worse than either.

What this package adds is the part `dart test` cannot know about: the browser
lifecycle, a clean page per test, assertions that retry, and a screenshot when
something fails.

## Fixtures

`playwrightTest` gives the body a `PlaywrightFixtures` with `browserName`,
`browser`, `context` and `page`.

- The **browser** is shared by every test in the file, per engine, and is
  launched on first use. `playwrightGroup` closes them when the group ends —
  call it once around your tests, or the browsers stay open until the process
  exits.
- The **context and page** are created fresh for each test and closed after
  it, so nothing leaks between tests: no cookies, no storage, no leftover
  tabs.

Run one body against several engines by naming them:

```dart
playwrightTest('works everywhere', (t) async {
  ...
}, options: const PlaywrightTestOptions(
     browsers: ['chromium', 'firefox', 'webkit']));
```

Each engine becomes a separate `dart test` case, so a failure names the engine
and `--name` can select one.

`PlaywrightTestOptions` also carries `headless`, `viewport`, `locale`,
`timezoneId`, `colorScheme`, `hasTouch` and `artifactsPath`.

## Your own fixtures

`defineFixture` declares a value with setup, teardown and scope. The object it
returns **is the key**: `t.use(key)` gives back the value, typed.

```dart
final loggedInPage = defineFixture<Page>('loggedInPage', (f) async {
  await f.page.goto('http://localhost:8080/login');
  await f.page.fill('#user', 'ana');
  await f.page.fill('#pass', 's3cr3t');
  await f.page.click('#entrar');
  await expectLocator(f.page.locator('#painel')).toBeVisible();
  return f.page;
});

playwrightTest('sees the dashboard', (t) async {
  final page = await t.use(loggedInPage);   // Future<Page>, no cast
  await expectLocator(page.locator('#logout')).toBeVisible();
});
```

That is the whole trick, and it is deliberately not `test.extend()`. In JS the
fixtures arrive as one object whose shape the type system grows on every
`extend`; Dart has no such shape, so a literal port would hand every test body
a `dynamic` or an `as` on each fixture — worse than the fixed struct it
replaces. A `Fixture<T>` carries `T`, so `use<T>(Fixture<T>) → Future<T>` is
exact with no code generation and no cast anywhere a test can see.

A fixture's setup receives a `FixtureContext`: the built-in `browserName`,
`browser`, `context` and `page`, plus `use` — which is how a fixture composes
with another one, and `onTeardown` for extra cleanup.

- **Scope.** `FixtureScope.test` (the default) is created per test and torn
  down when it ends, **including when it fails**. `FixtureScope.worker` is
  created once per file and engine and torn down by `playwrightGroup` — the
  place to put what is expensive and shareable. A worker fixture may not use
  `page` or `context`: it would outlive both, and saying so is an error with
  the reason in it rather than a stale handle.
- **Teardown order** is the reverse of setup, so a fixture always goes after
  whatever used it. A failing teardown does not stop the others; the first
  error is the one that surfaces.
- **Automatic fixtures** exist for their effect, not their value. List them in
  the options and they run without being asked:
  `fixtures: [consoleCollector.asAuto]`.
- **Options** are fixtures with a default that a suite can replace:
  `final env = defineOption('env', 'dev');` and
  `fixtures: [env.overrideWith('staging')]`. Only a `FixtureOption` has
  `overrideWith`, so replacing something that is not an option does not
  compile — upstream checks the same rule at runtime.

## Logging in once: `storageState`

`StorageState` runs the login once, writes cookies and localStorage to a file,
and applies them to every test's context:

```dart
final auth = StorageState(
  path: '.auth/user.json',
  logIn: (page) async { /* ... */ },
  verify: (page) async {
    await page.goto('http://localhost:8080/painel');
    return page.locator('#logout').isVisible();
  },
);

playwrightTest('sees the dashboard', (t) async {
  await t.page.goto('http://localhost:8080/painel');
  await expectLocator(t.page.locator('#logout')).toBeVisible();
}, options: PlaywrightTestOptions(storageState: auth));
```

**State expires**, and a file from yesterday makes the whole suite fail with
"not logged in" without saying why. Upstream does not handle this at all: the
file is read, the dead cookies go to the browser, and the tests fail as if the
app were broken. Three layers here, cheapest first:

1. **A cookie in the file that already expired.** The state carries each
   cookie's `expires`; a dead one is visible without opening a browser.
2. **`maxAge`** (8 hours by default) — the file's age on disk. It is a guess,
   since the server decides the real lifetime, but it costs nothing and skips
   a doomed round trip.
3. **`verify`** — the only layer that knows. It opens a throwaway context with
   the state applied and asks the app. When it says no, the login runs again
   and the file is rewritten, **once**. If the freshly made state also fails
   verification, that is a real failure and it is raised with the reason,
   instead of a login loop.

Without `verify` only the first two apply: they cover the common case for
free, but they do not replace asking the app.

## Steps

`step` names a block inside a test and puts it in the trace:

```dart
await t.context.tracing.start(snapshots: true);
await step('checkout', () async {
  await step('fill the address', () async { ... });
  await step('pay', () async { ... });
});
await t.context.tracing.stop(path: 'trace.zip');
```

Each step is a `before`/`after` pair written as `Tracing.tracingGroup`, which
is what `tracing.group()` writes upstream and what `npx playwright show-trace`
knows how to draw. The actions inside a step nest under it, and so do nested
steps. `step` returns whatever its body returned, and re-raises a failure
unchanged — the step turns red in the trace and the error stays the error the
matcher threw. With no trace recording on, it just runs the body.

## Assertions

Every locator and page assertion **retries** until it passes or its timeout
runs out (5 seconds by default). That is not a convenience: an assertion that
reads a live page once is a flaky test waiting to happen.

```dart
await expectLocator(t.page.locator('#status')).toHaveText('Ready');
await expectLocator(t.page.locator('#spinner')).not.toBeVisible();
await expectPage(t.page).toHaveURL(RegExp(r'/done$'));
await expectResponse(await t.context.request.get('/api/health')).toBeOK();
```

| On a locator | On a page | On a response |
| --- | --- | --- |
| `toBeVisible`, `toBeHidden`, `toBeAttached` | `toHaveTitle` | `toBeOK` |
| `toBeEnabled`, `toBeDisabled`, `toBeEditable` | `toHaveURL` | |
| `toBeChecked`, `toBeFocused`, `toBeEmpty` | `toMatchAriaSnapshot` | |
| `toBeInViewport` | | |
| `toHaveText`, `toContainText`, `toHaveValue` | | |
| `toHaveValues`, `toHaveAttribute`, `toHaveClass` | | |
| `toHaveCount`, `toHaveId`, `toHaveCSS` | | |
| `toHaveJSProperty`, `toHaveRole` | | |
| `toHaveAccessibleName`, `toHaveAccessibleDescription` | | |
| `toMatchAriaSnapshot` | | |

All of them accept `.not`, and a `String` or a `RegExp` wherever a pattern
fits. A failure says both what was expected and what was last seen — an
assertion message that only says "expected visible" sends you back to the
browser to find out whether the element was hidden, detached, or never there.

Two notes where this differs from upstream, both documented on the methods:
`toBeInViewport` computes the visible fraction from rectangles (the element's
and every clipping ancestor's) instead of an `IntersectionObserver`, because a
locator evaluation in this port does not await a promise; and
`toHaveAccessibleDescription` falls back to the text content of an
`aria-describedby` target, since the accessible name of a plain `<span>` is
empty by definition.

### `expectPoll`

For what is not a locator and still takes time to become true — upstream's
`expect.poll`. It takes a `package:test` matcher and retries on the same
schedule upstream uses (100ms, 250ms, 500ms, then every second):

```dart
await expectPoll(
  () async => (await t.context.request.get('/api/jobs/7')).status(),
  equals(200),
);
```

An exception from the function counts as "not yet", and its message is in the
failure if the deadline passes.

### `.soft`

`expectLocator(l).soft.toBeVisible()` records the failure and lets the test
keep going; the test then **fails at the end** with every soft failure it
collected. This is upstream's `expect.soft`, moved to a getter because Dart
cannot hang a member off `package:test`'s `expect`.

The collected failures are raised from an `addTearDown` registered on the first
one, which is what keeps `dart test`'s report intact: the failure belongs to
that test, with the full message, and no second runner is involved. A soft
failure also takes the failure screenshot, since the body did not stop to let
`playwrightTest` take it.

## Screenshot on failure

When a test fails, a full-page screenshot is written under `artifactsPath`
(`test-results` by default) and its path is added to the error. Set
`artifactsPath: null` to turn it off.

Video on failure is **not** here: the port does not record video yet. Trace
recording exists (`context.tracing`, and `step` writes into it), but turning it
on and keeping only the failing runs is still something you wire yourself.

## Web server

Testing a Dart web app means having it **served and compiled** on a known port
before the first test. `PlaywrightWebServer` starts that server, waits for it,
and kills it afterwards.

```dart
late PlaywrightWebServer server;

setUpAll(() async {
  server = await PlaywrightWebServer.start(
    command: 'webdev serve web:8080 --release',
    url: 'http://127.0.0.1:8080/',
    readyUrl: 'http://127.0.0.1:8080/main.dart.js',
  );
});

tearDownAll(() => server.stop());
```

Or let the group own it, which also guarantees the server outlives the
browsers it was serving:

```dart
playwrightGroup(
  'my app',
  webServer: () => PlaywrightWebServer.start(
    command: 'webdev serve web:8080',
    url: 'http://127.0.0.1:8080/',
  ),
  () {
    playwrightTest('opens', (t) async {
      await t.page.goto(t.webServer!.baseURL);
    });
  },
);
```

Three things separate this from the process spawn everybody writes by hand:

- **It waits for the build, not for the socket.** Measured here against
  `webdev serve` 3.7.1: the port opens **7.8 s before** the first successful
  HTTP request on a cold build (15.2 s vs 23.0 s), and 0.6 s before it on a
  warm one. So upstream's port-only mode returns far too early, while its
  `url` mode returns at the right moment — `build_runner` holds requests
  until the build finishes, so a 200 from it already means "compiled".
  `readyUrl` is for the other way to serve a Dart app: a plain file server in
  front of `dart compile js` output, which answers `index.html` immediately
  and 404s the bundle while the compiler runs. Point it at the artifact that
  only exists after the build. `readyBody` tightens it one more notch by
  requiring the response body to match, for a server that answers 200 with a
  "compiling" placeholder. `waitForStdout` and `waitForStderr` are upstream's
  `wait`, for servers that announce themselves.

  With `webdev` in debug mode, note that `main.dart.js` is a small DDC
  bootstrap; the app code is in `main.ddc.js`, with its own `.map`.
- **It kills the process tree.** The command runs under a shell, and tools like
  `webdev` launch the real server in a child of their own. Killing only the
  process the command created leaves the grandchild holding the port, and the
  next run fails on a busy port — on Windows there is no process group to
  signal, so this uses `taskkill /T`. `stop()` does not return until the port
  is actually free.
- **When it does not come up, it says so.** The timeout message carries the
  command, what the probe was looking for, what to try, and the server's own
  stdout and stderr.

`reuseExistingServer` follows upstream's default: outside CI a server already
on the port is reused (that is the development flow, with `webdev` open in
another terminal) and `stop()` leaves it alone; on CI a busy port is an error,
because it is usually a leaked process from the previous run serving stale
code.

Pass `port:` instead of `url:` for upstream's port-only check. It is the weak
mode, and the reason `readyUrl` exists.

## Dart stack traces from the browser

When a Dart app throws in the browser, the error points at
`main.dart.js:4821:3`. The compiler writes `main.dart.js.map` next to the
bundle, and this package uses it:

```
Erro nao capturado na pagina:
Error
dart:_internal  Object.wrapException
main.dart 11:3  Object.explodeDeliberadamente
main.dart 16:3  main.<fn>
```

This runs automatically: a failing `playwrightTest` gets the page's uncaught
errors appended, already translated, and any compiled-JS frames inside the
failure message itself are rewritten too. Turn it off with
`PlaywrightTestOptions(translateDartStackTraces: false)`.

Use it directly with `translateDartStackTrace(stack)`, or keep your own
`DartSourceMapResolver` (`terse: false` keeps the runtime frames that
`Trace.terse` folds away).

- Source maps are **cached per URL**. They are megabytes in a real app, and an
  error that costs a download is an error nobody attaches.
- A missing source map (a release build compiled with `--no-source-maps`) is
  **never a failure**: the original trace comes back with a note saying why.
- Frames from scripts that are not dart2js output are left alone.

## What is missing

Compared to `@playwright/test`:

- **Video on failure** — the port does not record video yet.
- **Trace on failure** — the recorder exists, the automatic
  `trace: 'retain-on-failure'` policy does not.
- **Snapshot and screenshot assertions** (`toMatchSnapshot`,
  `toHaveScreenshot`) — they need an image comparator and a baseline story,
  which is a project of its own.
- **Projects, sharding and global setup/teardown** — `dart test` covers
  parallelism and filtering; the rest is configuration this package
  deliberately does not own.
- **`test.step.skip`, boxed steps and per-step timeouts** — `step` records the
  step and nests it; the reporting knobs around it are upstream's runner, not
  this layer.

## Maturity

This sits on `package:playwright`, which is at **milestone 5 of 5** of the
port but still not at parity with Playwright for Node. Read [that package's
README](https://pub.dev/packages/playwright) for what is missing before you
build a test suite on it.

## How this package was built

Parts of the code, the tests and the documentation were written with the help
of LLM tooling. Everything in the package goes through the test suite
(`dart test`), the analyzer (`dart analyze`) and `dart pub publish --dry-run`
before it lands, and the person who commits it is responsible for it. Treat the
disclosure as information about how the work was produced, not as a disclaimer
about its quality: the checks are the same either way, and so is the
accountability.

## License

Apache License 2.0. See `LICENSE`.

Part of a derivative work of [Playwright](https://github.com/microsoft/playwright),
Copyright (c) Microsoft Corporation, under Apache 2.0. This project is not
produced, endorsed or supported by Microsoft, and "Playwright" is their
trademark, used here only to say what this is compatible with.

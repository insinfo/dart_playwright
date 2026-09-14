# Changelog

## Unreleased

### Web server

- `PlaywrightWebServer.start(...)` starts the server that serves the app under
  test and `stop()` takes it down. Port-only and URL probes follow upstream's
  `webServer` plugin; `readyUrl` and `readyBody` add what upstream has no
  reason to: a wait that measures the dart2js build instead of the socket.
- Shutdown kills the whole process tree (`taskkill /T` on Windows, children
  first on POSIX) and does not return until the port is free.
- `reuseExistingServer` defaults to upstream's rule: reuse outside CI, refuse
  on CI.

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

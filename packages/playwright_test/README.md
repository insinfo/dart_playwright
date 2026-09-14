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
| `toBeChecked`, `toBeFocused`, `toBeEmpty` | | |
| `toHaveText`, `toContainText`, `toHaveValue` | | |
| `toHaveAttribute`, `toHaveClass`, `toHaveCount` | | |

All of them accept `.not`, and a `String` or a `RegExp` wherever a pattern
fits. A failure says both what was expected and what was last seen — an
assertion message that only says "expected visible" sends you back to the
browser to find out whether the element was hidden, detached, or never there.

## Screenshot on failure

When a test fails, a full-page screenshot is written under `artifactsPath`
(`test-results` by default) and its path is added to the error. Set
`artifactsPath: null` to turn it off.

Video and trace on failure are **not** here: the port does not record either
yet. When it does, they will land in this package.

## What is missing

Compared to `@playwright/test`:

- **Video and trace on failure** — the port has neither yet.
- **Snapshot and screenshot assertions** (`toMatchSnapshot`,
  `toHaveScreenshot`) — they need an image comparator and a baseline story,
  which is a project of its own.
- **`ariaSnapshot` assertions** — need the ARIA snapshot the port has not
  finished.
- **Projects, sharding, global setup/teardown, web server management** —
  `dart test` covers parallelism and filtering; the rest is configuration this
  package deliberately does not own.
- **Custom fixtures** — `PlaywrightFixtures` is a fixed set, not an
  extensible dependency-injected one.

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

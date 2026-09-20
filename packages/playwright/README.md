# playwright

[![CI](https://github.com/insinfo/dart_playwright/actions/workflows/ci.yml/badge.svg)](https://github.com/insinfo/dart_playwright/actions/workflows/ci.yml)
[![AI Assisted](https://img.shields.io/badge/AI-Assisted-purple.svg)](https://github.com/insinfo/dart_playwright#how-this-package-was-built)

Browser automation for Chromium, Firefox and WebKit, implemented natively in
Dart.

This is a port of [Playwright](https://playwright.dev), not a client for it.
There is no Node.js driver in the loop: the browser registry, the process
launch, the pipe transport and the three protocol adapters (Chrome DevTools
Protocol, Firefox's Juggler, WebKit's inspector protocol) are all written in
Dart. A Dart CLI, server or agent can drive a real browser without treating
Node as its control plane.

## Read this before you install

**This port is at milestone 5 of 5. It is not at parity with Playwright for
Node, and installing it expecting parity will disappoint you.**

What works today is the core automation path, proven end to end on all three
engines: launching browsers, contexts and pages, navigation and history,
frames and frame locators, the full `Locator` surface with `getBy*` and
auto-waiting actionability, real protocol-level mouse and keyboard input,
network events and request interception, cookies and `storageState`, dialogs,
console messages, page errors, popups and the events and waiters around them.
Milestone 3 added the rest of `Request`/`Response`/`Route`, file uploads and
the file chooser, downloads, screenshot options with per-element capture,
`page.pdf` on Chromium, and an `APIRequestContext` that shares the browser
context's cookie jar.
Milestone 4 added the context emulation options (`locale`, `timezoneId`,
`colorScheme`, `reducedMotion`, `forcedColors`, `deviceScaleFactor`,
`isMobile`, `hasTouch`, `offline`, `extraHTTPHeaders`, `httpCredentials`,
`geolocation`, `permissions`), the touchscreen with `tap`, a `devices`
catalogue and `setTestIdAttribute`.

What is **missing**, and will stay missing until later milestones:

| Missing | Milestone |
| --- | --- |
| Tracing and video recording | 3 |
| Screenshot `mask`, `caret`, `animations`, `omitBackground`, `style` | 3 |
| Multipart uploads and `storageState` on `APIRequestContext` | 3 |
| Worker console messages, and service workers (`context.serviceWorkers`) | 3 |
| Context options: proxy, `forcedColors` on Chromium's older builds, `screen`, `videosPath` | 4 |
| `Clock`, `Coverage`, `Selectors.register` | 4 |
| `addInitScript`, `exposeFunction`, `exposeBinding` | 4 |
| `BrowserType.connect`, `connectOverCDP`, `launchPersistentContext`, `launchServer` | 4 |
| Snapshot and screenshot assertions, `ariaSnapshot` | 5 |
| Codegen, UI mode, trace viewer, inspector | not planned yet |
| Android, Electron, WebView | not planned yet |

One protocol limitation worth knowing: `page.evaluate` of an expression that
returns a promise resolves it on Chromium and WebKit, but **not on Firefox**
— Juggler's `Runtime.evaluate` has no `awaitPromise` flag and no equivalent
command. On Firefox, have the page store the result and poll for it with
`waitForFunction`.

Also deliberately partial: the `css` selector engine uses the browser's native
`querySelectorAll`, so it does not pierce shadow DOM and does not understand
Playwright's CSS extensions (`:has-text()`, `:visible`, layout selectors). The
`text`, `label` and `role` engines do enter open shadow roots, and
`filter(hasText:)`, `visible()` and the `getBy*` helpers cover the common
cases. Actionability checks `visible`, `stable`, `enabled` and `editable`, but
not yet `receivesPointerEvents`, so an element covered by another is still
clicked.

If any of the above is on your critical path, use the Node Playwright for now.

## Install

```yaml
dependencies:
  playwright: ^0.1.0
```

Then download the browser binaries. They come from the same CDN the upstream
project uses and are not bundled with this package:

```bash
dart run playwright install chromium firefox webkit
dart run playwright list
```

## Example

```dart
import 'package:playwright/playwright.dart';

Future<void> main() async {
  final playwright = await Playwright.create();
  final browser = await playwright.chromium.launch(headless: true);

  try {
    final context = await browser.newContext();
    final page = await context.newPage();

    page.onConsole.listen((message) {
      print('[${message.type()}] ${message.text()}');
    });

    await page.goto('https://example.com');
    print(await page.title());
    print(await page.getByRole('heading').textContent());

    // Start the wait before the action that triggers it.
    final popup = page.waitForPopup();
    await page.getByRole('link', name: 'More information').click();
    print(await (await popup).title());
  } finally {
    await browser.close();
  }
}
```

## The other packages

| Package | What it is |
| --- | --- |
| `playwright` | This one. The API you write against. |
| `playwright_core` | Browser registry, transport and the three engine drivers. A dependency, not something you import directly. |
| `playwright_protocol` | Protocol envelopes, errors and the event emitter shared by both. |
| `playwright_test` | Browser fixtures and retrying assertions on top of `package:test`. |
| `playwright_mcp` | A Model Context Protocol server that drives this port. |

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

This is a derivative work of [Playwright](https://github.com/microsoft/playwright),
Copyright (c) Microsoft Corporation, which is itself derived from Puppeteer,
Copyright 2017 Google Inc. — both under Apache 2.0. The `NOTICE` file that
ships with this package lists what was ported and how it was modified.

This project is not produced, endorsed or supported by Microsoft. "Playwright"
is a trademark of Microsoft Corporation, used here only to say what this is
compatible with.

# Playwright for Dart

[![CI](https://github.com/insinfo/dart_playwright/actions/workflows/ci.yml/badge.svg)](https://github.com/insinfo/dart_playwright/actions/workflows/ci.yml)
[![AI Assisted](https://img.shields.io/badge/AI-Assisted-purple.svg)](https://github.com/insinfo/dart_playwright#how-this-package-was-built)

A native Dart port of Playwright focused on browser automation across Chromium,
Firefox, and WebKit.

This repository is organized as a Dart workspace and provides the public
`playwright` API, a protocol/core implementation, browser binary management, and
an experimental MCP server package.

## Why This Port Exists

Most Playwright ports are thin client bindings around the upstream Node.js
driver. This project takes a different path: it implements the browser launch,
transport, registry, and engine protocol layers directly in Dart.

That means Dart applications can automate browsers without treating Node.js as
the runtime control plane.

## Packages

| Package | Purpose | Published |
| --- | --- | --- |
| `packages/playwright` | User-facing Dart API. | yes |
| `packages/playwright_core` | Browser registry, process transport, and engine-specific implementations for Chromium, Firefox, and WebKit. | yes, as a dependency of `playwright` |
| `packages/playwright_protocol` | Shared protocol types, transport types, errors, and event utilities. | yes, as a dependency of the two above |
| `packages/playwright_mcp` | Model Context Protocol server backed by this Playwright Dart implementation. | yes |
| `packages/playwright_test` | Browser fixtures and retrying assertions on top of `package:test`. | yes |

All five are published. `playwright_mcp` was internal for a while — it had no
public library, no tests, and six tools sitting on an API that was still
moving. It now has a public library, twenty-two tools, dual-era MCP version
negotiation, and protocol tests that run the server as a real process and
speak JSON-RPC over the pipe.

## Current Capabilities

- Launch Chromium, Firefox, and WebKit from Dart.
- Install official Playwright browser binaries with `dart run playwright install`.
- Use isolated browser contexts, pages, frames, locators, element handles, JS
  handles, requests, responses, routes, dialogs, and console messages.
- Navigate pages, evaluate JavaScript, inspect text/content/URL state, take
  screenshots, and interact with forms.
- Dispatch real protocol-level mouse and keyboard input, including trusted
  click/input events, special keys, chords, and `ControlOrMeta`.
- Intercept network routes with continue, fulfill, and abort support.
- Manage cookies and capture `storageState()` with cookies plus localStorage.
- Record a trace the official viewer opens: `context.tracing.start(...)`,
  then `npx playwright show-trace trace.zip`. Actions, network, console, DOM
  snapshots of every frame, and the Dart source of each call.
- Run browser parity tests across Chromium, Firefox, and WebKit.
- Exercise CI on Linux, Windows, and macOS.

## Installation

From the workspace root:

```bash
dart pub get
dart run playwright install chromium firefox webkit
```

List installed browsers:

```bash
dart run playwright list
```

Run the test suite:

```bash
dart analyze packages
dart test packages/playwright/test packages/playwright_core/test packages/playwright_mcp/test packages/playwright_test/test --timeout 180s
```

Test an unpacked Chromium extension:

```bash
dart run examples/extension_smoke.dart path/to/extension
dart run examples/web_canvas_smoke.dart http://localhost:8787 captura.png
```

The Chromium launcher exposes `ignoreDefaultArgs`, `executablePath`,
`userDataDir`, and `extensionPaths`. Firefox requires a signed add-on for
permanent installation; use `about:debugging` or Mozilla's `web-ext` for a
temporary development install.
`userDataDir`; extension tests normally remove `--disable-extensions` and pass
`--disable-extensions-except` plus `--load-extension`.

## Quick Example

```dart
import 'package:playwright/playwright.dart';

Future<void> main() async {
  final playwright = await Playwright.create();
  final browser = await playwright.chromium.launch(headless: true);

  try {
    final context = await browser.newContext();
    final page = await context.newPage();

    await page.goto('https://example.com');

    print(await page.title());
    print(await page.locator('h1').textContent());
  } finally {
    await browser.close();
  }
}
```

## Architecture

This port is split into three main layers:

1. Public API: ergonomic Dart classes exposed by `package:playwright`.
2. Core layer: browser registry, process launch, transport, contexts, pages, and
   engine-specific protocol adapters.
3. Protocol layer: shared typed protocol structures and event infrastructure.

Browser communication is implemented per engine:

- Chromium uses Chrome DevTools Protocol over `--remote-debugging-pipe`.
- Firefox uses Playwright's Juggler protocol.
- WebKit uses the Playwright WebKit protocol.

The transport layer supports the Playwright-style fd3/fd4 pipe model on Linux,
macOS, and Windows. On Windows, the implementation uses named pipes passed to
the child process; on POSIX systems it uses FIFO-backed descriptors.

## Comparison With `devsdocs/playwright-dart`

The competing `devsdocs/playwright-dart` analysis describes a Dart SDK that
communicates with the Playwright Node.js driver via JSON-RPC over stdio. Its own
architecture summary states that the Node.js driver executes browser automation,
while Dart wrapper classes forward commands to that driver.

This repository has a different advantage:

| Area | This Port | `devsdocs/playwright-dart` Analysis |
| --- | --- | --- |
| Runtime model | Native Dart control plane. Browser processes and protocol transports are implemented in Dart. | Dart wrappers talk to the Playwright Node.js driver over JSON-RPC. |
| Node.js dependency | No Node.js driver is required for normal browser automation. | Node.js driver is central to browser execution. |
| Engine implementation | Contains engine-specific Dart implementations for Chromium, Firefox, and WebKit. | Delegates engine behavior to upstream Playwright's Node driver. |
| Transport | Implements native pipe/WebSocket transport, including fd3/fd4 handling across Windows, Linux, and macOS. | Uses JSON-RPC over stdio to the Node driver. |
| Browser registry | Downloads and resolves browser binaries from Dart. | Browser management is tied to the driver-based architecture. |
| Embedding story | Better fit for Dart CLIs, servers, tools, and agents that want a pure Dart automation stack. | Better fit for projects that prefer upstream Node driver parity over native implementation. |
| MCP integration | Includes a dedicated `playwright_mcp` package. | Not highlighted in the referenced analysis. |

In short: the competitor's strongest point is likely API breadth through the
official Node driver. This project's strongest point is ownership of the Dart
runtime path: fewer moving pieces outside Dart, deeper control of browser
transport, and a foundation for Dart-native automation tooling.

## Status: milestone 5 of 5

This port is **not at parity with Playwright for Node**, and it is worth being
blunt about it before anyone builds on it.

What works is the core automation path, proven end to end on all three engines:
launch, contexts and pages, navigation and history, frames with per-frame
execution contexts, the full `Locator` surface with `getBy*` and auto-waiting
actionability, trusted mouse and keyboard input, network events and request
interception, cookies and `storageState`, and the page/context/browser event
model with its waiters. Milestone 3 added the rest of
`Request`/`Response`/`Route`, file uploads and the file chooser, downloads,
screenshot options with per-element capture, `page.pdf` on Chromium, and an
`APIRequestContext` sharing the browser context's cookie jar. Milestone 4 added the context emulation options (`locale`, `timezoneId`, `colorScheme`, `reducedMotion`, `forcedColors`, `deviceScaleFactor`, `isMobile`, `hasTouch`, `offline`, `extraHTTPHeaders`, `httpCredentials`, `geolocation`, `permissions`), the touchscreen with `tap`, a `devices` catalogue and `setTestIdAttribute`. Milestone 5 added the `playwright_test` package and a real accessibility tree: `page.accessibilitySnapshot()` and `page.ariaSnapshot()` answer on all three engines with the same ARIA roles, accessible names and states, computed in the page by the injected script — the two upstream ports to check it are `injected/ariaSnapshot.ts` and the `normalizePlugins` of `ariaSnapshotDistiller.ts`.

What is missing:

| Missing | Milestone |
| --- | --- |
| Video recording, and the screencast filmstrip of the trace viewer | 3 |
| Screenshot `mask`, `caret`, `animations`, `omitBackground`, `style` | 3 |
| Multipart uploads and `storageState` on `APIRequestContext` | 3 |
| `WebSocket`, `WebSocketRoute`, `Worker` | 3 |
| Context options: proxy, `forcedColors` on Chromium's older builds, `screen`, `videosPath` | 4 |
| `Clock`, `Coverage`, `Selectors.register` | 4 |
| `addInitScript`, `exposeFunction`, `exposeBinding` | 4 |
| `BrowserType.connect`, `connectOverCDP`, `launchPersistentContext`, `launchServer` | 4 |
| Screenshot assertions (`toHaveScreenshot`) | 5 |
| Codegen, UI mode, inspector | not planned yet |
| Android, Electron, WebView | not planned yet |

One thing the accessibility tree does **not** give you, on any engine: the
browser's own accessibility tree. `page.accessibilitySnapshot()` and
`page.ariaSnapshot()` compute ARIA roles and accessible names from the DOM, in
the page, with the same injected code everywhere — which is how the three
engines agree, and is what upstream Playwright does since it removed
`page.accessibility.snapshot()` and its three per-engine protocol backends. If
you need to know what a platform screen reader would announce, that question
is outside what any Playwright, this one included, answers.

One protocol limitation worth knowing: `page.evaluate` of an expression that
returns a promise resolves it on Chromium and WebKit, but **not on Firefox**
— Juggler's `Runtime.evaluate` has no `awaitPromise` flag and no equivalent
command. On Firefox, have the page store the result and poll for it with
`waitForFunction`.

The `css` selector engine runs the ported `selectorEvaluator`, so it supports
Playwright's CSS extensions (`:has-text()`, `:text()`, `:text-is()`,
`:text-matches()`, `:visible`, `:has()`, `:is()`/`:where()`, `:not()`,
`:scope`, `:nth-match()`, `:left-of()`, `:right-of()`, `:above()`, `:below()`,
`:near()` and `:light()`) and pierces open shadow roots, the same as the
`text`, `label` and `role` engines. Closed shadow roots stay invisible, as
upstream. Deliberately partial: actionability
checks `visible`, `stable`, `enabled` and `editable` but not
`receivesPointerEvents`, so an element covered by another is still clicked.

Tracing records into upstream's own format, so `npx playwright show-trace`
opens what this port writes — there is no viewer here, and there should not be
one. Two differences are worth knowing before you rely on it: `screenshots:
true` captures a PNG per action phase rather than upstream's screencast
filmstrip (that needs `Page.startScreencast`, which is not ported), and the DOM
snapshot streamer is installed on first capture instead of before the page's
own scripts, because `addInitScript` is not ported yet — so a stylesheet edited
through `insertRule`/`replaceSync` before the first capture is not overridden
in the snapshot. See `doc/07_API_PUBLICA.md`.

`doc/11_RELATORIO_GAPS_PLAYWRIGHT_ORIGINAL.md` tracks the gap in detail.

## Development Notes

Useful commands:

```bash
dart pub get
dart analyze packages
dart run playwright install chromium firefox webkit
dart test packages/playwright/test packages/playwright_core/test packages/playwright_mcp/test packages/playwright_test/test --timeout 180s
```

From the workspace root a bare `dart test` does not pick the packages up; name
the test directories, as above.

### What CI actually runs

Being precise, because "CI is green" means different things in different
repositories:

- `dart analyze packages` on Ubuntu.
- `dart format --output=none --set-exit-if-changed` on Ubuntu only. The
  formatter changes between Dart releases, so this gate is pinned to one SDK.
- `dart doc` for each published package, on Ubuntu, failing unless the output
  says `Found 0 warnings and 0 errors` — `dart doc` exits 0 even when it warns,
  so the exit code alone would prove nothing.
- `dart pub publish --dry-run` for each published package, on Ubuntu.
- **The full parity suite — 410 tests, on Chromium, Firefox and WebKit — on
  Ubuntu, Windows and macOS**, plus the MCP protocol tests, which start the
  server as a real process and drive a browser through it. All three engines
  really are launched on all three operating systems; the browsers come from
  this repository's own Dart registry, not from an npm install.

What CI does not cover: headful mode (everything runs headless) and
architectures other than x64.

## How this package was built

Parts of the code, the tests and the documentation were written with the help
of LLM tooling. Everything in the package goes through the test suite
(`dart test`), the analyzer (`dart analyze`) and `dart pub publish --dry-run`
before it lands, and the person who commits it is responsible for it. Treat the
disclosure as information about how the work was produced, not as a disclaimer
about its quality: the checks are the same either way, and so is the
accountability.

## License and attribution

Apache License 2.0 — see `LICENSE`.

This is a derivative work of [Playwright](https://github.com/microsoft/playwright),
Copyright (c) Microsoft Corporation, under Apache 2.0, which is itself derived
from Puppeteer, Copyright 2017 Google Inc. `NOTICE` lists the files ported from
upstream and how each was modified, and a copy of both files travels inside
every published package, as Apache 2.0 section 4 requires.

`referencias/` holds read-only clones of the upstream projects used while
porting — `playwright-typescript` (Apache 2.0, 107 MB) and `playwright-dotnet`
(MIT, 19 MB). Both are gitignored and outside every package, so they are in
neither the repository nor the published archives.

This project is not produced, endorsed or supported by Microsoft. "Playwright"
is a trademark of Microsoft Corporation; Apache 2.0 section 6 grants no
trademark rights, and the name is used here only to say what this is
compatible with.

### Dependency licenses

Read from the local pub cache, not guessed:

| Dependency | License |
| --- | --- |
| `path`, `crypto`, `logging`, `collection`, `async`, `meta`, `args`, `http`, `web_socket_channel`, `ffi` | BSD-3-Clause (Dart project authors) |
| `archive` | MIT |
| `win32` | BSD-3-Clause |
| **`stdlibc`** | **MPL-2.0 — weak copyleft** |

`stdlibc` is the only copyleft dependency, and it is worth being explicit about
it. It is used by `playwright_core` for the POSIX FIFO pair behind the fd3/fd4
browser transport. MPL-2.0 is file-level copyleft: its own files stay under
MPL-2.0 if modified, but section 3.3 allows a larger work built on it to be
distributed under other terms, so it does not change this project's license. No
`stdlibc` source is copied or vendored here — it is an ordinary pub dependency
resolved at install time.

The browser binaries downloaded by `dart run playwright install` are not
covered by this license. Each carries its own: Chromium is BSD-3-Clause plus
third-party licenses, Firefox is MPL-2.0, WebKit is LGPL-2.1/BSD, and the
optional ffmpeg build is LGPL or GPL depending on its configuration. Nothing is
bundled — they are fetched at install time.

## Reference

- Competitor analysis:
  <https://github.com/devsdocs/playwright-dart/blob/main/dart-port-plan/analysis.md>
- Official Playwright documentation:
  <https://playwright.dev/docs/intro>

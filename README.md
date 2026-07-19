# Playwright for Dart

[![CI](https://github.com/insinfo/dart_playwright/actions/workflows/ci.yml/badge.svg)](https://github.com/insinfo/dart_playwright/actions/workflows/ci.yml)

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

| Package | Purpose |
| --- | --- |
| `packages/playwright_protocol` | Shared protocol types, transport types, errors, and event utilities. |
| `packages/playwright_core` | Browser registry, process transport, and engine-specific implementations for Chromium, Firefox, and WebKit. |
| `packages/playwright` | User-facing Dart API. |
| `packages/playwright_mcp` | Model Context Protocol server backed by this Playwright Dart implementation. |

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
dart test packages/playwright/test/integration/browser_parity_test.dart
```

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

## Status

This project is under active development. The current implementation already
covers the essential browser automation path across the three Playwright engines,
with cross-platform CI and parity tests. Some advanced Playwright APIs may still
be missing or intentionally deferred while the native core stabilizes.

## Development Notes

Useful commands:

```bash
dart pub get
dart analyze packages
dart run playwright install chromium firefox webkit
dart test packages/playwright/test/integration/browser_parity_test.dart --reporter expanded --timeout 120s
```

The CI workflow runs analysis and browser parity tests on Ubuntu, Windows, and
macOS.

## Reference

- Competitor analysis:
  <https://github.com/devsdocs/playwright-dart/blob/main/dart-port-plan/analysis.md>
- Official Playwright documentation:
  <https://playwright.dev/docs/intro>

# playwright_protocol

[![CI](https://github.com/insinfo/dart_playwright/actions/workflows/ci.yml/badge.svg)](https://github.com/insinfo/dart_playwright/actions/workflows/ci.yml)
[![AI Assisted](https://img.shields.io/badge/AI-Assisted-purple.svg)](https://github.com/insinfo/dart_playwright#how-this-package-was-built)

The shared bottom layer of [Playwright for Dart](https://pub.dev/packages/playwright).

**You probably want [`playwright`](https://pub.dev/packages/playwright)
instead.** This package exists so that `playwright` and `playwright_core` can
agree on a handful of types without depending on each other.

## What is in here

- **Transport types** — the request/response envelope the three browser
  protocols share, including the WebKit `pageProxyId` and the flattened CDP
  `sessionId`.
- **Errors** — `PlaywrightException` and the taxonomy under it:
  `TimeoutException`, `TargetClosedException`, `ProtocolException`,
  `NavigationException`, `ActionabilityException`, `SelectorException`.
- **Event emitter** — ordered listener dispatch with `once`, bridged to Dart
  broadcast streams. The bridge registers its underlying listener only while a
  stream has subscribers, which is what lets the port tell "nobody is watching
  this dialog" from "somebody read the getter".
- **Common types** — viewport size, load states, wait-until states.

## Stability

This package is at milestone 2 of 5 of the port and its API is internal. It
will change without a major version bump while the port matures; depend on
`playwright` and let it pin this one.

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
Copyright (c) Microsoft Corporation, under Apache 2.0 — itself derived from
Puppeteer, Copyright 2017 Google Inc. The `NOTICE` file that ships with this
package says which behaviour follows the upstream sources.

This project is not produced, endorsed or supported by Microsoft. "Playwright"
is a trademark of Microsoft Corporation, used here only to say what this is
compatible with.

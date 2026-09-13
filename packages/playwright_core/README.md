# playwright_core

[![CI](https://github.com/insinfo/dart_playwright/actions/workflows/ci.yml/badge.svg)](https://github.com/insinfo/dart_playwright/actions/workflows/ci.yml)
[![AI Assisted](https://img.shields.io/badge/AI-Assisted-purple.svg)](https://github.com/insinfo/dart_playwright#how-this-package-was-built)

The engine layer of [Playwright for Dart](https://pub.dev/packages/playwright).

**You probably want [`playwright`](https://pub.dev/packages/playwright)
instead.** This package has no ergonomic API; it is the machinery that one
sits on, published separately only because `playwright` depends on it.

## What is in here

- **Browser registry** — resolves, downloads and verifies the Chromium,
  Firefox and WebKit builds from the same CDN the upstream project uses, and
  knows the per-platform executable and archive layout.
- **Transport** — the Playwright fd3/fd4 pipe model, implemented with Windows
  named pipes and POSIX FIFOs, plus a WebSocket transport.
- **Engine drivers** — one per browser, each speaking its own protocol:
  Chrome DevTools Protocol for Chromium, Juggler for Firefox, the inspector
  protocol for WebKit. Frames, execution contexts per frame, network
  managers, input, dialogs and the event model live here.
- **Injected selector engine** — a hand port of Playwright's in-page script:
  the `text`, `label`, `role` and `internal:*` engines, ARIA role resolution
  and accessible-name computation.

## Stability

This package is at milestone 2 of 5 of the port and its API is internal. The
types under `lib/src/` are not a public contract and will change without a
major version bump while the port matures; depend on `playwright` and let it
pin this one.

The engine drivers are exercised end to end on Chromium, Firefox and WebKit by
the parity suite in the repository.

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

This package carries the most directly ported material in the project: the
injected selector engine, the US keyboard layout, the macOS editing commands,
the Chromium switch list, the browser revision table and the registry path
mappings all come from [Playwright](https://github.com/microsoft/playwright),
Copyright (c) Microsoft Corporation, under Apache 2.0 — which is itself derived
from Puppeteer, Copyright 2017 Google Inc. The `NOTICE` file that ships with
this package lists each file and how it was modified.

This project is not produced, endorsed or supported by Microsoft. "Playwright"
is a trademark of Microsoft Corporation, used here only to say what this is
compatible with.

The browser binaries this package downloads are **not** covered by its license.
Each carries its own terms: Chromium is BSD-3-Clause plus third-party licenses,
Firefox is MPL-2.0, WebKit is LGPL-2.1/BSD, and the optional ffmpeg build is
LGPL or GPL depending on how it was configured. Nothing is bundled here — the
binaries are fetched at install time, by you.

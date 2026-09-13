# Changelog

## 0.1.0

First release, extracted as the engine layer under `playwright`.

- Browser registry: resolve, download and verify Chromium, Firefox, WebKit and
  ffmpeg builds per platform.
- Transport: the Playwright fd3/fd4 pipe model on Windows named pipes and
  POSIX FIFOs, plus a WebSocket transport.
- Chromium driver over Chrome DevTools Protocol, Firefox driver over Juggler,
  WebKit driver over the inspector protocol, each with frames, per-frame
  execution contexts, a network manager, input and dialogs.
- Flattened target tracking per engine, so pages opened by the page itself are
  adopted the same way as pages the API asked for.
- Console, page-error and crash events normalized to one shape across the
  three protocols.
- Injected selector engine: `text`, `label`, `role` and `internal:*` engines,
  ARIA role resolution and accessible-name computation, entering open shadow
  roots.
- US keyboard layout and macOS editing commands.

The API of this package is internal and will change without a major version
bump while the port matures.

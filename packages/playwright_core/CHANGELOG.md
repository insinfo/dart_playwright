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
- Complete network model per engine: resource types, failure text, redirect
  chains, timings, sizes, remote address and TLS details, normalized across
  the three protocols.
- Route interception gained request overrides, a handler chain with
  `fallback`, and the per-engine error-code tables for `abort`.
- File input support (`DOM.setFileInputFiles`, `Page.setFileInputFiles`,
  `DOM.setInputFiles` plus WebKit's `grantFileReadAccess`) and file chooser
  interception.
- Downloads per engine, with a shared `CoreDownload` covering the three very
  different event shapes.
- Screenshot geometry computed once in document coordinates and translated
  per engine; `Page.printToPDF` on Chromium, read back over the `IO` stream.
- Hit-target testing in the injected script.
- Context emulation per engine: locale, timezone, colour scheme, reduced
  motion, forced colours, device scale factor, mobile, touch, offline, extra
  headers, HTTP credentials, geolocation and permissions - applied at the
  browser, context, pageProxy or page layer depending on what each engine
  wants.
- Touch dispatch per engine, and the permission name tables, which differ in
  size between the three.
- WebKit's `Runtime.evaluate` now resolves promises through
  `Runtime.awaitPromise`; Juggler has no equivalent and cannot.


The API of this package is internal and will change without a major version
bump while the port matures.

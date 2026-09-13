# Changelog

## [0.6.0] - Milestone 3: network, artifacts and the API request context

### Added
- **`Route`**: `continue_` now rewrites the URL, method, headers and body on the way out; `fallback()` hands the route to the next matching handler (they run newest first, as upstream orders them); `abort()` takes the documented error codes and maps them per engine.
- **`Request`**: `resourceType`, `isNavigationRequest`, `failure`, `response`, `redirectedFrom`/`redirectedTo`, `allHeaders`/`headersArray`/`headerValue`, `postDataBuffer`, `postDataJSON`, `timing` and `sizes`.
- **`Response`**: `headers`, `allHeaders`, `headersArray`, `headerValue`, `headerValues`, `serverAddr`, `securityDetails`, `fromServiceWorker` and `finished`.
- **Uploads**: `Locator.setInputFiles` and `Page.setInputFiles`, plus `FileChooser` with `Page.onFileChooser` and `Page.waitForFileChooser`.
- **Downloads**: `Download` with `path`, `saveAs`, `failure`, `cancel` and `delete`; `Page.onDownload`, `Page.waitForDownload`, `BrowserContext.onDownload`, and the `acceptDownloads` and `downloadsPath` context options.
- **Screenshots**: `type`, `quality`, `fullPage`, `clip` and `scale` on `Page.screenshot`, and `Locator.screenshot` capturing exactly the element's box.
- **`Page.pdf`** on Chromium, with paper formats, margins, header/footer templates and page ranges, read back through the `IO` stream.
- **`APIRequestContext`**: `playwright.request.newContext()` for standalone HTTP, and `context.request` sharing the browser context's cookie jar in both directions.

### Fixed
- **An element covered by another was still clicked.** Actionability now includes hit-target testing (`receivesEvents`), and the timeout names what intercepted the click.
- Firefox could not link a redirect whose previous hop had already finished, because the finished request was dropped from the map first.
- Chromium's `DOM.setFileInputFiles` ignores an empty file list, so clearing an input goes through the DOM instead and now works on all three engines.
- File paths are normalized to absolute, native-separator form before reaching an engine: Firefox builds an `nsIFile` from each one and rejects a Windows path containing forward slashes.

## [0.5.0] - P0 events, and getting ready to publish

### Added
- **`Page` events**: `onConsole`, `onPageError`, `onPopup`, `onCrash` and `onDialog` (now a `Stream<Dialog>`), alongside the ones that already existed. Plus `opener()`, `context()` and `isClosed()`.
- **`BrowserContext` events**: `onPage`, `onClose`, `onConsole`, `onPageError`, `onDialog`, `onRequest`, `onResponse`, `onRequestFinished`, `onRequestFailed`.
- **Waiters**: `page.waitForPopup`, `page.waitForConsoleMessage`, `page.waitForDialog`, `context.waitForPage`, `context.waitForConsoleMessage`, `context.waitForEvent`. All of them give up on timeout, on the target closing and — for page-scoped waits — on the page crashing, with the same error wording upstream uses.
- **Per-engine target tracking**: flattened `Target.setAutoAttach` on Chromium, `Browser.attachedToTarget` on Firefox, `Playwright.pageProxyCreated` on WebKit. `newPage` takes the same path a popup does, so `context.pages()` can never disagree with the `page` event.
- **`page.setViewportSize` and `page.setExtraHTTPHeaders`** on all three engines.
- **Public wrappers are now unique per core object**, so `context.pages()`, `popup.opener()` and the `page` event all hand back the same instance.
- **Hit-target testing** (`receivesEvents`): an element covered by another is no longer clicked. The timeout names what intercepted the click. `force: true` skips the check.
- **67 new event parity tests**: 276 in total, green on Chromium, Firefox and WebKit.
- **Ready to publish**: `LICENSE` (Apache 2.0) and `NOTICE` at the root and inside every publishable package, an English `README.md` and a `CHANGELOG.md` per package, per-package `.gitignore` and `.pubignore`, and CI running `dart doc` (checking for the `Found 0 warnings and 0 errors` line, because `dart doc` exits 0 even when it warns) and `dart pub publish --dry-run`. The test job now runs the whole suite instead of a single file.
- `playwright`, `playwright_core` and `playwright_protocol` become publishable; `playwright_mcp` stays on `publish_to: none`.

### Fixed
- **`EventEmitter.stream` registered a permanent listener every time the getter was read** and built a fresh controller per call, so `listenerCount` lied and upstream's rule of dismissing a dialog nobody watches had nothing truthful to stand on. There is now one controller per event, and the listener only exists while somebody is subscribed.
- **Payload-free events never reached stream subscribers**: `page.onLoad`, `onClose` and `onDomContentLoaded` threw `NoSuchMethodError` during dispatch.
- **Chromium and Firefox never closed a page's session on detach**, so the `close` event only existed when the whole connection went down.
- **Chromium: `Runtime.runIfWaitingForDebugger` was missing at the end of page initialization.** Without it, with auto-attach on, the opener's renderer stays blocked inside `window.open` and the `evaluate` or the click that opened the popup never returns.
- **`playwright_core` imported `package:win32` and `package:ffi` without declaring them** in its own pubspec; it worked in the workspace and would have broken the published package.
- **`browsers_json.dart` had lost the provenance line** that the root `browsers.json` carries. Restored, and the files ported from upstream gained an Apache 2.0 attribution header.

## [0.4.0] - Frames, FrameLocator, getBy* and actionability

### Added
- **Per-frame execution contexts on all three engines**: every frame gets its own JS context, tracked by a shared registry fed by `Runtime.executionContextCreated` (CDP `auxData.frameId`, Juggler `auxData.frameId` of the unnamed world, WebKit `context.frameId` of type `normal`). This unlocks everything below.
- **Complete public `Frame`**: `goto`, `content`, `setContent`, `title`, `url`, `name`, `parentFrame`, `childFrames`, `isDetached`, `frameElement`, `evaluate`, `evaluateHandle`, `waitForSelector/Function/LoadState/Navigation/URL`, per-frame interactions and states, the legacy DOM shortcuts (`querySelector`, `querySelectorAll`, `evalOnSelector`, `evalOnSelectorAll`, `dispatchEvent`), `locator`, `frameLocator` and the `getBy*` helpers.
- **`FrameLocator`** with all 13 upstream methods, chainable through nested frames.
- **`getBy*`** (`getByRole`, `getByText`, `getByLabel`, `getByPlaceholder`, `getByAltText`, `getByTitle`, `getByTestId`) on `Page`, `Frame`, `Locator` and `FrameLocator`, over an injected selector engine ported from `domUtils.ts`, `selectorUtils.ts`, `roleUtils.ts`, `roleSelectorEngine.ts` and the `internal:*` engines of `injectedScript.ts` — including whitespace normalization, `exact:`, and ARIA role and accessible-name computation.
- **Complete `Locator`**: composition (`first`, `last`, `nth`, `filter`, `and`, `or`, `visible`, `all`, `contentFrame`), actions (`dragTo`, `setChecked`, `selectText`, `scrollIntoViewIfNeeded`, `dispatchEvent`, `clear`, `blur`), state (`boundingBox`, `ariaRole`, `accessibleName`), evaluation (`evaluate`, `evaluateAll`, `evaluateHandle`, `elementHandle`, `elementHandles`) and `waitFor` with `attached`/`detached`/`visible`/`hidden`.
- **Real actionability**: actions wait for `visible`/`stable`/`enabled`/`editable` in a loop until the timeout; `timeout`, `strict` and `force` options.
- **`Mouse`**: `move` (with `steps`), `down`, `up`, `click`, `dblclick` and `wheel`, tracking position and button mask; `Page.mouse`.
- **`evaluateHandle` on Firefox and WebKit**, each with its own execution context, `JSHandle` and `ElementHandle`.
- **`ElementHandle`**: `innerText`, `innerHTML`, `inputValue`, `getAttribute`, `boundingBox`, `scrollIntoViewIfNeeded`, the state methods and `contentFrame`/`ownerFrame`.
- **Parity suite**: 202 end-to-end tests green on Chromium, Firefox and WebKit.

### Fixed
- **Firefox**: `Page.navigationCommitted` carries no `parentFrameId`, and the frame manager trusted the event parameter — so every iframe navigation promoted the child to main frame. The parent now comes from the frame recorded at `frameAttached`.
- **WebKit**: `Page.loadEventFired`/`Page.domContentEventFired` report which frame fired; attributing them to the main frame left iframes without a lifecycle and made `frame.goto()` inside an iframe hang forever.
- Removed `chromium/frame_manager.dart`, dead code that duplicated — with competing handlers — what `CrPage` already does inline.

## [0.3.0] - Keyboard, cookies and dialogs

### Added
- **Real keyboard**: the full US layout (`us_keyboard_layout.dart`) and a `Keyboard` class with modifier state. `Page.keyboard`, `Page.press/type` and `Locator.press/pressSequentially` dispatch real key events (CDP `Input.dispatchKeyEvent`, Juggler `Page.dispatchKeyEvent`, WebKit `Input.dispatchKeyEvent`), falling back to `insertText` for characters outside the layout. Supports chords (`Control+A`, `Shift+ArrowLeft`) and the platform-sensitive `ControlOrMeta`.
- **Cookies and storageState**: `BrowserContext.cookies/addCookies/clearCookies` and `storageState()` (cookies plus per-origin localStorage) on all three engines — CDP `Storage.*`, Juggler `Browser.*Cookies`, WebKit `Playwright.*Cookies`.
- **Dialogs**: `Page.onDialog` receives alert/confirm/prompt/beforeunload with `accept([text])`/`dismiss()`; with no handler the dialog is auto-dismissed. Per-engine events: CDP `Page.javascriptDialogOpening`, Juggler `Page.dialogOpened`, WebKit `Dialog.javascriptDialogOpening`.

## [0.2.0] - Multi-engine and cross-platform parity

### Added
- **Firefox (Juggler) and WebKit**: complete engines with launch, navigation, evaluate, screenshot and network interception (`FfRoute`, `WkRoute`). WebKit with its two-layer routing (pageProxy plus `Target.sendMessageToTarget`), `Playwright.navigate` and `Target.resume`.
- **Unified fd3/fd4 transport on all three operating systems**: on Windows through named pipes injected via `lpReserved2` (emulating libuv, without `FILE_FLAG_OVERLAPPED` on the child's end); on Linux/macOS through FIFOs (`mkfifo` via `stdlibc`) plus `sh -c 'exec … 3<fifo 4>fifo'`. Shared `\0` framing (`NullDelimitedFramer`).
- **Chromium over `--remote-debugging-pipe`**: CDP now uses the same fd3/fd4 transport on every platform — the earlier `--remote-debugging-port=0` workaround on Windows is gone.
- **Trusted protocol input**: `click`/`fill`/`check` dispatch real events (CDP `Input.*`, Juggler `Page.dispatch*`, WebKit `Input.*`); the tests assert `event.isTrusted` on all three engines.
- **Real contexts**: `BrowserContext` creates and disposes isolated contexts through the protocol (`Target.createBrowserContext`/`disposeBrowserContext`, `Browser.createBrowserContext`/`removeBrowserContext`, `Playwright.createContext`/`deleteContext`), with a `localStorage` isolation test.
- **Wider public API**: `Page.content/url/waitForSelector/click/fill`; `Locator` with `innerText`, `innerHTML`, `inputValue`, `getAttribute`, `count`, `isVisible`, `isEnabled`, `isChecked`, `check/uncheck`, `selectOption`, `waitFor` — selectors escaped safely through `jsonEncode`.
- **Multi-OS CI**: GitHub Actions (ubuntu-22.04, windows-latest, macos-15) running analysis plus the E2E parity suite (33 tests x 3 operating systems), with browser caching and concurrency cancellation.

### Changed
- Chromium's `goto` waits for a real `Page.loadEventFired` (the fixed 1500 ms delay is gone).
- Browsers are closed gracefully through the protocol (`Browser.close`/`Playwright.close`) before being killed.
- WebKit launches with `--no-startup-window` (avoids an abort on Linux without a display); Firefox's `-foreground` is restricted to macOS.
- Browser extraction on POSIX uses the system `unzip` (which preserves the execute bits); install progress is throttled to 1%/10% steps, keeping CI logs readable.

### Fixed
- The `playwright install` CLI never exited after downloading (`HttpClient` keep-alive plus a missing explicit `exit()`).
- Asynchronous "User initiated close" errors after teardown (abandoned futures now use `ignore()`).
- Several `\$` literals in strings that were meant to interpolate values.

## [0.1.0] - Foundation and initial Chromium support

### Added
- **Monorepo (workspace)**: the initial project split into three packages (`playwright_protocol`, `playwright_core` and `playwright`).
- **Registry**: downloading and extracting the official Playwright browser binaries (Chromium) natively in Dart, with no Node.js dependency, across Windows, Linux and macOS.
- **Transport**: `PipeTransport` and `WebSocketTransport` for Chrome DevTools Protocol (CDP) communication.
- **Chromium engine**: launching local Chromium instances through `Process.start`, with WebSocket/pipe detection.
- **CDP domains**: `CrConnection`, `CDPSession`, context/page/frame handling, network management (`CrNetworkManager`) and remote evaluation (`CrExecutionContext`, `CrJSHandle`, `CrElementHandle`).
- **Public API**: the first object-oriented surface exposed to users (`Playwright`, `BrowserType`, `Browser`, `BrowserContext`, `Page`, `Locator`, `Frame`, `Request`, `Response`, `JSHandle`, `ElementHandle`, `ConsoleMessage`, `Dialog`).
- **End-to-end example**: `example.dart`, which launches the browser, visits a site and reads remote state (`h1` and `title`).

### Changed
- SDK constraint set to `^3.6.2` to enable Dart workspaces.
- CDP pipe injection on Windows temporarily used `--remote-debugging-port=0` (lifted in 0.2.0 by the fd3/fd4 transport via `lpReserved2`).

### Fixed
- Linter warnings and unused imports across the base project.

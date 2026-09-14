# Changelog

## Unreleased

### Added
- **`BrowserType.launchPersistentContext`**: a browser on an on-disk profile, returning the `BrowserContext` directly instead of a `Browser`. Cookies, localStorage and the rest of the profile survive the run, which is the whole point; closing the context closes the browser with it. All three engines.
- **`BrowserType.connectOverCDP`**: attach to a Chromium already running with `--remote-debugging-port`, by WebSocket URL or by HTTP address (`/json/version` is read to find the socket). `close()` disconnects and leaves that browser running. Chromium only — CDP is Chromium's protocol, and Firefox (Juggler) and WebKit (its own inspector protocol) do not implement it; asking them says so instead of failing obscurely.
- **Per-context proxy**: `newContext(proxy: ...)` and `launchPersistentContext(proxy: ...)`, alongside `launch(proxy: ...)` for the whole browser. All three engines take one per context.
- **The launch options that were missing**: `channel` (a branded Chromium the machine already has: `chrome`, `msedge` and their pre-release rings), `executablePath`, `downloadsPath`, `env`, `slowMo`, `timeout`, `tracesDir`, `chromiumSandbox`, `firefoxUserPrefs`, `ignoreDefaultArgs`/`ignoreAllDefaultArgs`, and `handleSIGINT`/`handleSIGTERM`/`handleSIGHUP`. An option only one engine has is refused by the others rather than quietly ignored.
- **Playwright's CSS extensions in the `css` engine**: `:has-text()`, `:text()`, `:text-is()`, `:text-matches()`, `:visible`, `:has()`, `:is()`/`:where()`, `:not()`, `:scope`, `:nth-match()`, `:left-of()`, `:right-of()`, `:above()`, `:below()`, `:near()` and `:light()`, plus the `css:light=` prefix. Upstream's `cssTokenizer.ts`, `cssParser.ts`, `layoutSelectorUtils.ts` and `selectorEvaluator.ts` are ported into the injected script, so the semantics — whitespace normalisation, the exact/substring split between `:text-is()` and `:text()`, and the proximity ordering of the layout selectors — are upstream's.
- **The attribute engines pierce open shadow roots too**: `getByTestId`, `getByPlaceholder`, `getByAltText` and `getByTitle` queried the light DOM only, while `getByText`, `getByLabel` and `getByRole` already descended. Upstream builds all of them on the same piercing query.
- **The `css` engine pierces open shadow roots**, like the `text`, `label` and `role` engines already did. Combinators cross the boundary too, so `#host .inside` matches. Closed shadow roots stay invisible, as upstream; `:light()` opts a subtree out.

### Fixed
- **Browser processes outlived the Dart process.** `CrBrowser.close()` waited on `Browser.close` with no limit, so a Chromium that would not answer — wedged on `beforeunload`, or on a hung renderer — never let `close()` return; Firefox and WebKit already bounded that wait. Killing the browser also never reached its renderer and content children, which on Windows do not die with their parent. And nothing took the live browsers down when the Dart process was interrupted, so a Ctrl+C on a test run left every one of them running for hours.
- **A persistent context did not close its browser.** On Chromium, closing the profile's own context closed its pages and left the process running with nobody holding it.
- **A persistent context never recognised its own pages.** The engines report a real id for the default context, not a missing one, so every `newPage()` there waited for a session that had been quietly discarded, and timed out.
- **Closing a browser threw away what it was still writing.** The inspector pipe closes long before the profile is flushed, so killing on end-of-pipe lost the cookies and localStorage a persistent profile exists to keep. The process is now given a few seconds to exit on its own first.
- **`isConnected()` was still true right after `close()` returned**, because the transport announces its closure through a stream one tick later.
- **A malformed selector timed out instead of failing.** A selector that does not parse, or an extension used with the wrong arguments, reached the locator retry loop as a generic error and became a `TimeoutException` after 30s. It now raises `InvalidSelectorError` at once, as upstream does.

### A real accessibility tree on all three engines

### Added
- **`page.accessibilitySnapshot()` answers on Firefox and WebKit**, and answers the same thing Chromium does. It used to be Chromium-only: the other two returned a single empty `WebArea` node, so the method had the right shape and false content on two of three engines.
- **`page.ariaSnapshot()` and `Locator.ariaSnapshot()`**: the aria snapshot YAML, upstream's format for accessibility assertions.
- **`AccessibilityNode` carries state**: `checked`, `disabled`, `expanded`, `invalid`, `level`, `pressed`, `selected` and `props` (a link's `url`, a textbox's `placeholder`), next to the role, name, value and description it already had.
- **`interestingOnly`** on `accessibilitySnapshot`, defaulting to `true`: `false` keeps the `generic` wrappers that are otherwise skipped.
- **`Locator.accessibilitySnapshot()` and `Locator.ariaSnapshot()`**, rooted at the element instead of at the page body.
- **`toMatchAriaSnapshot`** on `expectPage` and `expectLocator` in `playwright_test`, with upstream's template syntax: `- role "name" [state]`, `/pattern/` names, `- /url:` properties and `- /children: equal`. A template that does not parse fails at once instead of retrying until the timeout and then blaming the page. `[active]` is rejected rather than ignored, because this port does not compute the focused node and silently dropping it would let the assertion pass on anything.
- **`parseAriaTemplate`, `ariaTemplateMatches` and `ariaTemplateMatchAll`** are public, for matching a template against a tree you already hold.

### Changed
- **Roles are ARIA roles now, not platform roles.** Chromium used to hand back the raw CDP tree — `RootWebArea`, `StaticText`, `InlineTextBox`, `LabelText`, names with unnormalized whitespace, no pruning. That was not upstream's format either. Code reading `role == 'WebArea'` needs updating: the root is a synthetic node with role `fragment`, and text is a node with role `text`.

Upstream Playwright removed the `Accessibility` class in favour of a tree its
injected script computes from the DOM, because the three browsers' own
accessibility trees disagreed about the same page. This port follows: the tree
is built in the page, by the same code everywhere. The consequence is stated in
the method's own documentation rather than left for the caller to discover —
what a platform screen reader would announce is not available here, on any
engine.

Not ported, all from upstream's `ai` mode: `[ref=...]` element anchors,
`[active]`, `[box=...]`, `depth`, and descending into iframes.

## [0.8.0] - Milestone 5: fixtures and assertions

### Added
- **New package `playwright_test`**: browser fixtures and retrying assertions on top of `package:test`. `playwrightTest` runs a body once per engine, each as its own `dart test` case, with a browser shared per file and a fresh context and page per test; `playwrightGroup` closes them.
- **Assertions that retry**: `toBeVisible`, `toBeHidden`, `toBeAttached`, `toBeEnabled`, `toBeDisabled`, `toBeEditable`, `toBeChecked`, `toBeFocused`, `toBeEmpty`, `toHaveText`, `toContainText`, `toHaveValue`, `toHaveAttribute`, `toHaveClass`, `toHaveCount` on a locator; `toHaveTitle` and `toHaveURL` on a page; `toBeOK` on an API response. All of them take `.not`, and a failure reports both what was expected and what was last seen.
- **Screenshot on failure**, written under `artifactsPath` with its path added to the error.

This is deliberately a layer over `package:test`, not a runner of its own:
`dart test` keeps its CLI, its reporters, its filtering and its parallelism.
Video and trace on failure are missing because the port does not record either
yet.

### Fixed
- **The library wrote diagnostics to stdout.** The POSIX launcher printed `[browser stdout]`, `[browser stderr]` and `[browser exit]` with `print`, which for a stdio protocol server — our own `playwright_mcp`, for one — corrupts the protocol channel. Everything now goes to stderr. It only showed up on Linux and macOS, and only with `PLAYWRIGHT_DEBUG=1`, which is exactly what CI sets.

## [0.7.0] - Milestone 4: context emulation, touch and devices

### Added
- **Context options**: `locale`, `timezoneId`, `colorScheme`, `reducedMotion`, `forcedColors`, `deviceScaleFactor`, `isMobile`, `hasTouch`, `offline`, `extraHTTPHeaders`, `httpCredentials`, `geolocation` and `permissions` on `Browser.newContext`, applied per engine at whichever layer that engine wants them.
- **Touch**: `Page.touchscreen`, `Page.tap` and `Locator.tap`, which need `hasTouch: true` on the context — without it the engines discard the event.
- **`devices`**: a catalogue of ready-made emulation presets (desktop browsers, iPhone, iPad, Pixel, Galaxy). A subset of upstream's 207, transcribed with attribution.
- **`setTestIdAttribute`**: changes the attribute `getByTestId` looks at, process-wide, as upstream does.
- **Permission name tables per engine**, with the sizes the engines actually have: Chromium seventeen, WebKit six, Firefox five. Asking for one an engine does not know throws instead of passing for the wrong reason.
- 38 emulation parity tests across the three engines.

### Fixed
- **`page.evaluate` did not resolve promises on WebKit.** Only Chromium passed `awaitPromise`; WebKit's `Runtime.evaluate` has no such flag, so an async function came back as an empty object. It now resolves through `Runtime.awaitPromise`. Firefox cannot do this at all — Juggler has no equivalent — and that is documented rather than papered over.
- WebKit validates permission names when the context is created instead of when the first page appears, so a bad name fails at the call that caused it.

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

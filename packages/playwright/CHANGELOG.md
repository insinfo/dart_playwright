# Changelog

## 0.1.0

First release. Milestone 2 of 5 of the port; see the README for what is
missing and when it is planned.

### Browsers

- Launch Chromium, Firefox and WebKit from Dart, with no Node.js driver.
- `dart run playwright install` / `list` to download and inspect browser
  binaries.
- `Browser.newContext(viewport:, userAgent:)`, `contexts()`, `isConnected()`,
  `version()`, `onDisconnected`.

### Pages, frames and locators

- `Page`: navigation with `waitUntil` and `timeout`, `reload`, `goBack`,
  `goForward`, `setContent`, `content`, `url`, `title`, `screenshot`,
  `evaluate`, `evaluateHandle`, `setViewportSize`, `setExtraHTTPHeaders`.
- Waiters: `waitForSelector`, `waitForLoadState`, `waitForNavigation`,
  `waitForURL`, `waitForFunction`, `waitForRequest`, `waitForResponse`,
  `waitForPopup`, `waitForConsoleMessage`, `waitForDialog`, `waitForEvent`,
  `waitForTimeout`.
- `Frame` with ~45 methods and its own execution context per frame;
  `FrameLocator` complete.
- `Locator` with composition (`first`, `last`, `nth`, `filter`, `and`, `or`,
  `visible`, `all`), actions, state, evaluation and `waitFor`.
- `getByRole`, `getByText`, `getByLabel`, `getByPlaceholder`, `getByAltText`,
  `getByTitle`, `getByTestId` on `Page`, `Frame`, `Locator` and `FrameLocator`.
- Auto-waiting actionability: `visible`, `stable`, `enabled`, `editable` and
  `receivesEvents` (hit-target testing, so an element covered by another is
  not clicked), retried until the timeout, with `force` and `strict`.
- `Mouse` and `Keyboard` dispatching trusted protocol input, including macOS
  editing commands on WebKit.

### Events

- `Page`: `onClose`, `onLoad`, `onDomContentLoaded`, `onFrameAttached`,
  `onFrameNavigated`, `onFrameDetached`, `onRequest`, `onResponse`,
  `onRequestFinished`, `onRequestFailed`, `onConsole`, `onPageError`,
  `onPopup`, `onCrash`, `onDialog`.
- `BrowserContext`: `onPage`, `onClose`, `onConsole`, `onPageError`,
  `onDialog`, `onRequest`, `onResponse`, `onRequestFinished`,
  `onRequestFailed`, `waitForPage`, `waitForConsoleMessage`.
- A dialog nobody is watching is dismissed automatically, as upstream does.
- Every waiter gives up on timeout, on the target closing and — on a page — on
  the page crashing.

### Network

- `page.route` / `unroute` / `unrouteAll`, with `Route.continue_` (including
  URL, method, header and body overrides), `fallback` into the next matching
  handler, `fulfill` (status, headers, body, `json`, `contentType`) and
  `abort` with the documented error codes.
- `Request`: `resourceType`, `isNavigationRequest`, `failure`, `response`,
  `redirectedFrom`/`redirectedTo`, `allHeaders`/`headersArray`/`headerValue`,
  `postData`/`postDataBuffer`/`postDataJSON`, `timing`, `sizes`.
- `Response`: `headers`, `allHeaders`, `headersArray`, `headerValue`,
  `headerValues`, `serverAddr`, `securityDetails`, `fromServiceWorker`,
  `finished`, `body`/`text`/`json`.
- `APIRequestContext`: `playwright.request.newContext()` for standalone HTTP,
  and `context.request` sharing the browser context's cookie jar both ways.

### Artifacts

- Uploads: `Locator.setInputFiles`, `Page.setInputFiles`, and `FileChooser`
  with `Page.onFileChooser` / `Page.waitForFileChooser`.
- Downloads: `Download` with `path`, `saveAs`, `failure`, `cancel`, `delete`;
  `Page.onDownload`, `Page.waitForDownload`, `BrowserContext.onDownload`, and
  the `acceptDownloads` / `downloadsPath` context options.
- Screenshots with `type`, `quality`, `fullPage`, `clip` and `scale`, plus
  `Locator.screenshot` capturing exactly the element's box.
- `Page.pdf` on Chromium, with paper formats, margins, header and footer
  templates and page ranges.

### Storage

- `cookies`, `addCookies`, `clearCookies`, `storageState` with cookies and
  per-origin localStorage.

### Verified on

341 end-to-end parity tests run on Chromium, Firefox and WebKit.

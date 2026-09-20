# Changelog

## 0.1.0

First release: the trace model of the Playwright trace viewer, in pure Dart,
with no UI.

### The format

- Version 10 of the trace format as a typed reader (`trace.dart`): the
  context, the actions, the network, the console, the stdio, the errors, the
  screencast frames, the screenshots, the aria snapshots, the videos and the
  DOM snapshots.
- Versions 3 to 9 as writers, one file each, so a fixture can be built from
  the real shape of an old trace.
- The HAR 1.2 log, reader and writer, which is what `trace.network` carries.

### The modernizer

- The whole chain, `_modernize_0_to_1` through `_modernize_9_to_10`: the
  `CallMetadata` envelope, the two halves of a console message, the action log
  leaving the `after` event, the `origin`/`monotonicTime`/`stepId` of a
  mergeable trace, `apiName` becoming `title`, snapshot names becoming phases,
  every `sha1` becoming a trace-relative `file`, and the step id being adopted
  as the call id.
- `TraceVersionError` for a trace written by a newer Playwright.
- The reader's current version is 10, as upstream's is; the recorder of this
  port writes 9 on purpose, and the chain brings it up.

### The model

- `TraceLoader` reads a trace archive through `TraceLoaderBackend`, which is
  the only platform-shaped thing in the package: `ZipTraceLoaderBackend` reads
  a zip already in memory, and `package:playwright_trace_viewer/io.dart` adds
  the `dart:io` ones for a file and for a directory of a live trace.
- `TraceModel` merges the library's context with the test runner's onto one
  clock, nests the actions by parent, collects the sources and the errors,
  names the issuer of each request, and answers which snapshot, screenshot and
  aria snapshot each call has.
- `protocol_formatter.dart` renders the title, the subtitle and the curated
  params of a call from the protocol table, with the locator rendering left
  pluggable until the code generator is ported.

### The snapshot

- `SnapshotStorage` and `SnapshotRenderer` rebuild the HTML of a captured DOM
  tree, including the `[[n, i]]` subtree cache this port's own recorder emits,
  and answer which recorded response a request from inside the rendered page
  should be served.
- The bootstrap script that turns the captured attributes back into state:
  values, checked boxes, open dialogs, shadow roots, adopted stylesheets,
  scroll positions, the highlighted target, the click pointer and the canvases.
- `SnapshotServer` answers the four requests a rendered snapshot makes, as
  plain data, so the same code can serve an `HttpServer` of `dart:io` and a
  service worker compiled by dart2js.

### The package

- No `dart:io`, no `dart:html` and no `package:web` in the core, so the whole
  model compiles to the web with dart2js.
- 81 unit tests that need no browser, plus 8 end-to-end tests that record a
  trace with this port in Chromium and read it back.

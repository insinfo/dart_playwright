# playwright_trace_viewer

[![CI](https://github.com/insinfo/dart_playwright/actions/workflows/ci.yml/badge.svg)](https://github.com/insinfo/dart_playwright/actions/workflows/ci.yml)
[![AI Assisted](https://img.shields.io/badge/AI-Assisted-purple.svg)](https://github.com/insinfo/dart_playwright#how-this-package-was-built)

The trace model behind the [Playwright](https://pub.dev/packages/playwright)
trace viewer, in pure Dart. No UI, no Node, no npm.

A trace archive is a zip of newline-delimited JSON plus the bodies it points
at. This package turns one into something a viewer can draw: a list of
actions on one clock, the network, the console, the sources, and the DOM of
every frame at every step, rebuilt as HTML you can load in an iframe.

The UI is a separate package, built on what follows. **Everything below is the
contract.**

```dart
import 'package:playwright_trace_viewer/io.dart';

final loader = await loadTraceFile('trace.zip');
final model = TraceModel('trace.zip', loader.contextEntries);

for (final action in model.actions) {
  print('${action.startTime} ${action.className}.${action.method}');
}
```

## Reading an archive

Nothing in the core imports `dart:io`, `dart:html` or `package:web`, so the
whole model compiles to the web with `dart2js`. Reaching the archive is the
one platform-shaped job, and it is the only thing you have to bring:

```dart
abstract class TraceLoaderBackend {
  Future<List<String>> entryNames();
  Future<bool> hasEntry(String entryName);
  Future<String?> readText(String entryName);
  Future<Uint8List?> readBlob(String entryName);
  bool isLive();
}
```

| What you have | What to use | Where it lives |
| --- | --- | --- |
| A zip already in memory | `ZipTraceLoaderBackend(bytes, live: false)` | the core, web included |
| A zip on disk | `openTraceFile(path)` / `loadTraceFile(path)` | `io.dart` |
| A directory being written right now | `DirectoryTraceLoaderBackend(dir)` | `io.dart` |
| A fetch, a file picker, a service worker | your own three methods | your code |

`isLive()` matters: in a finished trace an action with no `after` event is
closed by the end of its children, because the archive is usually written
before the after-hooks finish. In a live one it is left open, because it may
simply still be running.

### `TraceLoader`

```dart
final loader = TraceLoader();
await loader.load(backend, traceFile: null, unzipProgress: (done, total) {});

loader.contextEntries;                  // List<ContextEntry>
loader.storage();                       // SnapshotStorage
await loader.hasEntry('trace.network'); // bool
await loader.resourceEntry(file);       // TraceResource?  { bytes, contentType }
```

An archive can hold more than one `.trace` file — the library writes one and
the test runner another — and each becomes a `ContextEntry`. `traceFile`
narrows the load to one of them.

## `TraceModel`

`TraceModel(traceUri, contexts)` merges the contexts and is what every panel
reads. Building one mutates the contexts' timestamps onto a single clock, so
build it once.

```dart
TraceModel(
  String traceUri,
  List<ContextEntry> contexts, {
  LocatorDescriber describeLocator = passThroughLocatorDescriber,
})
```

### What it holds

| Field | Type | For |
| --- | --- | --- |
| `actions` | `List<ActionEntry>` | the action list, in start order |
| `startTime`, `endTime`, `wallTime` | `double` | the timeline |
| `browserName`, `channel`, `platform`, `playwrightVersion`, `title`, `options`, `sdkLanguage`, `testIdAttributeName` | | the metadata panel |
| `pages` | `List<PageEntry>` | the filmstrip, per page |
| `videos` | `List<VideoTraceEvent>` | the video panel |
| `resources` | `List<ResourceEntry>` | the network panel, in time order |
| `resourceOwnerRefToTitle` | `Map<String, String>` | `page#1`, `api#1`, `service-worker#1` |
| `events` | `List<TimelineTraceEvent>` | the console and browser events, in time order |
| `stdio` | `List<StdioTraceEvent>` | the test runner's output |
| `errors`, `errorDescriptors` | | the errors panel |
| `sources` | `Map<String, SourceModel>` | the source tab, one entry per file, `content` filled in by the UI |
| `attachments`, `visibleAttachments` | `List<Attachment>` | the attachments panel; the visible ones drop the `_`-prefixed |
| `actionCounters` | `Map<String, int>` | how many actions each group has |
| `hasSource`, `hasStepData`, `hasDomSnapshots`, `hasAriaSnapshots` | `bool` | which tabs to offer |
| `testTimeout`, `annotations` | | the test runner's own |

### What it answers

```dart
model.failedAction();                            // ActionEntry?
model.filteredActions([ActionGroup.route]);      // List<ActionEntry>
model.renderActionTree([ActionGroup.getter]);    // List<String>, indented
model.eventsForAction(action);                   // List<TimelineTraceEvent>
model.stats(action);                             // ({int errors, int warnings})
model.screenshotForCall(callId, ActionPhase.before);
model.ariaSnapshotForCall(callId, ActionPhase.after);
model.hasDomSnapshotForCall(callId, ActionPhase.before);
model.createRelativeUrl('snapshot/$callId?phase=before');
```

Plus, as free functions:

```dart
buildActionTree(actions);            // ActionTree { rootItem, itemMap }
previousActionByEndTime(action);     // ActionEntry?
nextActionByStartTime(action);       // ActionEntry?
resourceOwnerRef(resource);          // String?
```

`ActionGroup` names the three groups an action can belong to —
`configuration`, `route`, `getter` — and `ActionGroup.values` lists them.
An action with no group is always shown; one with a group appears only when
its group is in the filter.

### `ActionEntry`

One action, which is the `before`, `input` and `after` events joined:
`callId`, `startTime`, `endTime`, `title`, `subtitle`, `className`, `method`,
`params`, `stack`, `parentId`, `group`, `point`, `box`, `error`,
`attachments`, `annotations`, `result`, and `log`.

`className` and `method` are the **protocol** names (`Frame`, `click`), not
the Dart ones, because that pair is how the title is looked up.

## Titles

```dart
renderTitleForCall(metainfo, sdkLanguage: ..., describeLocator: ...);
renderSubtitleForCall(metainfo, ...);
renderFullTitleForCall(metainfo, ...);
renderParamsForCall(metainfo, ...);
getActionGroup(className, method);
```

`CallMetainfo(className:, method:, params:, title:, subtitle:)` is the input;
a trace of version 8 or newer may carry a pre-rendered `title`, which wins
over the template. Without one the template comes from `methodMetainfo`, the
transcription of upstream's protocol table: `Frame.click` is `Click` with the
selector under it, `Frame.fill` is `Fill "{value}"`.

Rendering a selector as a locator (`getByRole('button')` rather than
`internal:role=button`) belongs to the code generator, which is a front of
its own in this port. Until it lands, pass your own:

```dart
typedef LocatorDescriber = String Function(String sdkLanguage, String selector);
```

The default, `passThroughLocatorDescriber`, shows the selector as recorded.

## Snapshots

`loader.storage()` is a `SnapshotStorage`:

```dart
storage.snapshotForCall(callId, ActionPhase.before);            // main frame
storage.snapshotForCall(callId, ActionPhase.before, frameId);   // one frame
storage.hasResourceOverride(url);
```

A `SnapshotRenderer` rebuilds one snapshot:

```dart
renderer.snapshot();            // FrameSnapshot
renderer.viewport();            // TraceSize
renderer.closestScreenshot();   // String?  a filmstrip frame's file
renderer.render();              // RenderedFrameSnapshot { html, scriptNonce, pageId, frameId, index }
renderer.resourceByUrl(url, method);  // ResourceSnapshot?
```

The HTML it returns is a whole document, with a bootstrap script inlined
under `scriptNonce`. Serve it with
`Content-Security-Policy: script-src 'nonce-<scriptNonce>'; object-src 'none'`
and nothing else in that document can run — the trace is data from outside,
and a crafted one must not execute in the viewer.

Two things the renderer does that a tree walk would not:

- It resolves the `[[n, i]]` subtree cache, "take node number `i` of the
  snapshot `n` captures ago", which is how a hundred-action trace avoids
  holding a hundred copies of the same page. This port's own recorder emits
  it.
- It sanitizes: scripts and `on*` handlers are dropped, `srcdoc`, `sandbox`,
  `<object data>` and dangerous `<meta http-equiv>` directives are renamed out
  of the way, and the doctype is stripped to alphanumerics.

## Serving a snapshot

`SnapshotServer` answers the four requests a rendered snapshot makes. It owns
no transport: an answer is a `SnapshotResponse`, which is a status, headers
and bytes, so the same code serves an `HttpServer` of `dart:io` and a service
worker compiled by dart2js.

```dart
final server = SnapshotServer(
  loader.storage(),
  (file) async => (await loader.resourceEntry(file))?.bytes,
);

server.serveSnapshot(callId, {'phase': 'before'}, snapshotUrl);
server.serveSnapshotInfo(callId, {'phase': 'before'});
await server.serveClosestScreenshot(callId, {'phase': 'before'});
await server.serveResource([url], 'GET', snapshotUrl);
```

`snapshotUrl` is the URL the document was served at. A request that the
rendered page makes carries no idea which snapshot it came from; that URL is
the link, so pass the same one to `serveSnapshot` and to `serveResource`.

## Format versions

The trace format is versioned, and a viewer that does not modernize refuses
real traces. `TraceModernizer` runs the whole chain — `_modernize_0_to_1`
through `_modernize_9_to_10` — and every step exists because some trace in the
world has that shape:

| Step | What it fixes |
| --- | --- |
| 0 → 1 | the error of an action was a bare string |
| 1 → 2 | the main frame's snapshot had a wrong viewport |
| 2 → 3 | a resource was not a HAR entry yet |
| 3 → 4 | the `CallMetadata` envelope opens; internal calls are dropped |
| 4 → 5 | a console message was split across an `object` and an `event` |
| 5 → 6 | the action log leaves the `after` event and becomes `log` events |
| 6 → 7 | the context declares `origin` and `monotonicTime`; actions get `stepId` |
| 7 → 8 | `apiName` becomes the rendered `title` |
| 8 → 9 | snapshot names become phases; every `sha1` becomes a `file` path |
| 9 → 10 | the step id is adopted as the call id, everywhere it is referenced |

`kLatestTraceVersion` is 10, as upstream's is; a trace that declares more is
refused with `TraceVersionError`. `kRecorderTraceVersion` is 9, which is what
this port's recorder writes on purpose — version 10 exists only in upstream's
unreleased tree, and the newest viewer installable from npm stops at 9. Both
land on the same in-memory shape.

The version files `trace_v3.dart` .. `trace_v9.dart` carry each old shape as
writers: the modernizer reads an old trace as raw JSON, as upstream does, and
these are what a test uses to build a fixture of a real old trace.

## Tests

```bash
dart test packages/playwright_trace_viewer
```

Everything but one file is unit tests that need no browser. The exception is
`test/real_trace_test.dart`, which records a trace with this port's own
recorder in Chromium and reads it back — the proof that the two halves of the
format agree.

## License

Apache 2.0. See `LICENSE` and `NOTICE`.

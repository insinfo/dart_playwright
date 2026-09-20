# playwright_trace_viewer_ui

The [Playwright][repo] trace viewer, in Dart.

Upstream's viewer is a React application. This is a port of it to Dart,
compiled to the web with dart2js, served by a plain `HttpServer` from
`dart:io`. Nothing here needs Node or npm at runtime, and no prebuilt bundle of
the official viewer is vendored: the UI is the port.

## Opening a trace

```
dart run playwright_trace_viewer_ui:show_trace trace.zip
```

It serves the compiled viewer and the trace's own resources on a local port and
prints the URL.

## What renders

The action list -- with the groups `tracing.group` writes -- the timeline, the
film strip, and the panels for snapshot, call, log, errors, console, network,
source and attachments.

The source panel carries the stack trace, and the stack is a **Dart** stack:
its frames come from `StackTrace.current` at the moment the call was made, not
from JavaScript. The shape is the same as upstream's -- file, line, column,
function -- which is why the panel is a plain port; what changes is that the
file is a `.dart` path and the function is a Dart member.

## What is not here yet

UI mode: the test list, the filters and the live trace view. Also the playback
control, the settings view, the annotations and inspector tabs, and the aria
mode view.

## Layout

- `web/` -- the entry points compiled by dart2js: the page, the snapshot frame
  and the service worker.
- `lib/src/ui/` -- the panels, ported one for one from
  `packages/trace-viewer/src/ui` upstream.
- `lib/src/server/` -- the `HttpServer` that serves the compiled assets and
  bridges the transport-agnostic `SnapshotServer` of `playwright_trace_viewer`.
- `tool/build_ui.dart` -- compiles `web/` into `lib/assets/`.

## License

Apache 2.0. Derived from Playwright; see `NOTICE` in the repository root.

[repo]: https://github.com/insinfo/dart_playwright

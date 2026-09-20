# Changelog

## 0.1.0

First release: the Playwright trace viewer, ported to Dart and compiled to the
web with dart2js.

No Node and no npm at runtime, and no compiled bundle of somebody else's viewer
vendored in. The model it reads is `playwright_trace_viewer`; this package is
the interface over it, plus the `show-trace` command that serves both.

### What renders

The action list with the groups the recorder writes, the timeline and the film
strip, and the panels for snapshot, call, log, errors, console, network, source
and attachments. The source panel carries the stack, and the stack here is a
**Dart** stack: the frames come from `StackTrace.current` at the moment of the
call.

### What is not here yet

UI mode -- the test list, the filters and the live trace view -- and the
smaller pieces around it: the playback control, the settings view, the
annotations and inspector tabs, and the aria mode view.

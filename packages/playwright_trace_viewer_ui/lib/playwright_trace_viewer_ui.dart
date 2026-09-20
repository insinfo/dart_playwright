// Part of the Dart port of the Playwright trace viewer UI.

/// The `dart:io` half of the viewer: reading a trace and serving it.
///
/// A CLI imports this. The dart2js build never does — everything here
/// touches `dart:io`, and `lib/src/ui/` touches `package:web`; the two halves
/// only meet through `src/wire.dart`, which imports neither.
library;

export 'src/server/trace_viewer_server.dart';
export 'src/server/viewer_assets.dart';
export 'src/wire.dart';

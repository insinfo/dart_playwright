// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.

/// The trace model of the Playwright trace viewer, in pure Dart.
///
/// This is the half of the viewer that has no UI: read a trace archive with
/// [TraceLoader], build a [TraceModel] from what comes out, and ask it for
/// the actions, the network, the console, the sources and the snapshots. The
/// UI is built on top of it, in another package.
///
/// Nothing here imports `dart:io` or `package:web`, so the whole model
/// compiles to the web with dart2js. Reading an archive is the one
/// platform-shaped job, and it sits behind [TraceLoaderBackend]:
/// [ZipTraceLoaderBackend] handles a zip already in memory, and
/// `package:playwright_trace_viewer/io.dart` adds the `dart:io` one that
/// reads it from disk.
///
/// ```dart
/// final loader = TraceLoader();
/// await loader.load(ZipTraceLoaderBackend(bytes));
/// final model = TraceModel('trace.zip', loader.contextEntries);
/// for (final action in model.actions) {
///   print('${action.className}.${action.method}');
/// }
/// ```
library;

export 'src/entries.dart';
export 'src/lru_cache.dart' show LruCache, SizedValue;
export 'src/protocol_formatter.dart';
export 'src/snapshot_renderer.dart';
export 'src/snapshot_server.dart';
export 'src/snapshot_storage.dart';
export 'src/string_utils.dart';
export 'src/trace.dart';
export 'src/trace_loader.dart';
export 'src/trace_model.dart';
export 'src/trace_modernizer.dart';
export 'src/trace_utils.dart';
export 'src/versions/har.dart';
export 'src/zip_trace_backend.dart';

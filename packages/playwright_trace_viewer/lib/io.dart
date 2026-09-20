// Part of the Dart port of the Playwright trace viewer.

/// The `dart:io` side of the trace model.
///
/// Everything platform-shaped lives here and nowhere else, so
/// `playwright_trace_viewer.dart` stays compilable to the web. A CLI —
/// `show-trace`, or a test — imports this; a dart2js build never does.
library;

import 'dart:io';
import 'dart:typed_data';

import 'src/trace_loader.dart';
import 'src/zip_trace_backend.dart';

export 'playwright_trace_viewer.dart';

/// Reads the trace archive at [path].
///
/// [live] marks a trace that is still being written, which keeps actions
/// without an `after` event from being closed artificially.
Future<TraceLoaderBackend> openTraceFile(String path,
    {bool live = false}) async {
  final bytes = await File(path).readAsBytes();
  return ZipTraceLoaderBackend(Uint8List.fromList(bytes), live: live);
}

/// Loads the trace archive at [path] in one call.
///
/// The returned loader carries the contexts and the snapshot storage; hand
/// its `contextEntries` to a `TraceModel` and its `storage()` to a
/// `SnapshotServer`.
Future<TraceLoader> loadTraceFile(
  String path, {
  String? traceFile,
  bool live = false,
  void Function(int done, int total)? unzipProgress,
}) async {
  final loader = TraceLoader();
  await loader.load(
    await openTraceFile(path, live: live),
    traceFile: traceFile,
    unzipProgress: unzipProgress,
  );
  return loader;
}

/// A [TraceLoaderBackend] over a directory of loose trace files.
///
/// A trace being written is a directory, not a zip: this is what a live mode
/// reads while the run is still going.
class DirectoryTraceLoaderBackend implements TraceLoaderBackend {
  final Directory directory;
  final bool _live;

  DirectoryTraceLoaderBackend(this.directory, {bool live = true})
      : _live = live;

  @override
  Future<List<String>> entryNames() async {
    final names = <String>[];
    await for (final entity in directory.list(recursive: true)) {
      if (entity is! File) continue;
      names.add(_relative(entity.path));
    }
    return names;
  }

  @override
  Future<bool> hasEntry(String entryName) =>
      File('${directory.path}/$entryName').exists();

  @override
  Future<String?> readText(String entryName) async {
    final file = File('${directory.path}/$entryName');
    if (!await file.exists()) return null;
    return file.readAsString();
  }

  @override
  Future<Uint8List?> readBlob(String entryName) async {
    final file = File('${directory.path}/$entryName');
    if (!await file.exists()) return null;
    return Uint8List.fromList(await file.readAsBytes());
  }

  @override
  bool isLive() => _live;

  String _relative(String path) {
    final root = directory.path.replaceAll('\\', '/');
    final normalized = path.replaceAll('\\', '/');
    if (!normalized.startsWith(root)) return normalized;
    final rest = normalized.substring(root.length);
    return rest.startsWith('/') ? rest.substring(1) : rest;
  }
}

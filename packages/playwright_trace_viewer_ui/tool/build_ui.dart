// Part of the Dart port of the Playwright trace viewer UI.

/// Compiles the viewer into `lib/assets`, the bundle the package ships.
///
///     dart run playwright_trace_viewer_ui:build_ui
///
/// Run this after changing anything under `web/` or `lib/src/ui/`. The
/// checked-in bundle is what `show-trace` serves when it exists, so a stale
/// one is a viewer that does not match its source;
/// `test/bundle_freshness_test.dart` is what catches that.
library;

import 'dart:io';
import 'dart:isolate';

import 'package:playwright_trace_viewer_ui/src/server/viewer_assets.dart';

Future<void> main(List<String> args) async {
  final root = await _packageRoot();
  final target = Directory('$root/lib/assets');
  if (await target.exists()) await target.delete(recursive: true);

  final started = DateTime.now();
  await buildViewer(root, outputRoot: target.path);
  final elapsed = DateTime.now().difference(started);

  var bytes = 0;
  var files = 0;
  await for (final entity in target.list(recursive: true)) {
    if (entity is! File) continue;
    bytes += await entity.length();
    ++files;
  }
  stdout.writeln('Built the trace viewer into ${target.path}');
  stdout.writeln('$files files, ${(bytes / 1024).toStringAsFixed(0)} KiB, '
      'in ${elapsed.inMilliseconds}ms');
}

Future<String> _packageRoot() async {
  final uri = await Isolate.resolvePackageUri(
      Uri.parse('package:playwright_trace_viewer_ui/'));
  if (uri == null) {
    throw StateError('Cannot resolve package:playwright_trace_viewer_ui.');
  }
  return File.fromUri(uri.resolve('..')).path;
}

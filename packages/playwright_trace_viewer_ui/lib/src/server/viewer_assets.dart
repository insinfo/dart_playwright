// Part of the Dart port of the Playwright trace viewer UI.

/// Where the compiled viewer comes from.
///
/// The UI is Dart compiled to JavaScript, and that output has to reach the
/// user somehow. Two ways were possible and this package takes both, in this
/// order:
///
/// 1. **A build that is versioned.** `tool/build_ui.dart` writes
///    `lib/assets/`, which ships inside the package. Starting `show-trace`
///    then costs nothing, and a user who installed the package from pub does
///    not need `dart compile js` to exist on their machine at all. The price
///    is a generated file in the repository, which has to be rebuilt when the
///    UI changes — `test/bundle_freshness_test.dart` fails when it was not.
///
/// 2. **A build on first run.** When `lib/assets/` is missing — a checkout
///    that has never run the build, which is what a contributor has — the
///    server compiles the entrypoint into the cache directory and serves
///    that. The price is the wait — measured at 33 seconds for this bundle on
///    the machine it was developed on, for the two entrypoints together — and
///    a dependency on the SDK's `dart compile js` being present.
///
/// The first is what a released package uses and the second is what keeps a
/// fresh clone working; neither is a fallback for a broken other.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'trace_viewer_server.dart' show ViewerAsset;

/// The file inside the bundle that records which sources it was built from.
const String kStampFile = 'build.stamp';

/// The files the viewer is served from, keyed by their path under `/app/`.
class ViewerAssets {
  final Map<String, ViewerAsset> _assets;

  ViewerAssets(this._assets);

  /// One asset, or null when the viewer does not ship it.
  ViewerAsset? read(String name) => _assets[name];

  /// The asset names, for a test that wants to check what shipped.
  Iterable<String> get names => _assets.keys;

  /// Loads the viewer, building it first if this checkout has never done so.
  ///
  /// [packageRoot] is only needed for the build-on-demand path; it is
  /// resolved from the package URI when omitted.
  static Future<ViewerAssets> load({String? packageRoot}) async {
    final root = packageRoot ?? await _resolvePackageRoot();
    if (root == null) {
      throw StateError('Cannot locate playwright_trace_viewer_ui on disk, and '
          'no prebuilt viewer is bundled with it.');
    }
    final prebuilt = Directory('$root/lib/assets');
    if (await prebuilt.exists()) return _fromDirectory(prebuilt, root);
    final built = await buildViewer(root);
    return _fromDirectory(built, root);
  }

  static Future<ViewerAssets> _fromDirectory(
      Directory bundle, String root) async {
    final assets = <String, ViewerAsset>{};
    await for (final entity in bundle.list(recursive: true)) {
      if (entity is! File) continue;
      final name = entity.path
          .replaceAll(r'\', '/')
          .substring(bundle.path.replaceAll(r'\', '/').length + 1);
      assets[name] = ViewerAsset(
          Uint8List.fromList(await entity.readAsBytes()), _typeOf(name));
    }
    return ViewerAssets(assets);
  }
}

/// Compiles the viewer into [outputRoot], returning the directory it wrote.
///
/// This is what `tool/build_ui.dart` calls to produce the versioned bundle
/// and what the server calls when that bundle is missing.
Future<Directory> buildViewer(String packageRoot, {String? outputRoot}) async {
  final out =
      Directory(outputRoot ?? '$packageRoot/.dart_tool/trace_viewer_ui');
  await out.create(recursive: true);

  for (final entry in const [
    ('web/main.dart', 'main.dart.js'),
    ('web/sw.dart', 'sw.js'),
  ]) {
    final result = await Process.run(
      Platform.resolvedExecutable,
      [
        'compile',
        'js',
        '-O2',
        // The viewer is served from a loopback address to one person; a
        // readable stack from it is worth more than the bytes saved.
        '--no-source-maps',
        '-o',
        '${out.path}/${entry.$2}',
        '$packageRoot/${entry.$1}',
      ],
      workingDirectory: packageRoot,
    );
    if (result.exitCode != 0) {
      throw StateError('Failed to compile ${entry.$1}:\n'
          '${result.stdout}\n${result.stderr}');
    }
  }
  // dart2js writes a `.deps` file beside its output that nothing serves.
  await for (final entity in out.list()) {
    if (entity is File && entity.path.endsWith('.deps')) {
      await entity.delete();
    }
  }

  // What the bundle was built from, so a stale one can be told apart from a
  // fresh one without recompiling to compare.
  await File('${out.path}/$kStampFile')
      .writeAsString(await viewerSourceStamp(packageRoot));

  // The static half: the page, the stylesheets and the icon font.
  for (final name in const [
    'index.html',
    'snapshot.html',
    'viewer.css',
    'third_party/vscode/colors.css',
    'third_party/vscode/codicon.css',
    'third_party/vscode/codicon.ttf',
    'third_party/vscode/LICENSE.txt',
  ]) {
    final source = File('$packageRoot/web/$name');
    if (!await source.exists()) continue;
    final target = File('${out.path}/$name');
    await target.parent.create(recursive: true);
    await source.copy(target.path);
  }
  return out;
}

/// A digest of every source the viewer is compiled from.
///
/// `tool/build_ui.dart` writes this beside the bundle and
/// `test/bundle_freshness_test.dart` recomputes it, so a bundle that was not
/// rebuilt after a change fails the suite instead of shipping.
Future<String> viewerSourceStamp(String packageRoot) async {
  final inputs = <String, String>{};
  for (final directory in const ['web', 'lib/src/ui', 'lib/src/server']) {
    final dir = Directory('$packageRoot/$directory');
    if (!await dir.exists()) continue;
    await for (final entity in dir.list(recursive: true)) {
      if (entity is! File) continue;
      final name = entity.path
          .replaceAll(r'\', '/')
          .substring(packageRoot.replaceAll(r'\', '/').length + 1);
      inputs[name] = sha1.convert(await entity.readAsBytes()).toString();
    }
  }
  inputs['lib/src/wire.dart'] = sha1
      .convert(await File('$packageRoot/lib/src/wire.dart').readAsBytes())
      .toString();
  final names = inputs.keys.toList()..sort();
  final joined = [for (final name in names) '$name:${inputs[name]}'].join('\n');
  return sha1.convert(utf8.encode(joined)).toString();
}

Future<String?> _resolvePackageRoot() async {
  final uri = await Isolate.resolvePackageUri(
      Uri.parse('package:playwright_trace_viewer_ui/'));
  if (uri == null) return null;
  // `.../playwright_trace_viewer_ui/lib/` — the package root is its parent.
  return File.fromUri(uri.resolve('..')).path;
}

String _typeOf(String name) {
  if (name.endsWith('.html')) return 'text/html; charset=utf-8';
  if (name.endsWith('.js')) return 'text/javascript; charset=utf-8';
  if (name.endsWith('.css')) return 'text/css; charset=utf-8';
  if (name.endsWith('.ttf')) return 'font/ttf';
  if (name.endsWith('.json')) return 'application/json; charset=utf-8';
  if (name.endsWith('.svg')) return 'image/svg+xml';
  if (name.endsWith('.txt')) return 'text/plain; charset=utf-8';
  return 'application/octet-stream';
}

/// The bytes of [text] as UTF-8, for a caller building assets in memory.
Uint8List utf8Bytes(String text) => Uint8List.fromList(utf8.encode(text));

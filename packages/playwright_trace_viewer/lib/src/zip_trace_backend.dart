// Part of the Dart port of the Playwright trace viewer. Upstream reads the
// archive from a service worker that unzips it with its own code; this is the
// same job done with `package:archive`, which is pure Dart and compiles to
// the web.

/// A [TraceLoaderBackend] over a trace zip held in memory.
///
/// This is the backend both builds share: the CLI reads the file with
/// `dart:io` and hands the bytes over, and the web build gets them from a
/// fetch or a file picker.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'trace_loader.dart';

/// Reads a trace archive out of a zip in memory.
class ZipTraceLoaderBackend implements TraceLoaderBackend {
  final Map<String, ArchiveFile> _files = <String, ArchiveFile>{};
  final bool _live;

  /// Decodes [bytes] as a zip.
  ///
  /// [live] marks a trace that is still being written, which keeps actions
  /// that never got an `after` event from being closed artificially.
  ZipTraceLoaderBackend(Uint8List bytes, {bool live = false}) : _live = live {
    final archive = ZipDecoder().decodeBytes(bytes);
    for (final file in archive.files) {
      if (file.isFile) _files[file.name] = file;
    }
  }

  @override
  Future<List<String>> entryNames() async => _files.keys.toList();

  @override
  Future<bool> hasEntry(String entryName) async =>
      _files.containsKey(entryName);

  @override
  Future<String?> readText(String entryName) async {
    final bytes = await readBlob(entryName);
    return bytes == null ? null : utf8.decode(bytes, allowMalformed: true);
  }

  @override
  Future<Uint8List?> readBlob(String entryName) async {
    final file = _files[entryName];
    if (file == null) return null;
    final content = file.readBytes();
    return content == null ? Uint8List(0) : Uint8List.fromList(content);
  }

  @override
  bool isLive() => _live;
}

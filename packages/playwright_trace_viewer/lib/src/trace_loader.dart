// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/isomorphic/trace/traceLoader.ts

/// Reads a trace archive into contexts.
///
/// The archive is reached through [TraceLoaderBackend], which is the whole
/// platform surface of this package: a zip in memory, a zip on disk, a
/// directory being written to right now. The loader itself knows only that
/// entries have names and contents.
library;

import 'dart:typed_data';

import 'entries.dart';
import 'snapshot_storage.dart';
import 'trace_modernizer.dart';

/// How the loader reaches the trace archive.
///
/// The core of this package never imports `dart:io`, so reading a file is
/// something the caller brings: `lib/io.dart` has the `dart:io` one, and a
/// web build can implement the same three methods over whatever it has.
abstract class TraceLoaderBackend {
  /// Every entry of the archive, by name.
  Future<List<String>> entryNames();

  /// Whether [entryName] exists.
  Future<bool> hasEntry(String entryName);

  /// The content of [entryName] as text, or null when it is missing.
  Future<String?> readText(String entryName);

  /// The content of [entryName] as bytes, or null when it is missing.
  Future<Uint8List?> readBlob(String entryName);

  /// True while the trace is still being written.
  ///
  /// A live trace keeps actions that never got an `after` event, because the
  /// action may simply still be running.
  bool isLive();
}

/// One blob of the archive, with the content type the HAR recorded for it.
class TraceResource {
  final Uint8List bytes;

  /// The media type, or null when the trace did not record one.
  final String? contentType;

  const TraceResource({required this.bytes, this.contentType});
}

/// Reads the `.trace`, `.network` and `.stacks` files of an archive.
class TraceLoader {
  /// One entry per `.trace` file found, in the order they were read.
  final List<ContextEntry> contextEntries = <ContextEntry>[];

  SnapshotStorage? _snapshotStorage;
  late TraceLoaderBackend _backend;
  final Map<String, String> _resourceToContentType = <String, String>{};

  TraceLoader();

  /// Loads every context of [backend].
  ///
  /// [traceFile] restricts the load to one `.trace` file of an archive that
  /// holds several. [unzipProgress] is called three times per context, which
  /// is what upstream reports to its progress bar.
  Future<void> load(
    TraceLoaderBackend backend, {
    String? traceFile,
    void Function(int done, int total)? unzipProgress,
  }) async {
    _backend = backend;

    final prefixMatch = traceFile != null
        ? RegExp(r'(.+)\.trace$').firstMatch(traceFile)
        : null;
    final prefix = prefixMatch?.group(1);
    final prefixes = <String>[];
    var hasSource = false;
    for (final entryName in await _backend.entryNames()) {
      final match = RegExp(r'(.+)\.trace$').firstMatch(entryName);
      if (match != null && (prefix == null || prefix == match.group(1))) {
        prefixes.add(match.group(1) ?? '');
      }
      if (entryName.startsWith('src/') || entryName.contains('src@')) {
        hasSource = true;
      }
    }
    if (prefixes.isEmpty) throw Exception('Cannot find .trace file');

    final snapshotStorage = SnapshotStorage();
    _snapshotStorage = snapshotStorage;

    // 3 * ordinals progress increments below.
    final total = prefixes.length * 3;
    var done = 0;
    for (final prefix in prefixes) {
      final contextEntry = ContextEntry.empty();
      contextEntry.hasSource = hasSource;
      final modernizer = TraceModernizer(contextEntry, snapshotStorage);

      final trace = await _backend.readText('$prefix.trace') ?? '';
      modernizer.appendTrace(trace);
      unzipProgress?.call(++done, total);

      final network = await _backend.readText('$prefix.network') ?? '';
      modernizer.appendTrace(network);
      unzipProgress?.call(++done, total);

      final stacks = await _backend.readText('$prefix.stacks');
      if (stacks != null && stacks.isNotEmpty) modernizer.appendStacks(stacks);
      unzipProgress?.call(++done, total);

      contextEntry.actions = modernizer.actions()
        ..sort((a1, a2) => a1.startTime.compareTo(a2.startTime));

      if (!backend.isLive()) {
        // Terminate actions w/o after event gracefully.
        // This would close after hooks event that has not been closed because
        // the trace is usually saved before after hooks complete.
        for (final action in contextEntry.actions.reversed.toList()) {
          if (action.endTime == 0 && action.error == null) {
            for (final a in contextEntry.actions) {
              if (a.parentId == action.callId && action.endTime < a.endTime) {
                action.endTime = a.endTime;
              }
            }
          }
        }
      }

      for (final resource in contextEntry.resources) {
        final postDataFile = resource.request.postData?.file;
        if (postDataFile != null) {
          _resourceToContentType[postDataFile] = _stripEncodingFromContentType(
              resource.request.postData!.mimeType);
        }
        final contentFile = resource.response.content.file;
        if (contentFile != null) {
          _resourceToContentType[contentFile] =
              _stripEncodingFromContentType(resource.response.content.mimeType);
        }
      }

      contextEntries.add(contextEntry);
    }

    snapshotStorage.finalizeStorage();
  }

  /// Whether the archive holds [filename].
  Future<bool> hasEntry(String filename) => _backend.hasEntry(filename);

  /// One blob of the archive, with the content type the HAR recorded.
  ///
  /// `x-unknown` in the har means "no content type", and comes back as null.
  Future<TraceResource?> resourceEntry(String file) async {
    final blob = await _backend.readBlob(file);
    if (blob == null) return null;
    final contentType = _resourceToContentType[file];
    if (contentType == null || contentType == 'x-unknown') {
      return TraceResource(bytes: blob);
    }
    return TraceResource(bytes: blob, contentType: contentType);
  }

  /// The snapshots of the loaded trace.
  SnapshotStorage storage() => _snapshotStorage!;
}

final RegExp _charset = RegExp(r'^(.*);\s*charset=.*$');

String _stripEncodingFromContentType(String contentType) {
  final match = _charset.firstMatch(contentType);
  return match != null ? match.group(1)! : contentType;
}

// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/playwright-core/src/server/utils/crypto.ts and the
// `mime.getExtension` calls of harTracer.ts / snapshotter.ts.

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'trace_events.dart';

final _random = Random.secure();

/// A 32-hex-digit identifier, the shape upstream's `createGuid` produces.
String createGuid() {
  final buffer = StringBuffer();
  for (var i = 0; i < 16; i++) {
    buffer.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

/// The sha1 of [bytes], hex encoded. Resource files inside the archive are
/// named by this, so the same body is stored once no matter how often it is
/// served.
String sha1Hex(List<int> bytes) => sha1.convert(bytes).toString();

/// The sha1 of [text] encoded as UTF-8.
String sha1OfText(String text) => sha1Hex(utf8.encode(text));

/// The file extension upstream's `mime.getExtension` would return for the
/// common content types, falling back to `dat`.
///
/// The extension is cosmetic — the viewer resolves the content type from the
/// HAR entry, not from the file name — but keeping it makes an unzipped trace
/// browsable by hand, which is how upstream traces read.
String extensionForMimeType(String mimeType) {
  final type = mimeType.split(';').first.trim().toLowerCase();
  switch (type) {
    case 'text/html':
      return 'html';
    case 'text/css':
      return 'css';
    case 'text/plain':
      return 'txt';
    case 'text/javascript':
    case 'application/javascript':
    case 'application/x-javascript':
      return 'js';
    case 'application/json':
      return 'json';
    case 'application/xml':
    case 'text/xml':
      return 'xml';
    case 'image/png':
      return 'png';
    case 'image/jpeg':
      return 'jpeg';
    case 'image/gif':
      return 'gif';
    case 'image/webp':
      return 'webp';
    case 'image/svg+xml':
      return 'svg';
    case 'image/x-icon':
    case 'image/vnd.microsoft.icon':
      return 'ico';
    case 'font/woff':
      return 'woff';
    case 'font/woff2':
      return 'woff2';
    case 'font/ttf':
      return 'ttf';
    case 'application/pdf':
      return 'pdf';
    default:
      return 'dat';
  }
}

/// Frames of the caller's stack, for the viewer's Source tab.
///
/// Dart's `StackTrace.current` prints `#3  Foo.bar (file:///c:/a/b.dart:12:5)`,
/// and that is all the information the trace format wants. Frames inside the
/// SDK itself and inside the runtime are dropped, the same filtering upstream
/// applies to its own client library, so the first frame is the user's call.
List<TraceStackFrame> captureStack({int skip = 0, int limit = 30}) {
  final frames = <TraceStackFrame>[];
  final lines = StackTrace.current.toString().split('\n');
  var skipped = 0;
  for (final line in lines) {
    final match = _stackLine.firstMatch(line);
    if (match == null) continue;
    final function = match.group(1)!.trim();
    final location = match.group(2)!;
    if (!location.startsWith('file:')) continue; // dart:async, dart:io, ...
    final uri = Uri.tryParse(location);
    if (uri == null) continue;
    final String path;
    try {
      path = uri.toFilePath();
    } catch (_) {
      continue;
    }
    if (_isSdkFrame(path)) continue;
    if (skipped < skip) {
      skipped++;
      continue;
    }
    frames.add(TraceStackFrame(
      file: path,
      line: int.tryParse(match.group(3) ?? '') ?? 0,
      column: int.tryParse(match.group(4) ?? '') ?? 0,
      function: function.isEmpty ? null : function,
    ));
    if (frames.length >= limit) break;
  }
  return frames;
}

final _stackLine = RegExp(r'^#\d+\s+(.*?)\s+\((.+?):(\d+):(\d+)\)\s*$');

/// Matches this SDK's own `lib/` directories, both in the workspace layout
/// (`packages/playwright/lib/...`) and in the pub cache
/// (`hosted/pub.dev/playwright-0.1.0/lib/...`).
final _sdkPath =
    RegExp(r'/playwright(_core|_test|_protocol|_mcp)?(-[^/]+)?/lib/');

bool _isSdkFrame(String path) => _sdkPath.hasMatch(path.replaceAll(r'\', '/'));

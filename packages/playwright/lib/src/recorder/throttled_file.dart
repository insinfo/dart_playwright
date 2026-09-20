// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source:
// packages/playwright-core/src/server/recorder/throttledFile.ts.

import 'dart:async';
import 'dart:io';

/// A file that is rewritten at most every 250 ms.
///
/// The recorder regenerates the whole source on every keystroke; without this
/// an editor watching the output file would rebuild dozens of times a second.
class ThrottledFile {
  final String path;
  Timer? _timer;
  String? _text;

  ThrottledFile(this.path);

  void setContent(String text) {
    _text = text;
    _timer ??= Timer(const Duration(milliseconds: 250), flush);
  }

  /// Writes the pending content now, if any.
  void flush() {
    _timer?.cancel();
    _timer = null;
    final text = _text;
    if (text != null) File(path).writeAsStringSync(text);
    _text = null;
  }
}

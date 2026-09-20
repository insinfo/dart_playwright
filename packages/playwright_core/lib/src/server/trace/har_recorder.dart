// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/playwright-core/src/server/har/harRecorder.ts

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core_browser.dart';
import 'har_tracer.dart';
import 'serialized_fs.dart';

/// What to record into a standalone HAR file.
///
/// This is upstream's `recordHar` of `browser.newContext`, whose four public
/// knobs are all here. It is the same [HarTracer] the trace recorder uses,
/// pointed at a `.har` document instead of at `trace.network`.
class CoreRecordHarOptions {
  /// Where the document lands. A path ending in `.zip` produces an archive
  /// holding `har.har` plus the bodies; anything else is a plain `.har` with
  /// the resources written next to it.
  final String path;

  /// `full` records everything; `minimal` keeps only what a HAR is replayed
  /// from — no cookies, timings, addresses, sizes or page list. Upstream's
  /// `mode`.
  final HarRecordMode mode;

  /// What happens to the response bodies. Defaults to `attach` for a `.zip`
  /// and `embed` for a `.har`, which is upstream's rule: a lone `.har` has
  /// nowhere to put a sibling file that travels with it.
  final HarContentPolicy? content;

  /// Only requests whose URL matches are recorded: a glob [String] or a
  /// [RegExp]. See [HarTracerOptions.urlFilter] for the glob's reach.
  final Object? urlFilter;

  const CoreRecordHarOptions({
    required this.path,
    this.mode = HarRecordMode.full,
    this.content,
    this.urlFilter,
  });
}

/// How much of each request a recorded HAR keeps.
enum HarRecordMode { full, minimal }

/// Writes a standalone HAR document for one browser context.
///
/// The counterpart of the trace recorder for the network alone: same tracer,
/// same entries, a different destination. It exists because a HAR is what gets
/// replayed and diffed, and a trace zip is not — the viewer reads a trace,
/// nothing else does.
///
/// Like everything else driven by browser events, nothing here is async on
/// the event path: entries arrive synchronously and are held until [flush],
/// which is awaited from the context's `close`.
class CoreHarRecorder implements HarTracerDelegate {
  final CoreBrowserContext _context;
  final CoreRecordHarOptions options;
  final _fs = SerializedFs();

  /// Where the document itself is written. For a `.zip` this is a staging
  /// file inside [_stagingDir]; the zip is assembled from it in [flush].
  final String _harFilePath;

  /// Where the attached bodies go, and how the document refers to them.
  final String _resourcesDir;
  final String _relativeResourcesDir;

  /// Only set for a `.zip` destination: the temporary directory holding the
  /// staged document and bodies, removed once the archive is written.
  final String? _stagingDir;

  late final HarTracer _tracer;
  final _entries = <HarEntry>[];
  final _writtenContent = <String>{};
  bool _flushed = false;

  CoreHarRecorder._(
    this._context,
    this.options,
    this._harFilePath,
    this._resourcesDir,
    this._relativeResourcesDir,
    this._stagingDir,
  );

  /// Creates a recorder and starts it. The tracer has to be listening before
  /// the first page exists, which is why this is called from the context
  /// factory and not lazily on first use.
  factory CoreHarRecorder.start(
      CoreBrowserContext context, CoreRecordHarOptions options) {
    final isZip = options.path.toLowerCase().endsWith('.zip');
    final String harFilePath;
    final String resourcesDir;
    final String relativeResourcesDir;
    String? stagingDir;
    if (isZip) {
      // Staging layout for the archive, where the resources end up next to
      // `har.har` and the document refers to them by bare name.
      stagingDir =
          Directory.systemTemp.createTempSync('playwright-dart-har-').path;
      harFilePath = p.join(stagingDir, 'har.har');
      resourcesDir = stagingDir;
      relativeResourcesDir = '';
    } else {
      harFilePath = options.path;
      resourcesDir = p.dirname(harFilePath);
      relativeResourcesDir = '';
    }
    final recorder = CoreHarRecorder._(context, options, harFilePath,
        resourcesDir, relativeResourcesDir, stagingDir);
    recorder._tracer = HarTracer(
      context,
      recorder,
      options: HarTracerOptions(
        content: options.content ??
            (isZip ? HarContentPolicy.attach : HarContentPolicy.embed),
        slimMode: options.mode == HarRecordMode.minimal,
        // A standalone HAR is read for the network, so the scripts are the
        // point rather than dead weight — which is the opposite of the trace,
        // where they only inflate the archive.
        omitScripts: false,
        urlFilter: options.urlFilter,
      ),
    );
    recorder._tracer.start();
    return recorder;
  }

  // ------------------------------------------------------------ tracer sink

  @override
  void onEntryStarted(HarEntry entry) => _entries.add(entry);

  @override
  void onEntryFinished(HarEntry entry) {
    // The entry object is the one already in [_entries] and was filled in
    // place, so there is nothing to move here. Upstream does the same.
  }

  @override
  String onContentBlob(String shortName, List<int> bytes) {
    final fullName = _relativeResourcesDir.isEmpty
        ? shortName
        : '$_relativeResourcesDir/$shortName';
    if (!_writtenContent.add(shortName)) return fullName;
    if (_writtenContent.length == 1) _fs.mkdir(_resourcesDir);
    _fs.writeFile(p.join(_resourcesDir, shortName), bytes, skipIfExists: true);
    return fullName;
  }

  // ----------------------------------------------------------------- output

  /// Stops recording and writes the document. Idempotent: the context's
  /// `close` and its `notifyClosed` both reach here, and a user may have
  /// asked for it by hand before either.
  Future<void> flush() async {
    if (_flushed) return;
    _flushed = true;
    // The bodies still in flight belong in this document. Waiting first and
    // listing afterwards is the same ordering bug the trace recorder was
    // caught by: a body that lands after the entries are serialized is
    // referenced by a file that is not there.
    await _tracer.flush();
    _tracer.stop();

    String version = '';
    try {
      version = await _context.browser.version();
    } catch (_) {
      // A context whose browser already died still gets a document; the
      // browser version is the one field that needs the protocol.
    }
    final log = _tracer.logHeader(browserVersion: version);
    _tracer.clearPages();

    // Streamed field by field and entry by entry rather than encoded whole:
    // a recording of a long session holds more entries than is comfortable to
    // hold as one string, and upstream streams it for the same reason.
    _fs.mkdir(p.dirname(_harFilePath));
    _fs.writeText(_harFilePath, '');
    _fs.appendFile(
        _harFilePath, '{"log":{"version":${jsonEncode(log['version'])}');
    _fs.appendFile(_harFilePath, ',"creator":${jsonEncode(log['creator'])}');
    _fs.appendFile(_harFilePath, ',"browser":${jsonEncode(log['browser'])}');
    final pages = log['pages'] as List<Map<String, dynamic>>?;
    if (pages != null) {
      _fs.appendFile(_harFilePath, ',"pages":[');
      for (var i = 0; i < pages.length; i++) {
        if (i > 0) _fs.appendFile(_harFilePath, ',');
        _fs.appendFile(_harFilePath, jsonEncode(pages[i]));
      }
      _fs.appendFile(_harFilePath, ']');
    }
    _fs.appendFile(_harFilePath, ',"entries":[');
    for (var i = 0; i < _entries.length; i++) {
      if (i > 0) _fs.appendFile(_harFilePath, ',');
      _fs.appendFile(_harFilePath, jsonEncode(_entries[i].toJson()));
    }
    _fs.appendFile(_harFilePath, ']}}', flush: true);

    final stagingDir = _stagingDir;
    if (stagingDir != null) {
      _fs.zip([
        TraceZipEntry('har.har', _harFilePath),
        for (final name in _writtenContent)
          TraceZipEntry(name, p.join(_resourcesDir, name)),
      ], options.path);
    }
    await _fs.sync();
    if (stagingDir != null) {
      _fs.removeDirectory(stagingDir);
      await _fs.sync();
    }
  }

  /// Drops the recording without writing anything, for a context that is
  /// going away without having been closed properly.
  void dispose() {
    if (_flushed) return;
    _flushed = true;
    _tracer.stop();
    final stagingDir = _stagingDir;
    if (stagingDir != null) _fs.removeDirectory(stagingDir);
  }
}

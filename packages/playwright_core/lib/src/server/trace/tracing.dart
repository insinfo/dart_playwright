// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/playwright-core/src/server/trace/recorder/tracing.ts

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core_browser.dart';
import '../core_page.dart';
import '../video/page_screencast.dart';
import '../video/screencast_hub.dart';
import '../video/video_frame.dart';
import 'har_tracer.dart';
import 'instrumentation.dart';
import 'serialized_fs.dart';
import 'snapshotter.dart';
import 'trace_events.dart';
import 'trace_utils.dart';

/// What to record.
class CoreTracingOptions {
  /// Base name of the trace files inside the traces directory. A random one is
  /// used when omitted.
  final String? name;

  /// Record the screencast filmstrip: the strip of frames the viewer runs
  /// along the top of its timeline, and the image it shows while you scrub.
  ///
  /// This is upstream's `screenshots: true`. The frames come from the page's
  /// screencast, shared with video recording when both are on, and are written
  /// as `screencast/<page>-<n>.jpeg` resources referenced by `screencast-frame`
  /// events.
  final bool screenshots;

  /// Capture a PNG of the page before, during and after each action.
  ///
  /// This is upstream's internal `snapshots: { screen: true }`, which its own
  /// test runner uses and its public `Tracing.start` does not expose. It is
  /// not the filmstrip — that is [screenshots] — and the two are independent:
  /// this one is tied to actions, the filmstrip to wall time.
  final bool actionScreenshots;

  /// Capture the DOM of every frame around each action, which is what makes
  /// the viewer show the page as it was. See [Snapshotter] for the two ways
  /// this differs from upstream.
  final bool snapshots;

  /// Record the caller's stack with each action, and put the Dart files it
  /// points at inside the archive, so the viewer's Source tab has something to
  /// show.
  final bool sources;

  const CoreTracingOptions({
    this.name,
    this.screenshots = false,
    this.actionScreenshots = false,
    this.snapshots = false,
    this.sources = false,
  });
}

class _RecordingState {
  final CoreTracingOptions options;
  String traceName;
  String traceFile;
  String networkFile;
  final String tracesDir;
  int chunkOrdinal = 0;

  /// Blobs the network stream points at. The network file survives across
  /// chunks, so these go into every chunk's archive.
  final crossChunkFiles = <String>{};

  /// Blobs this chunk's trace stream points at.
  final chunkFiles = <String>{};

  /// Source files the actions of this chunk came from.
  final sourceFiles = <String>{};

  bool recording = false;
  final callsInProgress = <String>{};

  /// Ids of the `tracingGroup` rows currently open, innermost last. Every
  /// action recorded while one is open hangs off it in the viewer's tree.
  final groupStack = <String>[];

  _RecordingState({
    required this.options,
    required this.traceName,
    required this.traceFile,
    required this.networkFile,
    required this.tracesDir,
  });
}

/// Records a trace the official Playwright viewer opens.
///
/// The output is one zip holding `trace.trace` (the event stream, one JSON
/// object per line), `trace.network` (the HAR entries, same shape) and
/// `resources/<sha1>.<ext>` for every body the stream references.
///
/// Everything here that runs from a browser event runs **synchronously**:
/// `EventEmitter.emit` drops whatever a listener returns, so a failed future
/// born in a handler would vanish with the error inside it. Writes are
/// enqueued on [SerializedFs] instead, and the failure surfaces from
/// [stopChunk], where a caller is waiting.
class CoreTracing
    implements
        HarTracerDelegate,
        CoreInstrumentationListener,
        SnapshotterDelegate {
  final CoreBrowserContext _context;
  final _fs = SerializedFs();
  late final HarTracer _harTracer = HarTracer(_context, this);
  late final Snapshotter _snapshotter = Snapshotter(this);

  _RecordingState? _state;
  bool _isStopping = false;
  bool _started = false;
  String? _tracesTmpDir;
  final _allResources = <String>{};
  final _listeners = <({String event, Function listener})>[];
  final _pageCloseListeners = <CorePage, Function>{};
  final _filmstrips = <CorePage, _PageFilmstrip>{};

  CoreTracing(this._context);

  bool get isRecording => _state?.recording ?? false;

  /// Prepares the recorder. Call [startChunk] to actually begin a trace.
  void start(CoreTracingOptions options) {
    if (_isStopping) {
      throw StateError('Cannot start tracing while stopping');
    }
    if (_state != null) throw StateError('Tracing has been already started');

    final tracesDir = _createTracesDirIfNeeded();
    final traceName = options.name ?? createGuid();
    _state = _RecordingState(
      options: options,
      traceName: traceName,
      tracesDir: tracesDir,
      traceFile: p.join(tracesDir, '$traceName.trace'),
      networkFile: p.join(tracesDir, '$traceName.network'),
    );
    _fs.mkdir(p.join(tracesDir, 'resources'));
    if (options.actionScreenshots) {
      _fs.mkdir(p.join(tracesDir, 'screenshots'));
    }
    if (options.screenshots) _fs.mkdir(p.join(tracesDir, 'screencast'));
    _fs.writeText(_state!.networkFile, '');
    _harTracer.start();
    _started = true;
  }

  /// Opens a new chunk and starts recording into it. Returns the trace name.
  String startChunk({String? name, String? title}) {
    final state = _state;
    if (state == null) {
      throw StateError('Must start tracing before starting a new chunk');
    }
    if (_isStopping) {
      throw StateError('Cannot start a trace chunk while stopping');
    }
    if (state.recording) {
      throw StateError('Must stop the current chunk before starting a new one');
    }

    state.recording = true;
    state.callsInProgress.clear();
    state.groupStack.clear();

    if (name != null && name != state.traceName) {
      _changeTraceName(state, name);
    } else {
      _allocateNewTraceFile(state);
    }

    _appendTraceEvent(ContextCreatedTraceEvent(
      browserName: _context.browser.name,
      platform: _nodePlatform(),
      playwrightVersion: kPlaywrightDartVersion,
      wallTime: TraceClock.wallTime(),
      monotonicTime: TraceClock.monotonicTime(),
      title: title,
      options: TraceContextOptions(
        viewport: _context.options.viewport,
        deviceScaleFactor: _context.options.deviceScaleFactor,
        isMobile: _context.options.isMobile,
        userAgent: _context.options.userAgent,
      ),
    ));

    if (state.options.snapshots) _snapshotter.start();
    _context.instrumentation.captureStacks = state.options.sources;
    _context.instrumentation.addListener(this);
    _listen('console',
        (dynamic message) => _onConsoleMessage(message as CoreConsoleMessage));
    _listen(
        'pageerror', (dynamic error) => _onPageError(error as CorePageError));
    _listen('dialog', (dynamic dialog) => _onDialog(dialog as Dialog));
    _listen('download', (dynamic download) => _onDownload(download));
    _listen('page', (dynamic page) => onPageOpen(page as CorePage));
    for (final page in _context.pages) {
      onPageOpen(page);
    }
    return state.traceName;
  }

  /// The group every new action currently hangs off, if any.
  String? get _currentGroupId =>
      _state?.groupStack.isNotEmpty ?? false ? _state!.groupStack.last : null;

  /// Opens a named row in the viewer's action tree. Everything recorded until
  /// the matching [groupEnd] is nested under it.
  ///
  /// The row is a plain `before`/`after` pair with `class: Tracing` and
  /// `method: tracingGroup` — the viewer has no separate group event, it just
  /// draws children under a parent. So a group with nothing inside it is a
  /// row of its own, not an error.
  ///
  /// [location] is what the viewer's Source tab jumps to. Without one the
  /// caller's own frame is used, but only while `sources` is on: writing a
  /// `stack` whose file is not in the archive would give the Source tab a
  /// line it cannot open.
  ///
  /// Synchronous on purpose, like everything else that appends to the stream:
  /// see the class comment.
  void group(String name, {TraceStackFrame? location}) {
    final state = _state;
    if (state == null || !state.recording) return;
    final frame = location ?? (state.options.sources ? _callerFrame() : null);
    if (frame != null && state.options.sources) {
      state.sourceFiles.add(frame.file);
    }
    final callId = 'call@${createGuid()}';
    _appendTraceEvent(BeforeActionTraceEvent(
      callId: callId,
      startTime: TraceClock.monotonicTime(),
      title: name,
      klass: 'Tracing',
      method: 'tracingGroup',
      stack: frame == null ? null : [frame],
      parentId: _currentGroupId,
    ));
    state.groupStack.add(callId);
  }

  /// Closes the innermost group. Closing one that was never opened does
  /// nothing, which is what upstream does too — a `groupEnd` in a `finally`
  /// must not turn a failure into a different one.
  void groupEnd() {
    final state = _state;
    if (state == null || state.groupStack.isEmpty) return;
    final callId = state.groupStack.removeLast();
    _appendTraceEvent(AfterActionTraceEvent(
      callId: callId,
      endTime: TraceClock.monotonicTime(),
    ));
  }

  /// A chunk that ends with groups still open would leave `before` rows with
  /// no `after`, and the viewer renders those as never-finished actions.
  void _closeAllGroups() {
    while (_currentGroupId != null) {
      groupEnd();
    }
  }

  /// The first frame outside this SDK, for a group that was not given a
  /// location of its own.
  static TraceStackFrame? _callerFrame() {
    final frames = captureStack(limit: 1);
    return frames.isEmpty ? null : frames.first;
  }

  /// Closes the current chunk. With [path] the archive is written there;
  /// otherwise it lands next to the trace files. `discard` throws everything
  /// away and returns null.
  Future<String?> stopChunk({String? path, bool discard = false}) async {
    if (_isStopping) throw StateError('Tracing is already stopping');
    _isStopping = true;
    try {
      final state = _state;
      if (state == null || !state.recording) {
        if (!discard) throw StateError('Must start tracing before stopping');
        return null;
      }

      _closeAllGroups();
      _detachListeners();
      _snapshotter.stop();
      await _stopFilmstrips();

      // The response bodies still in flight belong to this chunk, and each one
      // that lands adds a `resources/` file. The archive can only be listed
      // once they are all in: listing first and waiting afterwards silently
      // dropped every body from the zip, which is what the network test
      // caught.
      await _harTracer.flush();
      _flushPendingHarEntries();

      if (discard) {
        state.chunkFiles.clear();
        return null;
      }

      final entries = <TraceZipEntry>[
        TraceZipEntry('trace.trace', state.traceFile),
      ];
      // The network file survives across chunks, so the chunk takes a copy of
      // it under a name that cannot clash with another trace name in the same
      // directory. The `-pwnetcopy-N` suffix is upstream's.
      final networkCopy = p.join(state.tracesDir,
          '${state.traceName}-pwnetcopy-${state.chunkOrdinal}.network');
      entries.add(TraceZipEntry('trace.network', networkCopy));
      for (final file in {...state.chunkFiles, ...state.crossChunkFiles}) {
        entries.add(TraceZipEntry(file, p.join(state.tracesDir, file)));
      }
      if (state.options.sources) {
        for (final source in state.sourceFiles) {
          final name = 'src/${sha1OfText(source)}${p.extension(source)}';
          entries.add(TraceZipEntry(name, source));
        }
      }
      state.chunkFiles.clear();

      final zipFileName = path ?? '${state.traceFile}.zip';
      _fs.copyFile(state.networkFile, networkCopy);
      _fs.zip(entries, zipFileName);
      await _fs.sync();
      return zipFileName;
    } finally {
      _isStopping = false;
      _state?.recording = false;
    }
  }

  /// Stops recording altogether and removes the temporary traces directory.
  Future<void> stop() async {
    if (_state == null) return;
    if (_state!.recording) {
      // The caller never closed the chunk; drop it so tracing can restart.
      await stopChunk(discard: true).catchError((Object _) => null);
    }
    _harTracer.stop();
    final tmpDir = _tracesTmpDir;
    if (tmpDir != null) {
      _fs.removeDirectory(tmpDir);
      _tracesTmpDir = null;
    }
    try {
      await _fs.sync();
    } finally {
      _state = null;
      _started = false;
    }
  }

  /// Called when the context closes: releases listeners and the temp
  /// directory without protocol traffic.
  void dispose() {
    if (!_started) return;
    _started = false;
    for (final filmstrip in _filmstrips.values) {
      unawaited(filmstrip.dispose());
    }
    _filmstrips.clear();
    _detachListeners();
    _harTracer.stop();
    final tmpDir = _tracesTmpDir;
    if (tmpDir != null) {
      _fs.removeDirectory(tmpDir);
      _tracesTmpDir = null;
    }
    _state = null;
  }

  // ------------------------------------------------------- instrumentation

  @override
  Future<void> onBeforeCall(CoreCallMetadata metadata) async {
    // No await before the append: the event order in the file is the order the
    // calls happened.
    final state = _state;
    if (state == null || !state.recording) return;
    state.callsInProgress.add(metadata.id);
    for (final frame in metadata.stack ?? const <TraceStackFrame>[]) {
      state.sourceFiles.add(frame.file);
    }
    _appendTraceEvent(BeforeActionTraceEvent(
      callId: metadata.id,
      startTime: metadata.startTime,
      title: metadata.title,
      klass: metadata.type,
      method: metadata.method,
      params: metadata.params,
      stack: metadata.stack,
      // An open group is the parent of everything recorded inside it, but
      // only of the outermost call: a nested call already has a parent of its
      // own and re-parenting it would flatten the tree.
      parentId: metadata.parentId ?? _currentGroupId,
    ));
    await _capture(metadata, 'before');
  }

  @override
  Future<void> onBeforeInputAction(
    CoreCallMetadata metadata, {
    ({double x, double y})? point,
    ({double x, double y, double width, double height})? box,
  }) async {
    final state = _state;
    if (state == null || !state.callsInProgress.contains(metadata.id)) return;
    _appendTraceEvent(InputActionTraceEvent(
      callId: metadata.id,
      point: point,
      box: box,
    ));
    await _capture(metadata, 'action');
  }

  @override
  void onCallLog(CoreCallMetadata metadata, String message) {
    final state = _state;
    if (state == null || !state.callsInProgress.contains(metadata.id)) return;
    _appendTraceEvent(LogTraceEvent(
      callId: metadata.id,
      time: TraceClock.monotonicTime(),
      message: message,
    ));
  }

  @override
  Future<void> onAfterCall(CoreCallMetadata metadata) async {
    final state = _state;
    if (state == null || !state.callsInProgress.remove(metadata.id)) return;
    _appendTraceEvent(AfterActionTraceEvent(
      callId: metadata.id,
      endTime:
          metadata.endTime == 0 ? TraceClock.monotonicTime() : metadata.endTime,
      error: metadata.error,
      attachments: _serializeAttachments(metadata.attachments),
    ));
    await _capture(metadata, 'after');
  }

  /// Writes each attachment's bytes into the archive and returns the events
  /// pointing at them.
  ///
  /// The resource is named by the sha1 of its own bytes, like every other
  /// blob here, so attaching the same screenshot to ten steps costs one file.
  /// The bytes go in as a chunk file rather than a cross-chunk one: an
  /// attachment belongs to the action that produced it, and that action is in
  /// exactly one chunk.
  List<TraceAttachment>? _serializeAttachments(
      List<CoreCallAttachment> attachments) {
    if (attachments.isEmpty) return null;
    final state = _state;
    if (state == null) return null;
    final serialized = <TraceAttachment>[];
    for (final attachment in attachments) {
      final file = 'resources/${sha1Hex(attachment.body)}'
          '.${extensionForMimeType(attachment.contentType)}';
      state.chunkFiles.add(file);
      _appendResource(file, attachment.body);
      serialized.add(TraceAttachment(
        name: attachment.name,
        contentType: attachment.contentType,
        path: attachment.path,
        file: file,
      ));
    }
    return serialized;
  }

  // -------------------------------------------------------- context events

  void onPageOpen(CorePage page) {
    _appendTraceEvent(EventTraceEvent(
      time: TraceClock.monotonicTime(),
      klass: 'BrowserContext',
      method: 'page',
      params: {
        'pageId': page.guid,
        if (page.opener != null) 'openerPageId': page.opener!.guid,
      },
    ));
    if (_state?.options.screenshots ?? false) _startFilmstrip(page);
    if (_pageCloseListeners.containsKey(page)) return;
    void onClose([dynamic _]) => onPageClose(page);
    _pageCloseListeners[page] = onClose;
    page.once('close', onClose);
  }

  void onPageClose(CorePage page) {
    _pageCloseListeners.remove(page);
    unawaited(_filmstrips.remove(page)?.dispose());
    _appendTraceEvent(EventTraceEvent(
      time: TraceClock.monotonicTime(),
      klass: 'BrowserContext',
      method: 'pageClosed',
      params: {'pageId': page.guid},
    ));
  }

  void _onConsoleMessage(CoreConsoleMessage message) {
    _appendTraceEvent(ConsoleMessageTraceEvent(
      time: TraceClock.monotonicTime(),
      messageType: message.type,
      text: message.text,
      url: message.location.url,
      lineNumber: message.location.lineNumber,
      columnNumber: message.location.columnNumber,
    ));
  }

  void _onPageError(CorePageError error) {
    _appendTraceEvent(EventTraceEvent(
      time: TraceClock.monotonicTime(),
      klass: 'BrowserContext',
      method: 'pageError',
      params: {
        'error': {
          'error': {
            'message': error.message,
            'name': error.name,
            'stack': error.stack,
          },
        },
      },
    ));
  }

  void _onDialog(Dialog dialog) {
    _appendTraceEvent(EventTraceEvent(
      time: TraceClock.monotonicTime(),
      klass: 'BrowserContext',
      method: 'dialog',
      params: {
        'type': dialog.type,
        'message': dialog.message,
        'defaultValue': dialog.defaultValue,
      },
    ));
  }

  void _onDownload(dynamic download) {
    _appendTraceEvent(EventTraceEvent(
      time: TraceClock.monotonicTime(),
      klass: 'BrowserContext',
      method: 'download',
      params: {
        'url': '${download.url}',
        'suggestedFilename': '${download.suggestedFilename}',
      },
    ));
  }

  // ------------------------------------------------------------- HAR sink

  final _pendingEntries = <HarEntry>{};

  @override
  void onEntryStarted(HarEntry entry) {
    _pendingEntries.add(entry);
  }

  @override
  void onEntryFinished(HarEntry entry) {
    _pendingEntries.remove(entry);
    final state = _state;
    if (state == null) return;
    _fs.appendFile(
      state.networkFile,
      '${jsonEncode(ResourceSnapshotTraceEvent(entry.toJson()).toJson())}\n',
      flush: true,
    );
  }

  @override
  String onContentBlob(String shortName, List<int> bytes) {
    final file = 'resources/$shortName';
    _state?.crossChunkFiles.add(file);
    _appendResource(file, bytes);
    return file;
  }

  // ------------------------------------------------------- snapshot sink

  @override
  String onSnapshotterBlob(String shortName, List<int> bytes) {
    final file = 'resources/$shortName';
    _state?.chunkFiles.add(file);
    _appendResource(file, bytes);
    return file;
  }

  @override
  void onFrameSnapshot(Map<String, dynamic> snapshot) {
    _appendTraceEvent(FrameSnapshotTraceEvent(snapshot));
  }

  /// Writes the entries whose request never finished, so a trace stopped
  /// mid-flight still lists them.
  void _flushPendingHarEntries() {
    final state = _state;
    if (state == null || _pendingEntries.isEmpty) return;
    final lines = <String>[
      for (final entry in _pendingEntries)
        jsonEncode(ResourceSnapshotTraceEvent(entry.toJson()).toJson()),
    ];
    _pendingEntries.clear();
    _fs.appendFile(state.networkFile, '${lines.join('\n')}\n', flush: true);
  }

  // ---------------------------------------------------------------- inside

  /// Captures whatever the options asked for around one action.
  ///
  /// Node references are only reset by the first snapshot of an action, which
  /// is what lets the later phases of the same action point back at it instead
  /// of re-serializing the page.
  Future<void> _capture(CoreCallMetadata metadata, String phase) async {
    final page = metadata.page;
    // A context-level call (`newPage`, `close`) has no page to snapshot, which
    // is also how upstream decides there is nothing to capture.
    if (page == null) return;
    if (_snapshotter.started) {
      await _snapshotter.captureSnapshot(page, metadata.id, phase,
          resetTargets: phase == 'before');
    }
    await _captureScreenshot(metadata, phase);
  }

  Future<void> _captureScreenshot(
      CoreCallMetadata metadata, String phase) async {
    final state = _state;
    final page = metadata.page;
    if (state == null || page == null || !state.options.actionScreenshots) {
      return;
    }
    List<int> bytes;
    try {
      bytes = await page.screenshot(
          options: const CoreScreenshotOptions(type: 'png', scale: 'css'));
    } catch (_) {
      // Best effort, exactly as upstream: a page that navigated away or
      // crashed must not fail the action being traced.
      return;
    }
    if (!(_state?.recording ?? false)) return;
    final file = 'screenshots/${metadata.id}-$phase.png';
    state.chunkFiles.add(file);
    _appendResource(file, bytes);
    _appendTraceEvent(ScreenshotTraceEvent(
      callId: metadata.id,
      phase: phase,
      pageId: page.guid,
      timestamp: TraceClock.monotonicTime(),
      file: file,
    ));
  }

  // ------------------------------------------------------------- filmstrip

  /// Subscribes to [page]'s screencast and turns every frame into a
  /// `screencast-frame` event plus the resource it points at.
  ///
  /// The screencast is shared with video recording through [ScreencastHub]:
  /// the engines run one per page, and a trace taken while `recordVideo` is on
  /// must not fight the recorder for it.
  void _startFilmstrip(CorePage page) {
    if (_filmstrips.containsKey(page)) return;
    final filmstrip = _PageFilmstrip(page, _onScreencastFrame);
    _filmstrips[page] = filmstrip;
    unawaited(filmstrip.start());
  }

  Future<void> _stopFilmstrips() async {
    if (_filmstrips.isEmpty) return;
    final filmstrips = _filmstrips.values.toList();
    _filmstrips.clear();
    await Future.wait([for (final f in filmstrips) f.dispose()]);
  }

  void _onScreencastFrame(
      CorePage page, VideoFrame frame, int ordinal, double timestamp) {
    final state = _state;
    if (state == null || !state.recording) return;
    // The engines' screencasts deliver JPEG, which is also the only still
    // format the bundled ffmpeg can decode; a PNG here would mean the
    // screencast backend is feeding the muxer something it cannot use, and
    // silently writing it into the trace would hide that.
    if (frame.format != VideoFrameFormat.jpeg) return;
    final file = 'screencast/${page.guid}-$ordinal.jpeg';
    // Write the frame before the event that references it: a viewer reading a
    // live trace must never see a reference to a file that is not there yet.
    state.chunkFiles.add(file);
    _appendResource(file, frame.data);
    _appendTraceEvent(ScreencastFrameTraceEvent(
      pageId: page.guid,
      file: file,
      width: frame.width,
      height: frame.height,
      timestamp: timestamp,
    ));
  }

  void _listen(String event, void Function(dynamic) listener) {
    _context.on(event, listener);
    _listeners.add((event: event, listener: listener));
  }

  void _detachListeners() {
    for (final entry in _listeners) {
      _context.off(entry.event, entry.listener);
    }
    _listeners.clear();
    _context.instrumentation.captureStacks = false;
    for (final entry in _pageCloseListeners.entries) {
      entry.key.off('close', entry.value);
    }
    _pageCloseListeners.clear();
    _context.instrumentation.removeListener(this);
  }

  void _allocateNewTraceFile(_RecordingState state) {
    final suffix = state.chunkOrdinal > 0 ? '-chunk${state.chunkOrdinal}' : '';
    state.chunkOrdinal++;
    state.traceFile =
        p.join(state.tracesDir, '${state.traceName}$suffix.trace');
  }

  void _changeTraceName(_RecordingState state, String name) {
    state.traceName = name;
    state.chunkOrdinal = 0;
    _allocateNewTraceFile(state);
    final newNetworkFile = p.join(state.tracesDir, '$name.network');
    // The resources the network stream points at are shared across chunks, so
    // the stream itself has to follow the new name.
    _fs.copyFile(state.networkFile, newNetworkFile);
    state.networkFile = newNetworkFile;
  }

  void _appendTraceEvent(TraceEvent event) {
    final state = _state;
    if (state == null) return;
    _fs.appendFile(state.traceFile, '${jsonEncode(event.toJson())}\n',
        flush: true);
  }

  void _appendResource(String file, List<int> bytes) {
    if (!_allResources.add(file)) return;
    final state = _state;
    if (state == null) return;
    _fs.writeFile(p.join(state.tracesDir, file), bytes, skipIfExists: true);
  }

  String _createTracesDirIfNeeded() {
    final existing = _tracesTmpDir;
    if (existing != null) return existing;
    final dir = Directory.systemTemp.createTempSync('playwright-dart-tracing-');
    _tracesTmpDir = dir.path;
    return dir.path;
  }

  /// Upstream writes node's `process.platform`, and the viewer shows it
  /// verbatim; using node's spelling keeps a Dart trace reading like any other.
  static String _nodePlatform() {
    if (Platform.isWindows) return 'win32';
    if (Platform.isMacOS) return 'darwin';
    if (Platform.isLinux) return 'linux';
    return Platform.operatingSystem;
  }
}

/// One page's contribution to the filmstrip.
///
/// Throttled to one frame every [_throttleMs]: upstream does the same, by
/// withholding the frame acknowledgement, because a trace that keeps every
/// repaint of an animated page is mostly duplicate JPEGs. Without an ack
/// channel in the contract the surplus frames are simply dropped here, which
/// costs the same frames and none of the plumbing.
///
/// The throttle reads the trace clock, not [VideoFrame.timestamp], and hands
/// the reading on to be written into the event. Those are two different
/// clocks — when the engine painted, and when the recorder saw it — and
/// throttling on one while writing the other let frames land 114 ms apart in
/// the trace on Firefox.
class _PageFilmstrip {
  static const _throttleMs = 200.0;

  final CorePage _page;
  final void Function(
      CorePage page, VideoFrame frame, int ordinal, double timestamp) _onFrame;

  ScreencastSubscription? _subscription;
  StreamSubscription<VideoFrame>? _frames;
  double _lastKept = double.negativeInfinity;
  int _ordinal = 0;
  bool _disposed = false;

  _PageFilmstrip(this._page, this._onFrame);

  Future<void> start() async {
    try {
      final subscription = await ScreencastHub.forPage(_page)
          .addClient(size: ScreencastHub.defaultSizeFor(_page));
      if (_disposed) {
        await subscription.close();
        return;
      }
      _subscription = subscription;
      if (subscription.kind != ScreencastKind.frames) {
        // WebKit's screencast records straight to a file and hands out no
        // frames, so there is nothing to build a filmstrip from. The rest of
        // the trace is unaffected.
        return;
      }
      _frames = subscription.frames.listen(_accept);
    } catch (_) {
      // A filmstrip is an extra, not the trace: a page that cannot be filmed
      // still gets actions, snapshots and network.
    }
  }

  void _accept(VideoFrame frame) {
    if (_disposed) return;
    final now = TraceClock.monotonicTime();
    if (now - _lastKept < _throttleMs) return;
    _lastKept = now;
    _onFrame(_page, frame, _ordinal++, now);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _frames?.cancel();
    _frames = null;
    await _subscription?.close();
    _subscription = null;
  }
}

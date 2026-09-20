// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/trace-viewer/src/ui/sourceTab.tsx and
// packages/trace-viewer/src/ui/stackTrace.tsx

/// The source file of an action, and the stack that led to it.
///
/// The stack in this port is a **Dart** stack: the frames come from
/// `StackTrace.current` at the moment the call was made, recorded by this
/// port's own tracer. Upstream's frames are JavaScript. The shape is the same
/// — file, line, column, function — which is why the panel is a plain port;
/// what changes is that the file is a `.dart` path and the function name is a
/// Dart member, so the heuristics that split a path are the ones that handle
/// a Windows drive letter and a `package:` URI alike.
library;

import 'dart:async';
import 'dart:js_interop';

import 'package:playwright_trace_viewer/playwright_trace_viewer.dart';
import 'package:web/web.dart' as web;

import 'components.dart';
import 'dom.dart';
import 'format.dart' as fmt;

/// `StackTraceView`: the frames of one action, most recent first.
class StackTraceView {
  final web.HTMLElement element;
  late final ListView<StackFrame> _list;

  List<StackFrame> _frames = const [];
  int _selectedFrame = 0;

  /// Called when the user picks a frame, so the source pane can follow it.
  void Function(int index)? onFrameSelected;

  StackTraceView() : element = div(className: 'vbox') {
    _list = ListView<StackFrame>(
      name: 'stack-trace',
      ariaLabel: 'Stack trace',
      isSelected: (frame) =>
          _frames.isNotEmpty && identical(frame, _frames[_selectedFrame]),
      render: (frame, index) => [
        span(
            className: 'stack-trace-frame-function',
            text: frame.function?.isNotEmpty == true
                ? frame.function!
                : '(anonymous)'),
        span(
            className: 'stack-trace-frame-location',
            text: _baseName(frame.file)),
        span(className: 'stack-trace-frame-line', text: ':${frame.line}'),
      ],
    );
    _list.onSelected = (frame, index) {
      _selectedFrame = index;
      _list.update(_frames);
      onFrameSelected?.call(index);
    };
    element.append(_list.element);
  }

  int get selectedFrame => _selectedFrame;

  /// Shows [frames], resetting the selection to the top frame.
  void update(List<StackFrame>? frames) {
    _frames = frames ?? const [];
    _selectedFrame = 0;
    _list.update(_frames);
  }

  /// The file name of a frame's path.
  ///
  /// Upstream decides the separator by looking at whether the second
  /// character is a colon, which is the Windows drive-letter test. That also
  /// does the right thing for a Dart `package:` URI, whose colon is further
  /// in, so the path splits on `/` as it should.
  static String _baseName(String file) {
    final separator = file.length > 1 && file[1] == ':' ? r'\' : '/';
    final parts = file.split(separator);
    return parts.isEmpty ? file : parts.last;
  }
}

/// One line to highlight in the source, and why.
class SourceHighlight {
  final int line;

  /// `running` for the action's own line, `error` for a failure.
  final String type;
  final String? message;

  const SourceHighlight(this.line, this.type, {this.message});
}

/// `SourceTab`: the file, the highlighted line, and the stack beside it.
class SourceTab {
  final web.HTMLElement element;
  late final SplitView _split;
  late final StackTraceView stackTrace;
  late final web.HTMLElement _fileNameLabel;
  late final web.HTMLElement _toolbar;
  late final web.HTMLElement _code;

  TraceModel? model;

  List<StackFrame>? _stack;
  String? _loadedFile;

  SourceTab() : element = div(className: 'vbox') {
    stackTrace = StackTraceView();
    _fileNameLabel = div();
    _toolbar = div(className: 'toolbar', children: [
      div(className: 'source-tab-file-name', children: [_fileNameLabel]),
    ]);
    _code = div(
        className: 'cm-wrapper', attrs: {'data-testid': 'source-code-mirror'});
    final sourceCode = div(
        className: 'vbox',
        attrs: {'data-testid': 'source-code'},
        children: [_toolbar, _code]);

    _split = SplitView(
      orientation: 'horizontal',
      sidebarSize: 200,
      sidebarHidden: true,
    );
    _split.main.append(sourceCode);
    _split.sidebar.append(stackTrace.element);
    element.append(_split.element);

    stackTrace.onFrameSelected = (_) => unawaited(_render());
  }

  /// Shows the source for [stack], which is the active action's.
  void update(List<StackFrame>? stack) {
    _stack = stack;
    stackTrace.update(stack);
    // Upstream only shows the stack pane when there is more than one frame;
    // a single frame is already named by the file label above the code.
    _split.sidebarHidden = (stack?.length ?? 0) <= 1;
    unawaited(_render());
  }

  Future<void> _render() async {
    final stack = _stack;
    final frame = (stack != null && stack.length > stackTrace.selectedFrame)
        ? stack[stackTrace.selectedFrame]
        : null;
    if (frame == null) {
      _fileNameLabel.textContent = '';
      _toolbar.style.display = 'none';
      removeChildren(_code);
      return;
    }
    _toolbar.style.display = '';
    _fileNameLabel.textContent = fmt.fileName(frame.file);
    _fileNameLabel.parentElement?.setAttribute('title', frame.file);

    final source = model?.sources[frame.file];
    if (source?.content == null && _loadedFile != frame.file) {
      _loadedFile = frame.file;
      removeChildren(_code);
      _code.append(div(text: 'Loading…'));
      final content = await _fetchSource(frame.file);
      // Cache it on the model so switching back to this frame is instant,
      // which is what upstream's `sources` map is for.
      final existing = model?.sources[frame.file];
      if (existing != null) {
        model!.sources[frame.file] =
            SourceModel(errors: existing.errors, content: content);
      }
      // The selection may have moved on while the fetch was in flight.
      if (_stack != stack) return;
    }

    final text = model?.sources[frame.file]?.content ?? '';
    final highlights = <SourceHighlight>[
      for (final error in model?.sources[frame.file]?.errors ?? const [])
        SourceHighlight(error.line, 'error', message: error.message),
      SourceHighlight(frame.line, 'running'),
    ];
    _drawCode(text, highlights, revealLine: frame.line);
  }

  Future<String> _fetchSource(String file) async {
    try {
      final response = await web.window
          .fetch('source?path=${Uri.encodeQueryComponent(file)}'.toJS)
          .toDart;
      if (response.status >= 400) return '';
      return (await response.text().toDart).toDart;
    } on Object {
      return '<Unable to read "$file">';
    }
  }

  /// Draws the file as numbered lines.
  ///
  /// Upstream hands the text to CodeMirror, which brings syntax colouring, a
  /// search box and a gutter. This port draws the lines itself: CodeMirror is
  /// thirty thousand lines of JavaScript, it is the one dependency that would
  /// have meant shipping npm output, and what the tab is actually for — see
  /// which line ran and which line failed — needs none of it. The line
  /// classes are upstream's, so the stylesheet is the same.
  void _drawCode(String text, List<SourceHighlight> highlights,
      {required int revealLine}) {
    removeChildren(_code);
    final byLine = <int, SourceHighlight>{};
    for (final highlight in highlights) {
      byLine[highlight.line] = highlight;
    }
    final lines = text.split('\n');
    final pre = el('div', className: 'source-lines');
    web.HTMLElement? target;
    for (var i = 0; i < lines.length; i++) {
      final number = i + 1;
      final highlight = byLine[number];
      final row = div(
        className: clsx([
          'source-line',
          if (highlight != null) 'source-line-${highlight.type}',
        ]),
        attrs: {if (highlight?.message != null) 'title': highlight!.message!},
        children: [
          span(className: 'source-line-number', text: '$number'),
          span(className: 'source-line-text', text: lines[i]),
        ],
      );
      if (number == revealLine) target = row;
      pre.append(row);
    }
    _code.append(pre);
    if (target != null) scrollIntoViewIfNeeded(target);
  }
}

// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/trace-viewer/src/ui/{callTab,logTab,errorsTab,
// consoleTab,metadataView,attachmentsTab}.tsx

/// The properties panel: everything the viewer knows about one action.
library;

import 'dart:async';
import 'dart:js_interop';

import 'package:playwright_trace_viewer/playwright_trace_viewer.dart';
import 'package:web/web.dart' as web;

import 'components.dart';
import 'dom.dart';
import 'format.dart';

/// `CallTab`: the action's own parameters and timing.
class CallTab {
  final web.HTMLElement element;

  /// The trace's start, which every time is shown relative to.
  double startTimeOffset = 0;
  String sdkLanguage = 'javascript';

  CallTab() : element = div(className: 'vbox');

  void update(ActionEntry? action) {
    removeChildren(element);
    if (action == null) {
      element.append(placeholderPanel('No action selected'));
      return;
    }
    final tab = div(className: 'call-tab');
    final metainfo = CallMetainfo(
      className: action.className,
      method: action.method,
      params: action.params,
      title: action.title,
      subtitle: action.subtitle,
    );
    tab.append(div(
        className: 'call-line',
        text: renderFullTitleForCall(metainfo, sdkLanguage: sdkLanguage)));

    tab.append(div(className: 'call-section', text: 'Time'));
    tab.append(_line(
        'start', msToString(action.startTime - startTimeOffset), 'literal'));
    tab.append(_line(
        'duration',
        action.endTime != 0
            ? msToString(action.endTime - action.startTime)
            : (action.error != null ? 'Timed Out' : 'Running'),
        'literal'));

    // `info` is the internal envelope of a `waitForEvent` call and is never
    // shown, which is upstream's one filtered parameter.
    final params = <String, dynamic>{...action.params}..remove('info');
    if (params.isNotEmpty) {
      tab.append(div(className: 'call-section', text: 'Parameters'));
      params.forEach((name, value) {
        final property = _property(action, name, value);
        tab.append(_line(property.name, property.text, property.type));
      });
    }
    // `result` is whatever the call returned, which is usually a map but is
    // typed loose because a trace may carry anything there.
    final result = action.result;
    if (result is Map && result.isNotEmpty) {
      tab.append(div(className: 'call-section', text: 'Return value'));
      result.cast<String, dynamic>().forEach((name, value) {
        final property = _property(action, name, value);
        tab.append(_line(property.name, property.text, property.type));
      });
    }
    element.append(tab);
  }

  web.HTMLElement _line(String name, String text, String type) {
    // A very long parameter would push the panel wide; upstream truncates at
    // a thousand characters and folds newlines into a visible glyph.
    var display = text;
    if (display.length > 1000) display = '${display.substring(0, 1000)}…';
    display = display.replaceAll('\n', '↵');
    if (type == 'string') display = '"$display"';
    return div(className: 'call-line', children: [
      textNode('$name:'),
      span(
          className: 'call-value $type',
          text: display,
          attrs: {'title': display}),
    ]);
  }

  ({String name, String text, String type}) _property(
      ActionEntry action, String name, Object? value) {
    if (name == 'selector') {
      // Upstream renames the key: what the user thinks about is the locator,
      // not the internal selector string it was recorded as.
      return (name: 'locator', text: '$value', type: 'locator');
    }
    if (value == null) return (name: name, text: 'null', type: 'object');
    if (value is String) return (name: name, text: value, type: 'string');
    if (value is num) return (name: name, text: '$value', type: 'number');
    if (value is bool) return (name: name, text: '$value', type: 'boolean');
    if (value is Map && value['guid'] != null) {
      return (name: name, text: '<handle>', type: 'handle');
    }
    return (name: name, text: '$value', type: 'object');
  }
}

/// `LogTab`: the lines the action logged while it ran.
class LogTab {
  final web.HTMLElement element;
  late final ListView<({String time, String message})> _list;
  final web.HTMLElement _body = div(className: 'vbox');

  LogTab() : element = div(className: 'vbox') {
    _list = ListView<({String time, String message})>(
      name: 'log',
      ariaLabel: 'Log entries',
      notSelectable: true,
      render: (entry, _) => [
        div(className: 'log-list-item', children: [
          span(className: 'log-list-duration', text: entry.time),
          textNode(entry.message),
        ])
      ],
    );
    _body.append(_list.element);
    element.append(_body);
  }

  void update(ActionEntry? action) {
    removeChildren(element);
    if (action == null || action.log.isEmpty) {
      element.append(placeholderPanel('No log entries'));
      return;
    }
    final rows = <({String time, String message})>[];
    for (var i = 0; i < action.log.length; i++) {
      final entry = action.log[i];
      // A log line is timed by how long the *next* one took to arrive, which
      // is what makes the column read as "this step took that long".
      final String time;
      if (entry.time == -1) {
        time = '';
      } else if (i + 1 < action.log.length) {
        time = msToString(action.log[i + 1].time - entry.time);
      } else if (action.endTime > 0) {
        time = msToString(action.endTime - entry.time);
      } else {
        time = '-';
      }
      rows.add((time: time, message: entry.message));
    }
    element.append(_body);
    _list.update(rows);
  }
}

/// `ErrorsTab`: every failure the trace recorded, with where it happened.
class ErrorsTab {
  final web.HTMLElement element;

  /// Called when the user clicks the location, to jump to the source.
  void Function(ErrorDescription error)? onRevealInSource;

  String sdkLanguage = 'javascript';

  ErrorsTab() : element = div(className: 'vbox');

  void update(List<ErrorDescription> errors) {
    removeChildren(element);
    if (errors.isEmpty) {
      element.append(placeholderPanel('No errors'));
      return;
    }
    final body = div(className: 'fill', style: {'overflow': 'auto'});
    for (final error in errors) {
      final frame = error.stack?.isNotEmpty == true ? error.stack!.first : null;
      final header = div(className: 'hbox', style: {
        'align-items': 'center',
        'padding': '5px 10px',
        'min-height': '36px',
        'font-weight': 'bold',
        'color': 'var(--vscode-errorForeground)',
        'flex': '0',
      });
      final action = error.action;
      if (action != null) {
        header.append(span(
            className: 'action-title-method',
            text: renderFullTitleForCall(
              CallMetainfo(
                className: action.className,
                method: action.method,
                params: action.params,
                title: action.title,
                subtitle: action.subtitle,
              ),
              sdkLanguage: sdkLanguage,
            )));
      }
      if (frame != null) {
        final short = '${fileName(frame.file)}:${frame.line}';
        final long = '${frame.file}:${frame.line}';
        final button = el('button',
            attrs: {
              'type': 'button',
              'title': long,
              'aria-label': 'Go to source: $long',
            },
            text: short);
        button.onClick.listen((_) => onRevealInSource?.call(error));
        header.append(div(
            className: 'action-location', children: [textNode('@ '), button]));
      }
      body.append(div(style: {
        'display': 'flex',
        'flex-direction': 'column',
        'overflow-x': 'clip',
      }, children: [
        header,
        div(className: 'error-message', text: error.message),
      ]));
    }
    element.append(body);
  }
}

/// One line of the console panel.
class _ConsoleEntry {
  final double timestamp;
  final bool isError;
  final bool isWarning;
  final String? location;
  final String source;
  final String message;
  final String? stack;

  _ConsoleEntry({
    required this.timestamp,
    required this.isError,
    required this.isWarning,
    required this.source,
    required this.message,
    this.location,
    this.stack,
  });
}

/// `ConsoleTab`: what the page and the runner printed, on one clock.
class ConsoleTab {
  final web.HTMLElement element;
  late final ListView<_ConsoleEntry> _list;
  final web.HTMLElement _body = div(className: 'console-tab');

  double startTimeOffset = 0;

  ConsoleTab() : element = div(className: 'vbox') {
    _list = ListView<_ConsoleEntry>(
      name: 'console',
      isError: (entry) => entry.isError,
      isWarning: (entry) => entry.isWarning,
      render: (entry, _) => [
        div(className: 'console-line', children: [
          span(
              className: 'console-time',
              text: msToString(entry.timestamp - startTimeOffset)),
          span(className: 'console-source', text: entry.source, attrs: {
            'title':
                entry.source == 'test' ? 'Runner message' : 'Browser message'
          }),
          if (entry.location != null)
            span(className: 'console-location', text: entry.location!),
          span(className: 'console-line-message', text: entry.message),
          if (entry.stack != null)
            div(className: 'console-stack', text: entry.stack!),
        ])
      ],
    );
    _body.append(_list.element);
    element.append(_body);
  }

  /// The number of lines, which the tab counter shows.
  int count = 0;

  void update(TraceModel? model) {
    removeChildren(element);
    final entries = _collect(model);
    count = entries.length;
    if (entries.isEmpty) {
      element.append(placeholderPanel('No console entries'));
      return;
    }
    element.append(_body);
    _list.update(entries);
  }

  List<_ConsoleEntry> _collect(TraceModel? model) {
    if (model == null) return const [];
    final entries = <_ConsoleEntry>[];
    for (final event in model.events) {
      if (event is ConsoleMessageTraceEvent) {
        final url = event.location.url;
        final name = url.isEmpty
            ? '<anonymous>'
            : url.substring(url.lastIndexOf('/') + 1);
        entries.add(_ConsoleEntry(
          timestamp: event.time,
          isError: event.messageType == 'error',
          isWarning: event.messageType == 'warning',
          source: 'page',
          location: '$name:${event.location.lineNumber}',
          message: event.text,
        ));
      } else if (event is EventTraceEvent && event.method == 'pageError') {
        final error = event.paramsMap['error'];
        final map = error is Map ? error.cast<String, dynamic>() : null;
        entries.add(_ConsoleEntry(
          timestamp: event.time,
          isError: true,
          isWarning: false,
          source: 'page',
          message: map?['message'] as String? ?? '$error',
          stack: map?['stack'] as String?,
        ));
      }
    }
    for (final line in model.stdio) {
      entries.add(_ConsoleEntry(
        timestamp: line.timestamp,
        isError: line.stream == 'stderr',
        isWarning: false,
        source: 'test',
        message: (line.text ?? '').trimRight(),
      ));
    }
    entries.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return entries;
  }
}

/// `MetadataView`: what recorded the trace, and how much of it there is.
class MetadataView {
  final web.HTMLElement element;

  MetadataView() : element = div(className: 'vbox');

  void update(TraceModel? model) {
    removeChildren(element);
    if (model == null) return;
    final body = div(style: {
      'flex': 'auto',
      'display': 'block',
      'overflow': 'hidden auto',
    });

    body.append(div(className: 'call-section', text: 'Time'));
    final wallTime = model.wallTime;
    if (wallTime != null && wallTime != 0) {
      body.append(_line(
          'start time',
          DateTime.fromMillisecondsSinceEpoch(wallTime.toInt()).toString(),
          'datetime'));
    }
    body.append(_line(
        'duration', msToString(model.endTime - model.startTime), 'number'));
    if (model.testTimeout != null) {
      body.append(
          _line('test timeout', msToString(model.testTimeout), 'number'));
    }

    body.append(div(className: 'call-section', text: 'Browser'));
    body.append(_line('engine', model.browserName, 'string'));
    if (model.channel != null) {
      body.append(_line('channel', model.channel!, 'string'));
    }
    if (model.platform != null) {
      body.append(_line('platform', model.platform!, 'string'));
    }
    if (model.playwrightVersion != null) {
      body.append(
          _line('playwright version', model.playwrightVersion!, 'string'));
    }
    final userAgent = model.options.userAgent;
    if (userAgent != null) {
      body.append(_line('user agent', userAgent, 'datetime'));
    }
    final baseURL = model.options.baseURL;
    if (baseURL != null) {
      body.append(div(className: 'call-section', text: 'Config'));
      body.append(_line('baseURL', baseURL, 'string'));
    }

    body.append(div(className: 'call-section', text: 'Viewport'));
    final viewport = model.options.viewport;
    if (viewport != null) {
      body.append(_line('width', '${viewport.width}', 'number'));
      body.append(_line('height', '${viewport.height}', 'number'));
    }
    body.append(
        _line('is mobile', '${model.options.isMobile ?? false}', 'boolean'));
    if (model.options.deviceScaleFactor != null) {
      body.append(_line(
          'device scale', '${model.options.deviceScaleFactor}', 'number'));
    }

    body.append(div(className: 'call-section', text: 'Counts'));
    body.append(_line('pages', '${model.pages.length}', 'number'));
    body.append(_line('actions', '${model.actions.length}', 'number'));
    body.append(_line('events', '${model.events.length}', 'number'));
    element.append(body);
  }

  web.HTMLElement _line(String name, String value, String type) =>
      div(className: 'call-line', children: [
        textNode('$name:'),
        span(
            className: 'call-value $type',
            text: value,
            attrs: {'title': value}),
      ]);
}

/// `AttachmentsTab`: the files the run attached, and the images among them.
class AttachmentsTab {
  final web.HTMLElement element;

  /// Which attachment to scroll to, set when the action list asks for one.
  String? revealCallId;

  AttachmentsTab() : element = div(className: 'vbox');

  /// The attachments worth showing, which is the model's own filter: a name
  /// starting with an underscore is internal and stays hidden.
  void update(TraceModel? model) {
    removeChildren(element);
    final attachments = model?.visibleAttachments ?? const <Attachment>[];
    if (attachments.isEmpty) {
      element.append(placeholderPanel('No attachments'));
      return;
    }
    final tab = div(className: 'attachments-tab');
    final screenshots =
        attachments.where((a) => a.contentType.startsWith('image/')).toList();
    final others =
        attachments.where((a) => !a.contentType.startsWith('image/')).toList();

    if (screenshots.isNotEmpty) {
      tab.append(div(className: 'attachments-section', text: 'Screenshots'));
      for (final attachment in screenshots) {
        final url = _url(attachment);
        tab.append(div(className: 'attachment-item', children: [
          div(children: [
            el('img', attrs: {'draggable': 'false', 'src': url})
          ]),
          div(children: [
            el('a',
                attrs: {'href': url, 'target': '_blank', 'rel': 'noreferrer'},
                text: attachment.name)
          ]),
        ]));
      }
    }
    if (others.isNotEmpty) {
      tab.append(div(className: 'attachments-section', text: 'Attachments'));
      for (final attachment in others) {
        tab.append(
            div(className: 'attachment-item', children: [_render(attachment)]));
      }
    }
    element.append(tab);
  }

  web.HTMLElement _render(Attachment attachment) {
    final url = _url(attachment);
    final downloadLink = el('a',
        style: {'margin-left': '5px'},
        attrs: {'href': _downloadUrl(attachment)},
        text: 'download');
    // Only a textual attachment can be unfolded in place; anything else is
    // just a name and a link, as upstream has it.
    if (!_isTextual(attachment.contentType) || url == null) {
      return div(style: {
        'margin-left': '20px'
      }, children: [
        span(
            style: {'margin-left': '5px'},
            text: attachment.name,
            attrs: {'aria-label': attachment.name}),
        if (url != null) downloadLink,
      ]);
    }
    final expandable = Expandable(
      title: span(
          style: {'margin-left': '5px'},
          text: attachment.name,
          attrs: {'aria-label': attachment.name}),
      titleChildren: [downloadLink],
    );
    final body = div(className: 'vbox');
    expandable.onToggled = (expanded) {
      if (!expanded || body.hasChildNodes()) return;
      body.append(el('i', text: 'Loading ...'));
      unawaited(_loadText(url).then((text) {
        removeChildren(body);
        // The snippet is at least five lines tall and at most twenty, which
        // keeps a one-line attachment from looking broken and a long one
        // from taking the whole panel.
        final lines = text.split('\n').length.clamp(5, 20);
        body.style.height = '${lines * 20}px';
        body.append(
            div(className: 'cm-wrapper', children: [el('pre', text: text)]));
      }));
    };
    final wrapper = div(children: [expandable.element, body]);
    if (revealCallId != null && revealCallId == attachment.callId) {
      wrapper.classList.add('yellow-flash');
      scrollIntoViewIfNeeded(wrapper);
    }
    return wrapper;
  }

  Future<String> _loadText(String url) async {
    try {
      final response = await web.window.fetch(url.toJS).toDart;
      return (await response.text().toDart).toDart;
    } on Object {
      return 'Failed to load';
    }
  }

  String? _url(Attachment attachment) {
    final file = attachment.file;
    if (file != null) return 'file/${Uri.encodeComponent(file)}';
    final path = attachment.path;
    if (path != null) return 'file?path=${Uri.encodeQueryComponent(path)}';
    return null;
  }

  String _downloadUrl(Attachment attachment) {
    final url = _url(attachment);
    if (url == null) return '';
    return '$url${url.contains('?') ? '&' : '?'}'
        'dn=${Uri.encodeQueryComponent(attachment.name)}'
        '&dct=${Uri.encodeQueryComponent(attachment.contentType)}';
  }

  bool _isTextual(String contentType) =>
      contentType.startsWith('text/') ||
      contentType.contains('json') ||
      contentType.contains('xml') ||
      contentType.contains('javascript');
}

/// `AnnotationsTab`: the annotations the test runner attached to this test.
class AnnotationsTab {
  final web.HTMLElement element;

  AnnotationsTab() : element = div(className: 'vbox');

  void update(TraceModel? model) {
    removeChildren(element);
    final annotations = model?.annotations ?? const <TraceEventAnnotation>[];
    if (annotations.isEmpty) {
      element.append(placeholderPanel('No annotations'));
      return;
    }
    final tab = div(className: 'annotations-tab');
    for (final annotation in annotations) {
      final item = div(className: 'annotation-item', children: [
        span(text: annotation.type, style: {'font-weight': 'bold'}),
      ]);
      final description = annotation.description;
      if (description != null && description.isNotEmpty) {
        item.append(span(children: [
          textNode(': '),
          for (final piece in linkifyText(description))
            if (piece.isLink)
              el('a',
                  attrs: {
                    'href': piece.href,
                    'target': '_blank',
                    'rel': 'noopener noreferrer'
                  },
                  text: piece.text)
            else
              textNode(piece.text),
        ]));
      }
      tab.append(item);
    }
    element.append(tab);
  }
}

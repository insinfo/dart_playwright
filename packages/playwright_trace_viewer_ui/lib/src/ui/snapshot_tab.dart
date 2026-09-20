// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/trace-viewer/src/ui/snapshotTab.tsx and
// packages/trace-viewer/src/ui/browserFrame.tsx

/// The panel that redraws the page as it was when an action ran.
///
/// This is the reason the viewer is a web page and not a Flutter app: what it
/// shows is a real document, rebuilt from the captured DOM and loaded in an
/// `<iframe>`. Everything it needs is served by the model's `SnapshotServer`;
/// this file only asks for the right URL and sizes the frame around it.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:playwright_trace_viewer/playwright_trace_viewer.dart';
import 'package:web/web.dart' as web;

import 'dom.dart';

/// One snapshot the panel can show: an action, a phase, and where the mouse
/// went if the phase is the action itself.
class _Snapshot {
  final ActionEntry action;
  final ActionPhase phase;
  TracePoint? point;

  _Snapshot(this.action, this.phase);
}

/// The viewport and URL of a snapshot, which the panel needs before the page
/// inside the iframe has loaded.
class _SnapshotInfo {
  String url = '';
  double width = 1280;
  double height = 720;
}

/// `SnapshotTab`: the phase tabs, the fake browser chrome and the iframe.
class SnapshotTab {
  final web.HTMLElement element;
  final String traceUri;

  TraceModel? model;

  late final web.HTMLElement _tabList;
  late final web.HTMLElement _wrapper;
  late final web.HTMLElement _container;
  late final web.HTMLElement _address;
  late final web.HTMLElement _body;
  late final web.HTMLElement _viewportBox;
  late final web.HTMLIFrameElement _iframeA;
  late final web.HTMLIFrameElement _iframeB;

  String _phase = 'action';
  ActionEntry? _action;
  int _visibleIframe = 0;
  int _iteration = 0;
  _SnapshotInfo _info = _SnapshotInfo();

  SnapshotTab({required this.traceUri})
      : element = div(className: 'snapshot-tab vbox') {
    _tabList = div(attrs: {'role': 'tablist'}, style: {'height': '100%'});
    _tabList.className = 'hbox';
    final toolbar = div(className: 'toolbar', children: [
      _tabList,
      div(style: {'flex': 'auto'}),
      toolbarButton(
        icon: 'link-external',
        title: 'Open snapshot in a new tab',
        onClick: _openInNewTab,
      ),
    ]);

    _address = span(className: 'browser-frame-address', text: 'about:blank');
    final header = div(className: 'browser-frame-header', children: [
      div(className: 'browser-traffic-lights', children: [
        span(
            className: 'browser-frame-dot',
            style: {'background-color': 'rgb(242, 95, 88)'}),
        span(
            className: 'browser-frame-dot',
            style: {'background-color': 'rgb(251, 190, 60)'}),
        span(
            className: 'browser-frame-dot',
            style: {'background-color': 'rgb(88, 203, 66)'}),
      ]),
      div(
          className: 'browser-frame-address-bar',
          attrs: {'title': 'about:blank'},
          children: [_address]),
      div(style: {
        'margin-left': 'auto'
      }, children: [
        div(children: [
          span(className: 'browser-frame-menu-bar'),
          span(className: 'browser-frame-menu-bar'),
          span(className: 'browser-frame-menu-bar'),
        ])
      ]),
    ]);

    _iframeA = _createIframe();
    _iframeB = _createIframe();
    final switcher =
        div(className: 'snapshot-switcher', children: [_iframeA, _iframeB]);
    _viewportBox = div(children: [switcher]);
    _body = div(className: 'snapshot-browser-body', children: [_viewportBox]);
    _container =
        div(className: 'snapshot-container', children: [header, _body]);
    _wrapper = div(className: 'snapshot-wrapper', children: [_container]);

    element.append(toolbar);
    element.append(div(className: 'vbox', attrs: {'tabindex': '0'}, children: [
      _wrapper,
    ]));
    _renderPhaseTabs();

    // The frame is sized against the space it was given, so it has to be
    // measured again whenever that space changes.
    web.window.addEventListener('resize', ((web.Event _) => _layout()).toJS);
    final observer = web.ResizeObserver(((JSArray _, web.ResizeObserver __) {
      _layout();
    }).toJS);
    observer.observe(_wrapper);
  }

  web.HTMLIFrameElement _createIframe() => el('iframe', attrs: {
        'name': 'snapshot',
        'title': 'DOM Snapshot',
        'sandbox': 'allow-same-origin allow-scripts',
      }) as web.HTMLIFrameElement;

  /// Shows the snapshots of [action], keeping the phase the user picked.
  void update(ActionEntry? action) {
    _action = action;
    _renderPhaseTabs();
    unawaited(_load());
  }

  void _renderPhaseTabs() {
    removeChildren(_tabList);
    for (final entry in const [
      ('action', 'Action'),
      ('before', 'Before'),
      ('after', 'After'),
    ]) {
      final selected = entry.$1 == _phase;
      final button = el('button',
          className: clsx(['tabbed-pane-tab', selected ? 'selected' : null]),
          attrs: {
            'role': 'tab',
            'title': entry.$2,
            'aria-selected': '$selected',
          },
          children: [
            div(className: 'tabbed-pane-tab-label', text: entry.$2)
          ]);
      button.onClick.listen((_) {
        _phase = entry.$1;
        _renderPhaseTabs();
        unawaited(_load());
      });
      _tabList.append(button);
    }
  }

  /// `collectSnapshots`: which snapshot each phase tab actually shows.
  ///
  /// An action does not always capture all three phases, so `before` falls
  /// back to the `after` of the last action that ended before this one
  /// started, and `after` to the last one that finished inside this one.
  /// That is what makes the tabs useful on a trace that only snapshots on
  /// change.
  ({_Snapshot? action, _Snapshot? before, _Snapshot? after}) _collect(
      ActionEntry action) {
    final traceModel = model;
    if (traceModel == null) return (action: null, before: null, after: null);

    _Snapshot? create(ActionEntry? candidate, ActionPhase phase) {
      if (candidate == null) return null;
      if (!traceModel.hasDomSnapshotForCall(candidate.callId, phase)) {
        return null;
      }
      return _Snapshot(candidate, phase);
    }

    var before = create(action, ActionPhase.before);
    if (before == null) {
      var candidate = previousActionByEndTime(action);
      while (candidate != null) {
        if (candidate.endTime <= action.startTime &&
            traceModel.hasDomSnapshotForCall(
                candidate.callId, ActionPhase.after)) {
          before = _Snapshot(candidate, ActionPhase.after);
          break;
        }
        candidate = previousActionByEndTime(candidate);
      }
    }

    var after = create(action, ActionPhase.after);
    if (after == null) {
      ActionEntry? last;
      var candidate = nextActionByStartTime(action);
      while (candidate != null && candidate.startTime <= action.endTime) {
        if (candidate.endTime <= action.endTime &&
            traceModel.hasDomSnapshotForCall(
                candidate.callId, ActionPhase.after) &&
            (last == null || last.endTime <= candidate.endTime)) {
          last = candidate;
        }
        candidate = nextActionByStartTime(candidate);
      }
      after = last == null ? before : _Snapshot(last, ActionPhase.after);
    }

    final actionSnapshot = create(action, ActionPhase.action) ?? after;
    // The recorded mouse point belongs to the action phase whichever
    // snapshot ends up standing in for it.
    actionSnapshot?.point = action.point;
    return (action: actionSnapshot, before: before, after: after);
  }

  _Snapshot? get _current {
    final action = _action;
    if (action == null) return null;
    final snapshots = _collect(action);
    return switch (_phase) {
      'before' => snapshots.before,
      'after' => snapshots.after,
      _ => snapshots.action,
    };
  }

  /// The query every snapshot request carries.
  String _params(_Snapshot snapshot) {
    final params = <String, String>{
      'trace': traceUri,
      if (snapshot.point != null) 'pointX': '${snapshot.point!.x}',
      if (snapshot.point != null) 'pointY': '${snapshot.point!.y}',
      'phase': snapshot.phase.wire,
    };
    return params.entries
        .map((e) =>
            '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
  }

  String? _snapshotUrl(_Snapshot snapshot) =>
      'snapshot/${Uri.encodeComponent(snapshot.action.callId)}?${_params(snapshot)}';

  /// An empty document, for an action with nothing captured.
  ///
  /// Upstream inlines the same `data:` URL so the panel always has something
  /// to show rather than an iframe stuck on the previous action.
  static final String _blankUrl = 'data:text/html;base64,${base64Encode(utf8.encode(
      '<body></body><style>body { color-scheme: light dark; background: light-dark(white, #333) }</style>'))}';

  Future<void> _load() async {
    final iteration = ++_iteration;
    final snapshot = _current;
    final info = _SnapshotInfo();
    if (snapshot != null) {
      final infoUrl =
          'snapshotInfo/${Uri.encodeComponent(snapshot.action.callId)}?${_params(snapshot)}';
      try {
        final response = await web.window.fetch(infoUrl.toJS).toDart;
        final text = (await response.text().toDart).toDart;
        final json = jsonDecode(text) as Map<String, dynamic>;
        if (json['error'] == null) {
          info.url = json['url'] as String? ?? '';
          final viewport = json['viewport'] as Map<String, dynamic>?;
          if (viewport != null) {
            info.width = (viewport['width'] as num?)?.toDouble() ?? 1280;
            info.height = (viewport['height'] as num?)?.toDouble() ?? 720;
          }
        }
      } on Object {
        // A snapshot the server does not know: the blank page is the answer.
      }
    }
    if (iteration != _iteration) return;

    // The two iframes swap: the hidden one loads, and only once it is ready
    // does it become the visible one, so the panel never flashes an empty
    // frame between two actions.
    final target = _visibleIframe == 0 ? _iframeB : _iframeA;
    final url = snapshot == null ? _blankUrl : _snapshotUrl(snapshot)!;
    final loaded = Completer<void>();
    void done(web.Event _) {
      if (!loaded.isCompleted) loaded.complete();
    }

    final listener = done.toJS;
    target.addEventListener('load', listener);
    target.addEventListener('error', listener);
    try {
      // `location.replace` rather than `src`, so stepping through a trace
      // does not fill the browser's history with snapshots.
      target.contentWindow?.location.replace(url);
    } on Object {
      target.src = url;
    }
    await loaded.future;
    target.removeEventListener('load', listener);
    target.removeEventListener('error', listener);
    if (iteration != _iteration) return;

    _visibleIframe = _visibleIframe == 0 ? 1 : 0;
    _iframeA.classList.toggle('snapshot-visible', _visibleIframe == 0);
    _iframeB.classList.toggle('snapshot-visible', _visibleIframe == 1);
    _info = info;
    _address.textContent = info.url.isEmpty ? 'about:blank' : info.url;
    _layout();
  }

  /// Fits the recorded viewport into the space the panel was given.
  ///
  /// The frame is never scaled up: a page recorded at 800x600 is shown at
  /// 800x600 in a larger panel, because an upscaled snapshot reads as a
  /// rendering bug that is not there.
  void _layout() {
    _viewportBox.style.width = '${_info.width}px';
    _viewportBox.style.height = '${_info.height}px';

    const headerHeight = 40.0;
    const padding = 10.0;
    final frameWidth = _info.width < 480 ? 480.0 : _info.width;
    final frameHeightRaw = _info.height + headerHeight;
    final frameHeight = frameHeightRaw < 320 ? 320.0 : frameHeightRaw;

    final measure = _wrapper.getBoundingClientRect();
    final availableWidth = measure.width - 2 * padding;
    final availableHeight = measure.height - 2 * padding;
    var scale = availableWidth / frameWidth;
    final byHeight = availableHeight / frameHeight;
    if (byHeight < scale) scale = byHeight;
    if (scale > 1 || !scale.isFinite || scale <= 0) scale = 1;

    final translateX = (measure.width - frameWidth) / 2 - padding;
    final translateY = (measure.height - frameHeight) / 2 - padding;
    _container.style.width = '${frameWidth}px';
    _container.style.height = '${frameHeight}px';
    _container.style.transform =
        'translate(${translateX}px, ${translateY}px) scale($scale)';
  }

  void _openInNewTab() {
    final snapshot = _current;
    if (snapshot == null) return;
    web.window.open(_snapshotUrl(snapshot)!, '_blank');
  }
}

// Part of the Dart port of the Playwright trace viewer UI.

/// The viewer's entrypoint, compiled to JavaScript by dart2js.
///
/// It does three things: register the service worker that the snapshot frames
/// need, read the trace from `/contexts`, and mount the workbench. The model
/// it builds is the same `TraceModel` the server has — the contexts cross the
/// wire as JSON and are rebuilt here — so every panel asks the real model
/// rather than a flattened view of it.
library;

import 'dart:convert';
import 'dart:js_interop';

import 'package:playwright_trace_viewer/playwright_trace_viewer.dart';
import 'package:playwright_trace_viewer_ui/src/ui/dom.dart';
import 'package:playwright_trace_viewer_ui/src/ui/workbench.dart';
import 'package:playwright_trace_viewer_ui/src/wire.dart';
import 'package:web/web.dart' as web;

void main() {
  _applyTheme();
  _start();
}

Future<void> _start() async {
  final root = web.document.getElementById('root') ?? web.document.body!;
  removeChildren(root);
  root.append(div(className: 'vbox', text: 'Loading trace…'));

  // The worker only proxies what the snapshot asks of origins this server
  // does not own. A viewer whose snapshots have no external resources works
  // without it, so a failure here is reported and not fatal.
  try {
    await web.window.navigator.serviceWorker.register('sw.js'.toJS).toDart;
  } on Object catch (error) {
    web.console.warn('Snapshot resource worker not registered: $error'.toJS);
  }

  try {
    final response = await web.window.fetch('contexts'.toJS).toDart;
    final text = (await response.text().toDart).toDart;
    final decoded =
        contextEntriesFromJson(jsonDecode(text) as Map<String, dynamic>);
    final model = TraceModel(decoded.traceUri, decoded.contexts);
    removeChildren(root);
    root.append(Workbench(model, traceUri: decoded.traceUri).element);
    web.document.title =
        model.title?.isNotEmpty == true ? model.title! : 'Playwright Trace';
  } on Object catch (error) {
    removeChildren(root);
    root.append(div(className: 'vbox', children: [
      div(className: 'error-message', text: 'Failed to open the trace: $error'),
    ]));
  }
}

/// Follows the system's light or dark preference, as upstream's theme does.
void _applyTheme() {
  final query = web.window.matchMedia('(prefers-color-scheme: dark)');
  void apply() {
    final classes = web.document.documentElement!.classList;
    classes.toggle('dark-mode', query.matches);
    classes.toggle('light-mode', !query.matches);
  }

  apply();
  query.addEventListener('change', ((web.Event _) => apply()).toJS);
}

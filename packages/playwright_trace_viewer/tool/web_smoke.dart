// Smoke entrypoint: proves the core library compiles to the web.
//
//   dart compile js -o /tmp/out.js packages/playwright_trace_viewer/tool/web_smoke.dart
//
// Nothing in `playwright_trace_viewer.dart` may import `dart:io`,
// `dart:html` or `package:web`; this is what catches a slip.
import 'dart:typed_data';

import 'package:playwright_trace_viewer/playwright_trace_viewer.dart';

void main() {
  final loader = TraceLoader();
  final backend = ZipTraceLoaderBackend(Uint8List(0));
  loader.load(backend).then((_) {
    final model = TraceModel('trace.zip', loader.contextEntries);
    final server = SnapshotServer(loader.storage(), (file) async => null);
    print(model.actions.length);
    print(server.serveSnapshotInfo('x', const {}).status);
  });
}

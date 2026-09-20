// Part of the Dart port of the Playwright trace viewer UI.

/// A trace archive built in memory, so the tests need no browser.
///
/// The shape is the recorder's: one JSON line per event in `trace.trace`, the
/// HAR entries in `trace.network`, the stacks in `trace.stacks`, and the
/// bodies by relative path. It is written with the version-9 writers because
/// that is what this port's recorder emits.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:playwright_trace_viewer/src/versions/trace_v9.dart';

/// The path of the source file the fixture's stack points at.
const String kFixtureSourcePath = 'example/probe.dart';

/// The text of that file, which the Source tab must come back with.
const String kFixtureSourceText = '''
void main() {
  // line two
  goto('http://localhost/');
}
''';

/// Writes the fixture archive to a temporary file and returns its path.
Future<String> writeFixtureTrace(Directory directory) async {
  final file = File('${directory.path}/fixture.zip');
  await file.writeAsBytes(buildFixtureTrace());
  return file.path;
}

/// The fixture archive as bytes.
Uint8List buildFixtureTrace() {
  final sourceEntry =
      'src/${sha1.convert(utf8.encode(kFixtureSourcePath))}.dart';
  return _zip({
    'trace.trace': _lines([
      ContextCreatedTraceEventV9(
        origin: 'library',
        browserName: 'chromium',
        platform: 'win32',
        playwrightVersion: '1.62.0',
        wallTime: 1700000000000,
        monotonicTime: 1000,
        options: {
          'viewport': {'width': 900, 'height': 600}
        },
        sdkLanguage: 'dart',
        title: 'fixture',
      ).toJson(),
      BeforeActionTraceEventV9(
        callId: 'call@1',
        startTime: 1100,
        title: 'Navigate',
        subtitle: 'localhost/',
        className: 'Frame',
        method: 'goto',
        params: {'url': 'http://localhost/'},
      ).toJson(),
      LogTraceEventV6(callId: 'call@1', time: 1120, message: 'navigating')
          .toJson(),
      AfterActionTraceEventV9(callId: 'call@1', endTime: 1200).toJson(),
      BeforeActionTraceEventV9(
        callId: 'call@2',
        startTime: 1300,
        className: 'Frame',
        method: 'click',
        params: {'selector': '#load'},
      ).toJson(),
      AfterActionTraceEventV9(callId: 'call@2', endTime: 1400).toJson(),
      ScreencastFrameTraceEventV9(
        pageId: 'page@1',
        file: 'resources/frame.jpeg',
        width: 900,
        height: 600,
        timestamp: 1150,
      ).toJson(),
      // The console event has not changed shape since version 5, so that is
      // the writer version 9 re-exports.
      const ConsoleMessageTraceEventV5(
        time: 1160,
        pageId: 'page@1',
        messageType: 'log',
        text: 'page booted',
        locationUrl: 'http://localhost/',
        locationLineNumber: 8,
        locationColumnNumber: 1,
      ).toJson(),
      FrameSnapshotTraceEventV9(
        snapshot: FrameSnapshotV9(
          phase: 'before',
          callId: 'call@1',
          pageId: 'page@1',
          frameId: 'frame@1',
          frameUrl: 'http://localhost/',
          timestamp: 1100,
          collectionTime: 1,
          html: const [
            'HTML',
            <String, String>{},
            [
              'BODY',
              <String, String>{},
              [
                'LINK',
                {'rel': 'stylesheet', 'href': 'http://localhost/a.css'}
              ],
              'hello from the fixture'
            ]
          ],
          viewport: (width: 900, height: 600),
          isMainFrame: true,
        ),
      ).toJson(),
    ]),
    'trace.network': _lines([
      _harEntry(
        url: 'http://localhost/a.css',
        file: 'resources/a.css',
        mimeType: 'text/css; charset=utf-8',
        monotonicTime: 1050,
      ),
    ]),
    'trace.stacks': jsonEncode({
      'files': [kFixtureSourcePath],
      'stacks': [
        [
          'call@1',
          [
            [0, 3, 3, 'main']
          ]
        ]
      ],
    }),
    'resources/a.css': 'body { color: red; }',
    'resources/frame.jpeg': const [0xFF, 0xD8, 0xFF, 0xD9],
    sourceEntry: kFixtureSourceText,
  });
}

Uint8List _zip(Map<String, Object> entries) {
  final archive = Archive();
  entries.forEach((name, content) {
    if (content is String) {
      archive.add(ArchiveFile.string(name, content));
    } else {
      archive.add(ArchiveFile.bytes(name, content as List<int>));
    }
  });
  return Uint8List.fromList(ZipEncoder().encodeBytes(archive));
}

String _lines(List<Map<String, dynamic>> events) =>
    events.map(jsonEncode).join('\n');

Map<String, dynamic> _harEntry({
  required String url,
  required String file,
  required String mimeType,
  required double monotonicTime,
}) =>
    {
      'type': 'resource-snapshot',
      'snapshot': {
        'startedDateTime': '2026-09-19T00:00:00.000Z',
        'time': 12,
        '_monotonicTime': monotonicTime,
        '_frameref': 'frame@1',
        'request': {
          'method': 'GET',
          'url': url,
          'headers': <Map<String, String>>[],
        },
        'response': {
          'status': 200,
          'statusText': 'OK',
          'bodySize': 20,
          'headers': [
            {'name': 'content-type', 'value': mimeType},
          ],
          'content': {'size': 20, 'mimeType': mimeType, '_file': file},
        },
      },
    };

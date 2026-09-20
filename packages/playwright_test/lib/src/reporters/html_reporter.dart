import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'html_app.dart';
import 'model.dart';

/// Writes a browsable HTML report.
///
/// ## Why this is not a React port
///
/// Upstream's report is a Vite-built React application: 54 files under
/// `packages/html-reporter/src`, most of them components, sharing a base with
/// the trace viewer under `packages/web/src/components`. Another front in this
/// port is bringing that base to Dart web compiled by dart2js, and the obvious
/// move was to wait and share it.
///
/// This does not wait, for two reasons. The first is that a report is not a
/// viewer: the trace viewer is a timeline over a recording, with a snapshot
/// renderer and a service worker unzipping frames, and the report is a list, a
/// filter and a detail pane. Almost none of the expensive part transfers. The
/// second is that a reporter blocked behind a compiler toolchain is a reporter
/// nobody has, and a run that failed in CI last night needs to be readable
/// this morning.
///
/// So the page is plain HTML with the data inlined and about six hundred lines
/// of vanilla JavaScript, and it has no build step at all.
///
/// **What that costs**, stated plainly rather than discovered later:
///
/// * no image-diff viewer -- upstream shows expected/actual/diff with a
///   slider and a swap, and here the three images are simply shown in a row;
/// * no trace viewer embedded in the report; the trace attachment is a
///   download, and it opens in the viewer separately;
/// * no ANSI-to-HTML colouring of failures -- colours are stripped instead;
/// * no lazy per-file loading, so a run with tens of thousands of tests
///   produces one large page where upstream produces a small one plus
///   fetched-on-demand chunks;
/// * no source snippet with the failing line highlighted, because that needs
///   a code frame builder this port does not have yet;
/// * no "copy prompt" button, no metadata/git panel, no shard timeline.
///
/// **What it deliberately keeps** is the part a later UI would have to agree
/// with anyway: the *data contract*. The JSON inlined in the page is upstream's
/// `HTMLReport`, `TestFileSummary`, `TestCaseSummary`, `TestCase`,
/// `TestResult`, `TestStep`, `TestAttachment` and `Stats`, field for field
/// from `packages/html-reporter/src/types.d.ts`, and the attachments are
/// written to `data/<sha1><ext>` the way upstream writes them. The filter
/// grammar (`p:`, `s:`, `@tag`, `!` negation, quoting, `file:line`) is ported
/// too. A Dart-web UI can therefore replace the rendering layer here and read
/// the same folder without the generator changing.
class HtmlReporter {
  /// Folder the report is written to. Wiped first, like upstream's.
  final String outputFolder;

  /// Where the run happened, for resolving attachment paths.
  final String rootDir;

  /// The `<title>` of the page.
  final String title;

  const HtmlReporter({
    required this.outputFolder,
    required this.rootDir,
    this.title = 'Playwright Test Report',
  });

  /// Writes the report and returns the path of `index.html`.
  Future<String> write(ReportRun run) async {
    final folder = Directory(outputFolder);
    // Upstream removes the folder first. A report is a snapshot of one run,
    // and a stale `data/` file from the run before it is a screenshot that
    // shows the wrong failure -- the most expensive kind of wrong.
    if (folder.existsSync()) await folder.delete(recursive: true);
    await folder.create(recursive: true);

    final report = buildReport(run);
    final indexPath = p.join(outputFolder, 'index.html');
    final payload = base64Encode(utf8.encode(jsonEncode(report)));
    await File(indexPath).writeAsString(renderIndexHtml(title, payload));
    return indexPath;
  }

  /// Builds the whole inlined payload: the summary plus every file's detail.
  ///
  /// Upstream splits these into `report.json` and one `<fileId>.json` per
  /// file, zipped, so the page can fetch a file's detail only when opened.
  /// Here they travel together because there is nothing to fetch from -- the
  /// page is one file. The two halves keep their upstream shapes so that a
  /// renderer written against upstream's types reads them unchanged.
  Map<String, Object?> buildReport(ReportRun run) {
    final summaries = <Map<String, Object?>>[];
    final details = <String, Object?>{};
    final total = _emptyStats();

    for (final file in run.files) {
      final fileId = _fileId(file.path);
      final sorted = [...file.tests]..sort(_failuresFirst);
      final stats = _emptyStats();
      for (final test in sorted) {
        stats[test.outcome.wire] = (stats[test.outcome.wire] as int) + 1;
        stats['total'] = (stats['total'] as int) + 1;
      }
      stats['ok'] = (stats['unexpected'] as int) + (stats['flaky'] as int) == 0;
      _addStats(total, stats);

      summaries.add({
        'fileId': fileId,
        'fileName': file.path,
        'tests': sorted.map((test) => _caseSummary(test, fileId)).toList(),
        'stats': stats,
      });
      details[fileId] = {
        'fileId': fileId,
        'fileName': file.path,
        'tests': sorted.map((test) => _testCase(test, fileId)).toList(),
      };
    }

    // Failing files first: the reader came here because something broke, and
    // scrolling past four hundred green files to find it is the difference
    // between a report and a log.
    summaries.sort((a, b) {
      final sa = a['stats'] as Map<String, Object?>;
      final sb = b['stats'] as Map<String, Object?>;
      final wa = (sa['unexpected'] as int) * 1000 + (sa['flaky'] as int);
      final wb = (sb['unexpected'] as int) * 1000 + (sb['flaky'] as int);
      return wb - wa;
    });

    final projectNames = run.tests.map((test) => test.platform).toSet().toList()
      ..sort();

    return {
      'report': {
        'metadata': <String, Object?>{},
        'files': summaries,
        'stats': total,
        'projectNames': projectNames,
        'startTime': run.startTime.millisecondsSinceEpoch,
        'duration': run.duration.inMilliseconds,
        'machines': <Object?>[],
        'errors': run.errors
            .map((error) => error.stack == null
                ? error.message
                : '${error.message}\n\n${error.stack}')
            .toList(),
        'options': {'title': title},
      },
      'files': details,
    };
  }

  static int _failuresFirst(ReportTest a, ReportTest b) {
    int weight(ReportTest test) =>
        (test.outcome == ReportOutcome.unexpected ? 1000 : 0) +
        (test.outcome == ReportOutcome.flaky ? 1 : 0);
    return weight(b) - weight(a);
  }

  Map<String, Object?> _caseSummary(ReportTest test, String fileId) => {
        'testId': test.id,
        'title': test.title,
        'path': test.groups,
        'projectName': test.platform,
        'location': _location(test),
        'annotations': _annotations(test),
        'tags': test.tags,
        'outcome': test.outcome.wire,
        'duration': test.duration.inMilliseconds,
        'ok': test.outcome != ReportOutcome.unexpected,
        'results': test.results
            .map((result) => {
                  'attachments': result.attachments
                      .map((a) => {
                            'name': a.name,
                            'contentType': a.contentType,
                            if (a.path != null) 'path': _copy(a.path!),
                          })
                      .toList(),
                  'startTime': result.startTime.toUtc().toIso8601String(),
                  'workerIndex': 0,
                })
            .toList(),
      };

  Map<String, Object?> _testCase(ReportTest test, String fileId) => {
        ..._caseSummary(test, fileId),
        'results': test.results.map((result) => _result(test, result)).toList(),
      };

  Map<String, Object?> _result(ReportTest test, ReportResult result) {
    final attachments = result.attachments
        .map((a) => {
              'name': a.name,
              'contentType': a.contentType,
              if (a.path != null) 'path': _copy(a.path!),
              if (a.base64Body != null) ..._inlineBody(a),
            })
        .toList();
    // Upstream's `TestStep.attachments` is a list of *indices* into the
    // result's attachments, not of objects, so that the same file shown in two
    // places is stored once.
    final indexByStep = <String, List<int>>{};
    for (var i = 0; i < result.attachments.length; i++) {
      final stepId = result.attachments[i].stepId;
      if (stepId != null) indexByStep.putIfAbsent(stepId, () => []).add(i);
    }
    return {
      'retry': result.retry,
      'startTime': result.startTime.toUtc().toIso8601String(),
      'duration': result.duration.inMilliseconds,
      'steps':
          result.steps.map((step) => _step(step, result, indexByStep)).toList(),
      'errors': result.errors
          .map((error) => {
                'message': error.stack == null
                    ? error.message
                    : '${error.message}\n\n${error.stack}',
              })
          .toList(),
      'attachments': attachments,
      'status': result.status.wire,
      'annotations': _annotations(test),
      'workerIndex': 0,
    };
  }

  Map<String, Object?> _step(
    ReportStep step,
    ReportResult result,
    Map<String, List<int>> indexByStep,
  ) =>
      {
        'title': step.title,
        'startTime': result.startTime
            .add(Duration(milliseconds: step.startTime))
            .toUtc()
            .toIso8601String(),
        'duration': step.duration.inMilliseconds,
        if (step.error != null) 'error': step.error,
        'steps': step.steps
            .map((child) => _step(child, result, indexByStep))
            .toList(),
        'attachments': indexByStep[step.id] ?? const <int>[],
        'count': 1,
      };

  List<Map<String, Object?>> _annotations(ReportTest test) => [
        if (test.skipReason != null)
          {'type': 'skip', 'description': test.skipReason},
      ];

  Map<String, Object?> _location(ReportTest test) => {
        'file': test.location?.file ?? test.file,
        'line': test.location?.line ?? 0,
        'column': test.location?.column ?? 0,
      };

  /// Turns an inline attachment into either text or a written-out file.
  ///
  /// Upstream's rule: a text content type keeps its body in the JSON, where
  /// the page can show it without a round trip; anything else goes to disk,
  /// because base64 of a video inside a JSON string is how a report becomes
  /// too big to open.
  Map<String, Object?> _inlineBody(ReportAttachment attachment) {
    final bytes = base64Decode(attachment.base64Body!);
    if (attachment.contentType.startsWith('text/') ||
        attachment.contentType.startsWith('application/json')) {
      try {
        return {'body': utf8.decode(bytes)};
      } catch (_) {
        // Not the encoding it claimed. Fall through and write the bytes.
      }
    }
    final extension = _extensionFor(attachment);
    final name = '${sha1.convert(bytes)}$extension';
    _writeData(name, bytes);
    return {'path': 'data/$name'};
  }

  String _extensionFor(ReportAttachment attachment) {
    final dot = attachment.name.lastIndexOf('.');
    if (dot >= 0) return attachment.name.substring(dot);
    return switch (attachment.contentType) {
      'image/png' => '.png',
      'image/jpeg' => '.jpg',
      'video/webm' => '.webm',
      'application/zip' => '.zip',
      _ => '.dat',
    };
  }

  /// Copies an attachment into `data/` and returns its path in the report.
  ///
  /// Content-addressed like upstream: the same screenshot attached by ten
  /// tests is written once. A file that cannot be read keeps its original
  /// path, so the report still names it and the reader can go looking.
  String _copy(String path) {
    final source = File(p.isAbsolute(path) ? path : p.join(rootDir, path));
    final List<int> bytes;
    try {
      bytes = source.readAsBytesSync();
    } catch (_) {
      return path;
    }
    final name = '${sha1.convert(bytes)}${p.extension(path)}';
    _writeData(name, bytes);
    return 'data/$name';
  }

  void _writeData(String name, List<int> bytes) {
    final target = File(p.join(outputFolder, 'data', name));
    if (target.existsSync()) return;
    target.parent.createSync(recursive: true);
    target.writeAsBytesSync(bytes);
  }

  static String _fileId(String fileName) =>
      sha1.convert(utf8.encode(fileName)).toString().substring(0, 20);

  static Map<String, Object?> _emptyStats() => {
        'total': 0,
        'expected': 0,
        'unexpected': 0,
        'flaky': 0,
        'skipped': 0,
        'ok': true,
      };

  static void _addStats(Map<String, Object?> into, Map<String, Object?> delta) {
    for (final key in const [
      'total',
      'expected',
      'unexpected',
      'flaky',
      'skipped'
    ]) {
      into[key] = (into[key] as int) + (delta[key] as int);
    }
    into['ok'] = (into['ok'] as bool) && (delta['ok'] as bool);
  }
}

import 'dart:convert';

import 'package:path/path.dart' as p;

import '../reporting_protocol.dart';
import 'ansi.dart';
import 'model.dart';

/// Turns the event stream of `dart test --file-reporter json:<file>` into a
/// [ReportRun].
///
/// This is the whole seam between this package and `package:test`. The runner
/// owns the run -- it loads the files, filters, repeats, parallelizes and
/// decides what passed -- and publishes a documented newline-delimited JSON
/// stream while it does. Everything the reporters here need is in that stream,
/// except attachments and steps, which `package:test` has no notion of. Those
/// arrive on a second stream written by [ReportingProtocol] and are folded in
/// by [applyEvents].
///
/// The protocol version this was written against is `0.1.1`. A stream that
/// announces something else is still parsed: an unknown event type is ignored,
/// which is what the protocol asks consumers to do.
class DartTestParser {
  /// Where `dart test` ran, so that file paths in the report are relative to
  /// something a reader can open.
  final String rootDir;

  final ReportRun _run = ReportRun();

  /// Files by the suite id the runner assigned them.
  final Map<int, ReportFile> _filesBySuiteId = {};

  /// The platform each suite ran on, by suite id.
  final Map<int, String> _platformBySuiteId = {};

  /// Group names by group id, so a test can name its enclosing groups.
  final Map<int, String> _groupNames = {};
  final Map<int, int?> _groupParents = {};

  /// The state of every test the stream has started but not finished.
  final Map<int, _LiveTest> _live = {};

  /// Tests already seen, keyed by suite and full name, so that the same test
  /// reported twice lands in one entry.
  final Map<String, ReportTest> _tests = {};

  /// The wall clock the run started at. Every event carries only milliseconds
  /// since the runner's own stopwatch, so this is what turns those into the
  /// timestamps the JSON report is specified to carry.
  DateTime _epoch = DateTime.now();

  DartTestParser({String? rootDir}) : rootDir = rootDir ?? p.current;

  /// Parses the whole stream and returns the run.
  ///
  /// [lines] is the file as written by `--file-reporter json:<file>`: one JSON
  /// object per line. A line that is not JSON is skipped rather than fatal --
  /// a stray banner printed by a wrapper script must not cost the report.
  ReportRun parse(Iterable<String> lines) {
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || !trimmed.startsWith('{')) continue;
      Object? decoded;
      try {
        decoded = jsonDecode(trimmed);
      } catch (_) {
        continue;
      }
      if (decoded is Map<String, Object?>) handle(decoded);
    }
    return finish();
  }

  /// Folds the attachment and step stream into a run already parsed.
  ///
  /// [lines] is the file [ReportingProtocol] appended to, one JSON object per
  /// line. Records from suites running in parallel are interleaved in it, so
  /// they are grouped by the test they name before being replayed -- within
  /// one test the order is the order they happened, which is what makes a
  /// nested step tree rebuildable.
  ///
  /// Order matters: call this after [parse], because a record can only be
  /// filed against a test the main stream already reported.
  void applyEvents(Iterable<String> lines) {
    final byTest = <String, List<Map<String, Object?>>>{};
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || !trimmed.startsWith('{')) continue;
      Object? decoded;
      try {
        decoded = jsonDecode(trimmed);
      } catch (_) {
        continue;
      }
      if (decoded is! Map<String, Object?>) continue;
      final key = '${_relative(decoded['suite'] as String? ?? '')}'
          '\u0000${decoded['platform'] ?? 'vm'}'
          '\u0000${decoded['test'] ?? ''}';
      byTest.putIfAbsent(key, () => []).add(decoded);
    }

    for (final entry in byTest.entries) {
      final test = _tests[entry.key];
      if (test == null || test.results.isEmpty) continue;
      final steps = <String, ReportStep>{};
      for (final record in entry.value) {
        final attempt = (record['attempt'] as num?)?.toInt() ?? 0;
        // A retried test can produce records for an attempt the main stream
        // did not report. Clamping is better than dropping: the attachment
        // still reaches the reader, on the nearest attempt that exists.
        final result = test.results[attempt.clamp(0, test.results.length - 1)];
        switch (record['kind']) {
          case 'attachment':
            result.attachments.add(ReportAttachment(
              name: record['name'] as String? ?? 'attachment',
              contentType: record['contentType'] as String? ??
                  'application/octet-stream',
              path: record['path'] as String?,
              base64Body: record['body'] as String?,
              stepId: record['stepId'] as String?,
            ));
          case 'step-begin':
            final step = ReportStep(
              id: record['id'] as String? ?? '',
              title: record['title'] as String? ?? '',
              category: record['category'] as String? ?? 'test.step',
              startTime: (record['startTime'] as num?)?.toInt() ?? 0,
            );
            final parentId = record['parentId'] as String?;
            final parent = parentId == null ? null : steps[parentId];
            (parent?.steps ?? result.steps).add(step);
            steps[step.id] = step;
          case 'step-end':
            final step = steps[record['id'] as String? ?? ''];
            if (step != null) {
              step.endTime =
                  (record['endTime'] as num?)?.toInt() ?? step.startTime;
              step.error = record['error'] as String?;
            }
        }
      }
      // Steps are timed from the isolate's own stopwatch, which starts long
      // before the test does. Rebasing on the first step makes the numbers the
      // report shows offsets within the test, which is what they look like.
      for (final result in test.results) {
        final first = _earliestStep(result.steps);
        if (first != null) _shiftSteps(result.steps, first);
      }
    }
  }

  static int? _earliestStep(List<ReportStep> steps) {
    int? earliest;
    for (final step in steps) {
      if (earliest == null || step.startTime < earliest) {
        earliest = step.startTime;
      }
      final child = _earliestStep(step.steps);
      if (child != null && child < earliest) earliest = child;
    }
    return earliest;
  }

  static void _shiftSteps(List<ReportStep> steps, int by) {
    for (final step in steps) {
      step.endTime -= by;
      step.startTime -= by;
      _shiftSteps(step.steps, by);
    }
  }

  /// Handles one event.
  void handle(Map<String, Object?> event) {
    final time = (event['time'] as num?)?.toInt() ?? 0;
    switch (event['type']) {
      case 'start':
        _epoch = DateTime.now();
        _run.startTime = _epoch;
        _run.runnerVersion = event['runnerVersion'] as String?;
      case 'suite':
        _onSuite(event['suite'] as Map<String, Object?>);
      case 'group':
        _onGroup(event['group'] as Map<String, Object?>);
      case 'testStart':
        _onTestStart(event['test'] as Map<String, Object?>, time);
      case 'print':
        _onPrint(event, time);
      case 'error':
        _onError(event);
      case 'testDone':
        _onTestDone(event, time);
      case 'done':
        _run.duration = Duration(milliseconds: time);
    }
  }

  void _onSuite(Map<String, Object?> suite) {
    final id = (suite['id'] as num).toInt();
    final path = suite['path'] as String? ?? '';
    final relative = _relative(path);
    // A file can be reported twice, once for the load suite and once for the
    // real one, under the same id; and two platforms share the same path. One
    // entry per path is what a reader expects to see.
    final existing =
        _run.files.where((file) => file.path == relative).firstOrNull;
    final file = existing ?? ReportFile(relative);
    if (existing == null) _run.files.add(file);
    _filesBySuiteId[id] = file;
    _platformBySuiteId[id] = suite['platform'] as String? ?? 'vm';
  }

  void _onGroup(Map<String, Object?> group) {
    final id = (group['id'] as num).toInt();
    _groupNames[id] = group['name'] as String? ?? '';
    _groupParents[id] = (group['parentID'] as num?)?.toInt();
  }

  void _onTestStart(Map<String, Object?> test, int time) {
    final id = (test['id'] as num).toInt();
    final suiteId = (test['suiteID'] as num).toInt();
    final file = _filesBySuiteId[suiteId];
    // A test whose suite was never announced cannot be placed in the report.
    // The stream always announces the suite first, so this is defensive only.
    if (file == null) return;

    final name = test['name'] as String? ?? '';
    final groupIds =
        (test['groupIDs'] as List?)?.map((e) => (e as num).toInt()).toList() ??
            const <int>[];

    final platform = _platformBySuiteId[suiteId] ?? 'vm';
    // The platform is part of the key: `dart test -p chrome -p vm` runs the
    // same file twice, and two platforms' runs of one test are two tests, not
    // two attempts at one.
    final key = '${file.path}\u0000$platform\u0000$name';
    var reportTest = _tests[key];
    if (reportTest == null) {
      // `url`/`line` point at the frame that called `test()`, which for a
      // `playwrightTest` is inside this package. `root_url`/`root_line` point
      // at the frame inside the suite file, which is the line the reader wants
      // to open, so it wins whenever the runner supplies it.
      final url = (test['root_url'] ?? test['url']) as String?;
      final line = (test['root_line'] ?? test['line']) as num?;
      final column = (test['root_column'] ?? test['column']) as num?;
      reportTest = ReportTest(
        title: _leafTitle(name, groupIds),
        groups: _groupTitles(groupIds),
        file: file.path,
        platform: platform,
        location: url == null
            ? null
            : ReportLocation(
                _relative(_fromUri(url)),
                line?.toInt() ?? 0,
                column?.toInt() ?? 0,
              ),
      );
      final metadata = test['metadata'] as Map<String, Object?>?;
      if (metadata?['skip'] == true) {
        reportTest.expectedStatus = ReportStatus.skipped;
        reportTest.skipReason = metadata?['skipReason'] as String?;
      }
      _tests[key] = reportTest;
      file.tests.add(reportTest);
    }

    final result = ReportResult(
        retry: reportTest.results.length,
        startTime: _epoch.add(Duration(milliseconds: time)));
    reportTest.results.add(result);
    _live[id] = _LiveTest(reportTest, result, name, time);
  }

  void _onPrint(Map<String, Object?> event, int time) {
    final live = _live[(event['testID'] as num?)?.toInt() ?? -1];
    if (live == null) return;
    final message = event['message'] as String? ?? '';
    final type = event['messageType'] as String? ?? 'print';

    for (final line in const LineSplitter().convert(message)) {
      // `package:test` retries inside the isolate, so the runner never starts
      // a second test for a retry -- the only trace of one in the stream is
      // this line. Without reading it, a test that failed twice and then
      // passed would be reported as a clean pass, which is exactly the
      // information a flaky-test hunt needs.
      if (line == 'Retry: ${live.name}') {
        live.result.status = _statusForFailure(live.result);
        live.result.duration = Duration(milliseconds: time - live.startTime);
        final next = ReportResult(
            retry: live.test.results.length,
            startTime: _epoch.add(Duration(milliseconds: time)));
        live.test.results.add(next);
        live.result = next;
        live.startTime = time;
        continue;
      }
      if (type == 'skip') {
        // A skip reason is the runner explaining itself, not the test
        // talking. It already shows as the test's status, so repeating it in
        // the output pane would be noise.
        continue;
      }
      live.result.stdout.add(line);
    }
  }

  void _onError(Map<String, Object?> event) {
    final live = _live[(event['testID'] as num?)?.toInt() ?? -1];
    final message = stripAnsiEscapes(event['error'] as String? ?? '');
    final stack = event['stackTrace'] as String?;
    final error = ReportError(
      message: message,
      stack: stack == null || stack.isEmpty ? null : stripAnsiEscapes(stack),
      location: _locationFromStack(stack),
    );
    if (live == null) {
      // A failure with no test is a file that would not load, or a crash
      // between tests. Dropping it would render a green report for a run that
      // never ran anything.
      _run.errors.add(error);
      return;
    }
    live.result.errors.add(error);
  }

  void _onTestDone(Map<String, Object?> event, int time) {
    final id = (event['testID'] as num?)?.toInt() ?? -1;
    final live = _live.remove(id);
    if (live == null) return;
    live.result.duration = Duration(milliseconds: time - live.startTime);

    if (event['skipped'] == true) {
      live.result.status = ReportStatus.skipped;
      // `package:test` reports a skipped test as a success, which is right for
      // an exit code and wrong for a report: a skipped test is not a tested
      // one. Upstream keeps them apart, and so does this.
      if (live.test.expectedStatus != ReportStatus.skipped) {
        live.test.expectedStatus = ReportStatus.skipped;
      }
    } else if (event['result'] == 'success') {
      live.result.status = ReportStatus.passed;
    } else {
      live.result.status = _statusForFailure(live.result);
    }

    // `hidden` marks the runner's own bookkeeping tests -- the ones that load
    // a file, and the `setUpAll`/`tearDownAll` bodies that passed. They are
    // not the user's tests and upstream has nothing like them, so a hidden
    // test that passed is dropped. One that failed is kept: that is the whole
    // reason the runner surfaces them.
    if (event['hidden'] == true && live.result.errors.isEmpty) {
      live.test.results.remove(live.result);
      if (live.test.results.isEmpty) {
        _tests.removeWhere((_, value) => identical(value, live.test));
        for (final file in _run.files) {
          file.tests.remove(live.test);
        }
      }
    }
  }

  /// Closes anything the stream left open and returns the run.
  ///
  /// A run killed mid-flight -- Ctrl-C, or a worker that died -- leaves tests
  /// started and never finished. They are reported as failed with a message
  /// saying so, because silently dropping them would shrink the total and hide
  /// the interruption.
  ReportRun finish() {
    for (final live in _live.values) {
      live.result.status = ReportStatus.failed;
      if (live.result.errors.isEmpty) {
        live.result.errors.add(const ReportError(
            message: 'The run ended before this test reported a result.'));
      }
    }
    _live.clear();
    for (final file in _run.files) {
      file.tests.removeWhere((test) => test.results.isEmpty);
    }
    _run.files.removeWhere((file) => file.tests.isEmpty);
    return _run;
  }

  ReportStatus _statusForFailure(ReportResult result) {
    // `package:test` has one failure channel, so the only way to tell a
    // timeout from an assertion is the message the runner writes for it.
    final timedOut = result.errors
        .any((error) => error.message.startsWith('TimeoutException after'));
    final testTimeout = result.errors
        .any((error) => error.message.contains('Test timed out after'));
    return timedOut || testTimeout
        ? ReportStatus.timedOut
        : ReportStatus.failed;
  }

  /// The group names of [groupIds], each relative to its parent.
  ///
  /// `package:test` stores a group's name already prefixed by its parents, so
  /// a nested group reads `outer inner`. A report that shows the chain would
  /// repeat the outer name at every level, so the prefix comes back off here.
  List<String> _groupTitles(List<int> groupIds) {
    final titles = <String>[];
    var previous = '';
    for (final id in groupIds) {
      final name = _groupNames[id] ?? '';
      if (name.isEmpty) continue;
      titles.add(_stripPrefix(name, previous));
      previous = name;
    }
    return titles;
  }

  String _leafTitle(String name, List<int> groupIds) {
    var previous = '';
    for (final id in groupIds) {
      final groupName = _groupNames[id] ?? '';
      if (groupName.isNotEmpty) previous = groupName;
    }
    return _stripPrefix(name, previous);
  }

  static String _stripPrefix(String name, String prefix) {
    if (prefix.isEmpty) return name;
    if (!name.startsWith(prefix)) return name;
    return name.substring(prefix.length).trimLeft();
  }

  String _relative(String path) {
    if (path.isEmpty) return path;
    try {
      return p.url.joinAll(p.split(p.relative(path, from: rootDir)));
    } catch (_) {
      return path;
    }
  }

  static String _fromUri(String url) {
    try {
      final uri = Uri.parse(url);
      return uri.scheme == 'file' ? uri.toFilePath() : url;
    } catch (_) {
      return url;
    }
  }

  /// The first frame of [stack] that names a file, as a location.
  ///
  /// Upstream does the same with `prepareErrorStack`, and the HTML report uses
  /// it to say where a failure happened without making the reader open the
  /// stack.
  ReportLocation? _locationFromStack(String? stack) {
    if (stack == null) return null;
    for (final line in const LineSplitter().convert(stack)) {
      final match = RegExp(r'([A-Za-z]:[\\/][^\s(]+|/[^\s(]+|[\w./\\-]+\.dart)'
              r'[: ](\d+)(?::(\d+))?')
          .firstMatch(line);
      if (match == null) continue;
      final file = match.group(1)!;
      if (!file.endsWith('.dart')) continue;
      return ReportLocation(
        _relative(_fromUri(file)),
        int.tryParse(match.group(2) ?? '') ?? 0,
        int.tryParse(match.group(3) ?? '') ?? 0,
      );
    }
    return null;
  }
}

/// A test the stream has started and not yet finished.
class _LiveTest {
  final ReportTest test;
  ReportResult result;

  /// The name as the runner spells it, needed to recognise its `Retry:` line.
  final String name;

  /// When the current attempt started, in runner milliseconds.
  int startTime;

  _LiveTest(this.test, this.result, this.name, this.startTime);
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

// Implementation import, on purpose. `Invoker.current` is how a running test
// finds out which test it is, and there is no other way: `package:test` has no
// public `TestInfo` the way upstream's runner does. It is the same object
// `printOnFailure` uses to route a message to the right test, so it is as
// stable as anything in that package. The alternative was to print markers on
// stdout, which correlates for free but doubles the console output of every
// suite that uses steps -- a reporting feature is not allowed to make the
// console worse.
import 'package:test_api/src/backend/invoker.dart';

/// The side channel between a running test and the report generator.
///
/// `package:test` owns the run: it loads, filters, repeats, parallelizes and
/// decides what passed, and publishes a machine-readable stream while it does.
/// Everything the reporters need is in that stream except attachments and
/// steps, because `package:test` has no notion of either.
///
/// So those travel out of band, as JSON lines appended to the file named by
/// the `PLAYWRIGHT_REPORT_EVENTS` environment variable, each line carrying the
/// suite, platform and test name that identify where it belongs. The report
/// generator sets that variable; when it is unset -- a plain `dart test` run --
/// every call here is a no-op and costs nothing.
class ReportingProtocol {
  ReportingProtocol._();

  /// Environment variable naming the file markers are appended to.
  static const environmentVariable = 'PLAYWRIGHT_REPORT_EVENTS';

  static String? _sinkPath = _resolveSink();
  static bool _resolved = true;

  static String? _resolveSink() {
    final path = Platform.environment[environmentVariable];
    return path == null || path.isEmpty ? null : path;
  }

  /// Whether anything is listening. Public so a caller can skip expensive work.
  static bool get enabled {
    if (!_resolved) {
      _sinkPath = _resolveSink();
      _resolved = true;
    }
    return _sinkPath != null;
  }

  /// Forgets the resolved sink, for a test that changes the environment.
  static void reset() => _resolved = false;

  /// Appends one record, tagged with the test that is running.
  ///
  /// Returns without writing outside a test: a record nobody can attribute is
  /// a record the report would have to guess about.
  static void emit(String kind, Map<String, Object?> payload) {
    if (!enabled) return;
    final invoker = Invoker.current;
    if (invoker == null) return;
    final live = invoker.liveTest;
    final record = <String, Object?>{
      'kind': kind,
      'suite': live.suite.path ?? '',
      'platform': live.suite.platform.runtime.identifier,
      'test': live.test.name,
      'attempt': currentAttempt,
      ...payload,
    };
    try {
      // Opened and closed per line so that suites running in parallel isolates
      // append to the same file without holding a handle across an await. One
      // line is a single small write, which the OS does not tear.
      File(_sinkPath!)
          .writeAsStringSync('${jsonEncode(record)}\n', mode: FileMode.append);
    } catch (_) {
      // A report that cannot be written must never take the run down with it.
    }
  }
}

/// Which attempt of the current test is running: 0 for the first.
///
/// `package:test` retries inside the isolate, so nothing in the runner's
/// stream says which attempt produced an attachment. `playwrightTest` sets
/// this around each attempt; a plain `test()` leaves it at 0, and its
/// attachments land on the first result.
const _attemptKey = #playwrightTestAttempt;

/// The attempt index in scope, or 0.
int get currentAttempt => (Zone.current[_attemptKey] as int?) ?? 0;

/// Runs [body] marked as attempt [attempt] of the current test.
Future<T> runAsAttempt<T>(int attempt, Future<T> Function() body) =>
    runZoned(body, zoneValues: {_attemptKey: attempt});

/// Monotonic milliseconds since the isolate started, used to order steps.
///
/// Wall clock would do for a single run, but a step that spans a clock
/// adjustment would come out with a negative duration, and a report with a
/// negative duration is a report nobody trusts again.
final Stopwatch _clock = Stopwatch()..start();

int _nextStepId = 0;

/// The step currently running in this zone, if any.
const _currentStepKey = #playwrightTestCurrentStep;

/// Id of the step that encloses the code running now, or null at the top.
String? get currentReportedStepId => Zone.current[_currentStepKey] as String?;

/// Runs [body] as a reported step named [title], recording begin and end.
///
/// The id is per isolate and the parent comes from the zone, so a step inside
/// a step nests without the caller saying so. [category] mirrors upstream's
/// step categories: `test.step` for a user step, `hook` for a fixture.
///
/// With no report being generated this is a plain call of [body] in a zone,
/// which is what keeps `step` free to use in a suite nobody reports on.
Future<T> runReportedStep<T>(
  String title,
  FutureOr<T> Function() body, {
  String category = 'test.step',
}) async {
  if (!ReportingProtocol.enabled) return await Future<T>.sync(body);
  final id = 'step${_nextStepId++}';
  ReportingProtocol.emit('step-begin', {
    'id': id,
    'parentId': currentReportedStepId,
    'title': title,
    'category': category,
    'startTime': _clock.elapsedMilliseconds,
  });
  Object? error;
  try {
    return await runZoned(() => Future<T>.sync(body),
        zoneValues: {_currentStepKey: id});
  } catch (e) {
    error = e;
    rethrow;
  } finally {
    ReportingProtocol.emit('step-end', {
      'id': id,
      'endTime': _clock.elapsedMilliseconds,
      if (error != null) 'error': error.toString(),
    });
  }
}

/// Records one attachment in the report.
///
/// The public door is `attach` in `step.dart`, which calls this and then also
/// records the attachment in the trace. This is the report half on its own,
/// for the places inside this package that already have the bytes or the path
/// and only need the report to know.
///
/// A [path] is recorded as written -- relative to the directory `dart test`
/// ran in -- because the report generator runs from there too. A [body]
/// travels inline as base64, so give it only for something small.
void reportAttachment(
  String name, {
  String? path,
  List<int>? body,
  required String contentType,
}) {
  if (path == null && body == null) return;
  ReportingProtocol.emit('attachment', {
    'name': name,
    if (path != null) 'path': path,
    if (path == null && body != null) 'body': base64Encode(body),
    'contentType': contentType,
    if (currentReportedStepId != null) 'stepId': currentReportedStepId,
  });
}

/// The result of one run, in the shape every reporter here reads from.
///
/// This is deliberately not upstream's `JSONReport`. Upstream's JSON is one
/// *output* among several, with its own nesting and its own field names frozen
/// by the tools that consume it; making it the in-memory model too would drag
/// that freeze into the HTML and the XML. So the parser builds this, and
/// `json_reporter.dart` is the only file that knows what upstream's JSON looks
/// like.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Where something is in the source.
class ReportLocation {
  final String file;
  final int line;
  final int column;

  const ReportLocation(this.file, this.line, this.column);

  @override
  String toString() => '$file:$line:$column';
}

/// One failure, with the message and the stack as the runner reported them.
class ReportError {
  /// The message, ANSI already stripped.
  final String message;

  /// The stack trace as text, or null when the runner had none.
  final String? stack;

  /// Where the failure happened, when the stack gave a usable frame.
  final ReportLocation? location;

  const ReportError({required this.message, this.stack, this.location});
}

/// A file or blob attached to a result.
class ReportAttachment {
  final String name;
  final String contentType;

  /// Path on disk, relative to where the run happened. Null for an inline
  /// attachment.
  final String? path;

  /// The bytes, base64, for an attachment that travelled inline.
  final String? base64Body;

  /// Id of the step this attachment was created inside, or null for one
  /// attached straight to the test.
  final String? stepId;

  const ReportAttachment({
    required this.name,
    required this.contentType,
    this.path,
    this.base64Body,
    this.stepId,
  });

  /// The bytes, decoded, for an inline attachment.
  List<int>? get body =>
      base64Body == null ? null : base64Decode(base64Body!) as List<int>;
}

/// A named step inside a test.
class ReportStep {
  final String id;
  final String title;

  /// `test.step` for a user step, `hook` for a fixture.
  final String category;

  /// Milliseconds from the start of the test's first step.
  ///
  /// Not final: the recorder writes these against the isolate's stopwatch,
  /// which started long before the test did, and the parser rebases them.
  int startTime;
  int endTime;

  /// The failure that ended this step, when one did.
  String? error;

  final List<ReportStep> steps = [];

  ReportStep({
    required this.id,
    required this.title,
    required this.category,
    required this.startTime,
    int? endTime,
  }) : endTime = endTime ?? startTime;

  Duration get duration => Duration(milliseconds: endTime - startTime);
}

/// How a run ended, in upstream's vocabulary.
enum ReportStatus {
  passed,
  failed,
  timedOut,
  skipped;

  /// The spelling upstream's JSON uses.
  String get wire => name;
}

/// One attempt at running a test: the first try, or a retry.
class ReportResult {
  /// 0 for the first attempt, 1 for the first retry, and so on.
  final int retry;

  ReportStatus status = ReportStatus.passed;
  Duration duration = Duration.zero;

  /// When the attempt started, wall clock, for the report header.
  DateTime startTime;

  final List<ReportError> errors = [];
  final List<ReportAttachment> attachments = [];
  final List<ReportStep> steps = [];
  final List<String> stdout = [];
  final List<String> stderr = [];

  ReportResult({required this.retry, required this.startTime});

  /// The first error, which is the one a summary shows.
  ReportError? get error => errors.isEmpty ? null : errors.first;
}

/// One test, with every attempt at running it.
///
/// `package:test` has no notion of a project, so there is exactly one of these
/// per test name -- where upstream would have one per project. The browser a
/// `playwrightTest` ran on ends up in the title, which is where
/// `playwrightTest` already put it.
class ReportTest {
  /// The test name as `package:test` reported it, without the group prefix.
  final String title;

  /// The enclosing group names, outermost first.
  final List<String> groups;

  /// The file the test came from, relative to the run directory.
  final String file;

  /// The `package:test` platform the test ran on: `vm`, `chrome`, `node`.
  ///
  /// This is what stands in for upstream's project. `package:test` has no
  /// projects, but `dart test -p chrome -p vm` runs the same file twice on two
  /// platforms, which is the same shape of thing, and CI dashboards group by
  /// exactly this field.
  final String platform;

  /// Where the test was declared, when the runner knew.
  final ReportLocation? location;

  /// What the runner expected: `skipped` for a skipped test, `passed`
  /// otherwise. `package:test` has no `test.fail`, so nothing else is
  /// reachable -- but the field exists because the JSON report has it and CI
  /// dashboards read it.
  ReportStatus expectedStatus = ReportStatus.passed;

  /// Why the test was skipped, when it was and the runner said.
  String? skipReason;

  /// Tags declared on the test, from `package:test` metadata.
  final List<String> tags = [];

  final List<ReportResult> results = [];

  ReportTest({
    required this.title,
    required this.groups,
    required this.file,
    required this.platform,
    this.location,
  });

  /// A stable id for this test, the same across runs.
  ///
  /// Upstream hashes the same three things -- file, project and title path --
  /// and both the HTML report and the JSON use the result as the identity a
  /// link points at. Truncated to 20 hex characters like upstream's, so a URL
  /// stays readable.
  String get id => sha1
      .convert(utf8.encode('$file\u001e$platform\u001e$fullTitle'))
      .toString()
      .substring(0, 20);

  /// The full title, group names included, the way a reporter prints it.
  String get fullTitle => [...groups.where((g) => g.isNotEmpty), title]
      .join(' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  /// The last attempt, which is the one that decided the outcome.
  ReportResult? get lastResult => results.isEmpty ? null : results.last;

  /// Total time across every attempt.
  Duration get duration =>
      results.fold(Duration.zero, (total, result) => total + result.duration);

  /// The outcome, the way the HTML and the JSON both classify a test.
  ///
  /// `flaky` is the interesting one: it is not a status a single attempt can
  /// have, it is what a test that failed and then passed *is*.
  ReportOutcome get outcome {
    if (results.isEmpty) return ReportOutcome.skipped;
    if (results.every((r) => r.status == ReportStatus.skipped)) {
      return ReportOutcome.skipped;
    }
    final ok = results.where((r) => r.status != ReportStatus.skipped);
    final passed = ok.where((r) => r.status == ReportStatus.passed).length;
    if (passed == ok.length) return ReportOutcome.expected;
    if (passed > 0) return ReportOutcome.flaky;
    return ReportOutcome.unexpected;
  }

  /// Whether this test needs somebody to look at it.
  bool get isFailure => outcome == ReportOutcome.unexpected;
}

/// What a whole test amounted to, across its attempts.
enum ReportOutcome {
  /// Ended the way it was supposed to.
  expected,

  /// Did not.
  unexpected,

  /// Failed, then passed on a retry.
  flaky,

  /// Never ran.
  skipped;

  String get wire => name;
}

/// Every test from one file.
class ReportFile {
  /// The path, relative to the run directory, which is also the id.
  final String path;

  final List<ReportTest> tests = [];

  ReportFile(this.path);

  Duration get duration =>
      tests.fold(Duration.zero, (total, test) => total + test.duration);
}

/// How many tests ended each way.
class ReportStats {
  int expected = 0;
  int unexpected = 0;
  int flaky = 0;
  int skipped = 0;

  int get total => expected + unexpected + flaky + skipped;

  /// Whether the run should fail the build.
  bool get ok => unexpected == 0;
}

/// A whole run: every file, plus what the run itself had to say.
class ReportRun {
  final List<ReportFile> files = [];

  /// Failures that belong to no test -- a file that would not compile, for
  /// one. Without these, a run where nothing loaded would render as an empty,
  /// green report, which is the worst possible lie for a report to tell.
  final List<ReportError> errors = [];

  /// When the run started, wall clock.
  DateTime startTime = DateTime.now();

  /// How long the run took.
  Duration duration = Duration.zero;

  /// The Dart SDK version the run reported, when it did.
  String? runnerVersion;

  /// How many retries the run was configured for.
  int retries = 0;

  /// How many suites ran in parallel.
  int workers = 1;

  /// Every test, in file order, flattened.
  Iterable<ReportTest> get tests => files.expand((file) => file.tests);

  ReportStats get stats {
    final stats = ReportStats();
    for (final test in tests) {
      switch (test.outcome) {
        case ReportOutcome.expected:
          stats.expected++;
        case ReportOutcome.unexpected:
          stats.unexpected++;
        case ReportOutcome.flaky:
          stats.flaky++;
        case ReportOutcome.skipped:
          stats.skipped++;
      }
    }
    return stats;
  }

  /// Whether the run passed: no unexpected test and no run-level error.
  bool get ok => stats.ok && errors.isEmpty;
}

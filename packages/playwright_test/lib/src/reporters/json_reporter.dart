import 'dart:convert';

import 'model.dart';

/// Writes upstream's `JSONReport`.
///
/// Every name in here is fixed by
/// `referencias/playwright-typescript/packages/playwright/types/testReporter.d.ts`
/// and by the tools that already read it -- Allure, CTRF converters, the
/// dashboards people build themselves. Renaming a field to something that
/// reads better in Dart would break all of them silently, so the shape is
/// copied and the explaining happens here instead.
///
/// Two vocabularies live side by side and they are not interchangeable:
///
/// * a **result** has a `TestStatus`: `passed`, `failed`, `timedOut`,
///   `skipped`, `interrupted`;
/// * a **test** has an outcome: `expected`, `unexpected`, `flaky`, `skipped`,
///   and it is those four the `stats` counters are keyed by.
///
/// What this port cannot fill in honestly is left out rather than faked.
/// `package:test` has no projects, no worker index per test and no
/// annotations, so `projectName` carries the platform, `workerIndex` is 0 and
/// `annotations` is empty. A consumer reading those gets nothing, which is
/// true; a consumer reading an invented value would get a lie.
class JsonReporter {
  /// Where the run happened, reported as `config.rootDir`.
  final String rootDir;

  /// The Dart SDK version, reported as `config.version`.
  final String version;

  /// How many suites ran at once, reported as `config.workers`.
  final int workers;

  const JsonReporter({
    required this.rootDir,
    required this.version,
    this.workers = 1,
  });

  /// Builds the report as a JSON-encodable map.
  Map<String, Object?> build(ReportRun run) {
    final stats = run.stats;
    // Key order matches upstream's object literal, because a diff of two
    // reports is a thing people do.
    return {
      'config': _config(run),
      'suites': run.files.map(_file).toList(),
      'errors': run.errors.map(_error).toList(),
      'stats': {
        'startTime': run.startTime.toUtc().toIso8601String(),
        'duration': run.duration.inMilliseconds,
        'expected': stats.expected,
        'unexpected': stats.unexpected,
        'flaky': stats.flaky,
        'skipped': stats.skipped,
      },
    };
  }

  /// Serializes the report the way upstream writes it: two-space indent, no
  /// trailing newline.
  String render(ReportRun run) =>
      const JsonEncoder.withIndent('  ').convert(build(run));

  Map<String, Object?> _config(ReportRun run) {
    // Only the keys that mean something here. Upstream spreads its whole
    // `FullConfig`, most of which is Node-side configuration this port has no
    // equivalent for, and a key present with a made-up value is worse than a
    // key that is absent.
    final platforms = run.tests.map((test) => test.platform).toSet().toList()
      ..sort();
    return {
      'rootDir': _posix(rootDir),
      'version': version,
      'workers': workers,
      'projects': [
        for (final platform in platforms)
          {
            'outputDir': 'test-results',
            'repeatEach': 1,
            'retries': run.retries,
            'metadata': <String, Object?>{},
            'id': platform,
            'name': platform,
            'testDir': _posix(rootDir),
            'testIgnore': <String>[],
            'testMatch': <String>[],
            'timeout': 0,
          },
      ],
    };
  }

  /// One `JSONReportSuite` per file, with the groups nested inside it.
  Map<String, Object?> _file(ReportFile file) {
    final root = _SuiteNode(file.path, file.path);
    for (final test in file.tests) {
      var node = root;
      for (final group in test.groups) {
        node = node.child(group, file.path);
      }
      node.tests.add(test);
    }
    return root.toJson();
  }

  static Map<String, Object?> _spec(ReportTest test, String file) => {
        'title': test.title,
        'ok': test.outcome != ReportOutcome.unexpected,
        // Upstream strips the leading '@' from a tag; `package:test` tags
        // never carry one, so there is nothing to strip.
        'tags': test.tags,
        'tests': [_test(test)],
        'id': test.id,
        'file': file,
        'line': test.location?.line ?? 0,
        'column': test.location?.column ?? 0,
      };

  static Map<String, Object?> _test(ReportTest test) => {
        'timeout': 0,
        'annotations': <Object?>[],
        'expectedStatus': test.expectedStatus.wire,
        'projectId': test.platform,
        'projectName': test.platform,
        'results': test.results.map(_result).toList(),
        'status': test.outcome.wire,
      };

  static Map<String, Object?> _result(ReportResult result) {
    final steps = result.steps.where((s) => s.category == 'test.step').toList();
    final error = result.error;
    return {
      'workerIndex': 0,
      'parallelIndex': 0,
      'status': result.status.wire,
      'duration': result.duration.inMilliseconds,
      'error': error == null
          ? null
          : {
              'message': error.message,
              if (error.stack != null) 'stack': error.stack,
              if (error.location != null) 'location': _location(error.location!)
            },
      'errors': result.errors.map(_error).toList(),
      'stdout': result.stdout.map((line) => {'text': '$line\n'}).toList(),
      'stderr': result.stderr.map((line) => {'text': '$line\n'}).toList(),
      'retry': result.retry,
      if (steps.isNotEmpty) 'steps': steps.map(_step).toList(),
      'startTime': result.startTime.toUtc().toIso8601String(),
      'annotations': <Object?>[],
      'attachments': result.attachments
          .map((attachment) => {
                'name': attachment.name,
                'contentType': attachment.contentType,
                if (attachment.path != null) 'path': attachment.path,
                if (attachment.base64Body != null)
                  'body': attachment.base64Body,
              })
          .toList(),
      if (error?.location != null) 'errorLocation': _location(error!.location!),
    };
  }

  static Map<String, Object?> _step(ReportStep step) {
    final children =
        step.steps.where((s) => s.category == 'test.step').toList();
    return {
      'title': step.title,
      'duration': step.duration.inMilliseconds,
      'error': step.error == null ? null : {'message': step.error},
      if (children.isNotEmpty) 'steps': children.map(_step).toList(),
    };
  }

  /// A `JSONReportError`: the message, and where it happened when known.
  static Map<String, Object?> _error(ReportError error) => {
        'message': error.stack == null
            ? error.message
            : '${error.message}\n\n${error.stack}',
        if (error.location != null) 'location': _location(error.location!),
      };

  static Map<String, Object?> _location(ReportLocation location) => {
        'file': location.file,
        'line': location.line,
        'column': location.column,
      };

  static String _posix(String path) => path.replaceAll(r'\', '/');
}

/// A node while the flat list of tests is folded back into nested suites.
class _SuiteNode {
  final String title;
  final String file;
  final List<ReportTest> tests = [];
  final Map<String, _SuiteNode> children = {};

  _SuiteNode(this.title, this.file);

  _SuiteNode child(String title, String file) =>
      children.putIfAbsent(title, () => _SuiteNode(title, file));

  Map<String, Object?> toJson() {
    final nested = children.values.map((child) => child.toJson()).toList();
    return {
      'title': title,
      'file': file,
      'line': 0,
      'column': 0,
      'specs': tests.map((test) => JsonReporter._spec(test, file)).toList(),
      // Upstream omits the key entirely rather than writing an empty array,
      // and at least one consumer in the wild treats `suites: []` as a leaf it
      // still has to walk.
      if (nested.isNotEmpty) 'suites': nested,
    };
  }
}

import 'dart:io';

import 'package:path/path.dart' as p;

import 'ansi.dart';
import 'model.dart';

/// Writes the JUnit XML that CI servers already know how to read.
///
/// Ported from `packages/playwright/src/reporters/junit.ts`. The element and
/// attribute names, their order, the `[[ATTACHMENT|path]]` convention and the
/// CDATA escaping are all copied: this file's only job is to be recognised by
/// somebody else's parser, so every place where a nicer choice existed, the
/// upstream choice won.
///
/// Notable inheritances that look like bugs and are not:
///
/// * there is no XML prolog, because upstream emits none;
/// * nothing is self-closing, so a skipped test gets `<skipped></skipped>`;
/// * `hostname` carries the project name, which is what upstream does with it;
/// * `time` is seconds, everywhere, while the JSON report is milliseconds.
class JUnitReporter {
  /// Value of `<testsuites id>`.
  final String suiteId;

  /// Value of `<testsuites name>`.
  final String suiteName;

  /// Whether to remove ANSI colors from attributes and text.
  final bool stripAnsiControlSequences;

  /// Whether to prefix a test name with `[project] `.
  final bool includeProjectInTestName;

  /// Where the file will be written, so attachment paths can be made relative
  /// to it. Null keeps them relative to the run directory.
  final String? outputFile;

  /// Where the run happened.
  final String rootDir;

  const JUnitReporter({
    required this.rootDir,
    this.suiteId = '',
    this.suiteName = '',
    this.stripAnsiControlSequences = false,
    this.includeProjectInTestName = false,
    this.outputFile,
  });

  /// Renders the whole document.
  String render(ReportRun run) {
    final timestamp = run.startTime.toUtc().toIso8601String();
    final children = <_XmlEntry>[
      for (final file in run.files) _testSuite(file, timestamp),
    ];
    var tests = 0;
    var failures = 0;
    var skipped = 0;
    var errors = 0;
    for (final file in run.files) {
      final counted = _count(file);
      tests += counted.tests;
      failures += counted.failures;
      skipped += counted.skipped;
      errors += counted.errors;
    }
    final root = _XmlEntry(
      'testsuites',
      attributes: {
        'id': suiteId,
        'name': suiteName,
        'tests': tests,
        'failures': failures,
        'skipped': skipped,
        'errors': errors,
        'time': _seconds(run.duration),
      },
      children: children,
    );
    final tokens = <String>[];
    _serialize(root, tokens);
    return tokens.join('\n');
  }

  _XmlEntry _testSuite(ReportFile file, String timestamp) {
    final counted = _count(file);
    final children = <_XmlEntry>[];
    for (final test in file.tests) {
      children.add(_testCase(file, test));
    }
    return _XmlEntry(
      'testsuite',
      attributes: {
        'name': file.path,
        'timestamp': timestamp,
        // Upstream puts the project name here. It is a strange home for it,
        // and it is also where every consumer now looks for it.
        'hostname': file.tests.isEmpty ? '' : file.tests.first.platform,
        'tests': counted.tests,
        'failures': counted.failures,
        'skipped': counted.skipped,
        'time': _seconds(file.duration),
        'errors': counted.errors,
      },
      children: children,
    );
  }

  _XmlEntry _testCase(ReportFile file, ReportTest test) {
    final prefix = includeProjectInTestName && test.platform.isNotEmpty
        ? '[${test.platform}] '
        : '';
    final entry = _XmlEntry(
      'testcase',
      attributes: {
        // U+203A between segments, exactly as upstream joins a title path.
        'name': prefix + [...test.groups, test.title].join(' › '),
        'classname': file.path,
        'time': _seconds(test.duration),
      },
      children: [],
    );

    if (test.skipReason != null) {
      entry.children.add(_XmlEntry('properties', children: [
        _XmlEntry('property',
            attributes: {'name': 'skip', 'value': test.skipReason!}),
      ]));
    }

    if (test.outcome == ReportOutcome.skipped) {
      entry.children.add(_XmlEntry('skipped'));
      return entry;
    }

    _appendStdIO(entry, test.results);

    if (test.outcome == ReportOutcome.unexpected) {
      final info = _classify(test);
      entry.children.add(_XmlEntry(
        info.element,
        attributes: {'message': info.message, 'type': info.type},
        text: _formatFailure(test),
      ));
    }
    return entry;
  }

  /// Adds `<system-out>` and `<system-err>`, attachments included.
  ///
  /// Exactly one of each, joined without a separator: upstream learned the
  /// hard way that parsers in the wild break on a second `<system-out>`.
  void _appendStdIO(_XmlEntry entry, List<ReportResult> results) {
    final out = <String>[];
    final err = <String>[];
    for (final result in results) {
      for (final line in result.stdout) {
        out.add('$line\n');
      }
      for (final line in result.stderr) {
        err.add('$line\n');
      }
      for (final attachment in result.attachments) {
        final path = attachment.path;
        // An inline attachment has no path to point a CI server at, and
        // upstream skips it for the same reason.
        if (path == null) continue;
        final relative = _relativeAttachment(path);
        if (File(path).existsSync()) {
          out.add('\n[[ATTACHMENT|$relative]]\n');
        } else {
          err.add('\nWarning: attachment $relative is missing');
        }
      }
    }
    if (out.isNotEmpty) {
      entry.children.add(_XmlEntry('system-out', text: out.join()));
    }
    if (err.isNotEmpty) {
      entry.children.add(_XmlEntry('system-err', text: err.join()));
    }
  }

  String _relativeAttachment(String path) {
    final from = outputFile == null ? rootDir : p.dirname(outputFile!);
    try {
      return p.relative(p.absolute(path), from: p.absolute(from));
    } catch (_) {
      return path;
    }
  }

  /// The text of a `<failure>`: every error of every attempt, plus a line per
  /// attachment so that a reader who only has the XML still knows what exists.
  String _formatFailure(ReportTest test) {
    final buffer = StringBuffer();
    for (final result in test.results) {
      if (test.results.length > 1) {
        buffer.writeln(
            result.retry == 0 ? '  Run:' : '  Retry #${result.retry}:');
      }
      for (final error in result.errors) {
        buffer.writeln(error.message);
        if (error.stack != null) buffer.writeln(error.stack);
      }
      for (var i = 0; i < result.attachments.length; i++) {
        final attachment = result.attachments[i];
        buffer.writeln('    attachment #${i + 1}: ${attachment.name} '
            '(${attachment.contentType})');
        if (attachment.path != null) buffer.writeln('    ${attachment.path}');
      }
    }
    return stripAnsiEscapes(buffer.toString());
  }

  /// Decides between `<failure>` and `<error>`, and what `type` to use.
  ///
  /// Upstream's rule, kept: an assertion that did not hold is a `failure` with
  /// the matcher as its type, and anything else is an `error` with the
  /// exception class as its type. CI dashboards group by `type`, so getting
  /// this wrong turns one recurring bug into a hundred unrelated ones.
  _ErrorInfo _classify(ReportTest test) {
    for (final result in test.results) {
      final error = result.error;
      if (error == null) continue;
      final raw = stripAnsiEscapes(error.message);
      final nameMatch = RegExp(r'^(\w+): ').firstMatch(raw);
      final body = nameMatch == null ? raw : raw.substring(nameMatch.end);
      final firstLine = body.split('\n').first.trim();

      final matcher = RegExp(r'expect\(.*?\)\.(not\.)?(\w+)').firstMatch(raw);
      if (matcher != null) {
        return _ErrorInfo('failure',
            'expect.${matcher.group(1) ?? ''}${matcher.group(2)}', firstLine);
      }
      // The Dart equivalent of upstream's matcher sniffing: an assertion that
      // went through `package:matcher` says so, and `TestFailure` is what
      // `expect` throws.
      if (raw.startsWith('Expected:') || nameMatch?.group(1) == 'TestFailure') {
        return _ErrorInfo('failure', 'expect', firstLine);
      }
      return _ErrorInfo('error', nameMatch?.group(1) ?? 'Error', firstLine);
    }
    return const _ErrorInfo('failure', 'FAILURE', '');
  }

  _Counts _count(ReportFile file) {
    var tests = 0;
    var failures = 0;
    var skipped = 0;
    var errors = 0;
    for (final test in file.tests) {
      tests++;
      switch (test.outcome) {
        case ReportOutcome.skipped:
          skipped++;
        case ReportOutcome.unexpected:
          if (_classify(test).element == 'error') {
            errors++;
          } else {
            failures++;
          }
        case ReportOutcome.expected:
        case ReportOutcome.flaky:
          break;
      }
    }
    return _Counts(tests, failures, skipped, errors);
  }

  void _serialize(_XmlEntry entry, List<String> tokens) {
    final attributes = <String>[
      for (final pair in entry.attributes.entries)
        '${pair.key}="${_escape('${pair.value}', isCharacterData: false)}"',
    ];
    tokens.add('<${entry.name}'
        '${attributes.isEmpty ? '' : ' '}${attributes.join(' ')}>');
    for (final child in entry.children) {
      _serialize(child, tokens);
    }
    final text = entry.text;
    if (text != null && text.isNotEmpty) {
      tokens.add(_escape(text, isCharacterData: true));
    }
    tokens.add('</${entry.name}>');
  }

  String _escape(String text, {required bool isCharacterData}) {
    var result = stripAnsiControlSequences ? stripAnsiEscapes(text) : text;
    if (isCharacterData) {
      result = '<![CDATA[${result.replaceAll(']]>', ']]&gt;')}]]>';
    } else {
      result = result.replaceAllMapped(
          RegExp('[&\"\'<>]'),
          (match) => const {
                '&': '&amp;',
                '"': '&quot;',
                "'": '&apos;',
                '<': '&lt;',
                '>': '&gt;',
              }[match[0]]!);
    }
    return result.replaceAll(discouragedXmlCharacters, '');
  }

  /// Milliseconds as seconds, printed the way JavaScript prints a number: no
  /// trailing zeros, and no decimal point at all for a whole number.
  static String _seconds(Duration duration) {
    final seconds = duration.inMilliseconds / 1000;
    if (seconds == seconds.truncate()) return '${seconds.truncate()}';
    return '$seconds';
  }
}

class _ErrorInfo {
  /// `failure` or `error`.
  final String element;
  final String type;
  final String message;

  const _ErrorInfo(this.element, this.type, this.message);
}

class _Counts {
  final int tests;
  final int failures;
  final int skipped;
  final int errors;

  const _Counts(this.tests, this.failures, this.skipped, this.errors);
}

class _XmlEntry {
  final String name;
  final Map<String, Object> attributes;
  final List<_XmlEntry> children;
  final String? text;

  _XmlEntry(
    this.name, {
    Map<String, Object>? attributes,
    List<_XmlEntry>? children,
    this.text,
  })  : attributes = attributes ?? const {},
        children = children ?? [];
}

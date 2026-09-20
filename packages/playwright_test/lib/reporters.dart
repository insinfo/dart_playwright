/// Reports for a `dart test` run: HTML, JSON and JUnit XML.
///
/// ```dart
/// import 'package:playwright_test/reporters.dart';
///
/// final run = DartTestParser().parse(File('events.jsonl').readAsLinesSync());
/// await HtmlReporter(outputFolder: 'playwright-report', rootDir: '.')
///     .write(run);
/// ```
///
/// The usual way in is the command line, which runs the suite and writes every
/// report in one go:
///
/// ```sh
/// dart run playwright_test:report -- test/
/// ```
///
/// ## Where these sit
///
/// `playwright_test` is a layer over `package:test`, not a runner, and that
/// holds here too. `package:test` already runs, filters, repeats, retries and
/// parallelizes, and it already prints a fine terminal report. What it has no
/// notion of is an HTML page, a JUnit file or a Playwright-shaped JSON — so
/// that is all this adds, reading the machine-readable stream
/// `--file-reporter json:<file>` writes while the normal console output goes
/// on as usual.
///
/// That is also why there is no `list`, `line` or `dot` reporter here:
/// `dart test -r expanded`, `-r compact` and `-r github` are those three, they
/// are what a Dart developer already knows, and a second implementation would
/// be a worse copy with a different name.
library;

export 'src/reporters/ansi.dart' show stripAnsiEscapes;
export 'src/reporters/dart_test_parser.dart';
export 'src/reporters/html_reporter.dart';
export 'src/reporters/json_reporter.dart';
export 'src/reporters/junit_reporter.dart';
export 'src/reporters/model.dart';

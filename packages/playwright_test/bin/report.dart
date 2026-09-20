// Runs `dart test` and writes an HTML, JSON and JUnit report of the run.
//
//   dart run playwright_test:report -- test/
//   dart run playwright_test:report --junit results.xml -- test/ -j 1
//   dart run playwright_test:report --input events.jsonl
//
// Everything after `--` is handed to `dart test` untouched, so every flag that
// already works keeps working. The console output is `dart test`'s own: the
// machine-readable stream goes to a file through `--file-reporter`, which is
// exactly why this does not have to reimplement a terminal reporter.
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'package:playwright_test/reporters.dart';

Future<void> main(List<String> arguments) async {
  final argParser = ArgParser()
    ..addOption('html',
        defaultsTo: 'playwright-report',
        help: 'Folder for the HTML report. Empty to skip it.')
    ..addOption('json', help: 'File for the Playwright-shaped JSON report.')
    ..addOption('junit', help: 'File for the JUnit XML report.')
    ..addOption('input',
        help: 'Read an existing `--file-reporter json:<file>` stream instead '
            'of running the suite.')
    ..addOption('events',
        help: 'With --input, the attachment and step stream that run wrote '
            '(the file PLAYWRIGHT_REPORT_EVENTS named).')
    ..addOption('title',
        defaultsTo: 'Playwright Test Report', help: 'Title of the HTML page.')
    ..addFlag('open',
        negatable: false, help: 'Print the file:// URL of the HTML report.')
    ..addFlag('help', abbr: 'h', negatable: false);

  final separator = arguments.indexOf('--');
  final ours = separator < 0 ? arguments : arguments.sublist(0, separator);
  final theirs = separator < 0 ? <String>[] : arguments.sublist(separator + 1);

  final ArgResults options;
  try {
    options = argParser.parse(ours);
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    stderr.writeln(argParser.usage);
    exit(64);
  }
  if (options['help'] as bool) {
    stdout.writeln('Usage: dart run playwright_test:report [options] '
        '[-- <dart test arguments>]\n');
    stdout.writeln(argParser.usage);
    return;
  }

  final rootDir = Directory.current.path;
  String runnerPath;
  String? sidePath;
  var exitCode = 0;
  Directory? temporary;

  final input = options['input'] as String?;
  if (input != null) {
    runnerPath = input;
    sidePath = options['events'] as String?;
  } else {
    temporary = Directory.systemTemp.createTempSync('playwright_report');
    runnerPath = p.join(temporary.path, 'runner.jsonl');
    sidePath = p.join(temporary.path, 'attachments.jsonl');

    // Two streams, because they come from two places. `--file-reporter` is the
    // runner's own machine-readable output and leaves the console report
    // untouched, which is the whole reason there is no terminal reporter in
    // this package. The other is written by the tests themselves, and only
    // because this variable names it.
    final process = await Process.start(
      Platform.resolvedExecutable,
      ['test', '--file-reporter', 'json:$runnerPath', ...theirs],
      mode: ProcessStartMode.inheritStdio,
      environment: {'PLAYWRIGHT_REPORT_EVENTS': sidePath},
    );
    exitCode = await process.exitCode;
  }

  final runnerEvents = File(runnerPath);
  if (!runnerEvents.existsSync()) {
    stderr.writeln('No event stream at $runnerPath: nothing to report on.');
    exit(exitCode == 0 ? 1 : exitCode);
  }

  final parser = DartTestParser(rootDir: rootDir);
  final run = parser.parse(runnerEvents.readAsLinesSync());
  if (sidePath != null && File(sidePath).existsSync()) {
    parser.applyEvents(File(sidePath).readAsLinesSync());
  }
  final stats = run.stats;

  final jsonPath = options['json'] as String?;
  if (jsonPath != null) {
    final report = JsonReporter(
      rootDir: rootDir,
      version: Platform.version.split(' ').first,
    ).render(run);
    File(jsonPath).parent.createSync(recursive: true);
    File(jsonPath).writeAsStringSync(report);
    stdout.writeln('JSON report:  $jsonPath');
  }

  final junitPath = options['junit'] as String?;
  if (junitPath != null) {
    final report = JUnitReporter(
      rootDir: rootDir,
      outputFile: junitPath,
      includeProjectInTestName: true,
    ).render(run);
    File(junitPath).parent.createSync(recursive: true);
    File(junitPath).writeAsStringSync(report);
    stdout.writeln('JUnit report: $junitPath');
  }

  final htmlFolder = options['html'] as String;
  if (htmlFolder.isNotEmpty) {
    final index = await HtmlReporter(
      outputFolder: htmlFolder,
      rootDir: rootDir,
      title: options['title'] as String,
    ).write(run);
    stdout.writeln('HTML report:  $index');
    if (options['open'] as bool) {
      stdout.writeln(Uri.file(p.absolute(index)).toString());
    }
  }

  stdout.writeln('${stats.expected} passed, ${stats.unexpected} failed, '
      '${stats.flaky} flaky, ${stats.skipped} skipped');

  temporary?.deleteSync(recursive: true);
  // The exit code is `dart test`'s. Reporting is a side effect of a run, and a
  // wrapper that turns a red run green is a wrapper that breaks CI quietly.
  exit(exitCode);
}

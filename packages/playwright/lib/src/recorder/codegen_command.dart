// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/playwright-core/src/cli/program.ts, the `codegen`
// command.

import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:playwright_isomorphic/playwright_isomorphic.dart';

import '../../playwright.dart';
import 'recorder.dart';
import 'recorder_app.dart';
import 'recorder_types.dart';
import 'throttled_file.dart';

/// `playwright codegen [url]`: opens a browser, records what the user does and
/// prints the code.
///
/// The default generator is the Dart one, because Dart is the only binding
/// this repository has; `--target` selects any of the others.
///
/// Difference from upstream: upstream opens a second browser window with the
/// recorder user interface, where the code appears and the language can be
/// switched. This port has no web application base yet, so the code goes to
/// the terminal instead — one line per action as it is recorded, and the whole
/// file when the browser closes. `--output` mirrors the file to disk while
/// recording, which is what an editor can watch.
class CodegenCommand extends Command<void> {
  @override
  String get name => 'codegen';

  @override
  String get description =>
      'Record actions in a browser and generate the code for them';

  @override
  String get invocation => 'playwright codegen [url]';

  CodegenCommand() {
    argParser
      ..addOption('browser',
          abbr: 'b',
          help: 'Browser to record in',
          allowed: ['chromium', 'firefox', 'webkit'],
          defaultsTo: 'chromium')
      ..addOption('target',
          help: 'Language and flavour of the generated code',
          allowed: generatorIds(),
          defaultsTo: 'dart-test')
      ..addOption('output',
          abbr: 'o', help: 'Also write the generated code to this file')
      ..addOption('test-id-attribute',
          help: 'Attribute getByTestId reads', defaultsTo: 'data-testid')
      ..addOption('timeout',
          help: 'Stop recording after this many seconds, 0 to wait for the '
              'browser to close',
          defaultsTo: '0')
      ..addFlag('headless',
          help: 'Run the browser headless; only useful for tests',
          defaultsTo: false)
      ..addFlag('quiet',
          help: 'Do not print each action as it is recorded',
          defaultsTo: false);
  }

  @override
  Future<void> run() async {
    final args = argResults!;
    final url = args.rest.isEmpty ? null : args.rest.first;
    final browserName = args['browser'] as String;
    final target = args['target'] as String;
    final outputPath = args['output'] as String?;
    final quiet = args['quiet'] as bool;
    final headless = args['headless'] as bool;
    final timeoutSeconds = int.tryParse(args['timeout'] as String) ?? 0;

    final code = await runCodegen(
      browserName: browserName,
      target: target,
      url: url,
      outputPath: outputPath,
      testIdAttributeName: args['test-id-attribute'] as String,
      headless: headless,
      quiet: quiet,
      timeout: timeoutSeconds > 0 ? Duration(seconds: timeoutSeconds) : null,
    );

    stdout
      ..writeln()
      ..writeln(code);
  }
}

/// Runs one recording session and returns the generated source.
///
/// Split out of [CodegenCommand] so a test can drive it without the argument
/// parser.
Future<String> runCodegen({
  required String browserName,
  String target = 'dart-test',
  String? url,
  String? outputPath,
  String testIdAttributeName = 'data-testid',
  bool headless = false,
  bool quiet = false,
  bool isUnderTest = false,
  Duration? timeout,
  FutureOr<void> Function(Page page)? onReady,
}) async {
  final playwright = await Playwright.create();
  final browserType = switch (browserName) {
    'firefox' => playwright.firefox,
    'webkit' => playwright.webkit,
    _ => playwright.chromium,
  };
  final browser = await browserType.launch(headless: headless);
  final context = await browser.newContext();

  final recorder = Recorder(
    context,
    language: generatorById(target).highlighter,
    testIdAttributeName: testIdAttributeName,
    isUnderTest: isUnderTest,
  );
  await recorder.install();

  final collection = RecorderCollection(
    recorder: recorder,
    generatorId: target,
    options: LanguageGeneratorOptions(
      browserName: browserName,
      launchOptions: {'headless': false},
      contextOptions: const {},
    ),
    outputFile: outputPath == null ? null : ThrottledFile(outputPath),
  );

  StreamSubscription<RecorderEvent>? printer;
  if (!quiet) {
    printer = collection.events.listen((event) {
      if (event.code.trim().isEmpty) return;
      final prefix = switch (event.kind) {
        RecorderEventKind.actionAdded => '',
        RecorderEventKind.actionUpdated => '~ ',
        RecorderEventKind.signalAdded => '~ ',
      };
      for (final line in event.code.trimRight().split('\n')) {
        stdout.writeln('$prefix$line');
      }
    });
  }

  // The session ends when the user closes the browser, or when the caller's
  // deadline passes. The subscription is opened before anything can close the
  // context, so a fast caller cannot miss the event and hang until the
  // deadline.
  final closed = context.onClose.first;

  final page = await context.newPage();
  await recorder.setMode(RecorderMode.recording);
  if (url != null) {
    await page.goto(url);
  }
  await onReady?.call(page);

  if (timeout != null) {
    await closed.timeout(timeout, onTimeout: () {});
  } else {
    await closed;
  }

  recorder.flushPendingActions();
  // Let the flushed action reach the collection before reading it: the
  // recorder hands actions over through a broadcast stream, which delivers on
  // the next microtask.
  await Future<void>.delayed(Duration.zero);

  final text = collection.generate().text;
  await printer?.cancel();
  await collection.dispose();
  await recorder.dispose();
  try {
    await browser.close();
  } catch (_) {
    // Already gone because the user closed it.
  }
  return text;
}

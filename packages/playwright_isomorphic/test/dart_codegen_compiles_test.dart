// The point of this test: the Dart generator's output is not checked by
// eye. It is written into the workspace, where `package:playwright` and
// `package:playwright_test` resolve, and `dart analyze` is run over it. A
// generator that emits a method this port does not have fails here.
@Tags(['analyzer'])
library;

import 'dart:io';

import 'package:playwright_isomorphic/playwright_isomorphic.dart';
import 'package:test/test.dart';

/// Walks up from the current directory to the workspace root.
Directory _workspaceRoot() {
  var dir = Directory.current;
  while (true) {
    if (Directory('${dir.path}/packages/playwright_test').existsSync()) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('Could not find the workspace root from '
          '${Directory.current.path}');
    }
    dir = parent;
  }
}

const _options = LanguageGeneratorOptions(
  browserName: 'chromium',
  launchOptions: {'headless': false},
  contextOptions: {
    'viewport': {'width': 1280, 'height': 720},
    'locale': 'pt-BR',
    'colorScheme': 'dark',
  },
);

/// One of every action, so that every branch of the generator is compiled.
List<ActionInContext> _actions() {
  const guid = 'page@1';
  ActionInContext at(Action action, [List<Signal> signals = const []]) =>
      ActionInContext(pageGuid: guid, action: action, signals: signals);
  return [
    at(OpenPageAction(url: 'https://example.com/')),
    at(NavigateAction(url: 'https://example.com/form')),
    at(ClickAction(selector: 'internal:role=button[name="Entrar"i]')),
    at(ClickAction(selector: 'canvas', position: const Point(250, 250))),
    at(ClickAction(
        selector: 'internal:role=link[name="Ok"s]',
        button: 'right',
        clickCount: 3,
        modifiers: 9)),
    at(ClickAction(selector: 'div', clickCount: 2)),
    at(HoverAction(selector: 'internal:text="Hover me"i')),
    at(HoverAction(selector: 'span', position: const Point(1, 2))),
    at(CheckAction(selector: 'internal:label="I agree"i')),
    at(UncheckAction(selector: '#news')),
    at(FillAction(selector: '#input', text: "it's a \$value\nwith lines")),
    at(SetInputFilesAction(selector: '#file', files: ['a.txt', 'b.txt'])),
    at(PressAction(
        selector: 'internal:role=textbox', key: 'Enter', modifiers: 8)),
    at(SelectAction(selector: '#select', options: ['one'])),
    at(SelectAction(selector: '#multi', options: ['one', 'two'])),
    at(AssertTextAction(selector: 'h1', text: 'Hello', substring: false)),
    at(AssertTextAction(selector: 'h2', text: 'Hello', substring: true)),
    at(AssertValueAction(selector: '#input', value: 'John')),
    at(AssertValueAction(selector: '#empty', value: '')),
    at(AssertCheckedAction(selector: '#news', checked: true)),
    at(AssertCheckedAction(selector: '#ads', checked: false)),
    at(AssertVisibleAction(selector: 'internal:role=alert')),
    at(AssertSnapshotAction(
        selector: 'body', ariaSnapshot: '- heading "Hello" [level=1]\n- list')),
    at(
      ClickAction(selector: 'internal:text="Open popup"i'),
      [PopupSignal(popupPageGuid: 'page@2')],
    ),
    at(
      ClickAction(selector: 'internal:text="Download"i'),
      [DownloadSignal(downloadAlias: '1')],
    ),
    at(
      ClickAction(selector: 'internal:text="Alert"i'),
      [DialogSignal(dialogAlias: '1')],
    ),
    at(ClosesPageAction()),
  ];
}

void main() {
  late Directory checkDir;

  setUpAll(() {
    checkDir = Directory(
        '${_workspaceRoot().path}/packages/playwright_test/test/codegen_check');
    if (checkDir.existsSync()) checkDir.deleteSync(recursive: true);
    checkDir.createSync(recursive: true);
  });

  tearDownAll(() {
    if (checkDir.existsSync()) checkDir.deleteSync(recursive: true);
  });

  test('the generated Dart passes dart analyze', () async {
    final testSource = generateCode(
            _actions(), DartLanguageGenerator(DartLanguageMode.test), _options)
        .text;
    final librarySource = generateCode(_actions(),
            DartLanguageGenerator(DartLanguageMode.library), _options)
        .text;
    final storageSource = generateCode(
        _actions(),
        DartLanguageGenerator(DartLanguageMode.library),
        const LanguageGeneratorOptions(
          browserName: 'firefox',
          launchOptions: {'headless': false},
          contextOptions: {},
          saveStorage: 'state.json',
        )).text;

    File('${checkDir.path}/generated_test_mode.dart')
        .writeAsStringSync(testSource);
    File('${checkDir.path}/generated_library_mode.dart')
        .writeAsStringSync(librarySource);
    File('${checkDir.path}/generated_storage_mode.dart')
        .writeAsStringSync(storageSource);

    final result = await Process.run(
      Platform.resolvedExecutable,
      ['analyze', '--no-fatal-warnings', checkDir.path],
      workingDirectory: _workspaceRoot().path,
    );
    expect(result.exitCode, 0,
        reason: 'dart analyze rejected the generated code:\n'
            '${result.stdout}\n${result.stderr}\n\n'
            '--- test mode ---\n$testSource\n'
            '--- library mode ---\n$librarySource');
  }, timeout: const Timeout(Duration(minutes: 3)));
}

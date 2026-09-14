import 'dart:io';

import 'package:playwright/playwright.dart';

import '../browser_session.dart';
import '../mcp_tool.dart';
import 'snapshot.dart';

/// Builds a tool from a closure, so the twenty-odd tools below stay readable
/// instead of becoming twenty-odd classes.
class _Tool extends McpTool {
  @override
  final String name;
  @override
  final String description;
  @override
  final Map<String, dynamic> inputSchema;

  final Future<McpResult> Function(
      BrowserSession session, Map<String, dynamic> args) _run;

  _Tool({
    required this.name,
    required this.description,
    Map<String, dynamic>? properties,
    List<String> required = const [],
    required Future<McpResult> Function(
            BrowserSession session, Map<String, dynamic> args)
        run,
  })  : inputSchema = {
          'type': 'object',
          'properties': properties ?? <String, dynamic>{},
          if (required.isNotEmpty) 'required': required,
        },
        _run = run;

  @override
  Future<McpResult> execute(
          BrowserSession session, Map<String, dynamic> args) =>
      _run(session, args);
}

Map<String, dynamic> _targetProps([Map<String, dynamic>? extra]) => {
      ...targetSchemaProperties(),
      ...?extra,
    };

/// A snapshot appended to an action's result, so the model sees the page it
/// just changed without having to ask for it.
Future<String> _withSnapshot(Page page, String message) async {
  try {
    return '$message\n\n${await renderSnapshot(page)}';
  } catch (error) {
    return '$message\n\n(snapshot unavailable: $error)';
  }
}

String _describeDialog(Dialog dialog) =>
    'A ${dialog.type} dialog is open and waiting: "${dialog.message}". '
    'Answer it with browser_handle_dialog before doing anything else.';

/// Every tool the server ships with.
List<McpTool> defaultTools() => [
      // ------------------------------------------------------ navigation
      _Tool(
        name: 'browser_navigate',
        description: 'Navigate the current tab to a URL and snapshot the page.',
        properties: {
          'url': {'type': 'string', 'description': 'URL to navigate to.'},
          'waitUntil': {
            'type': 'string',
            'enum': ['load', 'domcontentloaded', 'commit'],
            'description': 'When to consider navigation finished.',
          },
        },
        required: ['url'],
        run: (session, args) async {
          final page = await session.currentPage();
          final waitUntil = switch (args['waitUntil']) {
            'domcontentloaded' => WaitUntilState.domcontentloaded,
            'commit' => WaitUntilState.commit,
            _ => WaitUntilState.load,
          };
          await page.goto(requireString(args, 'url', 'browser_navigate'),
              waitUntil: waitUntil);
          return McpResult.text(
              await _withSnapshot(page, 'Navigated to ${await page.url()}.'));
        },
      ),
      _Tool(
        name: 'browser_navigate_back',
        description: 'Go back one entry in the current tab history.',
        run: (session, args) async {
          final page = await session.currentPage();
          final moved = await page.goBack();
          return McpResult.text(await _withSnapshot(
              page, moved ? 'Went back.' : 'No previous entry in history.'));
        },
      ),
      _Tool(
        name: 'browser_navigate_forward',
        description: 'Go forward one entry in the current tab history.',
        run: (session, args) async {
          final page = await session.currentPage();
          final moved = await page.goForward();
          return McpResult.text(await _withSnapshot(
              page, moved ? 'Went forward.' : 'No next entry in history.'));
        },
      ),

      // -------------------------------------------------------- snapshot
      _Tool(
        name: 'browser_snapshot',
        description:
            'Snapshot the page: URL, title and a tree of roles, names and '
            'element references to use with the other tools.',
        run: (session, args) async {
          final page = await session.currentPage();
          final dialog = session.pendingDialog;
          if (dialog != null) return McpResult.text(_describeDialog(dialog));
          return McpResult.text(await renderSnapshot(page));
        },
      ),

      // ----------------------------------------------------------- input
      _Tool(
        name: 'browser_click',
        description: 'Click an element. Waits for it to be actionable.',
        properties: _targetProps({
          'button': {
            'type': 'string',
            'enum': ['left', 'middle', 'right'],
          },
          'doubleClick': {'type': 'boolean'},
        }),
        run: (session, args) async {
          final page = await session.currentPage();
          final target = resolveTarget(page, args, 'browser_click');
          final button = args['button'] as String? ?? 'left';
          if (args['doubleClick'] == true) {
            await target.dblclick(button: button);
          } else {
            await target.click(button: button);
          }
          final dialog = session.pendingDialog;
          if (dialog != null) return McpResult.text(_describeDialog(dialog));
          return McpResult.text(await _withSnapshot(page, 'Clicked.'));
        },
      ),
      _Tool(
        name: 'browser_type',
        description:
            'Type text into an element, replacing what is there. Set submit '
            'to press Enter afterwards.',
        properties: _targetProps({
          'text': {'type': 'string', 'description': 'Text to type.'},
          'submit': {
            'type': 'boolean',
            'description': 'Press Enter after typing.',
          },
        }),
        required: ['text'],
        run: (session, args) async {
          final page = await session.currentPage();
          final target = resolveTarget(page, args, 'browser_type');
          await target.fill(requireString(args, 'text', 'browser_type'));
          if (args['submit'] == true) await target.press('Enter');
          final dialog = session.pendingDialog;
          if (dialog != null) return McpResult.text(_describeDialog(dialog));
          return McpResult.text(await _withSnapshot(page, 'Typed.'));
        },
      ),
      _Tool(
        name: 'browser_hover',
        description: 'Hover the pointer over an element.',
        properties: _targetProps(),
        run: (session, args) async {
          final page = await session.currentPage();
          await resolveTarget(page, args, 'browser_hover').hover();
          return McpResult.text(await _withSnapshot(page, 'Hovered.'));
        },
      ),
      _Tool(
        name: 'browser_select_option',
        description: 'Select one or more options in a <select>.',
        properties: _targetProps({
          'values': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': 'Option values, labels or texts to select.',
          },
        }),
        required: ['values'],
        run: (session, args) async {
          final page = await session.currentPage();
          final values = (args['values'] as List?)?.cast<Object?>();
          if (values == null || values.isEmpty) {
            throw ArgumentError('browser_select_option requires "values"');
          }
          final selected =
              await resolveTarget(page, args, 'browser_select_option')
                  .selectOption(values.map((v) => '$v').toList());
          return McpResult.text(
              await _withSnapshot(page, 'Selected: ${selected.join(', ')}.'));
        },
      ),
      _Tool(
        name: 'browser_press_key',
        description:
            'Press a key or chord on the page, e.g. "Enter", "Escape", '
            '"Control+A".',
        properties: {
          'key': {'type': 'string'},
        },
        required: ['key'],
        run: (session, args) async {
          final page = await session.currentPage();
          await page.keyboard
              .press(requireString(args, 'key', 'browser_press_key'));
          return McpResult.text(await _withSnapshot(page, 'Key pressed.'));
        },
      ),
      _Tool(
        name: 'browser_file_upload',
        description:
            'Point a file input at one or more files on the machine running '
            'the browser.',
        properties: _targetProps({
          'paths': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': 'Absolute paths of the files to upload.',
          },
        }),
        required: ['paths'],
        run: (session, args) async {
          final page = await session.currentPage();
          final paths = (args['paths'] as List?)?.map((p) => '$p').toList();
          if (paths == null) {
            throw ArgumentError('browser_file_upload requires "paths"');
          }
          for (final path in paths) {
            if (!File(path).existsSync()) {
              return McpResult.error('No such file: $path');
            }
          }
          await resolveTarget(page, args, 'browser_file_upload')
              .setInputFiles(paths);
          return McpResult.text(
              await _withSnapshot(page, 'Attached ${paths.length} file(s).'));
        },
      ),

      // -------------------------------------------------------- dialogs
      _Tool(
        name: 'browser_handle_dialog',
        description:
            'Answer the dialog the page opened. A dialog blocks the page '
            'until it is answered.',
        properties: {
          'accept': {'type': 'boolean', 'description': 'Accept or dismiss.'},
          'promptText': {
            'type': 'string',
            'description': 'Text to enter, for a prompt dialog.',
          },
        },
        required: ['accept'],
        run: (session, args) async {
          final dialog = session.pendingDialog;
          if (dialog == null) return McpResult.error('No dialog is open.');
          session.pendingDialog = null;
          if (args['accept'] == true) {
            await dialog.accept(args['promptText'] as String?);
          } else {
            await dialog.dismiss();
          }
          final page = await session.currentPage();
          return McpResult.text(await _withSnapshot(
              page,
              args['accept'] == true
                  ? 'Dialog accepted.'
                  : 'Dialog dismissed.'));
        },
      ),

      // ----------------------------------------------------------- tabs
      _Tool(
        name: 'browser_tab_list',
        description: 'List the open tabs and which one the tools act on.',
        run: (session, args) async {
          if (session.tabs.isEmpty) return McpResult.text('No tabs open.');
          final lines = <String>[];
          for (var i = 0; i < session.tabs.length; i++) {
            final page = session.tabs[i];
            final marker = i == session.currentTabIndex ? '*' : ' ';
            lines.add(
                '$marker [$i] ${await page.url()} - ${await page.title()}');
          }
          return McpResult.text(lines.join('\n'));
        },
      ),
      _Tool(
        name: 'browser_tab_new',
        description: 'Open a new tab and make it current.',
        properties: {
          'url': {'type': 'string', 'description': 'Optional URL to open.'},
        },
        run: (session, args) async {
          final page = await session.newTab();
          final url = args['url'];
          if (url is String && url.isNotEmpty) await page.goto(url);
          return McpResult.text(await _withSnapshot(
              page, 'Opened tab ${session.currentTabIndex}.'));
        },
      ),
      _Tool(
        name: 'browser_tab_select',
        description: 'Make another tab current.',
        properties: {
          'index': {'type': 'integer', 'description': 'Tab index.'},
        },
        required: ['index'],
        run: (session, args) async {
          final index = args['index'];
          if (index is! int) {
            throw ArgumentError(
                'browser_tab_select requires an integer "index"');
          }
          session.selectTab(index);
          final page = await session.currentPage();
          return McpResult.text(
              await _withSnapshot(page, 'Selected tab $index.'));
        },
      ),
      _Tool(
        name: 'browser_tab_close',
        description: 'Close a tab, or the current one when no index is given.',
        properties: {
          'index': {'type': 'integer'},
        },
        run: (session, args) async {
          final index = args['index'];
          await session
              .closeTab(index is int ? index : session.currentTabIndex);
          return McpResult.text('Tab closed. ${session.tabs.length} left.');
        },
      ),

      // ------------------------------------------------------ artifacts
      _Tool(
        name: 'browser_take_screenshot',
        description:
            'Screenshot the page, or one element when a target is given.',
        properties: _targetProps({
          'fullPage': {
            'type': 'boolean',
            'description': 'Capture the whole scrollable page.',
          },
          'type': {
            'type': 'string',
            'enum': ['png', 'jpeg'],
          },
        }),
        run: (session, args) async {
          final page = await session.currentPage();
          final type = args['type'] as String? ?? 'png';
          final hasTarget = args['ref'] != null ||
              args['selector'] != null ||
              args['role'] != null;
          final bytes = hasTarget
              ? await resolveTarget(page, args, 'browser_take_screenshot')
                  .screenshot(type: type)
              : await page.screenshot(
                  type: type, fullPage: args['fullPage'] == true);
          return McpResult.image(bytes, mimeType: 'image/$type');
        },
      ),
      _Tool(
        name: 'browser_pdf_save',
        description:
            'Render the page to PDF and save it. Chromium only: neither the '
            'Firefox nor the WebKit protocol has a print-to-PDF command.',
        properties: {
          'path': {
            'type': 'string',
            'description': 'Where to write the PDF, on the machine running '
                'the browser.',
          },
        },
        required: ['path'],
        run: (session, args) async {
          final page = await session.currentPage();
          final path = requireString(args, 'path', 'browser_pdf_save');
          try {
            final bytes = await page.pdf(path: path, printBackground: true);
            return McpResult.text(
                'Saved ${bytes.length} bytes of PDF to $path.');
          } on UnsupportedError catch (error) {
            return McpResult.error('$error');
          }
        },
      ),

      // ------------------------------------------------ page inspection
      _Tool(
        name: 'browser_console_messages',
        description: 'The console output and uncaught page errors seen so far.',
        run: (session, args) async {
          if (session.consoleMessages.isEmpty) {
            return McpResult.text('No console messages.');
          }
          return McpResult.text(session.consoleMessages
              .map((m) => '[${m.type}] ${m.text}')
              .join('\n'));
        },
      ),
      _Tool(
        name: 'browser_network_requests',
        description: 'The network exchanges seen so far.',
        run: (session, args) async {
          if (session.networkRequests.isEmpty) {
            return McpResult.text('No network activity recorded.');
          }
          return McpResult.text(session.networkRequests
              .map((r) => '${r.method} ${r.url} => ${r.status ?? 'failed'}')
              .join('\n'));
        },
      ),
      _Tool(
        name: 'browser_evaluate',
        description:
            'Run JavaScript in the page and return the result. Use this only '
            'when no other tool fits.',
        properties: {
          'expression': {
            'type': 'string',
            'description': 'A JS expression or arrow function, e.g. '
                '"() => document.title".',
          },
        },
        required: ['expression'],
        run: (session, args) async {
          final page = await session.currentPage();
          final result = await page
              .evaluate(requireString(args, 'expression', 'browser_evaluate'));
          return McpResult.text('$result');
        },
      ),
      _Tool(
        name: 'browser_wait_for',
        description:
            'Wait for text to appear, for an element to reach a state, or '
            'for a fixed delay.',
        properties: _targetProps({
          'text': {
            'type': 'string',
            'description': 'Text to wait for anywhere on the page.',
          },
          'state': {
            'type': 'string',
            'enum': ['attached', 'detached', 'visible', 'hidden'],
            'description': 'State the targeted element should reach.',
          },
          'timeMs': {
            'type': 'integer',
            'description': 'A fixed delay in milliseconds. A last resort.',
          },
          'timeoutMs': {'type': 'integer'},
        }),
        run: (session, args) async {
          final page = await session.currentPage();
          final timeout =
              Duration(milliseconds: (args['timeoutMs'] as int?) ?? 10000);
          final text = args['text'];
          if (text is String && text.isNotEmpty) {
            await page.getByText(text).first.waitFor(timeout: timeout);
            return McpResult.text(
                await _withSnapshot(page, 'Text "$text" appeared.'));
          }
          final delay = args['timeMs'];
          if (delay is int) {
            await page.waitForTimeout(Duration(milliseconds: delay));
            return McpResult.text(
                await _withSnapshot(page, 'Waited ${delay}ms.'));
          }
          final state = switch (args['state']) {
            'attached' => WaitForSelectorState.attached,
            'detached' => WaitForSelectorState.detached,
            'hidden' => WaitForSelectorState.hidden,
            _ => WaitForSelectorState.visible,
          };
          await resolveTarget(page, args, 'browser_wait_for')
              .waitFor(state: state, timeout: timeout);
          return McpResult.text(await _withSnapshot(
              page, 'Element reached ${args['state'] ?? 'visible'}.'));
        },
      ),

      // ----------------------------------------------------- viewport
      _Tool(
        name: 'browser_resize',
        description: 'Resize the viewport of the current tab.',
        properties: {
          'width': {'type': 'integer'},
          'height': {'type': 'integer'},
        },
        required: ['width', 'height'],
        run: (session, args) async {
          final width = args['width'];
          final height = args['height'];
          if (width is! int || height is! int) {
            throw ArgumentError(
                'browser_resize requires integer "width" and "height"');
          }
          final page = await session.currentPage();
          await page.setViewportSize(width, height);
          return McpResult.text(
              await _withSnapshot(page, 'Viewport is now ${width}x$height.'));
        },
      ),

      // -------------------------------------------------------- session
      _Tool(
        name: 'browser_close',
        description:
            'Close the browser. The next tool that needs a page opens a new '
            'one.',
        run: (session, args) async {
          if (!session.isStarted) return McpResult.text('No browser running.');
          await session.close();
          return McpResult.text('Browser closed.');
        },
      ),
    ];

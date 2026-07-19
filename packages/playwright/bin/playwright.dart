import 'dart:io';
import 'package:args/command_runner.dart';
import 'package:playwright_core/src/registry/registry.dart';

Future<void> main(List<String> args) async {
  final runner = CommandRunner<void>(
    'playwright',
    'Playwright for Dart — Browser automation',
  )..addCommand(InstallCommand())..addCommand(ListCommand());

  try {
    await runner.run(args);
  } catch (error) {
    stderr.writeln('Error: $error');
    exit(1);
  }
  // Exit explicitly: lingering keep-alive sockets or isolates must not keep
  // the CLI process alive after the command finished.
  exit(0);
}

class InstallCommand extends Command<void> {
  @override
  String get name => 'install';
  
  @override
  String get description => 'Install browser binaries';

  @override
  Future<void> run() async {
    final registry = BrowserRegistry();
    final browsers = argResults!.rest;

    if (browsers.isEmpty) {
      await registry.installAll(onProgress: _progressPrinter());
      stdout.writeln();
    } else {
      final printer = _progressPrinter();
      for (final browser in browsers) {
        await registry.install(browser, onProgress: (progress) {
          printer(browser, progress);
        });
        stdout.writeln();
      }
    }
  }

  /// Progress callback throttled to whole-percent changes. On a terminal it
  /// rewrites one line with \r; without a TTY (CI logs) it prints one line
  /// per 10% so logs stay small.
  void Function(String, double) _progressPrinter() {
    var lastPercent = -1;
    var lastBrowser = '';
    return (browser, progress) {
      final percent = (progress * 100).floor();
      if (browser == lastBrowser && percent == lastPercent) return;
      final browserChanged = browser != lastBrowser;
      lastBrowser = browser;
      lastPercent = percent;
      if (stdout.hasTerminal) {
        stdout.write('\r$browser: $percent%     ');
      } else if (percent % 10 == 0 || browserChanged) {
        stdout.writeln('$browser: $percent%');
      }
    };
  }
}

class ListCommand extends Command<void> {
  @override
  String get name => 'list';
  
  @override
  String get description => 'List installed browsers';

  @override
  void run() {
    final registry = BrowserRegistry();
    for (final browser in registry.browsers) {
      final installed = registry.isInstalled(browser.name);
      final status = installed ? '✅' : '❌';
      final version = browser.browserVersion ?? browser.revision;
      print('$status ${browser.title ?? browser.name} $version');
    }
  }
}

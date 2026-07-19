import 'dart:io';
import 'package:args/command_runner.dart';
import 'package:playwright_core/src/registry/registry.dart';

void main(List<String> args) {
  final runner = CommandRunner<void>(
    'playwright',
    'Playwright for Dart — Browser automation',
  )..addCommand(InstallCommand())..addCommand(ListCommand());

  runner.run(args).catchError((error) {
    stderr.writeln('Error: $error');
    exit(1);
  });
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
      await registry.installAll(onProgress: (browser, progress) {
        stdout.write('\r$browser: ${(progress * 100).toStringAsFixed(1)}%     ');
      });
      stdout.writeln();
    } else {
      for (final browser in browsers) {
        await registry.install(browser, onProgress: (progress) {
          stdout.write('\r$browser: ${(progress * 100).toStringAsFixed(1)}%     ');
        });
        stdout.writeln();
      }
    }
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

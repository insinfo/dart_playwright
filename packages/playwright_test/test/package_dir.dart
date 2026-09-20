import 'dart:io';

import 'package:path/path.dart' as p;

/// Absolute path of the `playwright_test` package directory.
///
/// The fixtures here are named relatively -- `test/fixtures/serve_app.dart`,
/// `test/fixtures/web_app` -- and a child process inherits the runner's
/// directory, not the test file's. That resolved only while `dart test` ran
/// from inside this package: from the repository root every web server test
/// failed, half with `Could not find file` and half with a 404 for a fixture
/// that was running but serving the wrong tree, and the source map tests died
/// on an invalid working directory.
///
/// Walking up from the current directory finds the package from either place.
final String packageDir = _resolve();

String _resolve() {
  var dir = Directory.current.absolute.path;
  while (true) {
    for (final candidate in [dir, p.join(dir, 'packages', 'playwright_test')]) {
      if (File(p.join(candidate, 'test', 'fixtures', 'serve_app.dart'))
          .existsSync()) {
        return candidate;
      }
    }
    final parent = p.dirname(dir);
    if (parent == dir) {
      throw StateError('o diretorio de playwright_test nao foi encontrado a '
          'partir de ${Directory.current.path}');
    }
    dir = parent;
  }
}

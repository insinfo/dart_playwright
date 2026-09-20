# playwright_isomorphic

The isomorphic layer of [Playwright for Dart][repo]: the code that has to run
both in a browser and on the command line.

It is a port of upstream's `packages/isomorphic`, and it imports only
`dart:convert` -- no `dart:io`, no `dart:html`, no `package:web`. That is the
whole point of it being a package of its own: the trace viewer is compiled to
the web with dart2js, the recorder runs in the VM, and both need the same
selector parsing and the same code generators.

You probably want the [`playwright`][pw] package instead. This one is a
dependency of it.

## Locators

`asLocator` turns an internal selector into the locator someone would have
written, in the language they are writing:

```dart
import 'package:playwright_isomorphic/playwright_isomorphic.dart';

asLocator('dart', "internal:role=button[name=\"Entrar\"i]");
// getByRole('button', name: 'Entrar')
```

`locatorOrSelectorAsSelector` is the inverse, for a "pick locator" box.

## Code generation

`generateCode` takes the actions a recorder collected and emits a script.
Generators ship for Dart, JavaScript, Python, Java, C# and JSONL; the Dart one
is the default here, because it is the binding this repository has.

## License

Apache 2.0. Derived from Playwright; see `NOTICE` in the repository root.

[repo]: https://github.com/insinfo/dart_playwright
[pw]: https://pub.dev/packages/playwright

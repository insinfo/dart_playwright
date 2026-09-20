# Changelog

## 0.1.0

First release: the isomorphic layer of Playwright, in pure Dart.

Port of `packages/isomorphic` from upstream. It holds the code that has to run
in two places at once -- the trace viewer compiled to the web, and the recorder
on the command line -- so it imports only `dart:convert`, and never `dart:io`,
`dart:html` or `package:web`.

### What is in it

- `locatorGenerators`, `locatorParser` and `locatorUtils`: an internal selector
  into the idiomatic locator of each language, and back.
- `selectorParser`, `cssParser` and `cssTokenizer`. These were not ported
  before: what existed was a translation into JavaScript inside a Dart string,
  which only runs inside the page. `parseSelector` needs `parseCSS` to tell a
  selector from a locator expression, which is what makes the reverse path
  work.
- The `codegen/` framework and the generators for JavaScript, Python, Java,
  C# and JSONL.
- A Dart generator, which upstream does not have because there is no official
  Dart binding. It emits code for `package:playwright` and
  `package:playwright_test`.
- `JsRegExp`, because Dart's `RegExp` keeps neither the source nor the flag
  string, so `/a/im` did not survive the round trip. It reproduces the
  `EscapeRegExpPattern` of ECMA-262.

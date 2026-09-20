/// Selector parsing and source code generation, shared by the recorder, the
/// trace viewer and the CLI.
///
/// Nothing here touches `dart:io` or the DOM, on purpose: the same code has
/// to run inside a `dart2js` build of the trace viewer and inside a plain
/// command line tool.
///
/// The two halves are:
///
/// * **Selectors.** [parseSelector] turns a Playwright selector string into
///   its engine chain and [stringifySelector] turns it back. [asLocator] and
///   [asLocators] render a selector as the idiomatic locator of a language,
///   and [locatorOrSelectorAsSelector] goes the other way.
/// * **Codegen.** A [LanguageGenerator] per language turns recorded
///   [ActionInContext]s into a source file; [generateCode] drives one.
///
/// ```dart
/// asLocator('dart', 'internal:role=button[name="Entrar"i]');
/// // getByRole('button', name: 'Entrar')
/// ```
library playwright_isomorphic;

export 'src/codegen/actions.dart';
export 'src/codegen/csharp.dart';
export 'src/codegen/dart.dart';
export 'src/codegen/java.dart';
export 'src/codegen/javascript.dart';
export 'src/codegen/jsonl.dart';
export 'src/codegen/language.dart';
export 'src/codegen/languages.dart';
export 'src/codegen/python.dart';
export 'src/codegen/types.dart';
export 'src/css_parser.dart';
export 'src/css_tokenizer.dart';
export 'src/js_regexp.dart';
export 'src/locator_generators.dart';
export 'src/locator_parser.dart';
export 'src/locator_utils.dart';
export 'src/selector_parser.dart';
export 'src/string_utils.dart';
export 'src/url_match.dart';

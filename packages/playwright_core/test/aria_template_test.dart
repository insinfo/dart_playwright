import 'package:playwright_core/src/accessibility.dart';
import 'package:playwright_core/src/aria_template.dart';
import 'package:test/test.dart';

/// Unit coverage for the aria snapshot template parser and matcher.
///
/// No browser here on purpose: the parser and the matcher are pure functions
/// over a tree, and pinning them without launching three engines is both
/// faster and a sharper signal when one of them breaks.

/// Builds a node without the ceremony the real constructor needs.
AccessibilityNode node(
  String role, {
  String name = '',
  String? checked,
  bool? disabled,
  bool? expanded,
  String? invalid,
  int? level,
  String? pressed,
  bool? selected,
  Map<String, String> props = const {},
  List<AccessibilityNode> children = const [],
}) =>
    AccessibilityNode(
      role: role,
      name: name,
      checked: checked,
      disabled: disabled,
      expanded: expanded,
      invalid: invalid,
      level: level,
      pressed: pressed,
      selected: selected,
      props: props,
      children: children,
      ref: 'node',
    );

AccessibilityNode text(String value) => node('text', name: value);

AccessibilityNode fragment(List<AccessibilityNode> children) =>
    node('fragment', children: children);

void main() {
  group('parseAriaTemplate', () {
    test('a single entry targets that node, not a fragment around it', () {
      final template = parseAriaTemplate('- button "Salvar"');
      expect(template, isA<AriaTemplateRole>());
      expect((template as AriaTemplateRole).role, equals('button'));
      expect(template.name, equals('Salvar'));
    });

    test('several entries stay a fragment', () {
      final template = parseAriaTemplate('- button\n- link');
      expect((template as AriaTemplateRole).role, equals('fragment'));
      expect(template.children, hasLength(2));
    });

    test('states', () {
      final template = parseAriaTemplate(
              '- checkbox "A" [checked=mixed] [disabled] [level=2]')
          as AriaTemplateRole;
      expect(template.checked, equals('mixed'));
      expect(template.disabled, isTrue);
      expect(template.level, equals(2));
    });

    test('[disabled=false] means "must not be disabled", not "any"', () {
      final template =
          parseAriaTemplate('- button [disabled=false]') as AriaTemplateRole;
      expect(template.disabled, isFalse);
    });

    test('a name written as /regex/ becomes a RegExp', () {
      final template =
          parseAriaTemplate(r'- heading /Cap.tulo \d+/') as AriaTemplateRole;
      expect(template.name, isA<RegExp>());
      expect((template.name as RegExp).hasMatch('Capitulo 3'), isTrue);
    });

    test('a name in quotes has its whitespace normalized', () {
      final template =
          parseAriaTemplate('- button "  um   dois  "') as AriaTemplateRole;
      expect(template.name, equals('um dois'));
    });

    test('a backslash escapes the next character, as upstream does', () {
      final template =
          parseAriaTemplate(r'- button "diz \"oi\""') as AriaTemplateRole;
      expect(template.name, equals('diz "oi"'));
    });

    test('a scalar value becomes a text child', () {
      final template =
          parseAriaTemplate('- listitem: Primeiro') as AriaTemplateRole;
      expect(template.children, hasLength(1));
      expect((template.children!.single as AriaTemplateText).text.normalized,
          equals('Primeiro'));
    });

    test('a numeric value is read as text, not as a number', () {
      final template = parseAriaTemplate('- textbox: 555') as AriaTemplateRole;
      expect((template.children!.single as AriaTemplateText).text.raw,
          equals('555'));
    });

    test('properties and /children', () {
      final template = parseAriaTemplate('''
- link "Um":
  - /url: /um
  - /children: equal
  - text: Um
''') as AriaTemplateRole;
      expect(template.props!['url']!.normalized, equals('/um'));
      expect(template.containerMode, equals('equal'));
      expect(template.children, hasLength(1));
    });

    test('an empty template parses to an empty fragment', () {
      final template = parseAriaTemplate('') as AriaTemplateRole;
      expect(template.role, equals('fragment'));
      expect(template.children, isNull);
    });

    test('errors point at the offending character', () {
      expect(() => parseAriaTemplate('- button [checked=perhaps]'),
          throwsA(isA<AriaTemplateParseException>()));
      expect(
          () => parseAriaTemplate('- button [nope]'),
          throwsA(predicate((Object e) =>
              e.toString().contains('Unsupported attribute [nope]'))));
      expect(() => parseAriaTemplate('- button "unterminated'),
          throwsA(isA<AriaTemplateParseException>()));
      expect(
          () => parseAriaTemplate('nao e uma sequencia'),
          throwsA(predicate(
              (Object e) => e.toString().contains('must be a YAML sequence'))));
    });

    test('[active] is refused rather than ignored', () {
      // Ignoring it would let a template that asks for focus pass on any node.
      expect(
          () => parseAriaTemplate('- button [active]'),
          throwsA(predicate((Object e) =>
              e.toString().contains('[active] is not supported'))));
    });
  });

  group('ariaTemplateMatches', () {
    final tree = fragment([
      node('heading', name: 'Relatorio', level: 1),
      node('navigation', name: 'Menu', children: [
        node('link', name: 'Um', props: {'url': '/um'}),
        node('link', name: 'Dois', props: {'url': '/dois'}),
      ]),
      node('list', children: [
        node('listitem', children: [text('Primeiro')]),
        node('listitem', children: [text('Segundo')]),
      ]),
      node('checkbox', name: 'Aceito', checked: 'true'),
      node('button', name: 'Salvar', disabled: true),
    ]);

    bool matches(String template) =>
        ariaTemplateMatches(tree, parseAriaTemplate(template));

    test('finds a node anywhere in the tree', () {
      expect(matches('- link "Dois"'), isTrue);
      expect(matches('- link "Tres"'), isFalse);
    });

    test('a role with no name matches any name', () {
      expect(matches('- heading'), isTrue);
    });

    test('states have to agree', () {
      expect(matches('- checkbox "Aceito" [checked]'), isTrue);
      expect(matches('- checkbox "Aceito" [checked=mixed]'), isFalse);
      expect(matches('- button "Salvar" [disabled]'), isTrue);
      expect(matches('- button "Salvar" [disabled=false]'), isFalse);
      expect(matches('- heading "Relatorio" [level=1]'), isTrue);
      expect(matches('- heading "Relatorio" [level=2]'), isFalse);
    });

    test('a regex name', () {
      expect(matches('- link /^D/'), isTrue);
      expect(matches('- link /^Z/'), isFalse);
    });

    test('children are contained, not equal, by default', () {
      expect(matches('''
- navigation "Menu":
  - link "Dois"
'''), isTrue, reason: 'skipping "Um" is fine under contain');
    });

    test('order still matters under contain', () {
      expect(matches('''
- navigation "Menu":
  - link "Dois"
  - link "Um"
'''), isFalse, reason: 'contain keeps the document order');
    });

    test('/children: equal demands the exact list', () {
      expect(matches('''
- navigation "Menu":
  - /children: equal
  - link "Um"
  - link "Dois"
'''), isTrue);
      expect(matches('''
- navigation "Menu":
  - /children: equal
  - link "Um"
'''), isFalse);
    });

    test('a text child', () {
      expect(matches('- listitem: Primeiro'), isTrue);
      expect(matches('- listitem: Terceiro'), isFalse);
    });

    test('a property', () {
      expect(matches('''
- link "Um":
  - /url: /um
'''), isTrue);
      expect(matches('''
- link "Um":
  - /url: /outro
'''), isFalse);
    });

    test('several top-level entries match the fragment in order', () {
      expect(matches('- heading "Relatorio"\n- list'), isTrue);
      expect(matches('- list\n- heading "Relatorio"'), isFalse);
    });

    test('ariaTemplateMatchAll collects every match', () {
      final all = ariaTemplateMatchAll(tree, parseAriaTemplate('- link'));
      expect(all.map((node) => node.name), equals(['Um', 'Dois']));
    });

    test('a matched text node reports its parent', () {
      final all =
          ariaTemplateMatchAll(tree, parseAriaTemplate('- text: Primeiro'));
      expect(all.single.role, equals('listitem'));
    });
  });
}

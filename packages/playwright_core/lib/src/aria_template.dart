// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/isomorphic/ariaSnapshot.ts (`parseAriaSnapshot`,
// `KeyParser`, `textValue`) and the matching half of
// packages/injected/src/ariaSnapshot.ts (`matchesNode`, `listEqual`,
// `containsList`, `matchesNodeDeep`).

import 'package:yaml/yaml.dart';

import 'accessibility.dart';

/// A value written in a template, kept in both the form it was written and
/// the whitespace-normalized one.
///
/// Upstream carries both because it cannot tell a pattern from literal text:
/// `- text: /\d+/` might mean "a regex" or might mean those seven characters.
class AriaTextValue {
  final String raw;
  final String normalized;

  const AriaTextValue(this.raw, this.normalized);

  factory AriaTextValue.of(String value) =>
      AriaTextValue(value, _normalizeTemplateWhitespace(value));

  @override
  String toString() => raw;
}

/// Upstream's template-side whitespace normalization.
///
/// Deliberately not the same as the tree-side `normalizeWhiteSpace`: this one
/// collapses newlines too, so a template may break a long name across lines.
String _normalizeTemplateWhitespace(String text) => text
    .replaceAll(RegExp('[​­]'), '')
    .replaceAll(RegExp(r'[\r\n\s\t]+'), ' ')
    .trim();

/// A node of a parsed aria snapshot template.
sealed class AriaTemplateNode {
  const AriaTemplateNode();
}

/// `- text: something`.
class AriaTemplateText extends AriaTemplateNode {
  final AriaTextValue text;
  const AriaTemplateText(this.text);
}

/// `- role "name" [state]`, with optional children and properties.
class AriaTemplateRole extends AriaTemplateNode {
  final String role;

  /// The expected accessible name: a [String] for an exact match, a [RegExp]
  /// when the template wrote `/pattern/`, or null for "any name".
  Object? name;

  String? checked;
  bool? disabled;
  bool? expanded;
  String? invalid;
  int? level;
  String? pressed;
  bool? selected;

  List<AriaTemplateNode>? children;
  Map<String, AriaTextValue>? props;

  /// `contain` (the default), `equal` or `deep-equal`, from `- /children:`.
  String? containerMode;

  AriaTemplateRole(this.role, {this.name});
}

/// Thrown when a template cannot be parsed.
///
/// The message points at the offending character, the way upstream's
/// `prettyErrors` does, because "Expected ]" with no position is a riddle.
class AriaTemplateParseException implements Exception {
  final String message;
  const AriaTemplateParseException(this.message);

  @override
  String toString() => 'Invalid aria snapshot: $message';
}

/// Parses upstream's aria snapshot YAML into a template tree.
///
/// ```
/// - list "todo":
///   - listitem: Buy milk
///   - listitem /Buy .*/
/// ```
AriaTemplateNode parseAriaTemplate(String text) {
  final YamlNode doc;
  try {
    doc = loadYamlNode(text);
  } on YamlException catch (error) {
    throw AriaTemplateParseException(error.message);
  }

  final fragment = AriaTemplateRole('fragment');
  if (doc is YamlScalar && doc.value == null) {
    // An empty template matches an empty tree, as upstream's does.
    return fragment;
  }
  if (doc is! YamlList) {
    throw const AriaTemplateParseException(
        'Aria snapshot must be a YAML sequence, elements starting with "-"');
  }
  _convertSeq(fragment, doc);

  // `- button` should target the button, not its parent.
  final children = fragment.children;
  if (children != null &&
      children.length == 1 &&
      (fragment.containerMode == null || fragment.containerMode == 'contain')) {
    return children.first;
  }
  return fragment;
}

void _convertSeq(AriaTemplateRole container, YamlList seq) {
  for (final item in seq.nodes) {
    if (item is YamlScalar && item.value is String) {
      (container.children ??= []).add(_parseKey(item.value as String));
      continue;
    }
    if (item is YamlMap) {
      _convertMap(container, item);
      continue;
    }
    throw const AriaTemplateParseException(
        'Sequence items should be strings or maps');
  }
}

void _convertMap(AriaTemplateRole container, YamlMap map) {
  for (final entry in map.nodes.entries) {
    final keyNode = entry.key;
    if (keyNode is! YamlScalar || keyNode.value is! String) {
      throw const AriaTemplateParseException('Only string keys are supported');
    }
    final key = keyNode.value as String;
    final value = entry.value;
    final children = container.children ??= [];

    // - text: "text"
    if (key == 'text') {
      children.add(AriaTemplateText(AriaTextValue.of(
          _scalarString(value, 'Text value should be a string'))));
      continue;
    }

    // - /children: equal
    if (key == '/children') {
      final mode = _scalarString(value, 'Strict value should be a string');
      if (mode != 'contain' && mode != 'equal' && mode != 'deep-equal') {
        throw const AriaTemplateParseException(
            'Strict value should be "contain", "equal" or "deep-equal"');
      }
      container.containerMode = mode;
      continue;
    }

    // - /url: "about:blank"
    if (key.startsWith('/')) {
      (container.props ??= {})[key.substring(1)] = AriaTextValue.of(
          _scalarString(value, 'Property value should be a string'));
      continue;
    }

    final childNode = _parseKey(key);

    // - role "name": "text"
    if (value is YamlScalar) {
      final scalar = value.value;
      if (scalar is! String && scalar is! num && scalar is! bool) {
        throw const AriaTemplateParseException(
            'Node value should be a string or a sequence');
      }
      childNode.children = [
        AriaTemplateText(AriaTextValue.of(scalar.toString()))
      ];
      children.add(childNode);
      continue;
    }

    // - role "name":
    //   - child
    if (value is YamlList) {
      children.add(childNode);
      _convertSeq(childNode, value);
      continue;
    }

    throw const AriaTemplateParseException(
        'Map values should be strings or sequences');
  }
}

String _scalarString(YamlNode node, String message) {
  if (node is YamlScalar && node.value is String) return node.value as String;
  throw AriaTemplateParseException(message);
}

// --------------------------------------------------------------- key parser

/// Port of upstream's `KeyParser`: reads `role "name" [state=value]`.
class _KeyParser {
  final String _input;
  int _pos = 0;

  _KeyParser(this._input);

  String get _peek => _pos < _input.length ? _input[_pos] : '';

  String? _next() => _pos < _input.length ? _input[_pos++] : null;

  bool get _eof => _pos >= _input.length;

  bool get _isWhitespace => !_eof && RegExp(r'\s').hasMatch(_peek);

  void _skipWhitespace() {
    while (_isWhitespace) {
      _pos++;
    }
  }

  Never _throw(String message, [int? offset]) {
    final at = offset ?? _pos;
    throw AriaTemplateParseException('$message:\n\n$_input\n${' ' * at}^');
  }

  String _readIdentifier(String type) {
    if (_eof) _throw('Unexpected end of input when expecting $type');
    final start = _pos;
    while (!_eof && RegExp('[a-zA-Z]').hasMatch(_peek)) {
      _pos++;
    }
    return _input.substring(start, _pos);
  }

  String _readString() {
    final result = StringBuffer();
    var escaped = false;
    while (!_eof) {
      final ch = _next();
      if (escaped) {
        result.write(ch);
        escaped = false;
      } else if (ch == r'\') {
        escaped = true;
      } else if (ch == '"') {
        return result.toString();
      } else {
        result.write(ch);
      }
    }
    _throw('Unterminated string');
  }

  RegExp _readRegex() {
    final result = StringBuffer();
    var escaped = false;
    var insideClass = false;
    while (!_eof) {
      final ch = _next();
      if (escaped) {
        result.write(ch);
        escaped = false;
      } else if (ch == r'\') {
        escaped = true;
        result.write(ch);
      } else if (ch == '/' && !insideClass) {
        return RegExp(result.toString());
      } else if (ch == '[') {
        insideClass = true;
        result.write(ch);
      } else if (ch == ']' && insideClass) {
        result.write(ch);
        insideClass = false;
      } else {
        result.write(ch);
      }
    }
    _throw('Unterminated regex');
  }

  Object? _readStringOrRegex() {
    if (_peek == '"') {
      _next();
      return _normalizeTemplateWhitespace(_readString());
    }
    if (_peek == '/') {
      _next();
      return _readRegex();
    }
    return null;
  }

  void _readAttributes(AriaTemplateRole result) {
    var errorPos = _pos;
    while (true) {
      _skipWhitespace();
      if (_peek != '[') break;
      _next();
      _skipWhitespace();
      errorPos = _pos;
      final flagName = _readIdentifier('attribute');
      _skipWhitespace();
      var flagValue = '';
      if (_peek == '=') {
        _next();
        _skipWhitespace();
        errorPos = _pos;
        while (_peek != ']' && !_isWhitespace && !_eof) {
          flagValue += _next()!;
        }
      }
      _skipWhitespace();
      if (_peek != ']') _throw('Expected ]');
      _next();
      _applyAttribute(
          result, flagName, flagValue.isEmpty ? 'true' : flagValue, errorPos);
    }
  }

  AriaTemplateRole parse() {
    _skipWhitespace();
    final role = _readIdentifier('role');
    _skipWhitespace();
    final result = AriaTemplateRole(role, name: _readStringOrRegex() ?? '');
    _readAttributes(result);
    _skipWhitespace();
    if (!_eof) _throw('Unexpected input');
    return result;
  }

  void _applyAttribute(
      AriaTemplateRole node, String key, String value, int errorPos) {
    void assertOneOf(List<String> allowed, String message) {
      if (!allowed.contains(value)) _throw(message, errorPos);
    }

    switch (key) {
      case 'checked':
        assertOneOf(['true', 'false', 'mixed'],
            'Value of "checked" attribute must be a boolean or "mixed"');
        node.checked = value;
      case 'disabled':
        assertOneOf(['true', 'false'],
            'Value of "disabled" attribute must be a boolean');
        node.disabled = value == 'true';
      case 'expanded':
        assertOneOf(['true', 'false'],
            'Value of "expanded" attribute must be a boolean');
        node.expanded = value == 'true';
      case 'invalid':
        assertOneOf([
          'true',
          'false',
          'grammar',
          'spelling'
        ], 'Value of "invalid" attribute must be a boolean, "grammar" or "spelling"');
        node.invalid = value;
      case 'level':
        final level = int.tryParse(value);
        if (level == null) {
          _throw('Value of "level" attribute must be a number', errorPos);
        }
        node.level = level;
      case 'pressed':
        assertOneOf(['true', 'false', 'mixed'],
            'Value of "pressed" attribute must be a boolean or "mixed"');
        node.pressed = value;
      case 'selected':
        assertOneOf(['true', 'false'],
            'Value of "selected" attribute must be a boolean');
        node.selected = value == 'true';
      case 'active':
        // Upstream's `[active]` marks the focused node, which only its `ai`
        // mode computes. Rejecting it beats silently ignoring it: a template
        // that asks for focus would otherwise pass on any node.
        _throw(
            'Attribute [active] is not supported: this port does not compute '
            'the focused node',
            errorPos);
      default:
        _throw('Unsupported attribute [$key]', errorPos);
    }
  }
}

AriaTemplateRole _parseKey(String text) => _KeyParser(text).parse();

// ------------------------------------------------------------------ matching

/// Whether [root]'s tree contains a node matching [template].
///
/// The search is deep: a template naming a single role matches that role
/// anywhere in the tree, which is what makes `- button "Save"` a useful
/// assertion on a whole page.
bool ariaTemplateMatches(AccessibilityNode root, AriaTemplateNode template) =>
    _matchesDeep(root, template).isNotEmpty;

/// Every node matching [template], in pre-order.
List<AccessibilityNode> ariaTemplateMatchAll(
        AccessibilityNode root, AriaTemplateNode template) =>
    _matchesDeep(root, template, collectAll: true);

List<AccessibilityNode> _matchesDeep(
    AccessibilityNode root, AriaTemplateNode template,
    {bool collectAll = false}) {
  final results = <AccessibilityNode>[];
  bool visit(AccessibilityNode node, AccessibilityNode? parent) {
    if (_matchesNode(node, template, false)) {
      // A matched text node reports its parent: there is nothing to act on in
      // a run of text.
      final result = node.isText ? parent : node;
      if (result != null) results.add(result);
      if (!collectAll) return true;
    }
    if (node.isText) return false;
    for (final child in node.children) {
      if (visit(child, node)) return true;
    }
    return false;
  }

  visit(root, null);
  return results;
}

bool _matchesNode(
    AccessibilityNode node, AriaTemplateNode template, bool isDeepEqual) {
  if (template is AriaTemplateText) {
    return node.isText && _matchesTextValue(node.name, template.text);
  }
  template as AriaTemplateRole;
  if (node.isText) return false;

  if (template.role != 'fragment' && template.role != node.role) return false;
  if (template.checked != null && template.checked != node.checked) {
    return false;
  }
  if (template.disabled != null && template.disabled != node.disabled) {
    return false;
  }
  if (template.expanded != null && template.expanded != node.expanded) {
    return false;
  }
  if (template.invalid != null && template.invalid != node.invalid) {
    return false;
  }
  if (template.level != null && template.level != node.level) return false;
  if (template.pressed != null && template.pressed != node.pressed) {
    return false;
  }
  if (template.selected != null && template.selected != node.selected) {
    return false;
  }
  if (!_matchesStringOrRegex(node.name, template.name)) return false;

  final urlTemplate = template.props?['url'];
  if (urlTemplate != null &&
      !_matchesTextValue(node.props['url'] ?? '', urlTemplate)) {
    return false;
  }

  final children = node.children;
  final templateChildren = template.children ?? const <AriaTemplateNode>[];
  switch (template.containerMode) {
    case 'equal':
      return _listEqual(children, templateChildren, false);
    case 'deep-equal':
      return _listEqual(children, templateChildren, true);
    default:
      if (isDeepEqual) return _listEqual(children, templateChildren, true);
      return _containsList(children, templateChildren);
  }
}

bool _listEqual(List<AccessibilityNode> children,
    List<AriaTemplateNode> template, bool isDeepEqual) {
  if (template.length != children.length) return false;
  for (var i = 0; i < template.length; i++) {
    if (!_matchesNode(children[i], template[i], isDeepEqual)) return false;
  }
  return true;
}

bool _containsList(
    List<AccessibilityNode> children, List<AriaTemplateNode> template) {
  if (template.length > children.length) return false;
  var index = 0;
  for (final expected in template) {
    var found = false;
    while (index < children.length) {
      final child = children[index++];
      if (_matchesNode(child, expected, false)) {
        found = true;
        break;
      }
    }
    if (!found) return false;
  }
  return true;
}

bool _matchesStringOrRegex(String text, Object? template) {
  if (template == null) return true;
  if (template is String && template.isEmpty) return true;
  if (text.isEmpty) return false;
  if (template is String) return text == template;
  return (template as RegExp).hasMatch(text);
}

bool _matchesTextValue(String text, AriaTextValue? template) {
  if (template == null || template.normalized.isEmpty) return true;
  if (text.isEmpty) return false;
  if (text == template.normalized) return true;
  // Accept the pattern as a literal value too.
  if (text == template.raw) return true;
  final regex = _templateRegex(template.raw);
  return regex != null && regex.hasMatch(text);
}

RegExp? _templateRegex(String raw) {
  if (!raw.startsWith('/') || !raw.endsWith('/') || raw.length <= 1) {
    return null;
  }
  try {
    return RegExp(raw.substring(1, raw.length - 1));
  } on FormatException {
    return null;
  }
}

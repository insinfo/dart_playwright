import 'dart:io';

import 'us_keyboard_layout.dart';

/// Engine-specific keyboard event sink.
///
/// Each browser protocol (CDP, Juggler, WebKit Inspector) implements this to
/// translate a resolved [KeyDescription] into its own dispatch command.
abstract class RawKeyboard {
  Future<void> keyDown(
      Set<String> modifiers, KeyDescription description, bool autoRepeat);
  Future<void> keyUp(Set<String> modifiers, KeyDescription description);
  Future<void> sendText(String text);
}

const _kModifiers = {'Alt', 'Control', 'Meta', 'Shift'};

/// Stateful keyboard driver shared by all engines.
///
/// Tracks which modifiers/keys are held and resolves key strings against the
/// US layout, exactly like Playwright's server-side Keyboard class.
class Keyboard {
  final RawKeyboard _raw;
  final _pressedModifiers = <String>{};
  final _pressedKeys = <String>{};

  Keyboard(this._raw);

  Set<String> get modifiers => _pressedModifiers;

  String _resolveSmartModifier(String key) {
    if (key == 'ControlOrMeta') return Platform.isMacOS ? 'Meta' : 'Control';
    return key;
  }

  KeyDescription _describe(String str) {
    final keyString = _resolveSmartModifier(str);
    var description = usKeyboardLayout()[keyString];
    if (description == null) {
      throw ArgumentError('Unknown key: "$keyString"');
    }
    final shift = _pressedModifiers.contains('Shift');
    if (shift && description.shifted != null) {
      description = description.shifted!;
    }
    // With any non-shift modifier held, no text should be produced.
    if (_pressedModifiers.length > 1 ||
        (!_pressedModifiers.contains('Shift') &&
            _pressedModifiers.length == 1)) {
      return description.copyWith(text: '');
    }
    return description;
  }

  Future<void> down(String key) async {
    final description = _describe(key);
    final autoRepeat = _pressedKeys.contains(description.code);
    _pressedKeys.add(description.code);
    if (_kModifiers.contains(description.key)) {
      _pressedModifiers.add(description.key);
    }
    await _raw.keyDown(_pressedModifiers, description, autoRepeat);
  }

  Future<void> up(String key) async {
    final description = _describe(key);
    if (_kModifiers.contains(description.key)) {
      _pressedModifiers.remove(description.key);
    }
    _pressedKeys.remove(description.code);
    await _raw.keyUp(_pressedModifiers, description);
  }

  Future<void> insertText(String text) => _raw.sendText(text);

  /// Presses a key or chord (e.g. 'Enter', 'Control+A', 'Shift+ArrowLeft').
  Future<void> press(String key, {Duration? delay}) async {
    final tokens = _split(key);
    final last = tokens.removeLast();
    for (final token in tokens) {
      await down(token);
    }
    await down(last);
    if (delay != null) await Future.delayed(delay);
    await up(last);
    for (final token in tokens.reversed) {
      await up(token);
    }
  }

  /// Types [text] char by char, pressing layout keys and inserting the rest.
  Future<void> type(String text, {Duration? delay}) async {
    final layout = usKeyboardLayout();
    for (final char in text.split('')) {
      if (layout.containsKey(char)) {
        await press(char, delay: delay);
      } else {
        if (delay != null) await Future.delayed(delay);
        await insertText(char);
      }
    }
  }

  static List<String> _split(String keyString) {
    final keys = <String>[];
    var building = '';
    for (final char in keyString.split('')) {
      if (char == '+' && building.isNotEmpty) {
        keys.add(building);
        building = '';
      } else {
        building += char;
      }
    }
    keys.add(building);
    return keys;
  }
}

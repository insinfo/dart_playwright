import '../keyboard.dart';
import '../mac_editing_commands.dart';
import '../us_keyboard_layout.dart';
import 'wk_connection.dart';

/// WebKit modifier bitmask (Shift=1, Control=2, Alt=4, Meta=8).
///
/// Note this differs from the CDP mask used elsewhere.
int _wkModifiersMask(Set<String> modifiers) {
  var mask = 0;
  if (modifiers.contains('Shift')) mask |= 1;
  if (modifiers.contains('Control')) mask |= 2;
  if (modifiers.contains('Alt')) mask |= 4;
  if (modifiers.contains('Meta')) mask |= 8;
  return mask;
}

/// WebKit keyboard event sink.
///
/// Key events are a pageProxy-level command (`Input.dispatchKeyEvent`) while
/// text insertion is a page-target command (`Page.insertText`).
class WkRawKeyboard implements RawKeyboard {
  final WkPageProxySession session;

  WkRawKeyboard(this.session);

  @override
  Future<void> keyDown(
      Set<String> modifiers, KeyDescription d, bool autoRepeat) async {
    // On macOS, WebKit applies editing keys (Backspace, arrows, Enter...)
    // through NSResponder selectors; without them the key is not consumed
    // by the focused editor and can trigger app shortcuts instead.
    final commands = macEditingCommandsFor(modifiers, d.code);
    await session.send('Input.dispatchKeyEvent', {
      'type': 'keyDown',
      'modifiers': _wkModifiersMask(modifiers),
      'windowsVirtualKeyCode': d.keyCode,
      'code': d.code,
      'key': d.key,
      'text': d.text,
      'unmodifiedText': d.text,
      'autoRepeat': autoRepeat,
      if (commands.isNotEmpty) 'macCommands': commands,
      'isKeypad': d.location == keypadLocation,
    });
  }

  @override
  Future<void> keyUp(Set<String> modifiers, KeyDescription d) async {
    await session.send('Input.dispatchKeyEvent', {
      'type': 'keyUp',
      'modifiers': _wkModifiersMask(modifiers),
      'key': d.key,
      'windowsVirtualKeyCode': d.keyCode,
      'code': d.code,
      'isKeypad': d.location == keypadLocation,
    });
  }

  @override
  Future<void> sendText(String text) async {
    await session.sendToTarget('Page.insertText', {'text': text});
  }
}

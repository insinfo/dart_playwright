import '../keyboard.dart';
import '../us_keyboard_layout.dart';

/// CDP keyboard event sink (Input.dispatchKeyEvent / Input.insertText).
class CrRawKeyboard implements RawKeyboard {
  final dynamic session;

  CrRawKeyboard(this.session);

  @override
  Future<void> keyDown(
      Set<String> modifiers, KeyDescription d, bool autoRepeat) async {
    await session.send('Input.dispatchKeyEvent', {
      'type': d.text.isNotEmpty ? 'keyDown' : 'rawKeyDown',
      'modifiers': toModifiersMask(modifiers),
      'windowsVirtualKeyCode': d.keyCodeWithoutLocation,
      'code': d.code,
      'key': d.key,
      'text': d.text,
      'unmodifiedText': d.text,
      'autoRepeat': autoRepeat,
      'location': d.location,
      'isKeypad': d.location == keypadLocation,
    });
  }

  @override
  Future<void> keyUp(Set<String> modifiers, KeyDescription d) async {
    await session.send('Input.dispatchKeyEvent', {
      'type': 'keyUp',
      'modifiers': toModifiersMask(modifiers),
      'key': d.key,
      'windowsVirtualKeyCode': d.keyCodeWithoutLocation,
      'code': d.code,
      'location': d.location,
    });
  }

  @override
  Future<void> sendText(String text) async {
    await session.send('Input.insertText', {'text': text});
  }
}

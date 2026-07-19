import '../keyboard.dart';
import '../us_keyboard_layout.dart';

/// Juggler keyboard event sink (Page.dispatchKeyEvent / Page.insertText).
class FfRawKeyboard implements RawKeyboard {
  final dynamic session;

  FfRawKeyboard(this.session);

  @override
  Future<void> keyDown(
      Set<String> modifiers, KeyDescription d, bool autoRepeat) async {
    // Firefox figures out Enter by itself, so '\r' text is dropped.
    final text = d.text == '\r' ? '' : d.text;
    await session.send('Page.dispatchKeyEvent', {
      'type': 'keydown',
      'keyCode': d.keyCodeWithoutLocation,
      'code': d.code,
      'key': d.key,
      'repeat': autoRepeat,
      'location': d.location,
      'text': text,
    });
  }

  @override
  Future<void> keyUp(Set<String> modifiers, KeyDescription d) async {
    await session.send('Page.dispatchKeyEvent', {
      'type': 'keyup',
      'key': d.key,
      'keyCode': d.keyCodeWithoutLocation,
      'code': d.code,
      'location': d.location,
      'repeat': false,
    });
  }

  @override
  Future<void> sendText(String text) async {
    await session.send('Page.insertText', {'text': text});
  }
}

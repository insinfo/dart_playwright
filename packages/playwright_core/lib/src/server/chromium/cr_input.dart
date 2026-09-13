import '../mouse.dart';
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

/// Chromium mouse events, dispatched with `Input.dispatchMouseEvent`.
class CrRawMouse implements RawMouse {
  final dynamic session;

  CrRawMouse(this.session);

  @override
  Future<void> move(double x, double y,
      {required String button, required int buttons}) async {
    await session.send('Input.dispatchMouseEvent', {
      'type': 'mouseMoved',
      'x': x,
      'y': y,
      'button': button,
      'buttons': buttons,
    });
  }

  @override
  Future<void> down(double x, double y,
      {required String button,
      required int buttons,
      required int clickCount}) async {
    await session.send('Input.dispatchMouseEvent', {
      'type': 'mousePressed',
      'x': x,
      'y': y,
      'button': button,
      'buttons': buttons,
      'clickCount': clickCount,
    });
  }

  @override
  Future<void> up(double x, double y,
      {required String button,
      required int buttons,
      required int clickCount}) async {
    await session.send('Input.dispatchMouseEvent', {
      'type': 'mouseReleased',
      'x': x,
      'y': y,
      'button': button,
      'buttons': buttons,
      'clickCount': clickCount,
    });
  }

  @override
  Future<void> wheel(double x, double y, double deltaX, double deltaY) async {
    await session.send('Input.dispatchMouseEvent', {
      'type': 'mouseWheel',
      'x': x,
      'y': y,
      'deltaX': deltaX,
      'deltaY': deltaY,
      'modifiers': 0,
    });
  }
}

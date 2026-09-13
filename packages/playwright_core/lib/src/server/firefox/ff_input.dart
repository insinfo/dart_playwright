import '../mouse.dart';
import 'ff_connection.dart';
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

/// Firefox (Juggler) mouse events, dispatched with `Page.dispatchMouseEvent`.
///
/// Juggler numbers the buttons (0 left, 1 middle, 2 right) and wants integer
/// coordinates, unlike CDP.
class FfRawMouse implements RawMouse {
  final FfSession session;

  FfRawMouse(this.session);

  static const Map<String, int> _buttonCode = {
    'none': 0,
    'left': 0,
    'middle': 1,
    'right': 2,
  };

  @override
  Future<void> move(double x, double y,
      {required String button, required int buttons}) async {
    await session.send('Page.dispatchMouseEvent', {
      'type': 'mousemove',
      'button': _buttonCode[button] ?? 0,
      'buttons': buttons,
      'x': x.floor(),
      'y': y.floor(),
      'modifiers': 0,
    });
  }

  @override
  Future<void> down(double x, double y,
      {required String button,
      required int buttons,
      required int clickCount}) async {
    await session.send('Page.dispatchMouseEvent', {
      'type': 'mousedown',
      'button': _buttonCode[button] ?? 0,
      'buttons': buttons,
      'x': x.floor(),
      'y': y.floor(),
      'modifiers': 0,
      'clickCount': clickCount,
    });
  }

  @override
  Future<void> up(double x, double y,
      {required String button,
      required int buttons,
      required int clickCount}) async {
    await session.send('Page.dispatchMouseEvent', {
      'type': 'mouseup',
      'button': _buttonCode[button] ?? 0,
      'buttons': buttons,
      'x': x.floor(),
      'y': y.floor(),
      'modifiers': 0,
      'clickCount': clickCount,
    });
  }

  @override
  Future<void> wheel(double x, double y, double deltaX, double deltaY) async {
    await session.send('Page.dispatchWheelEvent', {
      'x': x.floor(),
      'y': y.floor(),
      'deltaX': deltaX,
      'deltaY': deltaY,
      'deltaZ': 0,
      'modifiers': 0,
    });
  }
}

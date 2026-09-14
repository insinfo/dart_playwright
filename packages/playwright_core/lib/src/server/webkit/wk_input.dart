import '../mouse.dart';
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

/// WebKit mouse events. `Input.dispatchMouseEvent` is a pageProxy-level
/// command, not a page-target one.
class WkRawMouse implements RawMouse {
  final WkPageProxySession session;

  WkRawMouse(this.session);

  @override
  Future<void> move(double x, double y,
      {required String button, required int buttons}) async {
    await session.send('Input.dispatchMouseEvent', {
      'type': 'move',
      'button': button,
      'buttons': buttons,
      'x': x,
      'y': y,
      'modifiers': 0,
    });
  }

  @override
  Future<void> down(double x, double y,
      {required String button,
      required int buttons,
      required int clickCount}) async {
    await session.send('Input.dispatchMouseEvent', {
      'type': 'down',
      'button': button,
      'buttons': buttons,
      'x': x,
      'y': y,
      'modifiers': 0,
      'clickCount': clickCount,
    });
  }

  @override
  Future<void> up(double x, double y,
      {required String button,
      required int buttons,
      required int clickCount}) async {
    await session.send('Input.dispatchMouseEvent', {
      'type': 'up',
      'button': button,
      'buttons': buttons,
      'x': x,
      'y': y,
      'modifiers': 0,
      'clickCount': clickCount,
    });
  }

  @override
  Future<void> wheel(double x, double y, double deltaX, double deltaY) async {
    await session.send('Input.dispatchWheelEvent', {
      'x': x,
      'y': y,
      'deltaX': deltaX,
      'deltaY': deltaY,
      'modifiers': 0,
    });
  }
}

/// WebKit taps on the pageProxy session, not the page target.
class WkRawTouchscreen implements RawTouchscreen {
  final WkPageProxySession session;

  WkRawTouchscreen(this.session);

  @override
  Future<void> tap(double x, double y) async {
    await session
        .send('Input.dispatchTapEvent', {'x': x, 'y': y, 'modifiers': 0});
  }
}

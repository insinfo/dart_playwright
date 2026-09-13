/// Engine-level mouse event dispatch.
///
/// Each engine implements this over its own protocol; [Mouse] adds the state
/// (position, pressed buttons) that the protocols expect the client to track.
abstract class RawMouse {
  Future<void> move(double x, double y,
      {required String button, required int buttons});

  Future<void> down(double x, double y,
      {required String button, required int buttons, required int clickCount});

  Future<void> up(double x, double y,
      {required String button, required int buttons, required int clickCount});

  Future<void> wheel(double x, double y, double deltaX, double deltaY);
}

/// The page's mouse, dispatching trusted events through the protocol.
///
/// Mirrors upstream's `input.Mouse`: the position and the set of pressed
/// buttons live here, because `mousemove` while dragging must still report the
/// button mask, and a protocol event carries no memory of its own.
class Mouse {
  final RawMouse _raw;

  double _x = 0;
  double _y = 0;
  final Set<String> _pressed = <String>{};

  Mouse(this._raw);

  static const Map<String, int> _buttonBits = {
    'left': 1,
    'right': 2,
    'middle': 4,
  };

  /// The last known x coordinate, in the top-level viewport.
  double get x => _x;

  /// The last known y coordinate, in the top-level viewport.
  double get y => _y;

  int get _buttons =>
      _pressed.fold(0, (mask, button) => mask | (_buttonBits[button] ?? 0));

  String get _heldButton => _pressed.isEmpty ? 'none' : _pressed.first;

  /// Moves the mouse to ([x], [y]), in [steps] intermediate moves.
  ///
  /// More than one step matters for drag-and-drop and for hover effects that
  /// only react to movement.
  Future<void> move(double x, double y, {int steps = 1}) async {
    final fromX = _x;
    final fromY = _y;
    final count = steps < 1 ? 1 : steps;
    for (var i = 1; i <= count; i++) {
      _x = fromX + (x - fromX) * i / count;
      _y = fromY + (y - fromY) * i / count;
      await _raw.move(_x, _y, button: _heldButton, buttons: _buttons);
    }
  }

  /// Presses a mouse button at the current position.
  Future<void> down({String button = 'left', int clickCount = 1}) async {
    _pressed.add(button);
    await _raw.down(_x, _y,
        button: button, buttons: _buttons, clickCount: clickCount);
  }

  /// Releases a mouse button at the current position.
  Future<void> up({String button = 'left', int clickCount = 1}) async {
    _pressed.remove(button);
    await _raw.up(_x, _y,
        button: button, buttons: _buttons, clickCount: clickCount);
  }

  /// Moves to ([x], [y]) and clicks.
  Future<void> click(double x, double y,
      {String button = 'left', int clickCount = 1, Duration? delay}) async {
    await move(x, y);
    for (var count = 1; count <= clickCount; count++) {
      await down(button: button, clickCount: count);
      if (delay != null) await Future.delayed(delay);
      await up(button: button, clickCount: count);
    }
  }

  /// Moves to ([x], [y]) and double-clicks.
  Future<void> dblclick(double x, double y,
          {String button = 'left', Duration? delay}) =>
      click(x, y, button: button, clickCount: 2, delay: delay);

  /// Scrolls by ([deltaX], [deltaY]) at the current position.
  Future<void> wheel(double deltaX, double deltaY) =>
      _raw.wheel(_x, _y, deltaX, deltaY);
}

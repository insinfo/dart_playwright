import 'dart:async';
import 'cr_connection.dart';

/// Keyboard, Mouse, and Touchscreen input for Chromium.
class CrInput {
  final CDPSession session;

  CrInput(this.session);

  /// Dispatch a mouse event.
  Future<void> dispatchMouseEvent(
      String type, double x, double y, String button, int modifiers, int clickCount) async {
    await session.send('Input.dispatchMouseEvent', {
      'type': type,
      'x': x,
      'y': y,
      'button': button,
      'modifiers': modifiers,
      'clickCount': clickCount,
    });
  }

  /// Dispatch a keyboard event.
  Future<void> dispatchKeyEvent(
      String type, int modifiers, String key, String text) async {
    await session.send('Input.dispatchKeyEvent', {
      'type': type,
      'modifiers': modifiers,
      'key': key,
      'text': text,
    });
  }

  /// Insert text.
  Future<void> insertText(String text) async {
    await session.send('Input.insertText', {
      'text': text,
    });
  }
}

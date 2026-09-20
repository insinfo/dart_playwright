// Part of the Dart port of the Playwright trace viewer UI.

/// The whole rendering layer, which is `document.createElement`.
///
/// Upstream's UI is React. This port has no framework: every panel is a class
/// that owns one element and rebuilds its own subtree when the state it reads
/// changes. That is enough because the trace viewer is almost entirely
/// presentational — the one place with real interaction is the action tree,
/// and upstream re-indexes that from scratch on every change anyway.
///
/// The helpers below exist so a port reads like the TSX it came from: [el]
/// takes the same attributes in the same order the JSX does, and [clsx]
/// joins classes exactly as upstream's does, including the argument order,
/// because the class attribute is observable and this port is checked against
/// the official viewer's DOM.
library;

import 'dart:js_interop';
// `has` and `callMethod`, for the one call below that reaches a method
// `package:web` does not declare because only Blink implements it.
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

/// `clsx(...)`: the truthy class names, in order, single-space joined.
///
/// Upstream drops falsy entries, so a conditional class never leaves a stray
/// space behind. Passing null here is the Dart spelling of that.
String clsx(List<String?> classes) =>
    classes.where((c) => c != null && c.isNotEmpty).join(' ');

/// Builds one element, the way the JSX that it came from reads.
///
/// [children] accepts nulls so a conditional child can be written inline,
/// which is what `{cond && <div/>}` does in the source this is ported from.
web.HTMLElement el(
  String tag, {
  String? className,
  String? text,
  String? html,
  Map<String, String?>? attrs,
  Map<String, String>? style,
  List<web.Node?>? children,
  void Function(web.HTMLElement element)? init,
}) {
  final element = web.document.createElement(tag) as web.HTMLElement;
  if (className != null && className.isNotEmpty) {
    element.className = className;
  }
  if (attrs != null) {
    attrs.forEach((name, value) {
      if (value != null) element.setAttribute(name, value);
    });
  }
  if (style != null) {
    style.forEach((name, value) => element.style.setProperty(name, value));
  }
  if (text != null) element.textContent = text;
  // Only ever fed strings this package built, or a trace's own error text
  // that has already been through the ANSI converter's escaping.
  if (html != null) element.innerHTML = html.toJS;
  if (children != null) {
    for (final child in children) {
      if (child != null) element.append(child);
    }
  }
  if (init != null) init(element);
  return element;
}

/// A `<div>`, the tag nearly every panel is made of.
web.HTMLElement div({
  String? className,
  String? text,
  String? html,
  Map<String, String?>? attrs,
  Map<String, String>? style,
  List<web.Node?>? children,
  void Function(web.HTMLElement element)? init,
}) =>
    el('div',
        className: className,
        text: text,
        html: html,
        attrs: attrs,
        style: style,
        children: children,
        init: init);

/// A `<span>`.
web.HTMLElement span({
  String? className,
  String? text,
  String? html,
  Map<String, String?>? attrs,
  Map<String, String>? style,
  List<web.Node?>? children,
}) =>
    el('span',
        className: className,
        text: text,
        html: html,
        attrs: attrs,
        style: style,
        children: children);

/// A bare text node, for the places upstream emits text beside an element
/// rather than inside one — `{name}:` in a call line, say.
web.Text textNode(String value) => web.Text(value);

/// One codicon, which is a `<span>` carrying two classes.
///
/// The icon font is VS Code's, vendored beside the stylesheet.
web.HTMLElement codicon(String name, {Map<String, String>? style}) =>
    span(className: 'codicon codicon-$name', style: style);

/// `ToolbarButton`: the one button shape the whole viewer uses.
///
/// Upstream composes the class as `clsx(className, 'toolbar-button', icon,
/// toggled && 'toggled')` — note that the bare icon name is a class of its
/// own, which some stylesheets key off.
web.HTMLButtonElement toolbarButton({
  String? icon,
  String? title,
  String? ariaLabel,
  String? className,
  String? testId,
  bool toggled = false,
  bool disabled = false,
  String? label,
  void Function()? onClick,
}) {
  final button = el('button',
      className:
          clsx([className, 'toolbar-button', icon, toggled ? 'toggled' : null]),
      attrs: {
        'title': title ?? '',
        'aria-label': ariaLabel ?? title ?? '',
        if (testId != null) 'data-testid': testId,
        if (disabled) 'disabled': '',
      },
      children: [
        // The icon only carries a right margin when there is a label beside
        // it; an icon-only button emits no style attribute at all. A button
        // with no icon at all — the console badge — emits no span either.
        if (icon != null)
          codicon(icon, style: label != null ? {'margin-right': '5px'} : null),
        if (label != null) textNode(label),
      ]) as web.HTMLButtonElement;
  if (onClick != null) {
    button.onClick.listen((_) => onClick());
  }
  // A toolbar button must never start a selection or reach a double-click
  // handler on the row behind it.
  button.addEventListener('mousedown', _swallow);
  button.addEventListener('dblclick', _swallow);
  return button;
}

final web.EventListener _swallow = ((web.Event event) {
  event.preventDefault();
  event.stopPropagation();
}).toJS;

/// `PlaceholderPanel`: what a tab shows instead of itself when it is empty.
///
/// It replaces the panel rather than sitting inside it, which is how "the
/// trace has no network calls" is told apart from "the filter hid them all".
web.HTMLElement placeholderPanel(String text) => div(
      className: 'fill',
      text: text,
      style: {
        'display': 'flex',
        'align-items': 'center',
        'justify-content': 'center',
        'font-size': '24px',
        'font-weight': 'bold',
        'opacity': '0.5',
      },
    );

/// Shows or hides an element.
///
/// `hidden` is typed `JSAny?` by `package:web`, because the HTML attribute
/// also takes the string `until-found`; this is the boolean half of it.
void setHidden(web.HTMLElement element, bool hidden) =>
    element.hidden = hidden.toJS;

/// Empties an element, which is how a panel redraws.
void removeChildren(web.Element element) {
  while (element.firstChild != null) {
    element.removeChild(element.firstChild!);
  }
}

/// `scrollIntoViewIfNeeded`, which only Blink has, with the standard fallback.
void scrollIntoViewIfNeeded(web.Element element) {
  final object = element as JSObject;
  if (object.has('scrollIntoViewIfNeeded')) {
    object.callMethod('scrollIntoViewIfNeeded'.toJS, false.toJS);
  } else {
    element.scrollIntoView();
  }
}

/// `upperBound`: the first index whose item compares greater than [value].
///
/// Upstream uses it to find the filmstrip frame covering a moment, always as
/// `upperBound(...) - 1`, which is the last frame at or before it.
int upperBound<T>(List<T> list, num value, num Function(num, T) compare) {
  var low = 0;
  var high = list.length;
  while (low < high) {
    final middle = (low + high) >> 1;
    if (compare(value, list[middle]) >= 0) {
      low = middle + 1;
    } else {
      high = middle;
    }
  }
  return low;
}

// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/injected/src/ariaSnapshot.ts and
// packages/isomorphic/ariaSnapshot.ts (`AriaNode`).

/// A node of the accessibility tree.
///
/// This mirrors upstream Playwright's `AriaNode`, the node type its aria
/// snapshots are built from. Upstream removed the old `page.accessibility`
/// API — the one backed by CDP's `Accessibility.getFullAXTree` on Chromium and
/// by per-engine protocol commands on Firefox and WebKit — and replaced it
/// with a tree computed in the page itself, from the DOM, by the injected
/// script. That is what this port does too, which is why the three engines
/// agree: nothing here is read out of a browser's own accessibility
/// implementation.
///
/// What follows from that, and is worth knowing before trusting a field:
///
/// * [role] is the **ARIA** role computed per the WAI-ARIA and HTML-AAM
///   specs, never a platform role. There is no `WebArea`, `StaticText` or
///   `InlineTextBox` here; those were Chromium's CDP vocabulary.
/// * The tree is not what a screen reader would announce. It is what the
///   specs say the markup means. A browser's own accessibility tree may
///   legitimately differ — that difference is exactly what upstream stopped
///   exposing, because it made the same page produce three different answers.
/// * There is no node for the document itself. The root is a synthetic
///   [AccessibilitySnapshot.root] with role `fragment`, standing for the
///   element the snapshot was taken from (the page body, by default).
class AccessibilityNode {
  /// The ARIA role, or `text` for a run of text, or `fragment` for the root.
  ///
  /// `text` is not an ARIA role: upstream models text as a plain string child
  /// of its parent node and renders it as `- text: ...` in the snapshot YAML.
  /// A Dart tree of one node type cannot hold a bare string, so text arrives
  /// as a node whose [role] is `text` and whose [name] is the text. Use
  /// [isText] rather than comparing the role by hand.
  final String role;

  /// The accessible name, whitespace-normalized.
  ///
  /// Computed by upstream's `getElementAccessibleName`, so `aria-labelledby`,
  /// `aria-label`, `<label for>`, a wrapping `<label>`, `title` and
  /// name-from-content all resolve in spec order. For a [isText] node this is
  /// the text itself.
  final String name;

  /// The current value of an `<input>` or `<textarea>`, except for
  /// `checkbox`, `radio` and `file` inputs, where it carries no meaning.
  ///
  /// `null` for every other node. Upstream models this as the node's single
  /// text child and has no separate field; this port keeps the field it has
  /// always had and fills it from the same source.
  final String? value;

  /// The accessible description: `aria-describedby`, `aria-description` or
  /// `title`, in that order.
  ///
  /// Upstream's aria node has no description — its snapshot YAML never
  /// renders one — but its `getElementAccessibleDescription` does exist, as
  /// the engine behind `getByRole(description:)`, and that is what fills this.
  final String? description;

  /// `'true'`, `'false'` or `'mixed'` on the roles where `aria-checked`
  /// applies (`checkbox`, `radio`, `switch`, `option`, `treeitem`,
  /// `menuitemcheckbox`, `menuitemradio`); `null` elsewhere.
  final String? checked;

  /// Whether the node is disabled, on the roles where `aria-disabled`
  /// applies; `null` elsewhere.
  final bool? disabled;

  /// Whether the node is expanded, on the roles where `aria-expanded`
  /// applies. `null` both when the role does not support it and when the role
  /// supports it but the markup says nothing — upstream draws the same
  /// distinction, because an absent `aria-expanded` is not `expanded=false`.
  final bool? expanded;

  /// `'false'`, `'true'`, `'grammar'` or `'spelling'` on the roles where
  /// `aria-invalid` applies; `null` elsewhere.
  final String? invalid;

  /// The heading/listitem/row/treeitem level, `0` when the role supports a
  /// level but none is set; `null` when the role has no level at all.
  final int? level;

  /// `'true'`, `'false'` or `'mixed'` for `button`, the only role where
  /// `aria-pressed` applies; `null` elsewhere.
  final String? pressed;

  /// Whether the node is selected, on the roles where `aria-selected`
  /// applies; `null` elsewhere.
  final bool? selected;

  /// Extra properties upstream renders as `- /name: value` under the node.
  ///
  /// Today that is `url` on a `link` with an `href` (data URLs truncated) and
  /// `placeholder` on a `textbox` whose placeholder is not already its name.
  final Map<String, String> props;

  final List<AccessibilityNode> children;

  /// A stable address for this node inside *this* snapshot: `node_0` for the
  /// root, then pre-order.
  ///
  /// It is an index into one snapshot, not a handle on an element: it does not
  /// survive a new snapshot of a changed page, and it is not upstream's
  /// `[ref=e12]`, which only its `ai` mode assigns and which this port does
  /// not compute.
  final String ref;

  AccessibilityNode({
    required this.role,
    required this.name,
    this.value,
    this.description,
    this.checked,
    this.disabled,
    this.expanded,
    this.invalid,
    this.level,
    this.pressed,
    this.selected,
    this.props = const {},
    this.children = const [],
    required this.ref,
  });

  /// Whether this node stands for a run of text rather than an element.
  bool get isText => role == 'text';

  @override
  String toString() {
    final buffer = StringBuffer(role);
    if (name.isNotEmpty) buffer.write(' "$name"');
    if (checked != null) buffer.write(' [checked=$checked]');
    if (disabled == true) buffer.write(' [disabled]');
    if (expanded != null) buffer.write(' [expanded=$expanded]');
    if (level != null && level != 0) buffer.write(' [level=$level]');
    if (pressed != null) buffer.write(' [pressed=$pressed]');
    if (selected != null) buffer.write(' [selected=$selected]');
    return buffer.toString();
  }
}

/// The accessibility tree of a page or of one element.
class AccessibilitySnapshot {
  /// The page title, for orientation; it is not part of the tree.
  final String title;

  /// The synthetic root, with role `fragment`. It stands for the element the
  /// snapshot was taken from and carries no name or state of its own.
  final AccessibilityNode root;

  AccessibilitySnapshot({
    required this.title,
    required this.root,
  });

  /// Every node of the tree in pre-order, root first.
  Iterable<AccessibilityNode> get allNodes sync* {
    Iterable<AccessibilityNode> walk(AccessibilityNode node) sync* {
      yield node;
      for (final child in node.children) {
        yield* walk(child);
      }
    }

    yield* walk(root);
  }

  @override
  String toString() {
    final buffer = StringBuffer();
    void walk(AccessibilityNode node, int depth) {
      buffer.writeln('${'  ' * depth}- $node');
      for (final child in node.children) {
        walk(child, depth + 1);
      }
    }

    walk(root, 0);
    return buffer.toString();
  }
}

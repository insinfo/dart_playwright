// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/trace-viewer/src/ui/actionList.tsx

/// The list of actions, which is the spine of the viewer.
///
/// It is a tree, not a list: `tracing.group` nests actions under a parent,
/// and an internal call is nested under the public one that made it. The
/// nesting comes from the model's `buildActionTree`, and the groups the
/// recorder now writes are filtered by the model's `filteredActions`.
library;

import 'package:playwright_trace_viewer/playwright_trace_viewer.dart';
import 'package:web/web.dart' as web;

import 'components.dart';
import 'dom.dart';
import 'format.dart';

/// A tree node that carries the action it stands for.
class ActionNode extends TreeItem {
  final ActionEntry action;

  ActionNode(this.action) : super(action.callId);
}

/// `ActionList`: the filter button's "Show all", then the tree.
class ActionList {
  final web.HTMLElement element;
  late final TreeView tree;

  /// The trace's language, which decides how a selector is spelled.
  String sdkLanguage;

  /// Counts the console errors and warnings of an action, for the badges.
  ({int errors, int warnings}) Function(ActionEntry action) stats;

  void Function(ActionEntry action)? onSelected;
  void Function(ActionEntry? action)? onHighlighted;
  void Function(ActionEntry action)? onAccepted;
  void Function()? onRevealConsole;
  void Function(String callId)? onRevealAttachment;
  void Function()? onShowAll;

  /// The text typed in the filter box, which also decides how deep the tree
  /// opens itself.
  String filterText = '';

  /// Set while the timeline has a window selected, which adds the "Show all"
  /// button and hides every action outside the window.
  ({double minimum, double maximum})? selectedTime;

  late final web.HTMLButtonElement _showAll;

  ActionList({required this.sdkLanguage, required this.stats})
      : element = div(className: 'vbox action-list-container') {
    _showAll = toolbarButton(
      icon: 'triangle-left',
      className: 'action-list-show-all',
      label: 'Show all',
      onClick: () => onShowAll?.call(),
    );
    tree = TreeView(
      name: 'actions',
      render: (item) => _renderAction((item as ActionNode).action),
      title: (item) => _plainTitle((item as ActionNode).action),
      isError: (item) =>
          (item as ActionNode).action.error?.message.isNotEmpty ?? false,
      isVisible: _isVisible,
    );
    tree.onSelected = (item) => onSelected?.call((item as ActionNode).action);
    tree.onHighlighted =
        (item) => onHighlighted?.call((item as ActionNode?)?.action);
    tree.onAccepted = (item) => onAccepted?.call((item as ActionNode).action);
    element.append(_showAll);
    element.append(tree.element);
  }

  /// Rebuilds the tree from [actions], which are already group-filtered.
  void update(List<ActionEntry> actions, {ActionEntry? selectedAction}) {
    setHidden(_showAll, selectedTime == null);
    // Upstream opens the tree five levels deep while a filter is typed and
    // leaves it shut otherwise, so a plain trace starts collapsed.
    tree.autoExpandDepth = filterText.trim().isEmpty ? 0 : 5;

    final built = buildActionTree(actions);
    final nodes = <String, ActionNode>{};
    ActionNode convert(ActionTreeItem item) {
      final node = ActionNode(item.action);
      nodes[item.id] = node;
      for (final child in item.children) {
        final childNode = convert(child);
        childNode.parent = node;
        node.children.add(childNode);
      }
      return node;
    }

    final root = ActionNode(built.rootItem.action);
    for (final child in built.rootItem.children) {
      final node = convert(child);
      node.parent = root;
      root.children.add(node);
    }
    tree.update(root,
        selectedItem:
            selectedAction == null ? null : nodes[selectedAction.callId]);
  }

  /// Scrolls the selection back into view, which "Show all" asks for.
  void revealSelected() => tree.revealSelected();

  TreeVisibility _isVisible(TreeItem item) {
    final action = (item as ActionNode).action;
    final window = selectedTime;
    if (window != null &&
        !(action.startTime <= window.maximum &&
            action.endTime >= window.minimum)) {
      return TreeVisibility.hidden;
    }
    final needle = filterText.trim().toLowerCase();
    if (needle.isEmpty) return TreeVisibility.visible;
    final title = _plainTitle(action).toLowerCase();
    // A row that does not match itself is still drawn when a descendant
    // does, so a match is never hidden inside a group that missed.
    return title.contains(needle)
        ? TreeVisibility.visible
        : TreeVisibility.ifNeeded;
  }

  CallMetainfo _metainfo(ActionEntry action) => CallMetainfo(
        className: action.className,
        method: action.method,
        params: action.params,
        title: action.title,
        subtitle: action.subtitle,
      );

  String _plainTitle(ActionEntry action) {
    final title =
        renderTitleForCall(_metainfo(action), sdkLanguage: sdkLanguage);
    final subtitle =
        renderSubtitleForCall(_metainfo(action), sdkLanguage: sdkLanguage);
    return subtitle != null ? '$title $subtitle' : title;
  }

  /// One row: the title with its params picked out, then the badges.
  List<web.Node> _renderAction(ActionEntry action) {
    final counts = stats(action);
    final subtitle =
        renderSubtitleForCall(_metainfo(action), sdkLanguage: sdkLanguage);
    final showBadges = counts.errors > 0 || counts.warnings > 0;
    final hasAttachments = action.attachments?.isNotEmpty ?? false;
    final badgeLabel = [
      pluralize(counts.errors, 'error'),
      pluralize(counts.warnings, 'warning'),
    ].where((s) => s.isNotEmpty).join(', ');

    final row = div(className: 'hbox', children: [
      span(
        className: 'action-title-method',
        attrs: {'title': _titleOnly(action)},
        children: _titleChunks(action),
      ),
      div(className: 'spacer'),
      if (hasAttachments)
        toolbarButton(
          icon: 'attach',
          className: '',
          title: 'Open Attachment',
          onClick: () => onRevealAttachment?.call(action.callId),
        ),
      div(className: 'action-duration', text: _duration(action)),
      if (showBadges)
        toolbarButton(
          icon: null,
          className: 'action-icons',
          title: 'Reveal console',
          ariaLabel: 'Reveal console, $badgeLabel',
          onClick: () => onRevealConsole?.call(),
        )
          ..append(span(className: 'action-icon', children: [
            codicon('error'),
            span(className: 'action-icon-value', text: '${counts.errors}'),
          ]))
          ..append(span(className: 'action-icon', children: [
            codicon('warning'),
            span(className: 'action-icon-value', text: '${counts.warnings}'),
          ])),
    ]);

    return [
      div(className: 'action-title vbox', children: [
        row,
        if (subtitle != null)
          div(
              className: 'action-title-subtitle',
              text: subtitle,
              attrs: {'title': subtitle}),
      ])
    ];
  }

  /// The title template, with each `{param}` in its own span.
  ///
  /// Upstream renders the placeholders separately so they can be coloured;
  /// the one at the very start is left as plain text, which is how a title
  /// that is only a parameter reads as the action's name.
  List<web.Node> _titleChunks(ActionEntry action) {
    final template = (action.title ??
            getMetainfo(action.className, action.method)?.title ??
            action.method)
        .replaceAll('\n', ' ');
    final nodes = <web.Node>[];
    var last = 0;
    for (final match in _placeholder.allMatches(template)) {
      if (match.start > last) {
        nodes.add(textNode(template.substring(last, match.start)));
      }
      final value = formatProtocolParam(action.params, match[1]!,
              sdkLanguage: sdkLanguage) ??
          match[0]!;
      if (match.start == 0) {
        nodes.add(textNode(value));
      } else {
        nodes.add(span(className: 'action-title-param', text: value));
      }
      last = match.end;
    }
    if (last < template.length) {
      nodes.add(textNode(template.substring(last)));
    }
    return nodes;
  }

  String _titleOnly(ActionEntry action) =>
      renderTitleForCall(_metainfo(action), sdkLanguage: sdkLanguage);

  String _duration(ActionEntry action) {
    if (action.endTime != 0) {
      return msToString(action.endTime - action.startTime);
    }
    if (action.error != null) return 'Timed out';
    return '-';
  }
}

final RegExp _placeholder = RegExp(r'\{([^}]+)\}');

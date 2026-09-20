// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/web/src/components/{splitView,tabbedPane,
// listView,treeView,gridView,expandable}.tsx

/// The shared widgets the trace viewer is assembled from.
///
/// This is upstream's `packages/web/src/components`, which the viewer and the
/// HTML reporter both build on. Every class name and ARIA attribute here is
/// reproduced as upstream emits it, because they are what the stylesheets key
/// off and what this port's oracle run compares against the official viewer.
///
/// The one structural difference is that a widget is a Dart object that owns
/// its element and redraws it on demand, where upstream re-renders a function
/// component. Nothing about the resulting DOM changes.
library;

import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'dom.dart';

/// `SplitView`: a main area, a sidebar and a draggable resizer.
///
/// The DOM order is always main, sidebar, resizer; "sidebar first" is purely
/// visual, through `flex-direction: *-reverse`, exactly as upstream has it.
class SplitView {
  final String orientation;
  final bool sidebarIsFirst;
  final web.HTMLElement element;
  final web.HTMLElement main;
  final web.HTMLElement sidebar;

  late final web.HTMLElement _resizer;
  double _size;
  bool _sidebarHidden;
  final String? _settingName;

  SplitView({
    required this.orientation,
    this.sidebarIsFirst = false,
    double sidebarSize = 250,
    bool sidebarHidden = false,
    String? settingName,
  })  : _size = sidebarSize < _minSidebarSize ? _minSidebarSize : sidebarSize,
        _sidebarHidden = sidebarHidden,
        _settingName = settingName,
        main = div(className: 'split-view-main'),
        sidebar = div(className: 'split-view-sidebar'),
        element = div(
            className: clsx([
          'split-view',
          orientation,
          sidebarIsFirst ? 'sidebar-first' : null
        ])) {
    final stored = _settingName == null
        ? null
        : _readStoredSize('$_settingName.$orientation:size');
    if (stored != null) _size = stored;
    _resizer = div(className: 'split-view-resizer');
    element.append(main);
    element.append(sidebar);
    element.append(_resizer);
    _installDrag();
    _layout();
  }

  bool get isVertical => orientation == 'vertical';

  set sidebarHidden(bool value) {
    if (_sidebarHidden == value) return;
    _sidebarHidden = value;
    _layout();
  }

  void _layout() {
    setHidden(sidebar, _sidebarHidden);
    setHidden(_resizer, _sidebarHidden);
    sidebar.style.flexBasis = '${_size}px';
    // Upstream places the resizer four pixels into the sidebar so the handle
    // straddles the border, and gives it a fixed thickness of eight.
    final offset = '${_size - 4}px';
    _resizer.removeAttribute('style');
    if (isVertical) {
      if (sidebarIsFirst) {
        _resizer.style.top = offset;
      } else {
        _resizer.style.bottom = offset;
      }
      _resizer.style.height = '8px';
    } else {
      if (sidebarIsFirst) {
        _resizer.style.left = offset;
      } else {
        _resizer.style.right = offset;
      }
      _resizer.style.width = '8px';
    }
  }

  void _installDrag() {
    double? startOffset;
    double startSize = 0;

    void move(web.MouseEvent event) {
      if (startOffset == null) return;
      if (event.buttons == 0) {
        startOffset = null;
        web.document.body!.style.userSelect = 'inherit';
        return;
      }
      final offset =
          isVertical ? event.clientY.toDouble() : event.clientX.toDouble();
      final delta = offset - startOffset!;
      var next = sidebarIsFirst ? startSize + delta : startSize - delta;
      final rect = element.getBoundingClientRect();
      final total = isVertical ? rect.height : rect.width;
      if (next < _minSidebarSize) next = _minSidebarSize;
      if (next > total - _minSidebarSize) next = total - _minSidebarSize;
      _size = next;
      if (_settingName != null) {
        _writeStoredSize('$_settingName.$orientation:size', next);
      }
      _layout();
    }

    _resizer.addEventListener(
        'mousedown',
        ((web.MouseEvent event) {
          startOffset =
              isVertical ? event.clientY.toDouble() : event.clientX.toDouble();
          startSize = _size;
          web.document.body!.style.userSelect = 'none';
        }).toJS);
    web.document.addEventListener(
        'mousemove',
        ((web.Event e) {
          move(e as web.MouseEvent);
        }).toJS);
    web.document.addEventListener(
        'mouseup',
        ((web.Event _) {
          startOffset = null;
          web.document.body!.style.userSelect = 'inherit';
        }).toJS);
  }
}

const double _minSidebarSize = 50;

double? _readStoredSize(String key) {
  final raw = web.window.localStorage.getItem(key);
  if (raw == null) return null;
  final value = double.tryParse(raw);
  if (value == null) return null;
  return value / web.window.devicePixelRatio;
}

void _writeStoredSize(String key, double size) => web.window.localStorage
    .setItem(key, '${size * web.window.devicePixelRatio}');

/// One tab of a [TabbedPane].
class PaneTab {
  final String id;
  final String title;

  /// The body, built once and kept.
  ///
  /// Upstream distinguishes a tab declared with `component` — always in the
  /// DOM, toggled with `display` — from one declared with `render`, which
  /// only exists while selected. This port keeps every body mounted, which
  /// is the `component` shape, because a panel here is cheap to leave in
  /// place and the difference is not observable beyond `display`.
  final web.HTMLElement body;

  /// The plain counter beside the title, e.g. the number of network calls.
  int? count;

  /// The red counter, e.g. the number of errors.
  int? errorCount;

  PaneTab({
    required this.id,
    required this.title,
    required this.body,
    this.count,
    this.errorCount,
  });
}

/// `TabbedPane`: a toolbar of tabs over one body at a time.
class TabbedPane {
  final web.HTMLElement element;
  final List<PaneTab> tabs;
  final String? dataTestId;

  /// Called after the selection changed, so the owner can persist it.
  void Function(String id)? onSelected;

  late final web.HTMLElement _tabList;
  late final web.HTMLElement _toolbar;
  final web.HTMLElement _leftToolbar = div(style: {
    'flex': 'none',
    'display': 'flex',
    'margin': '0 4px',
    'align-items': 'center',
  });
  final web.HTMLElement _rightToolbar = div(style: {
    'flex': 'none',
    'display': 'flex',
    'align-items': 'center',
  });
  String _selected;
  static int _uid = 0;
  final String _id = 'tabbed-pane-${_uid++}';

  TabbedPane({
    required this.tabs,
    String? selectedTab,
    this.dataTestId,
  })  : _selected = selectedTab ?? tabs.first.id,
        element = div(
            className: 'tabbed-pane',
            attrs: {if (dataTestId != null) 'data-testid': dataTestId}) {
    _tabList = div(attrs: {
      'role': 'tablist'
    }, style: {
      'flex': 'auto',
      'display': 'flex',
      'height': '100%',
      'overflow': 'hidden',
    });
    _toolbar = div(
        className: 'toolbar',
        children: [_leftToolbar, _tabList, _rightToolbar]);
    final vbox = div(className: 'vbox', children: [_toolbar]);
    for (final tab in tabs) {
      tab.body.className = 'tab-content tab-${tab.id}';
      tab.body.setAttribute('id', '$_id-${tab.id}');
      tab.body.setAttribute('role', 'tabpanel');
      tab.body.setAttribute('aria-label', tab.title);
      vbox.append(tab.body);
    }
    element.append(vbox);
    _renderTabs();
  }

  /// The slot before the tabs, where a panel puts its own controls.
  web.HTMLElement get leftToolbar => _leftToolbar;

  /// The slot after the tabs.
  web.HTMLElement get rightToolbar => _rightToolbar;

  String get selectedTab => _selected;

  set selectedTab(String id) {
    if (_selected == id) return;
    _selected = id;
    _renderTabs();
  }

  PaneTab? tabById(String id) {
    for (final tab in tabs) {
      if (tab.id == id) return tab;
    }
    return null;
  }

  /// Redraws the tab strip, which is what a changed counter needs.
  void updateCounters() => _renderTabs();

  void _renderTabs() {
    removeChildren(_tabList);
    for (final tab in tabs) {
      final selected = tab.id == _selected;
      final button = el('button',
          className: clsx(['tabbed-pane-tab', selected ? 'selected' : null]),
          attrs: {
            'role': 'tab',
            'title': tab.title,
            'aria-controls': '$_id-${tab.id}',
            'aria-selected': '$selected',
          },
          children: [
            div(className: 'tabbed-pane-tab-label', text: tab.title),
            if (tab.count != null && tab.count != 0)
              div(className: 'tabbed-pane-tab-counter', text: '${tab.count}'),
            if (tab.errorCount != null && tab.errorCount != 0)
              div(
                  className: 'tabbed-pane-tab-counter error',
                  text: '${tab.errorCount}'),
          ]);
      button.onClick.listen((_) {
        selectedTab = tab.id;
        onSelected?.call(tab.id);
      });
      _tabList.append(button);
      // Upstream toggles the body with `display: inherit` / `none` rather
      // than unmounting it.
      tab.body.style.display = selected ? 'inherit' : 'none';
    }
  }
}

/// `ListView`: the flat list behind the console, the log and the grid.
class ListView<T> {
  final String name;
  final String? ariaLabel;
  final bool notSelectable;
  final String? noItemsMessage;

  /// Builds a row's contents, which are appended inside `.list-view-entry`.
  final List<web.Node> Function(T item, int index) render;

  final bool Function(T item)? isError;
  final bool Function(T item)? isWarning;
  final bool Function(T item)? isInfo;
  final bool Function(T item)? isSelected;

  void Function(T item, int index)? onSelected;
  void Function(T? item)? onHighlighted;
  void Function(T item, int index)? onAccepted;

  final web.HTMLElement element;
  late final web.HTMLElement _content;
  List<T> _items = const [];

  ListView({
    required this.name,
    required this.render,
    this.ariaLabel,
    this.notSelectable = false,
    this.noItemsMessage,
    this.isError,
    this.isWarning,
    this.isInfo,
    this.isSelected,
  }) : element = div(
            className: 'list-view vbox $name-list-view',
            attrs: {if (ariaLabel != null) 'aria-label': ariaLabel}) {
    _content = div(
        className: clsx(
            ['list-view-content', notSelectable ? 'not-selectable' : null]),
        attrs: {'tabindex': '0'});
    element.append(_content);
  }

  List<T> get items => _items;

  void update(List<T> items) {
    _items = items;
    // The role only exists once there is something to put in it, which is
    // how upstream keeps an empty list out of the accessibility tree.
    if (items.isEmpty) {
      element.removeAttribute('role');
    } else {
      element.setAttribute('role', 'listbox');
    }
    removeChildren(_content);
    if (items.isEmpty && noItemsMessage != null) {
      _content.append(div(className: 'list-view-empty', text: noItemsMessage));
      return;
    }
    for (var index = 0; index < items.length; index++) {
      final item = items[index];
      final selected = isSelected?.call(item) ?? false;
      final entry = div(
          className: clsx([
            'list-view-entry',
            selected ? 'selected' : null,
            (isError?.call(item) ?? false) ? 'error' : null,
            (isWarning?.call(item) ?? false) ? 'warning' : null,
            (isInfo?.call(item) ?? false) ? 'info' : null,
          ]),
          attrs: {'role': 'option', 'aria-selected': '$selected'},
          children: render(item, index));
      final capturedIndex = index;
      entry.onClick.listen((_) => onSelected?.call(item, capturedIndex));
      entry.ondblclick = ((web.Event _) {
        onAccepted?.call(item, capturedIndex);
      }).toJS;
      if (!notSelectable) {
        entry.addEventListener(
            'mouseenter',
            ((web.Event _) {
              entry.classList.add('highlighted');
              onHighlighted?.call(item);
            }).toJS);
        entry.addEventListener(
            'mouseleave',
            ((web.Event _) {
              entry.classList.remove('highlighted');
              onHighlighted?.call(null);
            }).toJS);
      }
      _content.append(entry);
    }
  }
}

/// One node of a [TreeView].
class TreeItem {
  final String id;
  final List<TreeItem> children = <TreeItem>[];
  TreeItem? parent;

  TreeItem(this.id);
}

/// How visible an item is: shown, hidden, or shown only if a child is shown.
enum TreeVisibility { visible, hidden, ifNeeded }

/// `TreeView`: the action tree.
///
/// The index this builds — which rows are visible, at what depth, and in what
/// order — is upstream's `indexTree`, including its two quirks: an item is
/// collapsed unless something says otherwise, and auto-expansion stops once
/// twenty-five rows are already laid out.
class TreeView {
  final String name;
  final String? dataTestId;

  /// Builds a row's contents, appended inside `.tree-view-entry`.
  final List<web.Node> Function(TreeItem item) render;

  final String? Function(TreeItem item)? title;
  final bool Function(TreeItem item)? isError;
  final TreeVisibility Function(TreeItem item)? isVisible;

  void Function(TreeItem item)? onSelected;
  void Function(TreeItem? item)? onHighlighted;
  void Function(TreeItem item)? onAccepted;

  /// How deep to open the tree with no stored state, which upstream raises
  /// from zero to five while a filter is typed.
  int autoExpandDepth = 0;

  final web.HTMLElement element;
  late final web.HTMLElement _content;

  TreeItem? _root;
  TreeItem? _selectedItem;
  final Map<String, bool> expandedItems = <String, bool>{};
  final Map<String, _TreeRow> _rows = <String, _TreeRow>{};
  final List<TreeItem> _flattened = <TreeItem>[];

  TreeView({
    required this.name,
    required this.render,
    this.dataTestId,
    this.title,
    this.isError,
    this.isVisible,
  }) : element = div(
            className: 'tree-view vbox $name-tree-view',
            attrs: {'data-testid': dataTestId ?? '$name-tree'}) {
    _content = div(className: 'tree-view-content', attrs: {'tabindex': '0'});
    element.append(_content);
    _installKeyboard();
  }

  TreeItem? get selectedItem => _selectedItem;

  void update(TreeItem root, {TreeItem? selectedItem}) {
    _root = root;
    _selectedItem = selectedItem;
    _index();
    _draw();
  }

  /// Opens or closes one item, as a click on its chevron does.
  void toggleExpanded(TreeItem item) {
    final row = _rows[item.id];
    if (row?.expanded == true) {
      // Collapsing a node the selection lives under moves the selection to
      // the node itself, so it does not vanish with its row.
      var ancestor = _selectedItem?.parent;
      while (ancestor != null) {
        if (identical(ancestor, item)) {
          onSelected?.call(item);
          break;
        }
        ancestor = ancestor.parent;
      }
      expandedItems[item.id] = false;
    } else {
      expandedItems[item.id] = true;
    }
    _index();
    _draw();
  }

  /// Opens or closes an item and everything under it, as alt-click does.
  void toggleSubtree(TreeItem item) {
    final expanded = _rows[item.id]?.expanded ?? false;
    final stack = <TreeItem>[item];
    while (stack.isNotEmpty) {
      final current = stack.removeLast();
      expandedItems[current.id] = !expanded;
      stack.addAll(current.children);
    }
    _index();
    _draw();
  }

  /// Scrolls the selected row into view, which "Show all" asks for.
  void revealSelected() {
    final selected = _content.querySelector('[aria-selected="true"]');
    if (selected != null) scrollIntoViewIfNeeded(selected);
  }

  final Map<String, TreeVisibility> _visibilityCache =
      <String, TreeVisibility>{};

  bool _effectivelyVisible(TreeItem item) {
    final cached = _visibilityCache[item.id];
    if (cached != null) return cached == TreeVisibility.visible;
    final value = isVisible?.call(item) ?? TreeVisibility.visible;
    final result = value == TreeVisibility.ifNeeded
        ? (item.children.any(_effectivelyVisible)
            ? TreeVisibility.visible
            : TreeVisibility.hidden)
        : value;
    _visibilityCache[item.id] = result;
    return result == TreeVisibility.visible;
  }

  void _index() {
    _rows.clear();
    _flattened.clear();
    _visibilityCache.clear();
    final root = _root;
    if (root == null) return;
    if (!_effectivelyVisible(root)) return;

    // The ancestors of the selection are opened whether or not they were
    // stored open, so a selected row is never hidden inside a closed group.
    final temporarilyExpanded = <String>{};
    var ancestor = _selectedItem?.parent;
    while (ancestor != null) {
      temporarilyExpanded.add(ancestor.id);
      ancestor = ancestor.parent;
    }

    TreeItem? last;
    void appendChildren(TreeItem parent, int depth) {
      for (final item in parent.children) {
        if (!_effectivelyVisible(item)) continue;
        final stored = expandedItems[item.id];
        final expandState =
            temporarilyExpanded.contains(item.id) ? true : stored;
        final autoExpand = autoExpandDepth > depth &&
            _rows.length < 25 &&
            expandState != false;
        final bool? expanded =
            item.children.isEmpty ? null : (expandState ?? autoExpand);
        _rows[item.id] = _TreeRow(
          depth: depth,
          expanded: expanded,
          parent: identical(parent, root) ? null : parent,
          previous: last,
        );
        if (last != null) _rows[last!.id]!.next = item;
        last = item;
        _flattened.add(item);
        if (expanded == true) appendChildren(item, depth + 1);
      }
    }

    appendChildren(root, 0);
  }

  void _draw() {
    removeChildren(_content);
    if (_rows.isEmpty) {
      _content.removeAttribute('role');
    } else {
      _content.setAttribute('role', 'tree');
    }
    final root = _root;
    if (root == null) return;
    for (final item in _flattened) {
      final row = _rows[item.id]!;
      // A row and its children are siblings in the DOM only at the top; a
      // group's children live inside its own [role=group], which is what
      // upstream's aria-controls points at.
      final parentElement =
          row.parent == null ? _content : (_groups[row.parent!.id] ?? _content);
      parentElement.append(_buildRow(item, row));
    }
  }

  final Map<String, web.HTMLElement> _groups = <String, web.HTMLElement>{};

  web.HTMLElement _buildRow(TreeItem item, _TreeRow row) {
    final selected = _selectedItem != null && _selectedItem!.id == item.id;
    final groupId = 'tree-group-${item.id}';
    final entry = div(
      className: clsx([
        'tree-view-entry',
        selected ? 'selected' : null,
        (isError?.call(item) ?? false) ? 'error' : null,
      ]),
      children: [
        for (var i = 0; i < row.depth; i++) div(className: 'tree-view-indent'),
        _chevron(item, row),
        ...render(item),
      ],
    );
    entry.onClick.listen((_) => onSelected?.call(item));
    entry.ondblclick = ((web.Event _) => onAccepted?.call(item)).toJS;
    entry.addEventListener(
        'mouseenter',
        ((web.Event _) {
          entry.classList.add('highlighted');
          onHighlighted?.call(item);
        }).toJS);
    entry.addEventListener(
        'mouseleave',
        ((web.Event _) {
          entry.classList.remove('highlighted');
          onHighlighted?.call(null);
        }).toJS);

    final children = <web.Node>[entry];
    if (row.expanded == true && item.children.isNotEmpty) {
      final group = div(attrs: {'id': groupId, 'role': 'group'});
      _groups[item.id] = group;
      children.add(group);
    }
    final wrapper = div(
      className: 'vbox',
      attrs: {
        'role': 'treeitem',
        'aria-selected': '$selected',
        if (row.expanded != null) 'aria-expanded': '${row.expanded}',
        'aria-controls': groupId,
        if (title?.call(item) != null) 'title': title!.call(item)!,
      },
      style: {'flex': 'none'},
      children: children,
    );
    if (selected) scrollIntoViewIfNeeded(wrapper);
    return wrapper;
  }

  web.HTMLElement _chevron(TreeItem item, _TreeRow row) {
    final icon = row.expanded == null
        ? 'codicon-blank'
        : (row.expanded! ? 'codicon-chevron-down' : 'codicon-chevron-right');
    final chevron = div(
      className: 'codicon $icon',
      attrs: {'aria-hidden': 'true'},
      style: {'min-width': '16px', 'margin-right': '4px'},
    );
    chevron.addEventListener(
        'click',
        ((web.Event event) {
          event.stopPropagation();
          event.preventDefault();
          if ((event as web.MouseEvent).altKey) {
            toggleSubtree(item);
          } else {
            toggleExpanded(item);
          }
        }).toJS);
    chevron.addEventListener(
        'dblclick',
        ((web.Event event) {
          event.stopPropagation();
          event.preventDefault();
        }).toJS);
    return chevron;
  }

  void _installKeyboard() {
    _content.addEventListener(
        'keydown',
        ((web.Event event) {
          final key = (event as web.KeyboardEvent).key;
          final selected = _selectedItem;
          if (key == 'Enter') {
            if (event.target == _content && selected != null) {
              onAccepted?.call(selected);
            }
            return;
          }
          if (key != 'ArrowUp' &&
              key != 'ArrowDown' &&
              key != 'ArrowLeft' &&
              key != 'ArrowRight') {
            return;
          }
          event.stopPropagation();
          event.preventDefault();
          if (key == 'ArrowLeft') {
            if (selected == null) return;
            final row = _rows[selected.id];
            if (row?.expanded == true) {
              expandedItems[selected.id] = false;
              _index();
              _draw();
            } else if (row?.parent != null) {
              onSelected?.call(row!.parent!);
            }
            return;
          }
          if (key == 'ArrowRight') {
            if (selected == null || selected.children.isEmpty) return;
            expandedItems[selected.id] = true;
            _index();
            _draw();
            return;
          }
          if (_flattened.isEmpty) return;
          if (selected == null) {
            onSelected
                ?.call(key == 'ArrowDown' ? _flattened.first : _flattened.last);
            return;
          }
          final row = _rows[selected.id];
          final next = key == 'ArrowDown' ? row?.next : row?.previous;
          if (next != null) onSelected?.call(next);
        }).toJS);
  }
}

class _TreeRow {
  final int depth;

  /// Null when the item has no children, which is what leaves the
  /// `aria-expanded` attribute off entirely.
  final bool? expanded;
  final TreeItem? parent;
  final TreeItem? previous;
  TreeItem? next;

  _TreeRow({
    required this.depth,
    required this.expanded,
    required this.parent,
    required this.previous,
  });
}

/// One cell of a [GridView] row.
class GridCell {
  final String text;
  final String? title;

  const GridCell(this.text, {this.title});
}

/// `GridView`: a [ListView] with a header of resizable, sortable columns.
class GridView<T> {
  final String name;
  final String? ariaLabel;
  final List<String> Function() columns;
  final String Function(String column) columnTitle;
  final double Function(String column) columnWidth;
  final GridCell Function(T item, String column) renderCell;

  void Function(String column)? onSortChanged;
  void Function(T item, int index)? onSelected;
  void Function(T? item)? onHighlighted;

  /// The column currently sorted by, and whether it is reversed.
  String? sortBy;
  bool sortNegate = false;

  final web.HTMLElement element;
  late final web.HTMLElement _header;
  late final ListView<T> _list;

  GridView({
    required this.name,
    required this.columns,
    required this.columnTitle,
    required this.columnWidth,
    required this.renderCell,
    this.ariaLabel,
    bool Function(T item)? isError,
    bool Function(T item)? isInfo,
    bool Function(T item)? isSelected,
  }) : element = div(className: 'grid-view $name-grid-view') {
    _header = div(className: 'grid-view-header');
    _list = ListView<T>(
      name: name,
      ariaLabel: ariaLabel,
      isError: isError,
      isInfo: isInfo,
      isSelected: isSelected,
      render: (item, index) {
        final visible = columns();
        return [
          for (var i = 0; i < visible.length; i++)
            div(
              className: 'grid-view-cell grid-view-column-${visible[i]}',
              text: renderCell(item, visible[i]).text,
              attrs: {
                if (renderCell(item, visible[i]).title != null)
                  'title': renderCell(item, visible[i]).title!,
              },
              style: i == visible.length - 1
                  ? null
                  : {'width': '${columnWidth(visible[i])}px'},
            )
        ];
      },
    );
    _list.onSelected = (item, index) => onSelected?.call(item, index);
    _list.onHighlighted = (item) => onHighlighted?.call(item);
    element.append(div(className: 'vbox', children: [_header, _list.element]));
  }

  void update(List<T> items) {
    _renderHeader();
    _list.update(items);
  }

  void _renderHeader() {
    removeChildren(_header);
    final visible = columns();
    for (var i = 0; i < visible.length; i++) {
      final column = visible[i];
      // Upstream builds this class by concatenation rather than with clsx,
      // which leaves the trailing space on an unsorted header and a double
      // space on a sorted one. Reproduced so the DOM matches byte for byte.
      final sortSuffix = sortBy != column
          ? ''
          : (sortNegate ? ' filter-negative' : ' filter-positive');
      final cell = div(
        className: 'grid-view-header-cell $sortSuffix',
        attrs: {},
        style: i == visible.length - 1
            ? null
            : {'width': '${columnWidth(column)}px'},
        children: [
          span(
              className: 'grid-view-header-cell-title',
              text: columnTitle(column)),
          codicon('triangle-up'),
          codicon('triangle-down'),
        ],
      );
      cell.onClick.listen((_) => onSortChanged?.call(column));
      _header.append(cell);
    }
  }
}

/// `Expandable`: a chevron, a title and a body that only exists while open.
class Expandable {
  final web.HTMLElement element;
  final web.HTMLElement content;
  final web.HTMLElement titleRow;

  bool _expanded;
  late final web.HTMLElement _chevron;
  static int _uid = 0;

  Expandable({
    required web.Node title,
    bool expanded = false,
    String? className,
    List<web.Node?> titleChildren = const [],
  })  : _expanded = expanded,
        content = div(className: 'expandable-content'),
        titleRow = div(className: 'expandable-title'),
        element = div() {
    final id = 'expandable-${_uid++}';
    _chevron = div(
      className:
          'codicon ${expanded ? 'codicon-chevron-down' : 'codicon-chevron-right'}',
      style: {'color': 'var(--vscode-foreground)', 'margin-left': '5px'},
    );
    final button = el('button', className: 'expandable-title-button', attrs: {
      'id': '$id-title',
      'aria-expanded': '$expanded',
      'aria-controls': '$id-region',
    }, children: [
      _chevron,
      title
    ]);
    button.onClick.listen((_) => this.expanded = !_expanded);
    titleRow.append(button);
    for (final child in titleChildren) {
      if (child != null) titleRow.append(child);
    }
    content.setAttribute('id', '$id-region');
    content.setAttribute('role', 'region');
    content.setAttribute('aria-labelledby', '$id-title');
    element.className =
        clsx(['expandable', expanded ? 'expanded' : null, className]);
    element.append(titleRow);
    if (expanded) element.append(content);
    _button = button;
  }

  late final web.HTMLElement _button;

  bool get expanded => _expanded;

  set expanded(bool value) {
    if (_expanded == value) return;
    _expanded = value;
    _button.setAttribute('aria-expanded', '$value');
    _chevron.className =
        'codicon ${value ? 'codicon-chevron-down' : 'codicon-chevron-right'}';
    element.classList.toggle('expanded', value);
    if (value) {
      element.append(content);
    } else {
      content.remove();
    }
    onToggled?.call(value);
  }

  void Function(bool expanded)? onToggled;
}

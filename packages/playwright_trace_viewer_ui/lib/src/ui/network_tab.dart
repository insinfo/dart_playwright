// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/trace-viewer/src/ui/{networkTab,networkFilters,
// networkResourceDetails}.tsx

/// The network panel: every request the recording saw.
library;

import 'package:playwright_trace_viewer/playwright_trace_viewer.dart';
import 'package:web/web.dart' as web;

import 'components.dart';
import 'dom.dart';
import 'format.dart';

/// One row of the grid, with every column already computed.
class _Entry {
  final ResourceEntry resource;
  final String name;
  final String url;
  final String method;
  final int status;
  final String statusText;
  final String contentType;
  final double duration;
  final int size;
  final double start;
  final String route;
  final String contextId;

  _Entry({
    required this.resource,
    required this.name,
    required this.url,
    required this.method,
    required this.status,
    required this.statusText,
    required this.contentType,
    required this.duration,
    required this.size,
    required this.start,
    required this.route,
    required this.contextId,
  });
}

/// The type buttons of the filter bar, in the order upstream shows them.
const List<String> _resourceTypes = [
  'All',
  'Fetch',
  'HTML',
  'JS',
  'CSS',
  'Font',
  'Image',
  'WS',
];

/// `NetworkTab`: the filter bar over a sortable grid.
class NetworkTab {
  final web.HTMLElement element;
  late final GridView<_Entry> _grid;
  late final web.HTMLElement _filters;
  late final web.HTMLInputElement _search;

  final web.HTMLElement _body = div(className: 'vbox');

  List<_Entry> _entries = const [];
  final Set<String> _selectedTypes = <String>{};
  String _searchValue = '';
  bool _multipleContexts = false;

  /// How many requests the trace has, which the tab counter shows.
  int count = 0;

  NetworkTab() : element = div(className: 'vbox') {
    _search = el('input', attrs: {
      'type': 'search',
      'placeholder': 'Filter network',
      'aria-label': 'Filter network',
      'spellcheck': 'false',
    }) as web.HTMLInputElement;
    _search.onInput.listen((_) {
      _searchValue = _search.value;
      _draw();
    });
    _filters = div(className: 'network-filters', children: [_search]);
    _grid = GridView<_Entry>(
      name: 'network',
      ariaLabel: 'Network requests',
      columns: _visibleColumns,
      columnTitle: _columnTitle,
      columnWidth: _columnWidth,
      renderCell: _renderCell,
      isError: (entry) => entry.status >= 400 || entry.status == -1,
      isInfo: (entry) => entry.route.isNotEmpty,
    );
    _grid.onSortChanged = (column) {
      // Upstream never cycles back to unsorted: a second click reverses the
      // order rather than clearing it.
      _grid.sortNegate = _grid.sortBy == column ? !_grid.sortNegate : false;
      _grid.sortBy = column;
      _draw();
    };
    _body.append(_filters);
    _body.append(_grid.element);
  }

  void update(TraceModel? model) {
    _entries = _collect(model);
    count = _entries.length;
    removeChildren(element);
    // An empty grid and no grid are different answers: the placeholder means
    // the trace recorded nothing, while an empty grid means the filter hid
    // everything. Upstream tests the unfiltered list here, and so does this.
    if (_entries.isEmpty) {
      element.append(placeholderPanel('No network calls'));
      return;
    }
    _renderFilterButtons();
    element.append(_body);
    _draw();
  }

  void _renderFilterButtons() {
    removeChildren(_filters);
    _filters.append(_search);
    final types = div(className: 'network-filters-resource-types', attrs: {
      'role': 'tablist',
      'aria-multiselectable': 'true',
    });
    for (final type in _resourceTypes) {
      final selected = type == 'All'
          ? _selectedTypes.isEmpty
          : _selectedTypes.contains(type);
      final button = el('button',
          className:
              'network-filters-resource-type ${selected ? 'selected' : ''}',
          attrs: {
            'title': type,
            'role': 'tab',
            'aria-selected': '$selected',
          },
          text: type);
      button.onClick.listen((event) {
        if (type == 'All') {
          _selectedTypes.clear();
        } else if (event.ctrlKey || event.metaKey) {
          // Ctrl-click adds a type to the selection; a plain click replaces
          // it, which is how one click narrows to exactly one kind.
          if (!_selectedTypes.remove(type)) _selectedTypes.add(type);
        } else {
          _selectedTypes
            ..clear()
            ..add(type);
        }
        _renderFilterButtons();
        _draw();
      });
      types.append(button);
    }
    _filters.append(types);
  }

  void _draw() {
    var rows = _entries.where(_matches).toList();
    final sortBy = _grid.sortBy;
    if (sortBy != null) {
      rows.sort((a, b) => _compare(a, b, sortBy));
      if (_grid.sortNegate) rows = rows.reversed.toList();
    }
    _multipleContexts =
        rows.map((e) => e.contextId).where((c) => c.isNotEmpty).toSet().length >
            1;
    _grid.update(rows);
  }

  bool _matches(_Entry entry) {
    if (_selectedTypes.isNotEmpty &&
        !_selectedTypes.any((t) => _isType(entry, t))) {
      return false;
    }
    // The search matches the whole URL, not the shortened name the grid
    // shows, so a query string is searchable too.
    return entry.url.toLowerCase().contains(_searchValue.toLowerCase());
  }

  bool _isType(_Entry entry, String type) => switch (type) {
        'Fetch' => entry.contentType == 'application/json',
        'HTML' => entry.contentType == 'text/html',
        'CSS' => entry.contentType == 'text/css',
        'JS' => entry.contentType.contains('javascript'),
        'Font' => entry.contentType.contains('font'),
        'Image' => entry.contentType.contains('image'),
        'WS' => entry.resource.resourceType == 'websocket',
        _ => true,
      };

  int _compare(_Entry a, _Entry b, String column) => switch (column) {
        'start' => a.start.compareTo(b.start),
        'duration' => a.duration.compareTo(b.duration),
        'status' => a.status.compareTo(b.status),
        'size' => a.size.compareTo(b.size),
        'method' => a.method.compareTo(b.method),
        'contentType' => a.contentType.compareTo(b.contentType),
        'route' => a.route.compareTo(b.route),
        'contextId' => a.contextId.compareTo(b.contextId),
        _ => a.name.compareTo(b.name),
      };

  List<String> _visibleColumns() => [
        if (_multipleContexts) 'contextId',
        'name',
        'method',
        'status',
        'contentType',
        'duration',
        'size',
        'start',
        'route',
      ];

  String _columnTitle(String column) => switch (column) {
        'contextId' => 'Source',
        'name' => 'Name',
        'method' => 'Method',
        'status' => 'Status',
        'contentType' => 'Content Type',
        'duration' => 'Duration',
        'size' => 'Size',
        'start' => 'Start',
        _ => 'Route',
      };

  double _columnWidth(String column) => switch (column) {
        'contextId' => 60,
        'name' => 200,
        'method' => 60,
        'status' => 60,
        'contentType' => 200,
        _ => 100,
      };

  GridCell _renderCell(_Entry entry, String column) => switch (column) {
        'contextId' => GridCell(entry.contextId, title: entry.url),
        'name' => GridCell(entry.name, title: entry.url),
        'method' => GridCell(entry.method),
        'status' => GridCell(
            entry.status == -1
                ? 'canceled'
                : (entry.status > 0 ? '${entry.status}' : ''),
            title: entry.status == -1 ? 'canceled' : entry.statusText),
        'contentType' => GridCell(entry.contentType),
        'duration' => GridCell(msToString(entry.duration)),
        'size' => GridCell(bytesToString(entry.size)),
        'start' => GridCell(msToString(entry.start)),
        _ => GridCell(entry.route),
      };

  List<_Entry> _collect(TraceModel? model) {
    if (model == null) return const [];
    return [
      for (final resource in model.resources)
        _Entry(
          resource: resource,
          name: _shortName(resource.request.url),
          url: resource.request.url,
          method: resource.request.method,
          status: resource.response.status,
          statusText: resource.response.statusText,
          contentType: _contentType(resource),
          duration: resource.resource.time,
          size: (resource.response.transferSize ?? 0) > 0
              ? resource.response.transferSize!
              : resource.response.bodySize,
          start: (resource.monotonicTime ?? 0) - model.startTime,
          route: _route(resource),
          contextId: model.resourceOwnerRefToTitle[
                  resourceOwnerRef(resource.resource) ?? ''] ??
              '',
        )
    ];
  }

  String _contentType(ResourceEntry resource) {
    if (resource.resourceType == 'websocket') return 'websocket';
    final mimeType = resource.response.content.mimeType;
    final match = RegExp(r'^(.*);\s*charset=.*$').firstMatch(mimeType);
    return match != null ? match[1]! : mimeType;
  }

  /// What the route handlers did with this request, if anything.
  String _route(ResourceEntry resource) {
    final entry = resource.resource;
    if (entry.wasAborted == true) return 'aborted';
    if (entry.wasContinued == true) return 'continued';
    if (entry.wasFulfilled == true) return 'fulfilled';
    if (entry.apiRequestRef != null) return 'api';
    return '';
  }

  /// The last path segment, which is what a developer recognizes a request
  /// by; a URL with no path falls back to the host.
  String _shortName(String url) {
    try {
      final uri = Uri.parse(url);
      var name = uri.path.substring(uri.path.lastIndexOf('/') + 1);
      if (name.isEmpty) name = uri.host;
      if (uri.hasQuery) name = '$name?${uri.query}';
      return name;
    } on FormatException {
      return url;
    }
  }
}

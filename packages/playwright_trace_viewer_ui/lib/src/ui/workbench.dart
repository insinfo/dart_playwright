// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/trace-viewer/src/ui/workbench.tsx

/// The whole viewer: the timeline on top, the actions on the left, the
/// snapshot in the middle and the tabs at the bottom.
library;

import 'package:playwright_trace_viewer/playwright_trace_viewer.dart';
import 'package:web/web.dart' as web;

import 'action_list.dart';
import 'components.dart';
import 'playback_control.dart';
import 'dom.dart';
import 'network_tab.dart';
import 'snapshot_tab.dart';
import 'source_tab.dart';
import 'tabs.dart';
import 'timeline.dart';

/// `Workbench`: the shell, and the one place the selection lives.
class Workbench {
  final web.HTMLElement element;
  final TraceModel model;

  late final Timeline timeline;
  late final ActionList actionList;
  late final SnapshotTab snapshotTab;
  late final CallTab callTab;
  late final LogTab logTab;
  late final ErrorsTab errorsTab;
  late final ConsoleTab consoleTab;
  late final NetworkTab networkTab;
  late final SourceTab sourceTab;
  late final AttachmentsTab attachmentsTab;
  late final AnnotationsTab annotationsTab;
  late final PlaybackControl playback;
  late final MetadataView metadataView;
  late final TabbedPane propertiesPane;
  late final TabbedPane navigatorPane;
  late final web.HTMLInputElement _filterInput;
  late final web.HTMLElement _hiddenCount;

  String? _selectedCallId;
  String? _highlightedCallId;

  /// Which action groups are shown. Empty is upstream's default, which hides
  /// the getters, the route handlers and the configuration calls.
  final List<String> actionsFilter = <String>[];

  Workbench(this.model, {required String traceUri})
      : element = div(className: 'vbox workbench') {
    final sdkLanguage = model.sdkLanguage ?? 'javascript';

    timeline = Timeline();
    actionList = ActionList(sdkLanguage: sdkLanguage, stats: model.stats);
    snapshotTab = SnapshotTab(traceUri: traceUri)..model = model;
    callTab = CallTab()
      ..startTimeOffset = model.startTime
      ..sdkLanguage = sdkLanguage;
    logTab = LogTab();
    errorsTab = ErrorsTab()..sdkLanguage = sdkLanguage;
    consoleTab = ConsoleTab()..startTimeOffset = model.startTime;
    networkTab = NetworkTab();
    sourceTab = SourceTab()..model = model;
    attachmentsTab = AttachmentsTab();
    annotationsTab = AnnotationsTab();
    playback = PlaybackControl();
    metadataView = MetadataView();

    _filterInput = el('input', attrs: {
      'type': 'search',
      'placeholder': 'Filter actions',
      'aria-label': 'Filter actions',
      'spellcheck': 'false',
    }) as web.HTMLInputElement;
    _filterInput.onInput.listen((_) {
      actionList.filterText = _filterInput.value;
      _renderActions();
    });
    _hiddenCount = span(className: 'workbench-actions-hidden-count');

    navigatorPane = TabbedPane(tabs: [
      PaneTab(
        id: 'actions',
        title: 'Actions',
        body: div(className: 'vbox', children: [
          div(className: 'workbench-action-filter', children: [_filterInput]),
          actionList.element,
        ]),
      ),
      PaneTab(id: 'metadata', title: 'Metadata', body: metadataView.element),
    ]);
    navigatorPane.rightToolbar.append(_buildFilterButton());

    propertiesPane = TabbedPane(
      selectedTab: 'call',
      tabs: [
        PaneTab(id: 'call', title: 'Call', body: callTab.element),
        PaneTab(id: 'log', title: 'Log', body: logTab.element),
        PaneTab(id: 'errors', title: 'Errors', body: errorsTab.element),
        PaneTab(id: 'console', title: 'Console', body: consoleTab.element),
        PaneTab(id: 'network', title: 'Network', body: networkTab.element),
        PaneTab(id: 'source', title: 'Source', body: sourceTab.element),
        PaneTab(
            id: 'attachments',
            title: 'Attachments',
            body: attachmentsTab.element),
        PaneTab(
            id: 'annotations',
            title: 'Annotations',
            body: annotationsTab.element),
      ],
    );

    final actionsSplit = SplitView(
      orientation: 'horizontal',
      sidebarIsFirst: true,
      sidebarSize: 250,
      settingName: 'actionListSidebar',
    );
    actionsSplit.main.append(snapshotTab.element);
    actionsSplit.sidebar.append(navigatorPane.element);

    final propertiesSplit = SplitView(
      orientation: 'vertical',
      sidebarSize: 250,
      settingName: 'propertiesSidebar',
    );
    propertiesSplit.main.append(actionsSplit.element);
    propertiesSplit.sidebar.append(propertiesPane.element);

    element.append(div(className: 'playback-bar', children: [
      playback.buttons,
      playback.scrubber,
    ]));
    element.append(timeline.element);
    element.append(propertiesSplit.element);

    _wire();
    update();
  }

  void _wire() {
    actionList.onSelected = (action) {
      _selectedCallId = action.callId;
      _highlightedCallId = null;
      _renderActions();
      _renderProperties();
    };
    actionList.onHighlighted = (action) {
      _highlightedCallId = action?.callId;
      // Hovering previews an action without moving the selection, which is
      // what makes scrubbing the list useful.
      _renderProperties();
    };
    actionList.onAccepted = (action) {
      timeline.selectedTime =
          (minimum: action.startTime, maximum: action.endTime);
      actionList.selectedTime = timeline.selectedTime;
      _renderActions();
    };
    actionList.onShowAll = () {
      timeline.selectedTime = null;
      actionList.selectedTime = null;
      _renderActions();
      actionList.revealSelected();
    };
    actionList.onRevealConsole = () => propertiesPane.selectedTab = 'console';
    actionList.onRevealAttachment = (callId) {
      attachmentsTab.revealCallId = callId;
      propertiesPane.selectedTab = 'attachments';
      attachmentsTab.update(model);
    };
    errorsTab.onRevealInSource = (error) {
      final action = error.action;
      if (action != null) {
        _selectedCallId = action.callId;
        _renderActions();
      }
      propertiesPane.selectedTab = 'source';
      sourceTab.update(error.stack ?? action?.stack);
    };
    timeline.onSelectedTimeChanged = (span) {
      actionList.selectedTime = span;
      _renderActions();
    };
    timeline.onActionSelected = (action) {
      _selectedCallId = action.callId;
      _renderActions();
      _renderProperties();
    };
    playback.onActionSelected = (action) {
      _selectedCallId = action.callId;
      _renderActions();
      _renderProperties();
    };
    // A janela da linha do tempo tambem limita a reproducao: com um trecho
    // selecionado, o play anda dentro dele e para no fim dele.
    final previousSelectedTimeChanged = timeline.onSelectedTimeChanged;
    timeline.onSelectedTimeChanged = (span) {
      playback.timeWindow = span;
      previousSelectedTimeChanged?.call(span);
    };
  }

  web.HTMLElement _buildFilterButton() {
    final dialog = el('dialog', attrs: {'data-testid': 'actions-filter-dialog'})
        as web.HTMLDialogElement;
    for (final entry in const [
      ('getter', 'Getters'),
      ('route', 'Network routes'),
      ('configuration', 'Configuration'),
    ]) {
      final checkbox =
          el('input', attrs: {'type': 'checkbox'}) as web.HTMLInputElement;
      checkbox.onChange.listen((_) {
        if (checkbox.checked) {
          actionsFilter.add(entry.$1);
        } else {
          actionsFilter.remove(entry.$1);
        }
        _renderActions();
      });
      dialog.append(el('label', children: [
        checkbox,
        textNode(' ${entry.$2} (${model.actionCounters[entry.$1] ?? 0})'),
      ]));
    }
    final button = toolbarButton(
      icon: 'filter',
      title: 'Filter actions',
      onClick: () {
        if (dialog.open) {
          dialog.close();
        } else {
          dialog.show();
        }
      },
    );
    button.insertBefore(_hiddenCount, button.firstChild);
    final wrapper = div(children: [button, dialog]);
    return wrapper;
  }

  /// The action the panels describe: the hovered one if there is one, else
  /// the selected one.
  ActionEntry? get activeAction {
    final actions = model.filteredActions(actionsFilter);
    for (final action in actions) {
      if (action.callId == _highlightedCallId) return action;
    }
    return selectedAction;
  }

  /// The selected action, or the one the viewer picks when nothing is.
  ActionEntry? get selectedAction {
    final actions = model.filteredActions(actionsFilter);
    for (final action in actions) {
      if (action.callId == _selectedCallId) return action;
    }
    // Nothing chosen: show the failure if there is one, because that is what
    // the trace was opened for.
    final failed = model.failedAction();
    if (failed != null) return failed;
    // Otherwise the last action before the after-hooks, which is the last
    // thing the test itself did.
    for (var i = 0; i < actions.length; i++) {
      if (actions[i].title == 'After Hooks' && i > 0) return actions[i - 1];
    }
    return actions.isEmpty ? null : actions.last;
  }

  /// Redraws everything, which is what opening a trace does.
  void update() {
    timeline.update(model);
    metadataView.update(model);
    consoleTab.update(model);
    networkTab.update(model);
    attachmentsTab.update(model);
    annotationsTab.update(model);
    errorsTab.update(model.errorDescriptors);
    _renderActions();
    _renderProperties();
    _updateCounters();
  }

  void _renderActions() {
    final actions = model.filteredActions(actionsFilter);
    final hidden = model.actions.length - actions.length;
    _hiddenCount.textContent = hidden > 0 ? '$hidden hidden' : '';
    _hiddenCount.setAttribute('title', '$hidden actions hidden by filters');
    actionList.update(actions, selectedAction: selectedAction);
    playback.selectedAction = selectedAction;
    playback.update(actions, timeline.boundaries);
  }

  void _renderProperties() {
    final action = activeAction;
    callTab.update(action);
    logTab.update(action);
    sourceTab.update(action?.stack);
    snapshotTab.update(action);
  }

  void _updateCounters() {
    propertiesPane.tabById('console')?.count = consoleTab.count;
    propertiesPane.tabById('network')?.count = networkTab.count;
    propertiesPane.tabById('attachments')?.count =
        model.visibleAttachments.length;
    propertiesPane.tabById('errors')?.errorCount =
        model.errorDescriptors.length;
    propertiesPane.updateCounters();
  }
}

// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/isomorphic/trace/traceModel.ts

/// One trace, as the panels of a viewer want it.
///
/// A trace archive can hold two recordings of the same run — the library's
/// and the test runner's — and this is where they become one list of actions
/// on one clock: the runner's ids and times win, the library's snapshots and
/// network stay, and the two clocks are reconciled through the
/// `wallTime`/`monotonicTime` pair each context declares.
library;

import 'entries.dart';
import 'protocol_formatter.dart';
import 'trace.dart';

/// Where in a source file something happened.
class SourceLocation {
  final String file;
  final int line;
  final int column;
  final SourceModel? source;

  const SourceLocation({
    required this.file,
    required this.line,
    required this.column,
    this.source,
  });
}

/// One source file the Source tab shows, and the errors marked in it.
class SourceModel {
  final List<({int line, String message})> errors;

  /// Filled in by the UI once it has fetched the file.
  String? content;

  SourceModel({List<({int line, String message})>? errors, this.content})
      : errors = errors ?? <({int line, String message})>[];
}

/// A recorded request, with the id the network panel keys rows by.
///
/// Upstream spreads the HAR entry into a new object with an `id`; here the id
/// sits beside the entry, with the fields the panel reads passed through, so
/// the entry the snapshot renderer serves stays the same object.
class ResourceEntry {
  final String id;
  final ResourceSnapshot resource;

  const ResourceEntry({required this.id, required this.resource});

  HarRequest get request => resource.request;
  HarResponse get response => resource.response;
  String get startedDateTime => resource.startedDateTime;
  double? get monotonicTime => resource.monotonicTime;
  String? get pageref => resource.pageref;
  String? get frameref => resource.frameref;
  String? get serviceWorkerRef => resource.serviceWorkerRef;
  String? get apiRequestRef => resource.apiRequestRef;
  String? get resourceType => resource.resourceType;
}

/// Who issued a request: a page, a service worker or an API request context.
String? resourceOwnerRef(ResourceSnapshot resource) =>
    resource.pageref ?? resource.serviceWorkerRef ?? resource.apiRequestRef;

/// One node of the action tree.
class ActionTreeItem {
  final String id;
  final List<ActionTreeItem> children = <ActionTreeItem>[];
  ActionTreeItem? parent;
  final ActionEntry action;

  ActionTreeItem({required this.id, required this.action});
}

/// One failure worth showing, with the action and the stack that caused it.
class ErrorDescription {
  final ActionEntry? action;
  final List<StackFrame>? stack;
  final String message;

  const ErrorDescription({this.action, this.stack, required this.message});
}

/// An attachment, and which call produced it.
class Attachment {
  final AfterActionTraceEventAttachment attachment;
  final String callId;
  final String traceUri;

  const Attachment({
    required this.attachment,
    required this.callId,
    required this.traceUri,
  });

  String get name => attachment.name;
  String get contentType => attachment.contentType;
  String? get path => attachment.path;
  String? get file => attachment.file;
  String? get base64 => attachment.base64;
}

/// The whole trace.
class TraceModel {
  final double startTime;
  final double endTime;
  final String browserName;
  final String? channel;
  final String? platform;
  final String? playwrightVersion;
  final double? wallTime;
  final String? title;
  final BrowserContextEventOptions options;
  final List<PageEntry> pages;
  final List<VideoTraceEvent> videos;
  final List<ActionEntry> actions;
  final List<Attachment> attachments;

  /// The attachments a user should see: an attachment whose name starts with
  /// `_` is the machinery's own.
  final List<Attachment> visibleAttachments;
  final List<TimelineTraceEvent> events;
  final List<StdioTraceEvent> stdio;
  final List<ErrorTraceEvent> errors;
  final List<ErrorDescription> errorDescriptors;
  final bool hasSource;

  /// True when the test runner recorded a context of its own, which is what
  /// gives the trace steps rather than bare library calls.
  final bool hasStepData;

  /// True when at least one action recorded a DOM snapshot.
  bool hasDomSnapshots = false;

  /// True when at least one action recorded a screenshot or an aria snapshot.
  bool hasAriaSnapshots = false;
  final String? sdkLanguage;
  final String? testIdAttributeName;
  final Map<String, SourceModel> sources;
  List<ResourceEntry> resources;
  final Map<String, int> actionCounters;
  final String traceUri;
  final double? testTimeout;
  final List<TraceEventAnnotation>? annotations;

  /// `page#1`, `service-worker#1`, `api#1`: what the network panel calls the
  /// issuer of a request.
  final Map<String, String> resourceOwnerRefToTitle = <String, String>{};

  /// How a selector is rendered in a title. See [LocatorDescriber].
  final LocatorDescriber describeLocator;

  final Map<ActionEntry, List<TimelineTraceEvent>> _eventsForAction =
      <ActionEntry, List<TimelineTraceEvent>>{};
  final Map<String, ScreenshotTraceEvent> _screenshots =
      <String, ScreenshotTraceEvent>{};
  final Map<String, AriaSnapshotTraceEvent> _ariaSnapshots =
      <String, AriaSnapshotTraceEvent>{};
  final Set<String> _domSnapshots = <String>{};

  TraceModel(
    this.traceUri,
    List<ContextEntry> contexts, {
    this.describeLocator = passThroughLocatorDescriber,
  })  : browserName = _libraryContext(contexts)?.browserName ?? '',
        sdkLanguage = _libraryContext(contexts)?.sdkLanguage,
        channel = _libraryContext(contexts)?.channel,
        testIdAttributeName = _libraryContext(contexts)?.testIdAttributeName,
        platform = _libraryContext(contexts)?.platform ?? '',
        playwrightVersion =
            _firstWhere(contexts, (c) => c.playwrightVersion != null)
                ?.playwrightVersion,
        title = _libraryContext(contexts)?.title ?? '',
        options =
            _libraryContext(contexts)?.options ?? BrowserContextEventOptions(),
        testTimeout =
            _firstWhere(contexts, (c) => c.origin == kTraceOriginTestRunner)
                ?.testTimeout,
        annotations =
            _firstWhere(contexts, (c) => c.origin == kTraceOriginTestRunner)
                ?.annotations,
        // The next call updates all timestamps for all events in library
        // contexts, so it must be done first.
        actions = mergeActionsAndUpdateTiming(contexts),
        pages = [for (final c in contexts) ...c.pages],
        videos = <VideoTraceEvent>[],
        // `prev || Number.MAX_VALUE` upstream: a context that recorded no
        // wall time must not drag the whole trace's origin to zero.
        wallTime = contexts.map((c) => c.wallTime).fold<double>(
            double.maxFinite,
            (prev, cur) =>
                (prev == 0 ? double.maxFinite : prev) < cur ? prev : cur),
        startTime = contexts.map((c) => c.startTime).fold<double>(
            double.maxFinite, (prev, cur) => prev < cur ? prev : cur),
        // `Number.MIN_VALUE` upstream, which is the smallest positive double,
        // not the most negative one.
        endTime = contexts.map((c) => c.endTime).fold<double>(
            double.minPositive, (prev, cur) => prev > cur ? prev : cur),
        events = [for (final c in contexts) ...c.events],
        stdio = [for (final c in contexts) ...c.stdio],
        errors = [for (final c in contexts) ...c.errors],
        hasSource = contexts.any((c) => c.hasSource),
        hasStepData = contexts.any((c) => c.origin == kTraceOriginTestRunner),
        resources = <ResourceEntry>[],
        attachments = <Attachment>[],
        visibleAttachments = <Attachment>[],
        sources = <String, SourceModel>{},
        errorDescriptors = <ErrorDescription>[],
        actionCounters = <String, int>{} {
    for (var i = 0; i < contexts.length; ++i) {
      for (final entry in contexts[i].resources) {
        resources.add(ResourceEntry(
          id: '${resourceOwnerRef(entry) ?? i}-${entry.startedDateTime}-'
              '${entry.request.url}',
          resource: entry,
        ));
      }
    }
    for (final context in contexts) {
      for (final event in context.screenshots) {
        _screenshots['${event.callId}/${event.phase?.wire}'] = event;
      }
      for (final event in context.ariaSnapshots) {
        _ariaSnapshots['${event.callId}/${event.phase?.wire}'] = event;
      }
      for (final entry in context.domSnapshots) {
        _domSnapshots.add('${entry.callId}/${entry.phase.wire}');
      }
      videos.addAll(context.videos);
    }
    hasDomSnapshots = _domSnapshots.isNotEmpty;
    hasAriaSnapshots = _screenshots.isNotEmpty || _ariaSnapshots.isNotEmpty;

    for (final action in actions) {
      for (final attachment in action.attachments ?? const []) {
        attachments.add(Attachment(
          attachment: attachment,
          callId: action.callId,
          traceUri: traceUri,
        ));
      }
    }
    visibleAttachments
        .addAll(attachments.where((a) => !a.name.startsWith('_')));

    for (var index = 0; index < pages.length; index++) {
      resourceOwnerRefToTitle[pages[index].pageId] = 'page#${index + 1}';
    }

    events.sort((a1, a2) => a1.time.compareTo(a2.time));
    resources.sort(
        (a1, a2) => (a1.monotonicTime ?? 0).compareTo(a2.monotonicTime ?? 0));

    var serviceWorkerCount = 0;
    var apiRequestCount = 0;
    for (final resource in resources) {
      final serviceWorkerRef = resource.serviceWorkerRef;
      if (serviceWorkerRef != null &&
          !resourceOwnerRefToTitle.containsKey(serviceWorkerRef)) {
        resourceOwnerRefToTitle[serviceWorkerRef] =
            'service-worker#${++serviceWorkerCount}';
      }
      final apiRequestRef = resource.apiRequestRef;
      if (apiRequestRef != null &&
          !resourceOwnerRefToTitle.containsKey(apiRequestRef)) {
        resourceOwnerRefToTitle[apiRequestRef] = 'api#${++apiRequestCount}';
      }
    }
    errorDescriptors.addAll(hasStepData
        ? _errorDescriptorsFromTestRunner()
        : _errorDescriptorsFromActions());
    sources.addAll(collectSources(actions, errorDescriptors));

    for (final action in actions) {
      action.group ??= getActionGroup(action.className, action.method);
      final group = action.group;
      if (group != null) {
        actionCounters[group] = 1 + (actionCounters[group] ?? 0);
      }
    }
  }

  /// A viewer URL for [path], carrying this trace's URI along.
  String createRelativeUrl(String path) {
    final url = Uri.parse('http://localhost/$path');
    final query = Map<String, String>.from(url.queryParameters)
      ..['trace'] = traceUri;
    return url.replace(queryParameters: query).toString().substring(
          'http://localhost/'.length,
        );
  }

  /// The innermost action that failed, which is the one worth opening on.
  ActionEntry? failedAction() {
    for (final action in actions.reversed) {
      if (action.error != null) return action;
    }
    return null;
  }

  /// The screenshot recorded for one call at one phase.
  ScreenshotTraceEvent? screenshotForCall(String callId, ActionPhase phase) =>
      _screenshots['$callId/${phase.wire}'];

  /// Whether a DOM snapshot exists for one call at one phase.
  bool hasDomSnapshotForCall(String callId, ActionPhase phase) =>
      _domSnapshots.contains('$callId/${phase.wire}');

  /// The aria snapshot recorded for one call at one phase.
  AriaSnapshotTraceEvent? ariaSnapshotForCall(
          String callId, ActionPhase phase) =>
      _ariaSnapshots['$callId/${phase.wire}'];

  /// The console messages and browser events that happened during [action].
  ///
  /// "During" means from this action's start to the next one's, skipping the
  /// `Route` actions in between, which are the handlers the events themselves
  /// triggered.
  List<TimelineTraceEvent> eventsForAction(ActionEntry action) {
    final cached = _eventsForAction[action];
    if (cached != null) return cached;

    var nextAction = nextActionByStartTime(action);
    while (nextAction != null && nextAction.className == 'Route') {
      nextAction = nextActionByStartTime(nextAction);
    }
    final result = events
        .where((event) =>
            event.time >= action.startTime &&
            (nextAction == null || event.time < nextAction.startTime))
        .toList();
    _eventsForAction[action] = result;
    return result;
  }

  /// How many console errors and warnings happened during [action].
  ({int errors, int warnings}) stats(ActionEntry action) {
    var errors = 0;
    var warnings = 0;
    for (final event in eventsForAction(action)) {
      if (event is ConsoleMessageTraceEvent) {
        final type = event.messageType;
        if (type == 'warning') {
          ++warnings;
        } else if (type == 'error') {
          ++errors;
        }
      }
      if (event is EventTraceEvent && event.method == 'pageError') ++errors;
    }
    return (errors: errors, warnings: warnings);
  }

  /// The actions the list shows for a given set of enabled groups.
  ///
  /// An action with no group is always shown; one with a group appears only
  /// when its group is in [actionsFilter]. See [ActionGroup].
  List<ActionEntry> filteredActions(List<String> actionsFilter) {
    final filter = actionsFilter.toSet();
    return actions
        .where(
            (action) => action.group == null || filter.contains(action.group))
        .toList();
  }

  /// The action tree as indented lines, which is what a test asserts on.
  List<String> renderActionTree([List<String>? filter]) {
    final filtered = filteredActions(filter ?? const <String>[]);
    final tree = buildActionTree(filtered);
    final actionTree = <String>[];
    void visit(ActionTreeItem actionItem, String indent) {
      final title = renderFullTitleForCall(
        CallMetainfo(
          className: actionItem.action.className,
          method: actionItem.action.method,
          params: actionItem.action.params,
          title: actionItem.action.title,
          subtitle: actionItem.action.subtitle,
        ),
        sdkLanguage: sdkLanguage,
        describeLocator: describeLocator,
      );
      actionTree.add('$indent${title.isNotEmpty ? title : actionItem.id}');
      for (final child in actionItem.children) {
        visit(child, '$indent  ');
      }
    }

    for (final item in tree.rootItem.children) {
      visit(item, '');
    }
    return actionTree;
  }

  List<ErrorDescription> _errorDescriptorsFromActions() {
    final errors = <ErrorDescription>[];
    for (final action in actions) {
      final message = action.error?.message;
      if (message == null || message.isEmpty) continue;
      errors.add(ErrorDescription(
        action: action,
        stack: action.stack,
        message: message,
      ));
    }
    return errors;
  }

  List<ErrorDescription> _errorDescriptorsFromTestRunner() => errors
      .where((e) => e.message.isNotEmpty)
      .map((error) =>
          ErrorDescription(stack: error.stack, message: error.message))
      .toList();

  static ContextEntry? _libraryContext(List<ContextEntry> contexts) =>
      _firstWhere(contexts, (c) => c.origin == kTraceOriginLibrary);

  static ContextEntry? _firstWhere(
      List<ContextEntry> contexts, bool Function(ContextEntry) test) {
    for (final context in contexts) {
      if (test(context)) return context;
    }
    return null;
  }
}

/// Merges the actions of every context and links them in time order.
List<ActionEntry> mergeActionsAndUpdateTiming(List<ContextEntry> contexts) {
  final result = mergeActionsAndUpdateTimingSameTrace(contexts);

  result.sort((a1, a2) {
    if (a2.parentId == a1.callId) return 1;
    if (a1.parentId == a2.callId) return -1;
    return a1.endTime.compareTo(a2.endTime);
  });

  for (var i = 1; i < result.length; ++i) {
    result[i].prevByEndTime = result[i - 1];
  }

  result.sort((a1, a2) {
    if (a2.parentId == a1.callId) return -1;
    if (a1.parentId == a2.callId) return 1;
    return a1.startTime.compareTo(a2.startTime);
  });

  for (var i = 0; i + 1 < result.length; ++i) {
    result[i].nextByStartTime = result[i + 1];
  }

  return result;
}

/// Reconciles the library's actions with the test runner's.
///
/// Both recorded the same calls, each on its own clock and, before format
/// version 10, under its own ids. The runner's timings win because they
/// preserve the order the client saw; the library's snapshots and network
/// stay because only it has them.
List<ActionEntry> mergeActionsAndUpdateTimingSameTrace(
    List<ContextEntry> contexts) {
  final map = <String, ActionEntry>{};

  final libraryContexts =
      contexts.where((c) => c.origin == kTraceOriginLibrary).toList();
  final testRunnerContexts =
      contexts.where((c) => c.origin == kTraceOriginTestRunner).toList();

  // With library-only or test-runner-only traces there is nothing to match.
  if (testRunnerContexts.isEmpty || libraryContexts.isEmpty) {
    return [
      for (final context in contexts)
        for (final action in context.actions) action.copy(),
    ];
  }

  double timeOrigin(ContextEntry context) =>
      context.wallTime - context.monotonicTime;
  ContextEntry? runnerContext;
  for (final context in testRunnerContexts) {
    if (context.monotonicTime != 0) {
      runnerContext = context;
      break;
    }
  }
  for (final context in libraryContexts) {
    if (runnerContext != null && context.monotonicTime != 0) {
      adjustMonotonicTime(
          context, timeOrigin(context) - timeOrigin(runnerContext));
    }
  }

  for (final context in libraryContexts) {
    for (final action in context.actions) {
      map[action.callId] = action.copy();
    }
  }

  for (final context in testRunnerContexts) {
    for (final action in context.actions) {
      final existing = map[action.callId];
      if (existing == null) {
        map[action.callId] = action.copy();
        continue;
      }
      if (action.error != null) existing.error = action.error;
      if (action.attachments != null) existing.attachments = action.attachments;
      if (action.annotations != null) existing.annotations = action.annotations;
      if (action.parentId != null) existing.parentId = action.parentId;
      if (action.group != null) existing.group = action.group;
      // For the events that are present in the test runner context, always
      // take their time from the test runner context to preserve client side
      // order.
      existing.startTime = action.startTime;
      existing.endTime = action.endTime;
    }
  }
  return map.values.toList();
}

/// Shifts every timestamp of [context] by [monotonicTimeDelta].
void adjustMonotonicTime(ContextEntry context, double monotonicTimeDelta) {
  if (monotonicTimeDelta == 0) return;
  context.startTime += monotonicTimeDelta;
  context.endTime += monotonicTimeDelta;
  context.monotonicTime += monotonicTimeDelta;
  for (final action in context.actions) {
    if (action.startTime != 0) action.startTime += monotonicTimeDelta;
    if (action.endTime != 0) action.endTime += monotonicTimeDelta;
  }
  for (final event in context.events) {
    event.time += monotonicTimeDelta;
  }
  for (final event in context.stdio) {
    event.timestamp += monotonicTimeDelta;
  }
  for (final page in context.pages) {
    for (final frame in page.screencastFrames) {
      frame.timestamp += monotonicTimeDelta;
    }
  }
  for (final video in context.videos) {
    video.timestamp += monotonicTimeDelta;
  }
  for (final screenshot in context.screenshots) {
    screenshot.timestamp += monotonicTimeDelta;
  }
  for (final ariaSnapshot in context.ariaSnapshots) {
    ariaSnapshot.timestamp += monotonicTimeDelta;
  }
  for (final resource in context.resources) {
    final monotonicTime = resource.monotonicTime;
    if (monotonicTime != null && monotonicTime != 0) {
      resource.monotonicTime = monotonicTime + monotonicTimeDelta;
    }
  }
}

/// The result of [buildActionTree].
class ActionTree {
  final ActionTreeItem rootItem;
  final Map<String, ActionTreeItem> itemMap;

  const ActionTree({required this.rootItem, required this.itemMap});
}

/// Nests the actions by `parentId`.
///
/// A child with no stack of its own inherits its parent's, which is what
/// makes the Source tab work for the internal calls a public one made.
ActionTree buildActionTree(List<ActionEntry> actions) {
  final itemMap = <String, ActionTreeItem>{};

  for (final action in actions) {
    itemMap[action.callId] = ActionTreeItem(id: action.callId, action: action);
  }

  final rootItem = ActionTreeItem(id: '', action: _fakeRootAction());
  for (final item in itemMap.values) {
    rootItem.action.startTime =
        rootItem.action.startTime < item.action.startTime
            ? rootItem.action.startTime
            : item.action.startTime;
    rootItem.action.endTime = rootItem.action.endTime > item.action.endTime
        ? rootItem.action.endTime
        : item.action.endTime;
    final parentId = item.action.parentId;
    final parent = parentId != null ? itemMap[parentId] ?? rootItem : rootItem;
    parent.children.add(item);
    item.parent = parent;
  }

  void inheritStack(ActionTreeItem item) {
    for (final child in item.children) {
      child.action.stack ??= item.action.stack;
      inheritStack(child);
    }
  }

  inheritStack(rootItem);

  return ActionTree(rootItem: rootItem, itemMap: itemMap);
}

/// The action that ended just before this one, in end-time order.
ActionEntry? previousActionByEndTime(ActionEntry action) =>
    action.prevByEndTime;

/// The action that started just after this one, in start-time order.
ActionEntry? nextActionByStartTime(ActionEntry action) =>
    action.nextByStartTime;

/// Every file the actions' stacks mention, with the errors to mark in them.
Map<String, SourceModel> collectSources(
  List<ActionEntry> actions,
  List<ErrorDescription> errorDescriptors,
) {
  final result = <String, SourceModel>{};
  for (final action in actions) {
    for (final frame in action.stack ?? const <StackFrame>[]) {
      result.putIfAbsent(frame.file, () => SourceModel());
    }
  }

  for (final error in errorDescriptors) {
    final stack = error.stack;
    if (error.action == null || stack == null || stack.isEmpty) continue;
    result[stack[0].file]
        ?.errors
        .add((line: stack[0].line, message: error.message));
  }
  return result;
}

ActionEntry _fakeRootAction() => ActionEntry(
      callId: '',
      startTime: 0,
      endTime: 0,
      className: '',
      method: '',
      params: <String, dynamic>{},
    );

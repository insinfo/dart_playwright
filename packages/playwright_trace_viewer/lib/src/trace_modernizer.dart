// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/isomorphic/trace/traceModernizer.ts

/// The compatibility chain: every version of the format, brought up to the
/// current one.
///
/// A viewer that does not modernize refuses real traces, because the format
/// is versioned and the field a panel reads today may have been three fields
/// four releases ago. Each `_modernize_N_to_M` exists because some trace in
/// the world has that shape.
///
/// The steps run on raw JSON maps, not on typed events, which is what
/// upstream does too — TypeScript's types are erased at runtime, so
/// `_modernize_8_to_9` is free to delete `beforeSnapshot` and add `phase` on
/// the same object. Only the result, which is always version
/// [kLatestTraceVersion], is parsed into the typed model.
library;

import 'dart:convert';

import 'entries.dart';
import 'snapshot_storage.dart';
import 'trace.dart';
import 'trace_utils.dart';

/// Thrown when a trace was written by a newer Playwright than this reader
/// knows.
///
/// There is nothing to do about it but say so: the reader cannot guess what
/// the newer version changed.
class TraceVersionError implements Exception {
  final String message;

  TraceVersionError(this.message);

  @override
  String toString() => 'TraceVersionError: $message';
}

/// Ensures distinct api request refs across contexts of the same trace.
int _lastApiRequestRefOrdinal = 0;

/// Reads the lines of one `.trace` (and `.network`) file into one
/// [ContextEntry], modernizing each line on the way in.
class TraceModernizer {
  final ContextEntry _contextEntry;
  final SnapshotStorage _snapshotStorage;
  final Map<String, ActionEntry> _actionMap = <String, ActionEntry>{};
  int? _version;
  final Map<String, PageEntry> _pageEntries = <String, PageEntry>{};
  final Map<String, Map<String, dynamic>> _jsHandles =
      <String, Map<String, dynamic>>{};
  final Map<String, Map<String, dynamic>> _consoleObjects =
      <String, Map<String, dynamic>>{};
  String? _apiRequestRef;
  final Map<String, ActionPhase> _snapshotPhases = <String, ActionPhase>{};
  final Map<String, String> _legacyCallIdToStepId = <String, String>{};

  TraceModernizer(this._contextEntry, this._snapshotStorage);

  /// Appends the whole content of a `.trace` or `.network` file, one JSON
  /// object per line.
  void appendTrace(String trace) {
    for (final line in trace.split('\n')) {
      _appendEvent(line);
    }
  }

  /// Appends a `.stacks` file, attaching a stack to every action that has
  /// none of its own.
  ///
  /// The ids in that file are the ones the client minted, which for traces
  /// before version 10 are not the ids the actions ended up with; the map
  /// `_modernize_9_to_10` built while reading the trace is what reconciles
  /// them, so this must run after [appendTrace].
  void appendStacks(String stacks) {
    final data = jsonDecode(stacks) as Map<String, dynamic>;
    final normalized = <SerializedStack>[];
    for (final stack in (data['stacks'] as List? ?? const [])) {
      final entry = (stack as List).toList();
      if (entry.isEmpty) continue;
      // Transform legacy numeric call ids into string ids.
      final rawId = entry[0];
      final callId =
          rawId is num ? legacyCallId(rawId.toInt()) : rawId as String;
      entry[0] = _legacyCallIdToStepId[callId] ?? callId;
      normalized.add(entry);
    }
    final callMetadata = parseClientSideCallMetadata(
      SerializedClientSideCallMetadata(
        files: (data['files'] as List? ?? const []).cast<String>(),
        stacks: normalized,
      ),
    );
    for (final action in _actionMap.values) {
      action.stack ??= callMetadata[action.callId];
    }
  }

  /// The actions read so far, in the order they were opened.
  List<ActionEntry> actions() => _actionMap.values.toList();

  void _collectSnapshotPhase(Object? snapshotName, ActionPhase phase) {
    if (snapshotName is String && snapshotName.isNotEmpty) {
      _snapshotPhases[snapshotName] = phase;
    }
  }

  PageEntry _pageEntry(String pageId) {
    var pageEntry = _pageEntries[pageId];
    if (pageEntry == null) {
      pageEntry = PageEntry(pageId: pageId);
      _pageEntries[pageId] = pageEntry;
      _contextEntry.pages.add(pageEntry);
    }
    return pageEntry;
  }

  void _appendEvent(String line) {
    if (line.isEmpty) return;
    final events = _modernize(jsonDecode(line) as Map<String, dynamic>);
    for (final event in events) {
      _innerAppendEvent(event);
    }
  }

  void _innerAppendEvent(Map<String, dynamic> json) {
    final contextEntry = _contextEntry;
    final event = TraceEvent.parse(json);
    switch (event) {
      case ContextCreatedTraceEvent():
        if (event.version > kLatestTraceVersion) {
          throw TraceVersionError(
              'The trace was created by a newer version of Playwright and is '
              'not supported by this version of the viewer. Please use latest '
              'Playwright to open the trace.');
        }
        _version = event.version;
        contextEntry.origin = event.origin;
        contextEntry.browserName = event.browserName;
        contextEntry.channel = event.channel;
        contextEntry.title = event.title;
        contextEntry.platform = event.platform;
        contextEntry.playwrightVersion = event.playwrightVersion;
        contextEntry.wallTime = event.wallTime;
        contextEntry.monotonicTime = event.monotonicTime;
        contextEntry.startTime = event.monotonicTime;
        contextEntry.sdkLanguage = event.sdkLanguage;
        contextEntry.options = event.options;
        contextEntry.testIdAttributeName = event.testIdAttributeName;
        contextEntry.testTimeout = event.testTimeout;
        contextEntry.annotations = event.annotations;
      case ScreencastFrameTraceEvent():
        _pageEntry(event.pageId).screencastFrames.add(event);
      case ScreenshotTraceEvent():
        contextEntry.screenshots.add(event);
      case VideoTraceEvent():
        contextEntry.videos.add(event);
      case AriaSnapshotTraceEvent():
        contextEntry.ariaSnapshots.add(event);
      case BeforeActionTraceEvent():
        _actionMap[event.callId] = ActionEntry.fromBefore(event);
      case InputActionTraceEvent():
        final existing = _actionMap[event.callId]!;
        existing.point = event.point;
        existing.box = event.box;
      case LogTraceEvent():
        final existing = _actionMap[event.callId];
        // We have some corrupted traces out there, tolerate them.
        if (existing == null) return;
        existing.log.add(ActionLogEntry(
          time: event.time,
          message: event.message,
        ));
      case AfterActionTraceEvent():
        final existing = _actionMap[event.callId]!;
        existing.endTime = event.endTime;
        existing.result = event.result;
        existing.error = event.error;
        existing.attachments = event.attachments;
        existing.annotations = event.annotations;
        if (event.point != null) existing.point = event.point;
      case ActionTraceEvent():
        _actionMap[event.callId] = ActionEntry.fromAction(event);
      case EventTraceEvent():
        // Make sure there is a page entry for each page.
        final pageId = event.paramsMap['pageId'];
        if ((event.method == 'page' || event.method == 'pageClosed') &&
            pageId is String &&
            pageId.isNotEmpty) {
          _pageEntry(pageId);
        }
        contextEntry.events.add(event);
      case StdioTraceEvent():
        contextEntry.stdio.add(event);
      case ErrorTraceEvent():
        contextEntry.errors.add(event);
      case ConsoleMessageTraceEvent():
        contextEntry.events.add(event);
      case ResourceSnapshotTraceEvent():
        _snapshotStorage.addResource(event.snapshot);
        contextEntry.resources.add(event.snapshot);
      case FrameSnapshotTraceEvent():
        final snapshot = event.snapshot;
        _snapshotStorage.addFrameSnapshot(
            snapshot, _pageEntry(snapshot.pageId).screencastFrames);
        if (snapshot.isMainFrame && snapshot.phase != null) {
          contextEntry.domSnapshots.add(DomSnapshotRef(
            callId: snapshot.callId,
            phase: snapshot.phase!,
          ));
        }
      case null:
        break;
    }

    // The bookkeeping below reads the event structurally, exactly as upstream
    // does on the parsed JSON object, so an event type this reader does not
    // model still moves the context clock.
    //
    // Make sure there is a page entry for each page, even without screencast
    // frames, to show in the metadata view.
    final pageId = json['pageId'];
    if (pageId is String && pageId.isNotEmpty) _pageEntry(pageId);
    final type = json['type'];
    if (type == 'action' || type == 'before') {
      contextEntry.startTime =
          _min(contextEntry.startTime, _number(json['startTime']));
    }
    if (type == 'action' || type == 'after') {
      contextEntry.endTime =
          _max(contextEntry.endTime, _number(json['endTime']));
    }
    if (type == 'event') {
      contextEntry.startTime =
          _min(contextEntry.startTime, _number(json['time']));
      contextEntry.endTime = _max(contextEntry.endTime, _number(json['time']));
    }
    if (type == 'screencast-frame') {
      contextEntry.startTime =
          _min(contextEntry.startTime, _number(json['timestamp']));
      contextEntry.endTime =
          _max(contextEntry.endTime, _number(json['timestamp']));
    }
  }

  bool _processedContextCreatedEvent() => _version != null;

  List<Map<String, dynamic>> _modernize(Map<String, dynamic> event) {
    // First record does not have this._version, but should have a version in
    // the event entry itself. Test traces before 7 (including 6) did not have
    // version in the first entry, run the modernizer for 6=>*.
    var version = _version ?? (event['version'] as num?)?.toInt() ?? 6;
    var events = <Map<String, dynamic>>[event];
    for (; version < kLatestTraceVersion; ++version) {
      final step = _steps[version];
      if (step == null) continue;
      events = step(this, events);
    }
    return events;
  }

  /// The chain, keyed by the version each step reads.
  static final Map<
      int,
      List<Map<String, dynamic>> Function(
          TraceModernizer, List<Map<String, dynamic>>)> _steps = <int,
      List<Map<String, dynamic>> Function(
          TraceModernizer, List<Map<String, dynamic>>)>{
    0: (m, e) => m.modernize0To1(e),
    1: (m, e) => m.modernize1To2(e),
    2: (m, e) => m.modernize2To3(e),
    3: (m, e) => m.modernize3To4(e),
    4: (m, e) => m.modernize4To5(e),
    5: (m, e) => m.modernize5To6(e),
    6: (m, e) => m.modernize6To7(e),
    7: (m, e) => m.modernize7To8(e),
    8: (m, e) => m.modernize8To9(e),
    9: (m, e) => m.modernize9To10(e),
  };

  /// `_modernize_0_to_1`: the error of an action used to be a bare string.
  List<Map<String, dynamic>> modernize0To1(List<Map<String, dynamic>> events) {
    for (final event in events) {
      if (event['type'] != 'action') continue;
      final metadata = event['metadata'];
      if (metadata is Map && metadata['error'] is String) {
        metadata['error'] = {
          'error': {'name': 'Error', 'message': metadata['error']},
        };
      }
    }
    return events;
  }

  /// `_modernize_1_to_2`: old versions had a completely wrong viewport on the
  /// main frame snapshot, so take the context's.
  List<Map<String, dynamic>> modernize1To2(List<Map<String, dynamic>> events) {
    for (final event in events) {
      if (event['type'] != 'frame-snapshot') continue;
      final snapshot = event['snapshot'];
      if (snapshot is! Map || snapshot['isMainFrame'] != true) continue;
      final viewport = _contextEntry.options.viewport;
      snapshot['viewport'] = viewport != null
          ? {'width': viewport.width, 'height': viewport.height}
          : {'width': 1280, 'height': 720};
    }
    return events;
  }

  /// `_modernize_2_to_3`: migrate from the old `ResourceSnapshot` to the HAR
  /// entry format.
  List<Map<String, dynamic>> modernize2To3(List<Map<String, dynamic>> events) {
    for (final event in events) {
      if (event['type'] != 'resource-snapshot') continue;
      final resource = event['snapshot'];
      if (resource is! Map || resource['request'] != null) continue;
      event['snapshot'] = <String, dynamic>{
        '_frameref': resource['frameId'],
        'request': <String, dynamic>{
          'url': resource['url'],
          'method': resource['method'],
          'headers': resource['requestHeaders'],
          'postData': resource['requestSha1'] != null
              ? {'_sha1': resource['requestSha1']}
              : null,
        },
        'response': <String, dynamic>{
          'status': resource['status'],
          'headers': resource['responseHeaders'],
          'content': <String, dynamic>{
            'mimeType': resource['contentType'],
            '_sha1': resource['responseSha1'],
          },
        },
        '_monotonicTime': resource['timestamp'],
      };
    }
    return events;
  }

  /// `_modernize_3_to_4`: unwrap `CallMetadata`.
  ///
  /// An action and an event were a `{ type, metadata }` pair; everything
  /// moves up one level, internal calls and the tracing calls themselves are
  /// dropped, and a created `ConsoleMessage` becomes an `object` event.
  List<Map<String, dynamic>> modernize3To4(List<Map<String, dynamic>> events) {
    final result = <Map<String, dynamic>>[];
    for (final event in events) {
      final e = modernizeEvent3To4(event);
      if (e != null) result.add(e);
    }
    return result;
  }

  /// One event of `_modernize_3_to_4`.
  Map<String, dynamic>? modernizeEvent3To4(Map<String, dynamic> event) {
    final type = event['type'];
    if (type != 'action' && type != 'event') return event;

    final metadata = (event['metadata'] as Map).cast<String, dynamic>();
    final method = metadata['method'] as String? ?? '';
    if (metadata['internal'] == true || method.startsWith('tracing')) {
      return null;
    }

    if (type == 'event') {
      if (method == '__create__' && metadata['type'] == 'ConsoleMessage') {
        final params = (metadata['params'] as Map?)?.cast<String, dynamic>() ??
            const <String, dynamic>{};
        return <String, dynamic>{
          'type': 'object',
          'class': metadata['type'],
          'guid': params['guid'],
          'initializer': params['initializer'],
        };
      }
      return <String, dynamic>{
        'type': 'event',
        'time': metadata['startTime'],
        'class': metadata['type'],
        'method': method,
        'params': metadata['params'],
        'pageId': metadata['pageId'],
      };
    }

    final snapshots = (metadata['snapshots'] as List? ?? const []);
    String? snapshotNamed(String title) {
      for (final snapshot in snapshots) {
        if (snapshot is Map && snapshot['title'] == title) {
          return snapshot['snapshotName'] as String?;
        }
      }
      return null;
    }

    final error = metadata['error'];
    return <String, dynamic>{
      'type': 'action',
      'callId': metadata['id'],
      'startTime': metadata['startTime'],
      'endTime': metadata['endTime'],
      'apiName': metadata['apiName'] ?? '${metadata['type']}.$method',
      'class': metadata['type'],
      'method': method,
      'params': metadata['params'],
      'wallTime': metadata['wallTime'] ?? DateTime.now().millisecondsSinceEpoch,
      'log': metadata['log'],
      'beforeSnapshot': snapshotNamed('before'),
      'inputSnapshot': snapshotNamed('input'),
      'afterSnapshot': snapshotNamed('after'),
      'error': error is Map ? error['error'] : null,
      'result': metadata['result'],
      'point': metadata['point'],
      'pageId': metadata['pageId'],
    };
  }

  /// `_modernize_4_to_5`: join the two halves of a console message.
  List<Map<String, dynamic>> modernize4To5(List<Map<String, dynamic>> events) {
    final result = <Map<String, dynamic>>[];
    for (final event in events) {
      final e = modernizeEvent4To5(event);
      if (e != null) result.add(e);
    }
    return result;
  }

  /// One event of `_modernize_4_to_5`.
  Map<String, dynamic>? modernizeEvent4To5(Map<String, dynamic> event) {
    final type = event['type'];
    if (type == 'event' &&
        event['method'] == '__create__' &&
        event['class'] == 'JSHandle') {
      final params = (event['params'] as Map?)?.cast<String, dynamic>();
      final guid = params?['guid'];
      final initializer = params?['initializer'];
      if (guid is String && initializer is Map) {
        _jsHandles[guid] = initializer.cast<String, dynamic>();
      }
    }
    if (type == 'object') {
      // We do not expect any other 'object' events.
      if (event['class'] != 'ConsoleMessage') return null;
      final initializer =
          (event['initializer'] as Map?)?.cast<String, dynamic>() ??
              const <String, dynamic>{};
      // Older traces might have `args` inherited from the protocol
      // initializer - the guid of a JSHandle - but might also have modern
      // `args` with preview and value.
      final rawArgs = initializer['args'] as List?;
      final args = rawArgs?.map((arg) {
        if (arg is Map && arg['guid'] != null) {
          final handle = _jsHandles[arg['guid']];
          return {'preview': handle?['preview'] ?? '', 'value': ''};
        }
        final map = arg is Map ? arg : const {};
        return {'preview': map['preview'] ?? '', 'value': map['value'] ?? ''};
      }).toList();
      _consoleObjects[event['guid'] as String? ?? ''] = <String, dynamic>{
        'type': initializer['type'],
        'text': initializer['text'],
        'location': initializer['location'],
        'args': args,
      };
      return null;
    }
    if (type == 'event' && event['method'] == 'console') {
      final params = (event['params'] as Map?)?.cast<String, dynamic>();
      final message = params?['message'];
      final guid = message is Map ? message['guid'] as String? : null;
      final consoleMessage = _consoleObjects[guid ?? ''];
      if (consoleMessage == null) return null;
      return <String, dynamic>{
        'type': 'console',
        'time': event['time'],
        'pageId': event['pageId'],
        'messageType': consoleMessage['type'],
        'text': consoleMessage['text'],
        'args': consoleMessage['args'],
        'location': consoleMessage['location'],
      };
    }
    return event;
  }

  /// `_modernize_5_to_6`: the action log leaves the `after` event.
  ///
  /// The lines had no time of their own, so they get -1, which is what
  /// upstream writes and what the UI has to tolerate.
  List<Map<String, dynamic>> modernize5To6(List<Map<String, dynamic>> events) {
    final result = <Map<String, dynamic>>[];
    for (final event in events) {
      result.add(event);
      if (event['type'] != 'after') continue;
      final log = event['log'] as List?;
      if (log == null || log.isEmpty) continue;
      for (final line in log) {
        result.add(<String, dynamic>{
          'type': 'log',
          'callId': event['callId'],
          'message': line,
          'time': -1,
        });
      }
    }
    return result;
  }

  /// `_modernize_6_to_7`: the context declares its origin and its clock, and
  /// an action gets the `stepId` side channel.
  List<Map<String, dynamic>> modernize6To7(List<Map<String, dynamic>> events) {
    final result = <Map<String, dynamic>>[];
    // A trace that starts with anything but a context event gets a synthetic
    // one. Upstream indexes `events[0]` here and would throw on an empty list,
    // which can only happen when the very first line was an internal call that
    // `_modernize_3_to_4` dropped; synthesizing the context is the same answer
    // one line later, so the empty case takes that path instead of crashing.
    if (!_processedContextCreatedEvent() &&
        (events.isEmpty || events[0]['type'] != 'context-options')) {
      result.add(<String, dynamic>{
        'type': 'context-options',
        'origin': 'testRunner',
        'version': 6,
        'browserName': '',
        'options': <String, dynamic>{},
        'platform': 'unknown',
        'wallTime': 0,
        'monotonicTime': 0,
        'sdkLanguage': 'javascript',
        'contextId': '',
      });
    }

    for (final event in events) {
      final type = event['type'];
      if (type == 'context-options') {
        result.add(<String, dynamic>{
          ...event,
          'monotonicTime': 0,
          'origin': 'library',
          'contextId': '',
        });
        continue;
      }
      if (type == 'before' || type == 'action') {
        if (_contextEntry.monotonicTime == 0) {
          _contextEntry.monotonicTime = _number(event['startTime']);
          _contextEntry.wallTime = _number(event['wallTime']);
        }
        event['stepId'] = '${event['apiName']}@${event['wallTime']}';
        result.add(event);
      } else {
        result.add(event);
      }
    }
    return result;
  }

  /// `_modernize_7_to_8`: `apiName` becomes the rendered `title`, and every
  /// action ends up with a `stepId`.
  List<Map<String, dynamic>> modernize7To8(List<Map<String, dynamic>> events) {
    final result = <Map<String, dynamic>>[];
    for (final event in events) {
      final type = event['type'];
      if (type == 'before' || type == 'action') {
        final apiName = event['apiName'];
        if (apiName != null) {
          event['title'] = apiName;
          event.remove('apiName');
        }
        event['stepId'] = event['stepId'] ?? event['callId'];
        result.add(event);
      } else {
        result.add(event);
      }
    }
    return result;
  }

  /// `_modernize_8_to_9`: phases replace snapshot names, and every blob stops
  /// being a bare sha1.
  List<Map<String, dynamic>> modernize8To9(List<Map<String, dynamic>> events) {
    for (final event in events) {
      final type = event['type'];
      // Actions used to point at their snapshots by name, now snapshots know
      // their own phase.
      if (type == 'before' ||
          type == 'input' ||
          type == 'after' ||
          type == 'action') {
        _collectSnapshotPhase(event['beforeSnapshot'], ActionPhase.before);
        _collectSnapshotPhase(event['inputSnapshot'], ActionPhase.action);
        _collectSnapshotPhase(event['afterSnapshot'], ActionPhase.after);
        event.remove('beforeSnapshot');
        event.remove('inputSnapshot');
        event.remove('afterSnapshot');
      }

      // Blobs used to be referenced by a bare sha1-style name, now they use a
      // trace-relative path.
      if (type == 'after' || type == 'action') {
        for (final attachment in (event['attachments'] as List? ?? const [])) {
          if (attachment is Map && attachment['sha1'] != null) {
            attachment['file'] = 'resources/${attachment['sha1']}';
            attachment.remove('sha1');
          }
        }
      }
      if (type == 'screencast-frame' && event['sha1'] != null) {
        event['file'] = 'resources/${event['sha1']}';
        event.remove('sha1');
      }

      if (type == 'frame-snapshot') {
        final snapshot = (event['snapshot'] as Map).cast<String, dynamic>();
        final snapshotName = snapshot['snapshotName'];
        if (snapshotName != null) {
          snapshot['phase'] = _snapshotPhases[snapshotName]?.wire;
        }
        for (final override
            in (snapshot['resourceOverrides'] as List? ?? const [])) {
          if (override is Map && override['sha1'] != null) {
            override['file'] = 'resources/${override['sha1']}';
            override.remove('sha1');
          }
        }
      }

      if (type == 'resource-snapshot') {
        final snapshot = (event['snapshot'] as Map).cast<String, dynamic>();
        final postData = (snapshot['request'] as Map?)?['postData'];
        if (postData is Map && postData['_sha1'] != null) {
          postData['_file'] = 'resources/${postData['_sha1']}';
          postData.remove('_sha1');
        }
        final content = (snapshot['response'] as Map?)?['content'];
        if (content is Map && content['_sha1'] != null) {
          content['_file'] = 'resources/${content['_sha1']}';
          content.remove('_sha1');
        }
        // Older hars marked api requests with a boolean instead of
        // referencing their api request context.
        if (snapshot['_apiRequest'] != null) {
          _apiRequestRef ??=
              'api-request-context@${++_lastApiRequestRefOrdinal}';
          snapshot['_apiRequestRef'] = _apiRequestRef;
          snapshot.remove('_apiRequest');
        }
      }
    }
    return events;
  }

  /// `_modernize_9_to_10`: the library and the test runner stop minting two
  /// ids for the same call.
  ///
  /// They used to reconcile through a `stepId` side channel; now they share a
  /// single id, so the step id is adopted as the call id and the mapping is
  /// remembered for the ids that [appendStacks] will see.
  List<Map<String, dynamic>> modernize9To10(List<Map<String, dynamic>> events) {
    for (final event in events) {
      final type = event['type'];
      if (type == 'before' || type == 'action') {
        final stepId = event['stepId'];
        final callId = event['callId'];
        if (stepId is String && stepId != callId && callId is String) {
          _legacyCallIdToStepId[callId] = stepId;
        }
        event.remove('stepId');
        final parentId = event['parentId'];
        if (parentId is String) {
          event['parentId'] = _legacyCallIdToStepId[parentId] ?? parentId;
        }
      }
      if (type == 'before' ||
          type == 'input' ||
          type == 'after' ||
          type == 'action' ||
          type == 'log') {
        final callId = event['callId'];
        if (callId is String) {
          event['callId'] = _legacyCallIdToStepId[callId] ?? callId;
        }
      }
      if (type == 'frame-snapshot') {
        final snapshot = (event['snapshot'] as Map).cast<String, dynamic>();
        final callId = snapshot['callId'];
        if (callId is String) {
          snapshot['callId'] = _legacyCallIdToStepId[callId] ?? callId;
        }
      }
    }
    return events;
  }
}

double _number(Object? value) => (value as num?)?.toDouble() ?? 0;

double _min(double a, double b) => a < b ? a : b;

double _max(double a, double b) => a > b ? a : b;

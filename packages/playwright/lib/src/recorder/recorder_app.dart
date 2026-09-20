// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source:
// packages/playwright-core/src/server/recorder/recorderApp.ts, the
// `ProgrammaticRecorderApp` half.

import 'dart:async';

import 'package:playwright_isomorphic/playwright_isomorphic.dart';

import 'recorder.dart';
import 'recorder_utils.dart';
import 'throttled_file.dart';

/// What happened to the recording, as the terminal app reports it.
enum RecorderEventKind {
  /// A new action was appended.
  actionAdded,

  /// The last action was replaced by a better version of itself: two fills of
  /// the same input are one fill.
  actionUpdated,

  /// A navigation, popup, download or dialog attached to the last action.
  signalAdded,
}

/// One change to the recording, with the code that expresses it.
class RecorderEvent {
  final RecorderEventKind kind;
  final ActionInContext actionInContext;

  /// The generated source of [actionInContext], with its signals.
  final String code;

  const RecorderEvent(this.kind, this.actionInContext, this.code);
}

/// Collects what a [Recorder] records and turns it into source code.
///
/// This is upstream's `ProgrammaticRecorderApp`: the recorder without a user
/// interface, which is the shape that fits a terminal. It keeps the whole
/// recording so it can regenerate the file, and it also emits one
/// [RecorderEvent] per change so a caller can print the code as it appears.
class RecorderCollection {
  final Recorder recorder;

  /// The generator the whole file is produced with.
  final LanguageGenerator generator;

  /// A second instance of the same generator, for the one-action-at-a-time
  /// output. A generator carries the page aliases it has handed out, and
  /// `generateCode` resets it; sharing one instance between the file and the
  /// running commentary would renumber the aliases under each other.
  final LanguageGenerator _incrementalGenerator;

  final LanguageGeneratorOptions options;

  /// Where the generated file is mirrored, if anywhere.
  final ThrottledFile? outputFile;

  final _actions = <ActionInContext>[];
  final _events = StreamController<RecorderEvent>.broadcast();
  final List<StreamSubscription<Object?>> _subscriptions = [];

  RecorderCollection({
    required this.recorder,
    required String generatorId,
    required this.options,
    this.outputFile,
  })  : generator = generatorById(generatorId),
        _incrementalGenerator = generatorById(generatorId) {
    _subscriptions.add(recorder.onAction.listen(_onActionAdded));
    _subscriptions.add(recorder.onSignal.listen(_onSignalAdded));
  }

  /// One event per change to the recording.
  Stream<RecorderEvent> get events => _events.stream;

  /// Every action recorded so far, merged the way the generators want them.
  List<ActionInContext> get actions => collapseActions(_actions);

  /// The whole file as it stands.
  GeneratedCode generate() => generateCode(actions, generator, options);

  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    outputFile?.flush();
    await _events.close();
  }

  void _onActionAdded(ActionInContext action) {
    final last = _actions.isEmpty ? null : _actions.last;
    var kind = RecorderEventKind.actionAdded;
    var recorded = action;
    if (shouldMergeAction(action, last)) {
      kind = RecorderEventKind.actionUpdated;
      // Signals already reported for the superseded action still belong to
      // this one.
      recorded = ActionInContext(
        pageGuid: action.pageGuid,
        action: action.action,
        signals: [...last!.signals, ...action.signals],
      );
      _actions[_actions.length - 1] = recorded;
    } else {
      recorded = ActionInContext(
        pageGuid: action.pageGuid,
        action: action.action,
        signals: [...action.signals],
      );
      _actions.add(recorded);
    }
    _emit(kind, recorded);
  }

  void _onSignalAdded(SignalInContext signal) {
    ActionInContext? lastAction;
    for (var i = _actions.length - 1; i >= 0; i--) {
      if (_actions[i].pageGuid == signal.pageGuid) {
        lastAction = _actions[i];
        break;
      }
    }
    if (lastAction == null) return;
    lastAction.signals.add(signal.signal);
    _emit(RecorderEventKind.signalAdded, lastAction);
  }

  void _emit(RecorderEventKind kind, ActionInContext actionInContext) {
    final code = _incrementalGenerator.generateAction(actionInContext, options);
    outputFile?.setContent(generate().text);
    if (!_events.isClosed) {
      _events.add(RecorderEvent(kind, actionInContext, code));
    }
  }
}

/// The generator with this id, or the Dart test-runner one when the id is not
/// a generator this build has.
LanguageGenerator generatorById(String id) {
  final generators = languageSet();
  for (final generator in generators) {
    if (generator.id == id) return generator;
  }
  return generators.first;
}

/// Every generator id the `codegen` command accepts, in the order the recorder
/// offers them.
List<String> generatorIds() => [for (final g in languageSet()) g.id];

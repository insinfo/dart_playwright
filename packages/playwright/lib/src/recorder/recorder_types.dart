// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/recorder/src/recorderTypes.d.ts.

import 'dart:convert';

/// What the recorder is doing right now.
///
/// These are upstream's mode strings verbatim: they cross the binding to the
/// page and back, so they are not an enum.
abstract final class RecorderMode {
  /// Nothing: no toolbar, no highlight, no recording.
  static const String none = 'none';

  /// The toolbar is up but nothing is being recorded.
  static const String standby = 'standby';

  /// Picking a locator, without recording.
  static const String inspecting = 'inspecting';

  /// Recording actions.
  static const String recording = 'recording';

  /// Recording, with the locator picker on.
  static const String recordingInspecting = 'recording-inspecting';

  /// Picking an element to assert its text.
  static const String assertingText = 'assertingText';

  /// Picking an element to assert that it is visible.
  static const String assertingVisibility = 'assertingVisibility';

  /// Picking an element to assert its value.
  static const String assertingValue = 'assertingValue';

  /// Picking an element to assert its aria snapshot.
  static const String assertingSnapshot = 'assertingSnapshot';

  /// The modes in which the page half records what the user does.
  static const List<String> recordingModes = [
    recording,
    assertingText,
    assertingVisibility,
    assertingValue,
    assertingSnapshot,
  ];

  static bool isRecording(String mode) => recordingModes.contains(mode);
}

/// Where the user dragged the floating toolbar to.
class OverlayState {
  final num offsetX;

  const OverlayState({this.offsetX = 0});

  factory OverlayState.fromJson(Map<String, Object?> json) =>
      OverlayState(offsetX: (json['offsetX'] as num?) ?? 0);

  Map<String, Object?> toJson() => {'offsetX': offsetX};
}

/// What the page half polls for once a second.
class RecorderUiState {
  final String mode;
  final String language;
  final String testIdAttributeName;
  final OverlayState overlay;

  const RecorderUiState({
    required this.mode,
    required this.language,
    required this.testIdAttributeName,
    required this.overlay,
  });

  Map<String, Object?> toJson() => {
        'mode': mode,
        'language': language,
        'testIdAttributeName': testIdAttributeName,
        'overlay': overlay.toJson(),
      };
}

/// What the locator picker hands back.
class ElementInfo {
  final String selector;
  final String? ariaSnapshot;

  const ElementInfo({required this.selector, this.ariaSnapshot});

  @override
  String toString() => selector;
}

/// One generated source file, as the recorder sees it.
///
/// Upstream's `Source` also carries highlight lines and the paused-source id,
/// both of which belong to the debugger this port does not have.
class RecorderSource {
  /// The generator id, such as `dart-test`.
  final String id;

  /// The name shown to the user, such as `Test Runner`.
  final String label;

  /// The language group, such as `Dart`.
  final String group;

  /// The whole file.
  final String text;

  final String header;
  final String footer;

  /// One entry per recorded action, in order.
  final List<String> actions;

  const RecorderSource({
    required this.id,
    required this.label,
    required this.group,
    required this.text,
    required this.header,
    required this.footer,
    required this.actions,
  });
}

/// Decodes what the page sends, which is JSON that came through a binding.
Map<String, Object?> asJsonMap(Object? value) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) return value.cast<String, Object?>();
  if (value is String) return jsonDecode(value) as Map<String, Object?>;
  return const <String, Object?>{};
}

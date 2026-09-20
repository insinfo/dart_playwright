// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/isomorphic/trace/traceUtils.ts

/// The `.stacks` side file: a stack table, shared by every action.
///
/// A trace that recorded sources writes one `.stacks` entry per chunk holding
/// `{ files, stacks }`, where a frame is the four-element array
/// `[fileOrdinal, line, column, function]`. Keeping the file names in one
/// table is what stops a hundred-action trace from repeating the same path a
/// thousand times.
library;

import 'dart:math';

import 'trace.dart';

/// `SerializedStackFrame`: `[fileOrdinal, line, column, function]`.
typedef SerializedStackFrame = List<Object?>;

/// `SerializedStack`: `[callId, frames]`.
typedef SerializedStack = List<Object?>;

/// `SerializedClientSideCallMetadata`: the whole `.stacks` file.
class SerializedClientSideCallMetadata {
  final List<String> files;
  final List<SerializedStack> stacks;

  const SerializedClientSideCallMetadata({
    required this.files,
    required this.stacks,
  });

  factory SerializedClientSideCallMetadata.fromJson(
          Map<String, dynamic> json) =>
      SerializedClientSideCallMetadata(
        files: (json['files'] as List?)?.map((e) => e as String).toList() ??
            <String>[],
        stacks: (json['stacks'] as List?)?.cast<List<Object?>>().toList() ??
            <SerializedStack>[],
      );

  Map<String, dynamic> toJson() => {'files': files, 'stacks': stacks};
}

int _lastIdOrdinal = 0;

/// `createCallIdGenerator()`: ids that will not clash inside one trace.
///
/// Every client prefixes its ordinals with four random letters, because a
/// trace can carry the calls of more than one client.
String Function() createCallIdGenerator([Random? random]) {
  const alphabet = 'abcdefghijklmnopqrstuvwxyz';
  final rng = random ?? Random();
  var prefix = '';
  for (var i = 0; i < 4; i++) {
    prefix += alphabet[rng.nextInt(alphabet.length)];
  }
  return () => '$prefix@${++_lastIdOrdinal}';
}

/// `legacyCallId(ordinal)`: the id format of traces recorded before call ids
/// became strings.
String legacyCallId(int ordinal) => 'call@$ordinal';

/// `parseClientSideCallMetadata(data)`: expands the stack table into a stack
/// per call id.
Map<String, List<StackFrame>> parseClientSideCallMetadata(
    SerializedClientSideCallMetadata data) {
  final result = <String, List<StackFrame>>{};
  for (final stack in data.stacks) {
    if (stack.isEmpty) continue;
    final id = stack[0] as String;
    final frames = (stack.length > 1 ? stack[1] as List? : null) ?? const [];
    result[id] = [
      for (final frame in frames)
        if (frame is List)
          StackFrame(
            file: _fileAt(data.files, frame.isNotEmpty ? frame[0] : null),
            line: frame.length > 1 ? ((frame[1] as num?)?.toInt() ?? 0) : 0,
            column: frame.length > 2 ? ((frame[2] as num?)?.toInt() ?? 0) : 0,
            function: frame.length > 3 ? frame[3] as String? : null,
          ),
    ];
  }
  return result;
}

String _fileAt(List<String> files, Object? ordinal) {
  final index = (ordinal as num?)?.toInt() ?? -1;
  return index >= 0 && index < files.length ? files[index] : '';
}

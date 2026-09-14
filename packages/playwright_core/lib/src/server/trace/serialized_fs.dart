// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/utils/serializedFS.ts

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

/// One entry of the resulting trace archive: the name it gets inside the zip
/// and the file on disk it is read from.
class TraceZipEntry {
  final String name;
  final String path;
  const TraceZipEntry(this.name, this.path);
}

/// Pending appends are flushed once they reach this size.
const _appendChunkSize = 64 * 1024;

/// Every write the tracer makes goes through here, in order.
///
/// The tracer is driven by browser events, and an event handler must never
/// await: a failed future born inside `EventEmitter.emit` has nobody to catch
/// it and the error disappears. So each operation is *enqueued* synchronously
/// and a single chain drains the queue. Failures are kept in [_error] and
/// surface on the next [sync], which is awaited from a real API call — the one
/// place where throwing reaches the caller.
class SerializedFs {
  final _buffers = <String, List<String>>{};
  final _operations = <_FsOperation>[];
  Object? _error;
  StackTrace? _errorStack;
  Completer<void>? _draining;

  void mkdir(String dir) => _append(_FsOperation.mkdir(dir));

  void writeFile(String file, List<int> content, {bool skipIfExists = false}) {
    // The buffered appends are about to be overwritten; drop them.
    _buffers.remove(file);
    _append(_FsOperation.writeFile(file, content, skipIfExists));
  }

  void writeText(String file, String content) =>
      writeFile(file, _utf8Bytes(content));

  /// Appends [text] to [file]. With [flush] the append is enqueued at once,
  /// otherwise it accumulates until [_appendChunkSize].
  void appendFile(String file, String text, {bool flush = false}) {
    final buffer = _buffers.putIfAbsent(file, () => <String>[]);
    buffer.add(text);
    var size = 0;
    for (final chunk in buffer) {
      size += chunk.length;
    }
    if (flush || size >= _appendChunkSize) _flushFile(file);
  }

  void copyFile(String from, String to) {
    _flushFile(from);
    _buffers.remove(to);
    _append(_FsOperation.copyFile(from, to));
  }

  /// Writes the zip once every queued write has landed, so no file changes
  /// while it is being read.
  void zip(List<TraceZipEntry> entries, String zipFileName) {
    for (final file in _buffers.keys.toList()) {
      _flushFile(file);
    }
    _append(_FsOperation.zip(entries, zipFileName));
  }

  void removeDirectory(String dir) => _append(_FsOperation.rmdir(dir));

  /// Waits for the queue to drain and rethrows the first failure, if any.
  Future<void> sync() async {
    for (final file in _buffers.keys.toList()) {
      _flushFile(file);
    }
    while (_draining != null) {
      await _draining!.future;
    }
    final error = _error;
    if (error != null) {
      _error = null;
      final stack = _errorStack;
      _errorStack = null;
      Error.throwWithStackTrace(error, stack ?? StackTrace.current);
    }
  }

  void _flushFile(String file) {
    final buffer = _buffers.remove(file);
    if (buffer == null) return;
    _append(_FsOperation.appendFile(file, buffer.join()));
  }

  void _append(_FsOperation op) {
    final last = _operations.isEmpty ? null : _operations.last;
    if (last != null &&
        last.kind == _FsOpKind.appendFile &&
        op.kind == _FsOpKind.appendFile &&
        last.file == op.file &&
        last.text!.length < _appendChunkSize) {
      last.text = last.text! + op.text!;
      return;
    }
    _operations.add(op);
    if (_draining == null) unawaited(_drain());
  }

  /// Never throws: a failure is recorded and rethrown from [sync].
  Future<void> _drain() async {
    final done = Completer<void>();
    _draining = done;
    try {
      while (_operations.isNotEmpty) {
        final op = _operations.removeAt(0);
        // Once something failed the trace is incomplete anyway; skip the rest
        // instead of piling up errors.
        if (_error != null) continue;
        try {
          await _perform(op);
        } catch (error, stack) {
          _error = error;
          _errorStack = stack;
        }
      }
    } finally {
      _draining = null;
      done.complete();
    }
  }

  Future<void> _perform(_FsOperation op) async {
    switch (op.kind) {
      case _FsOpKind.mkdir:
        await Directory(op.file!).create(recursive: true);
        return;
      case _FsOpKind.writeFile:
        final file = File(op.file!);
        if (op.skipIfExists && file.existsSync()) return;
        await file.parent.create(recursive: true);
        await file.writeAsBytes(op.bytes!, flush: false);
        return;
      case _FsOpKind.appendFile:
        final file = File(op.file!);
        await file.parent.create(recursive: true);
        await file.writeAsString(op.text!, mode: FileMode.append, flush: false);
        return;
      case _FsOpKind.copyFile:
        await File(op.file!).copy(op.target!);
        return;
      case _FsOpKind.rmdir:
        final dir = Directory(op.file!);
        if (dir.existsSync()) await dir.delete(recursive: true);
        return;
      case _FsOpKind.zip:
        await _writeZip(op.entries!, op.target!);
        return;
    }
  }

  Future<void> _writeZip(
      List<TraceZipEntry> entries, String zipFileName) async {
    await File(zipFileName).parent.create(recursive: true);
    final encoder = ZipFileEncoder();
    encoder.create(zipFileName);
    try {
      for (final entry in entries) {
        final file = File(entry.path);
        // A resource can be referenced by the stream and never have been
        // written (an aborted response, a blob the engine never handed over).
        // Skipping it keeps the archive readable instead of failing the whole
        // export.
        if (!file.existsSync()) continue;
        await encoder.addFile(file, p.posix.joinAll(p.split(entry.name)));
      }
    } finally {
      await encoder.close();
    }
  }

  static Uint8List _utf8Bytes(String s) => Uint8List.fromList(utf8.encode(s));
}

enum _FsOpKind { mkdir, writeFile, appendFile, copyFile, zip, rmdir }

class _FsOperation {
  final _FsOpKind kind;
  final String? file;
  final String? target;
  String? text;
  final List<int>? bytes;
  final bool skipIfExists;
  final List<TraceZipEntry>? entries;

  _FsOperation._(this.kind,
      {this.file,
      this.target,
      this.text,
      this.bytes,
      this.skipIfExists = false,
      this.entries});

  factory _FsOperation.mkdir(String dir) =>
      _FsOperation._(_FsOpKind.mkdir, file: dir);
  factory _FsOperation.rmdir(String dir) =>
      _FsOperation._(_FsOpKind.rmdir, file: dir);
  factory _FsOperation.writeFile(
          String file, List<int> bytes, bool skipIfExists) =>
      _FsOperation._(_FsOpKind.writeFile,
          file: file, bytes: bytes, skipIfExists: skipIfExists);
  factory _FsOperation.appendFile(String file, String text) =>
      _FsOperation._(_FsOpKind.appendFile, file: file, text: text);
  factory _FsOperation.copyFile(String from, String to) =>
      _FsOperation._(_FsOpKind.copyFile, file: from, target: to);
  factory _FsOperation.zip(List<TraceZipEntry> entries, String zipFileName) =>
      _FsOperation._(_FsOpKind.zip, entries: entries, target: zipFileName);
}

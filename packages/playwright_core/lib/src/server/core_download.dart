import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

/// A file the page started downloading.
///
/// The browser writes the file under the context's downloads directory named
/// by its own id, not by the suggested name — that is what keeps two
/// downloads of `report.pdf` from overwriting each other. [suggestedFilename]
/// is what the site asked it to be called, and [saveAs] is how it gets there.
class CoreDownload {
  /// The engine's id for this download.
  final String uuid;

  /// The URL the download came from.
  final String url;

  /// Where the browser is writing the file.
  final String downloadPath;

  final Completer<String?> _finished = Completer<String?>();
  final Future<void> Function() _cancel;

  String? _suggestedFilename;
  bool _canceled = false;

  CoreDownload({
    required this.uuid,
    required this.url,
    required this.downloadPath,
    required Future<void> Function() cancel,
    String? suggestedFilename,
  })  : _cancel = cancel,
        _suggestedFilename = suggestedFilename;

  /// The filename the site suggested, or an empty string when the engine has
  /// not said yet. WebKit reports it in a second event, after the download
  /// has already been created.
  String get suggestedFilename => _suggestedFilename ?? '';

  /// Records the suggested filename when it arrives late.
  void filenameSuggested(String filename) {
    _suggestedFilename ??= filename;
  }

  /// Whether the download was cancelled.
  bool get isCanceled => _canceled;

  /// Marks the download finished. [error] is null on success.
  void markFinished([String? error]) {
    if (error != null && error.isNotEmpty) _canceled = error == 'canceled';
    if (!_finished.isCompleted) _finished.complete(error);
  }

  /// Completes when the download ends, with the error text or null.
  Future<String?> failure() => _finished.future;

  /// The path of the finished file, or null when the download failed.
  Future<String?> path() async {
    final error = await _finished.future;
    if (error != null && error.isNotEmpty) return null;
    return downloadPath;
  }

  /// Copies the finished file to [target], creating parent directories.
  ///
  /// Throws when the download failed, carrying the engine's error text: a
  /// silent no-op would leave the caller with a missing file and no reason.
  Future<void> saveAs(String target) async {
    final error = await _finished.future;
    if (error != null && error.isNotEmpty) {
      throw StateError('Download failed: $error');
    }
    final destination = File(p.normalize(File(target).absolute.path));
    await destination.parent.create(recursive: true);
    await File(downloadPath).copy(destination.path);
  }

  /// Cancels a download still in flight. Finished downloads are unaffected.
  Future<void> cancel() => _cancel();

  /// Deletes the downloaded file.
  Future<void> delete() async {
    final file = File(downloadPath);
    if (await file.exists()) await file.delete();
  }
}

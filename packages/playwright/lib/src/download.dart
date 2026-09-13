import 'package:playwright_core/src/server/core_page.dart' show CoreDownload;

/// A file the page started downloading.
///
/// The browser writes it under the context's downloads directory named by an
/// internal id, not by [suggestedFilename] — that is what keeps two downloads
/// of `report.pdf` from overwriting each other. Use [saveAs] to put it where
/// you want it.
///
/// The file is deleted when the browser closes, so read or save it before
/// then.
abstract class Download {
  /// The URL the download came from.
  String url();

  /// The filename the site suggested.
  ///
  /// Empty until the engine reports it; WebKit sends it in a second event,
  /// slightly after the download appears.
  String suggestedFilename();

  /// The path of the finished file, or null when the download failed.
  ///
  /// Waits for the download to end.
  Future<String?> path();

  /// Copy the finished file to [target], creating parent directories.
  ///
  /// Waits for the download to end, and throws when it failed.
  Future<void> saveAs(String target);

  /// The failure text, or null when the download succeeded.
  ///
  /// Waits for the download to end.
  Future<String?> failure();

  /// Cancel a download still in flight.
  Future<void> cancel();

  /// Delete the downloaded file.
  Future<void> delete();
}

class DownloadImpl implements Download {
  final CoreDownload _download;

  DownloadImpl(this._download);

  @override
  String url() => _download.url;

  @override
  String suggestedFilename() => _download.suggestedFilename;

  @override
  Future<String?> path() => _download.path();

  @override
  Future<void> saveAs(String target) => _download.saveAs(target);

  @override
  Future<String?> failure() => _download.failure();

  @override
  Future<void> cancel() => _download.cancel();

  @override
  Future<void> delete() => _download.delete();
}

import 'dart:io';
import 'package:archive/archive.dart';
import 'package:path/path.dart' as path;
import 'package:playwright_protocol/playwright_protocol.dart';

import 'registry.dart';

/// Utility to fetch and extract browser binaries from the Playwright CDN.
class BrowserFetcher {
  /// Download and extract a browser zip file.
  static Future<void> downloadAndExtract({
    required String url,
    required String destinationDir,
    void Function(double progress)? onProgress,
  }) async {
    final tempFile = File(path.join(
      Directory.systemTemp.path,
      'playwright_download_${DateTime.now().millisecondsSinceEpoch}.zip',
    ));

    try {
      await _downloadFile(url, tempFile, onProgress: onProgress);
      await _extractZip(tempFile, destinationDir);
    } finally {
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
    }
  }

  /// Download with fallback to CDN mirrors.
  static Future<void> _downloadFile(
    String url,
    File destination, {
    void Function(double progress)? onProgress,
  }) async {
    final client = HttpClient();

    try {
      final mirrors = BrowserRegistry.cdnMirrors;
      PlaywrightException? lastError;

      for (int i = 0; i < mirrors.length; i++) {
        final mirror = mirrors[i];
        final fullUrl = '$mirror/$url';

        try {
          final request = await client.getUrl(Uri.parse(fullUrl));

          // Set up proxy if configured in environment
          final proxy = Platform.environment['HTTPS_PROXY'] ??
              Platform.environment['HTTP_PROXY'];
          if (proxy != null && proxy.isNotEmpty) {
            // HttpClient inherently respects HTTP_PROXY/HTTPS_PROXY environment variables
            // if client.findProxy is not overridden.
          }

          final response = await request.close();

          if (response.statusCode != 200) {
            throw PlaywrightException(
                'Failed to download from $fullUrl: HTTP ${response.statusCode}');
          }

          final totalBytes = response.contentLength;
          var downloadedBytes = 0;

          final sink = destination.openWrite();

          await for (final chunk in response) {
            sink.add(chunk);
            downloadedBytes += chunk.length;

            if (totalBytes > 0 && onProgress != null) {
              onProgress(downloadedBytes / totalBytes);
            }
          }

          await sink.close();
          return; // Success
        } on PlaywrightException catch (e) {
          lastError = e;
          if (i == mirrors.length - 1) rethrow;
        } catch (e) {
          lastError = PlaywrightException(e.toString());
          if (i == mirrors.length - 1) throw lastError;
        }
      }
      
      throw lastError ?? PlaywrightException('Download failed from all mirrors.');
    } finally {
      // force: true — do not let idle keep-alive connections hold the
      // event loop (and the whole CLI process) open after the download.
      client.close(force: true);
    }
  }

  /// Extract a zip file to the destination directory.
  ///
  /// On POSIX systems the system `unzip` is used: it is much faster than
  /// in-memory decoding and, crucially, preserves the executable bits of
  /// the many helper binaries browsers ship (pw_run.sh, crashpad handlers,
  /// subprocess launchers) which package:archive discards.
  static Future<void> _extractZip(File zipFile, String destination) async {
    if (!Platform.isWindows) {
      await Directory(destination).create(recursive: true);
      final result = await Process.run(
          'unzip', ['-q', '-o', zipFile.path, '-d', destination]);
      if (result.exitCode != 0) {
        throw PlaywrightException(
            'unzip failed (${result.exitCode}): ${result.stderr}');
      }
      return;
    }

    final bytes = await zipFile.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);

    for (final file in archive) {
      final filename = path.join(destination, file.name);

      if (file.isFile) {
        final outFile = File(filename);
        await outFile.create(recursive: true);
        await outFile.writeAsBytes(file.content as List<int>);
      } else {
        await Directory(filename).create(recursive: true);
      }
    }
  }
}

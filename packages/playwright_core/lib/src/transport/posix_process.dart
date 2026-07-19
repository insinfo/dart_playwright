import 'dart:io';
import 'dart:isolate';

import 'package:stdlibc/stdlibc.dart' as libc;

/// Launches a browser process on Linux/macOS with the Playwright fd3/fd4
/// inspector pipes attached.
///
/// Node's libuv hands the child real fds 3 and 4 backed by socketpairs.
/// Dart's Process.start cannot attach extra fds, so we reproduce the layout
/// with two named FIFOs and a `/bin/sh` wrapper that installs them as fd 3
/// (child reads commands) and fd 4 (child writes replies) before exec'ing
/// the browser — the child sees ordinary blocking pipe fds, exactly like
/// with libuv.
class PosixProcess {
  final Process process;

  /// Parent-side fd for writing protocol commands (child's fd 3).
  final int jugglerWriteFd;

  /// Parent-side fd for reading protocol replies (child's fd 4).
  final int jugglerReadFd;

  final Directory _fifoDir;
  bool _killed = false;

  PosixProcess._(
    this.process,
    this.jugglerWriteFd,
    this.jugglerReadFd,
    this._fifoDir,
  );

  int get processId => process.pid;

  void kill() {
    if (_killed) return;
    _killed = true;
    process.kill(ProcessSignal.sigkill);
    libc.close(jugglerWriteFd);
    libc.close(jugglerReadFd);
    try {
      _fifoDir.deleteSync(recursive: true);
    } catch (_) {}
  }

  static String _shQuote(String s) => "'${s.replaceAll("'", "'\\''")}'";

  static Future<PosixProcess> start(
      String executablePath, List<String> arguments) async {
    if (Platform.isWindows) {
      throw UnsupportedError('PosixProcess is not supported on Windows');
    }

    final fifoDir =
        Directory.systemTemp.createTempSync('playwright_dart_fifo_');
    final fifo3 = '${fifoDir.path}/fd3';
    final fifo4 = '${fifoDir.path}/fd4';

    if (libc.mkfifo(fifo3, 384 /* 0600 */) != 0 ||
        libc.mkfifo(fifo4, 384 /* 0600 */) != 0) {
      fifoDir.deleteSync(recursive: true);
      throw Exception('mkfifo failed: errno ${libc.errno}');
    }

    // sh performs the redirections left-to-right (fd3 first, fd4 second)
    // and then execs the browser, so the child ends up with plain pipe fds.
    final command = 'exec ${_shQuote(executablePath)} '
        '${arguments.map(_shQuote).join(' ')} '
        '3<${_shQuote(fifo3)} 4>${_shQuote(fifo4)}';

    final process = await Process.start('/bin/sh', ['-c', command]);
    // Drain stdio so the child never blocks on full pipe buffers.
    process.stdout.drain<void>().catchError((_) {});
    process.stderr.drain<void>().catchError((_) {});

    // Opening a FIFO blocks until the peer opens its end. The child opens
    // fifo3 (read) then fifo4 (write); we mirror that order. Each open runs
    // in a throwaway isolate and races against child exit so a browser that
    // crashes during startup surfaces as an error instead of a hang.
    int writeFd;
    int readFd;
    try {
      writeFd = await _openRendezvous(process, fifo3, libc.O_WRONLY);
      readFd = await _openRendezvous(process, fifo4, libc.O_RDONLY);
    } catch (e) {
      process.kill(ProcessSignal.sigkill);
      try {
        fifoDir.deleteSync(recursive: true);
      } catch (_) {}
      rethrow;
    }

    return PosixProcess._(process, writeFd, readFd, fifoDir);
  }

  /// Opens [path] with [flags], racing against [process] exiting first.
  ///
  /// If the child dies before opening its end, the blocked open() in the
  /// helper isolate is released by briefly opening complementary ends, so
  /// the isolate terminates instead of leaking.
  static Future<int> _openRendezvous(
      Process process, String path, int flags) async {
    final openFuture = Isolate.run(() => libc.open(path, flags: flags));

    final result = await Future.any<Object>([
      openFuture,
      process.exitCode.then((code) => _ChildExited(code)),
    ]);

    if (result is _ChildExited) {
      // Release the stuck open() in the helper isolate. A non-blocking read
      // open always succeeds on a FIFO; once a reader exists, a non-blocking
      // write open succeeds too. Together they satisfy whichever end the
      // helper is blocked on.
      final rdNb = libc.open(path, flags: libc.O_RDONLY | libc.O_NONBLOCK);
      final wrNb = libc.open(path, flags: libc.O_WRONLY | libc.O_NONBLOCK);
      final leakedFd = await openFuture
          .timeout(const Duration(seconds: 2), onTimeout: () => -1);
      if (leakedFd >= 0) libc.close(leakedFd);
      if (rdNb >= 0) libc.close(rdNb);
      if (wrNb >= 0) libc.close(wrNb);
      throw Exception(
          'Browser process exited with code ${result.code} before opening '
          'the inspector pipes');
    }

    final fd = result as int;
    if (fd < 0) {
      throw Exception('Failed to open FIFO $path: errno ${libc.errno}');
    }
    return fd;
  }
}

class _ChildExited {
  final int code;
  _ChildExited(this.code);
}

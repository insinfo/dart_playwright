import 'dart:io';

/// Kills the process tree rooted at [pid].
///
/// Killing only the process we spawned is not enough. All three engines fan
/// out into child processes — Chromium's renderer/GPU/network services,
/// Firefox's content processes, WebKit's web and network processes — and on
/// Windows a child is not killed with its parent. Those children are what
/// pile up: one abandoned browser leaves half a dozen live processes behind.
///
/// Upstream Playwright shells out to `taskkill /T /F` on win32 for the same
/// reason; on POSIX it signals the process group.
void killProcessTree(int pid) {
  if (pid <= 0) return;
  if (Platform.isWindows) {
    try {
      Process.runSync(
        'taskkill',
        ['/pid', '$pid', '/T', '/F'],
        runInShell: false,
      );
    } catch (_) {
      // taskkill missing or the process already gone: the direct kill the
      // caller also performs is the fallback.
    }
    return;
  }
  try {
    Process.killPid(pid, ProcessSignal.sigkill);
  } catch (_) {}
}

/// Every browser process this Dart process launched, and the signal handlers
/// that keep one from outliving us.
///
/// Nothing in Dart corresponds to Node's `process.on('exit')`, so a hard
/// `exit()` or a crash can still strand a browser. What is reachable — and
/// what was actually stranding them here — is interruption: Ctrl+C on a test
/// run left every live browser running, which is how orphans accumulated for
/// hours. Upstream installs the same handlers, gated by the same
/// `handleSIGINT`/`handleSIGTERM`/`handleSIGHUP` options.
class BrowserProcessRegistry {
  BrowserProcessRegistry._();

  static final _live = <int, void Function()>{};
  static final _watched = <ProcessSignal>{};
  static var _shuttingDown = false;

  /// Browser processes currently registered. Exposed for tests.
  static Iterable<int> get livePids => _live.keys;

  /// Records [pid] and the [kill] that reaps it, and arms the requested
  /// signal handlers. Registering is idempotent per pid.
  static void register(
    int pid,
    void Function() kill, {
    bool handleSIGINT = true,
    bool handleSIGTERM = true,
    bool handleSIGHUP = true,
  }) {
    _live[pid] = kill;
    if (handleSIGINT) _watch(ProcessSignal.sigint, 130);
    if (handleSIGTERM) _watch(ProcessSignal.sigterm, 143);
    if (handleSIGHUP) _watch(ProcessSignal.sighup, 129);
  }

  /// Forgets [pid]; the process has already been reaped.
  static void unregister(int pid) => _live.remove(pid);

  /// Kills every registered browser. Safe to call more than once.
  static void killAll() {
    _shuttingDown = true;
    for (final kill in _live.values.toList()) {
      try {
        kill();
      } catch (_) {}
    }
    _live.clear();
    _shuttingDown = false;
  }

  /// Windows has no POSIX signals: the VM maps Ctrl+C onto SIGINT and
  /// nothing onto SIGTERM or SIGHUP. Asking for those fails — and under the
  /// test runner it fails by delivering an error into the stream rather than
  /// by throwing — so they are never watched there.
  static bool _isWatchable(ProcessSignal signal) =>
      !Platform.isWindows || signal == ProcessSignal.sigint;

  static void _watch(ProcessSignal signal, int exitCode) {
    if (!_isWatchable(signal)) return;
    if (!_watched.add(signal)) return;
    try {
      signal.watch().listen(
        (_) {
          if (_shuttingDown) return;
          killAll();
          exit(exitCode);
        },
        // A platform that refuses the signal reports it here. Losing the
        // watch is the right outcome; letting the error escape would fail
        // whatever unrelated code happened to be launching a browser.
        onError: (Object _) => _watched.remove(signal),
        cancelOnError: true,
      );
    } catch (_) {
      _watched.remove(signal);
    }
  }
}

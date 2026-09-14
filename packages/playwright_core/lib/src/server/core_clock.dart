import 'core_browser.dart';
import 'core_page.dart';
import 'init_scripts.dart';
import 'injected/injected_clock_source.dart';

export 'injected/injected_clock_source.dart' show kClockProperty;

/// Deterministic time for every page of a browser context.
///
/// This is the driver half of the clock; the in-page half lives in
/// `injected/injected_clock_source.dart`, which explains how it works. What
/// matters here is the shape of every call: each one appends a `log(...)`
/// init script *and* evaluates the same command in the documents that are
/// already open. The init script is what carries the state across a
/// navigation — a document that has not loaded yet cannot be told anything,
/// so it is told afterwards, by replaying the log.
///
/// Upstream puts the clock on the browser context, and so does this port:
/// `page.clock` is the clock of the page's context. Faking time for one page
/// of a context and not the others is not something the engines offer.
class CoreClock {
  final CoreBrowserContext _context;

  /// `chromium`, `firefox` or `webkit`. Only `AbortSignal.timeout` reads it:
  /// Chromium words the abort reason differently from the other two.
  final String _browserName;

  /// The scripts installed so far. Empty means the clock was never installed,
  /// which is how [_installIfNeeded] knows to do the one-time work.
  final List<CoreInitScript> _initScripts = <CoreInitScript>[];

  CoreClock(this._context, this._browserName);

  /// Whether anything was installed yet.
  bool get isInstalled => _initScripts.isNotEmpty;

  /// Starts the fake clock at [timeMillis] (epoch milliseconds).
  Future<void> install(int timeMillis) =>
      _command('install', 'install($timeMillis)', timeMillis);

  /// Moves time forward by [ticksMillis], firing every timer on the way.
  Future<void> runFor(int ticksMillis) =>
      _command('runFor', 'runFor($ticksMillis)', ticksMillis);

  /// Jumps forward by [ticksMillis], collapsing pending timers onto the
  /// destination instead of firing each at its own moment.
  Future<void> fastForward(int ticksMillis) =>
      _command('fastForward', 'fastForward($ticksMillis)', ticksMillis);

  /// Runs time up to [timeMillis] and then stops it there.
  Future<void> pauseAt(int timeMillis) =>
      _command('pauseAt', 'pauseAt($timeMillis)', timeMillis);

  /// Lets time flow again after [pauseAt].
  Future<void> resume() => _command('resume', 'resume()', null);

  /// Freezes the wall clock at [timeMillis] without stopping timers.
  Future<void> setFixedTime(int timeMillis) =>
      _command('setFixedTime', 'setFixedTime($timeMillis)', timeMillis);

  /// Sets the wall clock to [timeMillis] and lets it keep running.
  Future<void> setSystemTime(int timeMillis) =>
      _command('setSystemTime', 'setSystemTime($timeMillis)', timeMillis);

  Future<void> _command(String logType, String call, int? param) async {
    await _installIfNeeded();
    final now = DateTime.now().millisecondsSinceEpoch;
    final logArgs = param == null ? '$now' : '$now, $param';
    _initScripts.add(await _context.addInitScript(
        "globalThis['$kClockProperty'].controller.log('$logType', $logArgs);"));
    await _evaluateInFrames("globalThis['$kClockProperty'].controller.$call");
  }

  Future<void> _installIfNeeded() async {
    if (_initScripts.isNotEmpty) return;
    final source = clockInstallSource(_browserName);
    // The order matters: register for future documents first, so a
    // navigation that starts while the live evaluation is in flight is
    // already covered.
    final script = await _context.addInitScript(source);
    _initScripts.add(script);
    await _evaluateInFrames(source);
  }

  /// Runs [script] in every frame of every page of the context.
  ///
  /// A failure in a page's main frame is the caller's business — asking to
  /// fast-forward into the past has to throw, not be swallowed. A failure in
  /// a child frame is not: a frame that navigated away mid-call would
  /// otherwise turn a correct command into an error, and the next document it
  /// loads gets the clock from the init script anyway.
  Future<void> _evaluateInFrames(String script) async {
    Object? mainFrameError;
    StackTrace? mainFrameStack;
    for (final page in _context.pages) {
      for (final frame in page.frames) {
        final isMainFrame = frame.parentId == null;
        try {
          final context = await page.executionContextFor(frame,
              timeout: const Duration(seconds: 5));
          await context.rawEvaluate(script);
        } catch (error, stack) {
          if (isMainFrame && mainFrameError == null) {
            mainFrameError = error;
            mainFrameStack = stack;
          }
        }
      }
    }
    if (mainFrameError != null) {
      Error.throwWithStackTrace(mainFrameError, mainFrameStack!);
    }
  }
}

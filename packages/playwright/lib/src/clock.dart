import 'package:playwright_core/src/server/core_clock.dart';

/// Deterministic time for the pages of a browser context.
///
/// The clock replaces `Date`, `setTimeout`, `setInterval`,
/// `requestAnimationFrame`, `requestIdleCallback`, `performance`,
/// `Intl.DateTimeFormat` and `AbortSignal.timeout` at the start of every
/// document, so a test can decide what "now" is and how fast it moves instead
/// of sleeping and hoping.
///
/// It is a property of the **context**, not of one page: `page.clock` and
/// `context.clock` are the same object, and faking time affects every page of
/// the context, including popups and pages opened later. That is how upstream
/// implements it too — none of the three engines can fake time for one page
/// of a context and not the others.
///
/// Two shapes of use, and they do not mix:
///
/// * **Frozen wall clock, running timers.** [setFixedTime] pins what
///   `Date.now()` answers while timers keep firing at their normal pace. This
///   is what you want when a page renders a timestamp and you need the
///   screenshot to be stable.
/// * **Controlled timers.** [install] starts the clock at a chosen instant
///   and hands the pace to the test: [runFor] moves time forward firing every
///   timer on the way, [fastForward] jumps and collapses the pending timers
///   onto the destination, [pauseAt] stops time at an instant and [resume]
///   lets it flow again.
///
/// [install] must come before the page loads to be worth much — call it, then
/// navigate. The state survives navigation and reload: each call is recorded
/// and replayed in the next document, real elapsed time included.
///
/// Upstream also accepts times and durations written as strings (`'2020-01-01'`,
/// `'30:00'`). Here they are [DateTime] and [Duration], which say the same
/// thing without a parser.
abstract class Clock {
  /// Installs the fake clock, starting at [time] (defaults to now).
  ///
  /// After this, timers only advance when the test says so — through
  /// [runFor], [fastForward], [pauseAt] or [resume]. Call it before
  /// navigating: a document that already ran its scripts keeps the timers it
  /// scheduled with the real ones.
  ///
  /// Calling it again just repositions the clock; the guard against two fake
  /// clocks stacked on one another lives in the page, against the install
  /// script running twice in the same document.
  Future<void> install({DateTime? time});

  /// Moves time forward by [ticks], firing every timer that comes due, in
  /// order, exactly as the page would have seen them.
  ///
  /// A timer that schedules another timer inside that window fires too, so
  /// this is what to use when the code under test chains timeouts.
  Future<void> runFor(Duration ticks);

  /// Jumps forward by [ticks] without living through it.
  ///
  /// Every pending timer is moved to the destination and fires there, once —
  /// an interval that would have ticked sixty times during the jump ticks
  /// once. Use [runFor] when those intermediate ticks are the point.
  Future<void> fastForward(Duration ticks);

  /// Runs time up to [time] and stops it there.
  ///
  /// Timers due before [time] fire on the way. After this, `Date.now()` keeps
  /// answering [time] until [resume] or another command moves it.
  Future<void> pauseAt(DateTime time);

  /// Lets time flow again at its normal pace after [pauseAt].
  Future<void> resume();

  /// Freezes what `Date.now()` and `new Date()` answer at [time], while
  /// timers keep running normally.
  ///
  /// This is the light-touch option: no timer behaviour changes, so a page
  /// that polls or animates keeps working while its clock reads a fixed
  /// instant. It does not need [install].
  Future<void> setFixedTime(DateTime time);

  /// Sets the wall clock to [time] and lets it keep running from there.
  Future<void> setSystemTime(DateTime time);
}

class ClockImpl implements Clock {
  final CoreClock _core;

  ClockImpl(this._core);

  @override
  Future<void> install({DateTime? time}) =>
      _core.install((time ?? DateTime.now()).millisecondsSinceEpoch);

  @override
  Future<void> runFor(Duration ticks) => _core.runFor(ticks.inMilliseconds);

  @override
  Future<void> fastForward(Duration ticks) =>
      _core.fastForward(ticks.inMilliseconds);

  @override
  Future<void> pauseAt(DateTime time) =>
      _core.pauseAt(time.millisecondsSinceEpoch);

  @override
  Future<void> resume() => _core.resume();

  @override
  Future<void> setFixedTime(DateTime time) =>
      _core.setFixedTime(time.millisecondsSinceEpoch);

  @override
  Future<void> setSystemTime(DateTime time) =>
      _core.setSystemTime(time.millisecondsSinceEpoch);
}

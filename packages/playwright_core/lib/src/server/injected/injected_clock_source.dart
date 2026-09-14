// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0, and from Sinon's lolex/@sinonjs/fake-timers,
// Copyright (c) 2010-2014 Christian Johansen, licensed under the 3-clause
// BSD licence. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/injected/src/clock.ts

/// The in-page clock: the code that replaces `Date`, `setTimeout`,
/// `setInterval`, `requestAnimationFrame`, `requestIdleCallback`,
/// `performance`, `Intl.DateTimeFormat` and `AbortSignal.timeout` at the
/// start of every document.
///
/// Two ideas carry the whole thing.
///
/// The first is that time has two axes: `ticks`, a monotonic counter the
/// fake timers are scheduled against, and `time`, the wall clock `Date.now()`
/// reports. `setFixedTime` freezes the second without stopping the first,
/// which is why a page can keep running its animation loop while `new Date()`
/// keeps answering the same instant.
///
/// The second is the log. A document that has not loaded yet cannot be told
/// anything, so every call the driver makes is *also* appended to an init
/// script as a `log(...)` line. When the next document installs this script,
/// the controller replays that log before answering its first question, and
/// lands in the state the previous document was left in — including the real
/// time that passed in between, measured with the native `Date.now()`.
///
/// Differences from upstream, all deliberate:
///
/// * `toFake` is not exposed: everything the port fakes is faked. Upstream's
///   option exists for its own tests.
/// * The `Builtins` bundle upstream hands to its injected script (so its
///   selector engine can keep using real timers) is not published here; the
///   selector engine of this port does not schedule anything.
library;

/// The property the controller lives on.
const String kClockProperty = '__pwDartClock';

/// Installs the clock. Evaluating it twice in one document is harmless: the
/// second run sees the property and returns.
const String kInjectedClockSource = r'''
const clockProperty = '__pwDartClock';
if (!globalThis[clockProperty]) {

// Timers are scheduled against `callAt`, a tick value. `maxTimeout` is what
// the HTML spec allows a delay to be; anything above it is clamped to 1, the
// same way a real browser does.
const maxTimeout = Math.pow(2, 31) - 1;
// Ids start absurdly high so that clearTimeout of a *native* id (one taken
// before the clock was installed) cannot hit one of ours by accident.
const idCounterStart = 1e12;

const kTimeout = 'Timeout';
const kInterval = 'Interval';
const kImmediate = 'Immediate';
const kAnimationFrame = 'AnimationFrame';
const kIdleCallback = 'IdleCallback';

function scheduleHandlerName(type) {
  if (type === kIdleCallback || type === kAnimationFrame)
    return 'request' + type;
  return 'set' + type;
}

function clearHandlerName(type) {
  if (type === kIdleCallback || type === kAnimationFrame)
    return 'cancel' + type;
  return 'clear' + type;
}

function compareTimers(a, b) {
  if (a.callAt < b.callAt)
    return -1;
  if (a.callAt > b.callAt)
    return 1;
  if (a.type === kImmediate && b.type !== kImmediate)
    return -1;
  if (a.type !== kImmediate && b.type === kImmediate)
    return 1;
  if (a.createdAt < b.createdAt)
    return -1;
  if (a.createdAt > b.createdAt)
    return 1;
  if (a.id < b.id)
    return -1;
  if (a.id > b.id)
    return 1;
  return 0;
}

class ClockController {
  constructor(embedder) {
    this._timers = new Map();
    this._duringTick = false;
    this._uniqueTimerId = idCounterStart;
    this._embedder = embedder;
    this._log = [];
    this._realTime = undefined;
    this._currentRealTimeTimer = undefined;
    this.disposables = [];
    // `origin` starts negative to mean "never installed"; the first
    // _innerSetTime pins it, and performance.timeOrigin reads it.
    this._now = { time: 0, isFixedTime: false, ticks: 0, origin: -1 };
  }

  uninstall() {
    for (const dispose of this.disposables)
      dispose();
    this.disposables.length = 0;
  }

  now() {
    this._replayLogOnce();
    // Syncing here is what lets a `while (Date.now() < deadline)` loop in the
    // page finish instead of spinning forever on a frozen clock.
    this._syncRealTime();
    return this._now.time;
  }

  performanceNow() {
    this._replayLogOnce();
    this._syncRealTime();
    return this._now.ticks;
  }

  install(time) {
    this._replayLogOnce();
    this._innerInstall(time);
  }

  setSystemTime(time) {
    this._replayLogOnce();
    this._innerSetTime(time);
  }

  setFixedTime(time) {
    this._replayLogOnce();
    this._innerSetFixedTime(time);
  }

  _syncRealTime() {
    if (!this._realTime)
      return;
    const now = this._embedder.performanceNow();
    const sinceLastSync = now - this._realTime.lastSyncTicks;
    if (sinceLastSync > 0) {
      this._advanceNow(this._now.ticks + sinceLastSync);
      this._realTime.lastSyncTicks = now;
    }
  }

  _innerSetTime(time) {
    this._now.time = time;
    this._now.isFixedTime = false;
    if (this._now.origin < 0)
      this._now.origin = this._now.time;
  }

  _innerInstall(time) {
    // On a fresh install the monotonic counter is reset, so drift the
    // real-time ticker accumulated before install() does not leak into
    // performance.now().
    if (this._now.origin < 0)
      this._now.ticks = 0;
    this._innerSetTime(time);
  }

  _innerSetFixedTime(time) {
    this._innerSetTime(time);
    this._now.isFixedTime = true;
  }

  _advanceNow(to) {
    if (this._now.ticks > to) {
      // While timers run, now() can advance by syncing with real time, so
      // `now` may already be past where we meant to move it.
      return;
    }
    if (!this._now.isFixedTime)
      this._now.time = this._now.time + to - this._now.ticks;
    this._now.ticks = to;
  }

  async log(type, time, param) {
    this._log.push({ type: type, time: time, param: param });
  }

  async runFor(ticks) {
    this._replayLogOnce();
    if (ticks < 0)
      throw new TypeError('Negative ticks are not supported');
    await this._runWithDisabledRealTimeSync(async () => {
      await this._runTo(this._now.ticks + ticks);
    });
  }

  async _runTo(to) {
    to = Math.ceil(to);
    if (this._now.ticks > to)
      return;

    let firstException = undefined;
    while (true) {
      const result = await this._callFirstTimer(to);
      if (!result.timerFound)
        break;
      firstException = firstException || result.error;
    }

    this._advanceNow(to);

    if (firstException)
      throw firstException;
  }

  async pauseAt(time) {
    this._replayLogOnce();
    await this._innerPause();
    const toConsume = time - this._now.time;
    await this._innerFastForwardTo(this._now.ticks + toConsume);
    return toConsume;
  }

  async _innerPause() {
    this._realTime = undefined;
    if (this._currentRealTimeTimer)
      await this._currentRealTimeTimer.dispose();
    this._currentRealTimeTimer = undefined;
  }

  resume() {
    this._replayLogOnce();
    this._innerResume();
  }

  _innerResume() {
    const now = this._embedder.performanceNow();
    this._realTime = { startTicks: now, lastSyncTicks: now };
    this._updateRealTimeTimer();
  }

  _updateRealTimeTimer() {
    if (this._currentRealTimeTimer && this._currentRealTimeTimer.promise) {
      // Already running; it reschedules itself once its promise settles.
      return;
    }

    const firstTimer = this._firstTimer();
    // Either run the next timer or move time forward in 100ms chunks.
    const nextTick = Math.min(
        firstTimer ? firstTimer.callAt : this._now.ticks + maxTimeout,
        this._now.ticks + 100);
    const callAt = this._currentRealTimeTimer
        ? Math.min(this._currentRealTimeTimer.callAt, nextTick)
        : nextTick;

    if (this._currentRealTimeTimer) {
      this._currentRealTimeTimer.cancel();
      this._currentRealTimeTimer = undefined;
    }

    const self = this;
    const realTimeTimer = {
      callAt: callAt,
      promise: undefined,
      cancel: this._embedder.setTimeout(() => {
        self._syncRealTime();
        realTimeTimer.promise = self._runTo(self._now.ticks).catch(() => {});
        void realTimeTimer.promise.then(() => {
          self._currentRealTimeTimer = undefined;
          if (self._realTime)
            self._updateRealTimeTimer();
        });
      }, callAt - this._now.ticks),
      dispose: async () => {
        realTimeTimer.cancel();
        await realTimeTimer.promise;
      },
    };

    this._currentRealTimeTimer = realTimeTimer;
  }

  async _runWithDisabledRealTimeSync(fn) {
    if (!this._realTime) {
      await fn();
      return;
    }
    await this._innerPause();
    try {
      await fn();
    } finally {
      this._innerResume();
    }
  }

  async fastForward(ticks) {
    this._replayLogOnce();
    await this._runWithDisabledRealTimeSync(async () => {
      await this._innerFastForwardTo(this._now.ticks + (ticks | 0));
    });
  }

  async _innerFastForwardTo(to) {
    if (to < this._now.ticks)
      throw new Error('Cannot fast-forward to the past');
    // Fast-forwarding *collapses* pending timers onto the destination instead
    // of running each one at its own moment: this is what makes it different
    // from runFor, where every intermediate tick fires.
    for (const timer of this._timers.values()) {
      if (to > timer.callAt)
        timer.callAt = to;
    }
    await this._runTo(to);
  }

  addTimer(options) {
    this._replayLogOnce();

    if (options.type === kAnimationFrame && !options.func)
      throw new Error('Callback must be provided to requestAnimationFrame calls');
    if (options.type === kIdleCallback && !options.func)
      throw new Error('Callback must be provided to requestIdleCallback calls');
    if ((options.type === kTimeout || options.type === kInterval) &&
        !options.func && options.delay === undefined)
      throw new Error('Callback must be provided to timer calls');

    let delay = options.delay ? +options.delay : 0;
    if (!Number.isFinite(delay))
      delay = 0;
    delay = delay > maxTimeout ? 1 : delay;
    delay = Math.max(0, delay);

    const timer = {
      type: options.type,
      func: options.func,
      args: options.args || [],
      delay: delay,
      // A timer scheduled from inside a timer callback must land strictly
      // after it, or a zero-delay loop would never make progress.
      callAt: this._now.ticks + (delay || (this._duringTick ? 1 : 0)),
      createdAt: this._now.ticks,
      id: this._uniqueTimerId++,
    };
    this._timers.set(timer.id, timer);
    if (this._realTime)
      this._updateRealTimeTimer();
    return timer.id;
  }

  countTimers() {
    return this._timers.size;
  }

  _firstTimer(beforeTick) {
    let firstTimer = null;
    for (const timer of this._timers.values()) {
      const isInRange = beforeTick === undefined || timer.callAt <= beforeTick;
      if (isInRange && (!firstTimer || compareTimers(firstTimer, timer) === 1))
        firstTimer = timer;
    }
    return firstTimer;
  }

  _takeFirstTimer(beforeTick) {
    const timer = this._firstTimer(beforeTick);
    if (!timer)
      return null;

    this._advanceNow(timer.callAt);

    if (timer.type === kInterval)
      timer.callAt = timer.callAt + timer.delay;
    else
      this._timers.delete(timer.id);
    return timer;
  }

  async _callFirstTimer(beforeTick) {
    const timer = this._takeFirstTimer(beforeTick);
    if (!timer)
      return { timerFound: false };

    this._duringTick = true;
    try {
      let error = undefined;
      if (typeof timer.func !== 'function') {
        // setTimeout('code string', ...). The scope is not the call site's,
        // which is already true of any eval-based timer.
        try {
          globalThis.eval(timer.func);
        } catch (e) {
          error = e;
        }
      } else {
        let args = timer.args;
        if (timer.type === kAnimationFrame)
          args = [this._now.ticks];
        else if (timer.type === kIdleCallback)
          args = [{ didTimeout: false, timeRemaining: () => 0 }];
        try {
          timer.func.apply(null, args);
        } catch (e) {
          error = e;
        }
      }
      // Yield to the real event loop so promises the callback created get a
      // chance to settle before the next timer runs.
      await new Promise(f => this._embedder.setTimeout(f));
      return { timerFound: true, error: error };
    } finally {
      this._duringTick = false;
    }
  }

  getTimeToNextFrame() {
    // requestAnimationFrame can be the page's very first call, so the log has
    // to be replayed here too.
    this._replayLogOnce();
    return 16 - this._now.ticks % 16;
  }

  clearTimer(timerId, type) {
    this._replayLogOnce();
    if (!timerId) {
      // Browsers accept a null id, and libraries rely on it.
      return;
    }
    const id = Number(timerId);
    const timer = this._timers.get(id);
    if (!timer)
      return;
    if (timer.type === type ||
        (timer.type === kTimeout && type === kInterval) ||
        (timer.type === kInterval && type === kTimeout)) {
      this._timers.delete(id);
    } else {
      throw new Error('Cannot clear timer: timer created with ' +
          scheduleHandlerName(timer.type) + '() but cleared with ' +
          clearHandlerName(type) + '()');
    }
  }

  _replayLogOnce() {
    if (!this._log.length)
      return;

    let lastLogTime = -1;
    let isPaused = false;

    for (const entry of this._log) {
      const type = entry.type;
      const time = entry.time;
      const param = entry.param;
      // Between two driver calls, real time passed. Unless the clock was
      // paused, that gap is replayed too, which is what makes a reload land
      // where the previous document would have been by now.
      if (!isPaused && lastLogTime !== -1)
        this._advanceNow(this._now.ticks + (time - lastLogTime));
      lastLogTime = time;

      if (type === 'install') {
        this._innerInstall(param);
      } else if (type === 'fastForward' || type === 'runFor') {
        this._advanceNow(this._now.ticks + param);
      } else if (type === 'pauseAt') {
        isPaused = true;
        this._innerSetTime(param);
      } else if (type === 'resume') {
        isPaused = false;
      } else if (type === 'setFixedTime') {
        this._innerSetFixedTime(param);
      } else if (type === 'setSystemTime') {
        this._innerSetTime(param);
      }
    }

    if (!isPaused) {
      if (lastLogTime > 0)
        this._advanceNow(this._now.ticks + (this._embedder.dateNow() - lastLogTime));
      this._innerResume();
    } else {
      this._realTime = undefined;
    }

    this._log.length = 0;
  }
}

function mirrorDateProperties(target, source) {
  for (const prop in source) {
    if (Object.prototype.hasOwnProperty.call(source, prop))
      target[prop] = source[prop];
  }
  target.toString = () => source.toString();
  target.prototype = source.prototype;
  target.parse = source.parse;
  target.UTC = source.UTC;
  target.prototype.toUTCString = source.prototype.toUTCString;
  target.isFake = true;
  return target;
}

function createDate(clock, NativeDate) {
  function ClockDate(year, month, date, hour, minute, second, ms) {
    // `Date()` without new returns a string, per the spec.
    if (!(this instanceof ClockDate))
      return new NativeDate(clock.now()).toString();
    switch (arguments.length) {
      case 0: return new NativeDate(clock.now());
      case 1: return new NativeDate(year);
      case 2: return new NativeDate(year, month);
      case 3: return new NativeDate(year, month, date);
      case 4: return new NativeDate(year, month, date, hour);
      case 5: return new NativeDate(year, month, date, hour, minute);
      case 6: return new NativeDate(year, month, date, hour, minute, second);
      default: return new NativeDate(year, month, date, hour, minute, second, ms);
    }
  }
  ClockDate.now = () => clock.now();
  return mirrorDateProperties(ClockDate, NativeDate);
}

function createIntl(clock, NativeIntl) {
  const ClockIntl = {};
  // Intl's properties are non-enumerable, so a for..in would miss them.
  for (const key of Object.getOwnPropertyNames(NativeIntl))
    ClockIntl[key] = NativeIntl[key];

  ClockIntl.DateTimeFormat = function(...args) {
    const realFormatter = new NativeIntl.DateTimeFormat(...args);
    return {
      formatRange: realFormatter.formatRange.bind(realFormatter),
      formatRangeToParts: realFormatter.formatRangeToParts.bind(realFormatter),
      resolvedOptions: realFormatter.resolvedOptions.bind(realFormatter),
      format: date => realFormatter.format(date || clock.now()),
      formatToParts: date => realFormatter.formatToParts(date || clock.now()),
    };
  };
  ClockIntl.DateTimeFormat.prototype =
      Object.create(NativeIntl.DateTimeFormat.prototype);
  ClockIntl.DateTimeFormat.supportedLocalesOf =
      NativeIntl.DateTimeFormat.supportedLocalesOf;
  return ClockIntl;
}

class FakePerformanceEntry {
  constructor(name, entryType, startTime, duration) {
    this.name = name;
    this.entryType = entryType;
    this.startTime = startTime;
    this.duration = duration;
  }
  toJSON() {
    return JSON.stringify({
      name: this.name,
      entryType: this.entryType,
      startTime: this.startTime,
      duration: this.duration,
    });
  }
}

function fakePerformance(clock, performance) {
  const result = { now: () => clock.performanceNow() };
  Object.defineProperty(result, 'timeOrigin', {
    get: () => clock._now.origin || 0,
  });
  const proto = Object.getPrototypeOf(performance);
  for (const key of Object.keys(proto)) {
    if (key === 'now' || key === 'timeOrigin')
      continue;
    if (key === 'getEntries' || key === 'getEntriesByName' || key === 'getEntriesByType')
      result[key] = () => [];
    else if (key === 'mark')
      result[key] = name => new FakePerformanceEntry(name, 'mark', 0, 0);
    else if (key === 'measure')
      result[key] = name => new FakePerformanceEntry(name, 'measure', 0, 50);
    else
      result[key] = () => {};
  }
  return result;
}

function fakeAbortSignal(clock, abortSignal, browserName) {
  Object.defineProperty(abortSignal, 'timeout', {
    configurable: true,
    value: function(ms) {
      const controller = new AbortController();
      clock.addTimer({
        delay: ms,
        type: kTimeout,
        func: () => controller.abort(new DOMException(
            browserName === 'chromium' ? 'signal timed out' : 'The operation timed out.',
            'TimeoutError')),
      });
      return controller.signal;
    },
  });
  return abortSignal;
}

function platformOriginals(globalObject) {
  const raw = {
    setTimeout: globalObject.setTimeout,
    clearTimeout: globalObject.clearTimeout,
    setInterval: globalObject.setInterval,
    clearInterval: globalObject.clearInterval,
    requestAnimationFrame: globalObject.requestAnimationFrame ? globalObject.requestAnimationFrame : undefined,
    cancelAnimationFrame: globalObject.cancelAnimationFrame ? globalObject.cancelAnimationFrame : undefined,
    requestIdleCallback: globalObject.requestIdleCallback ? globalObject.requestIdleCallback : undefined,
    cancelIdleCallback: globalObject.cancelIdleCallback ? globalObject.cancelIdleCallback : undefined,
    Date: globalObject.Date,
    performance: globalObject.performance,
    Intl: globalObject.Intl,
    AbortSignal: globalObject.AbortSignal,
  };
  const bound = Object.assign({}, raw);
  for (const key of Object.keys(bound)) {
    if (key !== 'Date' && key !== 'AbortSignal' && typeof bound[key] === 'function')
      bound[key] = bound[key].bind(globalObject);
  }
  return { raw: raw, bound: bound };
}

function createApi(clock, originals, browserName) {
  return {
    setTimeout: (func, timeout, ...args) => clock.addTimer({
      type: kTimeout, func: func, args: args, delay: timeout ? +timeout : timeout,
    }),
    clearTimeout: timerId => {
      if (timerId)
        clock.clearTimer(timerId, kTimeout);
    },
    setInterval: (func, timeout, ...args) => clock.addTimer({
      type: kInterval, func: func, args: args, delay: timeout ? +timeout : timeout,
    }),
    clearInterval: timerId => {
      if (timerId)
        clock.clearTimer(timerId, kInterval);
    },
    requestAnimationFrame: callback => clock.addTimer({
      type: kAnimationFrame, func: callback, delay: clock.getTimeToNextFrame(),
    }),
    cancelAnimationFrame: timerId => {
      if (timerId)
        clock.clearTimer(timerId, kAnimationFrame);
    },
    requestIdleCallback: (callback, options) => {
      let timeToNextIdlePeriod = 0;
      if (clock.countTimers() > 0)
        timeToNextIdlePeriod = 50;
      return clock.addTimer({
        type: kIdleCallback,
        func: callback,
        delay: options && options.timeout
            ? Math.min(options.timeout, timeToNextIdlePeriod)
            : timeToNextIdlePeriod,
      });
    },
    cancelIdleCallback: timerId => {
      if (timerId)
        clock.clearTimer(timerId, kIdleCallback);
    },
    Intl: originals.Intl ? createIntl(clock, originals.Intl) : undefined,
    Date: createDate(clock, originals.Date),
    performance: originals.performance ? fakePerformance(clock, originals.performance) : undefined,
    AbortSignal: originals.AbortSignal ? fakeAbortSignal(clock, originals.AbortSignal, browserName) : undefined,
  };
}

function install(globalObject, browserName) {
  if (globalObject.Date && globalObject.Date.isFake)
    throw new TypeError("Can't install fake timers twice on the same global object.");

  const originals = platformOriginals(globalObject);
  const embedder = {
    dateNow: () => originals.raw.Date.now(),
    performanceNow: () => Math.ceil(originals.raw.performance.now()),
    setTimeout: (task, timeout) => {
      const timerId = originals.bound.setTimeout(task, timeout);
      return () => originals.bound.clearTimeout(timerId);
    },
    setInterval: (task, delay) => {
      const intervalId = originals.bound.setInterval(task, delay);
      return () => originals.bound.clearInterval(intervalId);
    },
  };

  const clock = new ClockController(embedder);
  const api = createApi(clock, originals.bound, browserName);

  for (const method of Object.keys(originals.raw)) {
    if (method === 'Date') {
      globalObject.Date = mirrorDateProperties(api.Date, globalObject.Date);
    } else if (method === 'Intl' || method === 'AbortSignal') {
      if (api[method])
        globalObject[method] = api[method];
    } else if (method === 'performance') {
      if (api.performance) {
        globalObject.performance = api.performance;
        // An Event's timeStamp is read from performance.now(), so it has to
        // follow the fake clock too; it is cached per event, as a real one is.
        const kEventTimeStamp = Symbol('playwrightEventTimeStamp');
        if (globalObject.Event) {
          Object.defineProperty(globalObject.Event.prototype, 'timeStamp', {
            configurable: true,
            get() {
              if (!this[kEventTimeStamp])
                this[kEventTimeStamp] = api.performance.now();
              return this[kEventTimeStamp];
            },
          });
        }
      }
    } else if (api[method]) {
      globalObject[method] = (...args) => api[method].apply(api, args);
    }
    clock.disposables.push(() => {
      globalObject[method] = originals.raw[method];
    });
  }

  return clock;
}

const controller = install(globalThis, BROWSER_NAME);
controller.resume();
globalThis[clockProperty] = { controller: controller };

}
''';

/// The install script for [browserName], which only changes the message of
/// `AbortSignal.timeout` — Chromium words it differently from the other two,
/// and a test that asserts on that message would otherwise fail on one
/// engine.
String clockInstallSource(String browserName) => kInjectedClockSource
    .replaceFirst('BROWSER_NAME', "'${browserName.replaceAll("'", r"\'")}'");

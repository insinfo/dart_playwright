// Part of the Dart port of the Playwright trace viewer UI.

/// The envelope that carries a trace from the server to the browser.
///
/// The point of these tests is that the model the UI builds from the JSON is
/// the same model the server has. If that ever stops being true, a panel will
/// quietly show less than the trace holds, which is exactly the failure mode
/// the whole oracle run exists to catch.
library;

import 'package:playwright_trace_viewer/playwright_trace_viewer.dart';
import 'package:playwright_trace_viewer_ui/src/wire.dart';
import 'package:test/test.dart';

import 'fixture.dart';

Future<TraceLoader> _load() async {
  final loader = TraceLoader();
  await loader.load(ZipTraceLoaderBackend(buildFixtureTrace()));
  return loader;
}

void main() {
  group('the wire envelope', () {
    test('round-trips a context into the same model', () async {
      final loader = await _load();
      final before = TraceModel('fixture.zip', loader.contextEntries);

      // The far side of the wire: a fresh loader, so nothing is shared.
      final other = await _load();
      final json =
          contextEntriesToJson(other.contextEntries, traceUri: 'fixture.zip');
      final decoded = contextEntriesFromJson(json);
      final after = TraceModel(decoded.traceUri, decoded.contexts);

      expect(after.browserName, before.browserName);
      expect(after.platform, before.platform);
      expect(after.playwrightVersion, before.playwrightVersion);
      expect(after.sdkLanguage, before.sdkLanguage);
      expect(after.title, before.title);
      expect(after.startTime, before.startTime);
      expect(after.endTime, before.endTime);
      expect(after.actions.length, before.actions.length);
      expect(after.resources.length, before.resources.length);
      expect(after.events.length, before.events.length);
      expect(after.pages.length, before.pages.length);
    });

    test('keeps the action tree, the log and the stack', () async {
      final loader = await _load();
      final json =
          contextEntriesToJson(loader.contextEntries, traceUri: 'fixture.zip');
      final model =
          TraceModel('fixture.zip', contextEntriesFromJson(json).contexts);

      final navigate =
          model.actions.firstWhere((action) => action.method == 'goto');
      expect(navigate.title, 'Navigate');
      expect(navigate.className, 'Frame');
      expect(navigate.params['url'], 'http://localhost/');
      // The log lives beside the action rather than inside its events, so it
      // is the one field the envelope has to carry by hand.
      expect(navigate.log.single.message, 'navigating');
      expect(navigate.stack!.single.function, 'main');
      expect(navigate.stack!.single.file, kFixtureSourcePath);
      expect(navigate.stack!.single.line, 3);
    });

    test('keeps the console messages apart from the browser events', () async {
      final loader = await _load();
      final json =
          contextEntriesToJson(loader.contextEntries, traceUri: 'fixture.zip');
      final model =
          TraceModel('fixture.zip', contextEntriesFromJson(json).contexts);

      // `TimelineTraceEvent` is sealed, and the tag in the JSON is the only
      // thing that tells the two subclasses apart on the way back.
      final console = model.events.whereType<ConsoleMessageTraceEvent>();
      expect(console, hasLength(1));
      expect(console.single.text, 'page booted');
      expect(console.single.location.lineNumber, 8);
    });

    test('keeps the screencast frames, which the film strip draws', () async {
      final loader = await _load();
      final json =
          contextEntriesToJson(loader.contextEntries, traceUri: 'fixture.zip');
      final model =
          TraceModel('fixture.zip', contextEntriesFromJson(json).contexts);

      final frames = model.pages.single.screencastFrames;
      expect(frames, hasLength(1));
      expect(frames.single.file, 'resources/frame.jpeg');
      expect(frames.single.width, 900);
    });

    test('refuses a bundle built against another envelope', () {
      expect(
        () => contextEntriesFromJson(
            {'wireVersion': kWireVersion + 1, 'contexts': <dynamic>[]}),
        throwsA(isA<WireVersionError>()),
      );
    });

    test('no contexts decodes to an empty model', () {
      // What the viewer gets when the archive held nothing it could read.
      // The panels have to survive it, because the alternative is a blank
      // page with no explanation.
      final json = contextEntriesToJson(const [], traceUri: 'empty.zip');
      final decoded = contextEntriesFromJson(json);
      expect(decoded.traceUri, 'empty.zip');
      expect(decoded.contexts, isEmpty);
      final model = TraceModel('empty.zip', decoded.contexts);
      expect(model.actions, isEmpty);
      expect(model.resources, isEmpty);
      expect(model.visibleAttachments, isEmpty);
    });
  });
}

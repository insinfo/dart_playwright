/// The recorder: turns what a user does in the browser into source code.
///
/// This is the library half of the `codegen` command. `Recorder` installs the
/// in-page recorder on a browser context and reports every action the user
/// performs; `RecorderCollection` collects those actions and generates a
/// source file from them with one of `playwright_isomorphic`'s generators.
///
/// ```dart
/// final recorder = Recorder(context);
/// await recorder.install();
/// final collection = RecorderCollection(
///   recorder: recorder,
///   generatorId: 'dart-test',
///   options: LanguageGeneratorOptions(browserName: 'chromium'),
/// );
/// await recorder.setMode(RecorderMode.recording);
/// // ... the user drives the browser ...
/// print(collection.generate().text);
/// ```
library playwright.recorder;

export 'package:playwright_isomorphic/playwright_isomorphic.dart'
    show
        Action,
        ActionInContext,
        GeneratedCode,
        LanguageGenerator,
        LanguageGeneratorOptions,
        Languages,
        Signal,
        SignalInContext,
        asLocator,
        generateCode,
        languageSet;

export 'src/recorder/recorder.dart' show Recorder, performClick;
export 'src/recorder/recorder_app.dart'
    show
        RecorderCollection,
        RecorderEvent,
        RecorderEventKind,
        generatorById,
        generatorIds;
export 'src/recorder/recorder_types.dart'
    show
        ElementInfo,
        OverlayState,
        RecorderMode,
        RecorderSource,
        RecorderUiState;
export 'src/recorder/recorder_utils.dart'
    show buildFullSelectorForFrame, collapseActions, shouldMergeAction;
export 'src/recorder/throttled_file.dart' show ThrottledFile;

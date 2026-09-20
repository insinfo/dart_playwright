// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/isomorphic/codegen/languages.ts

import 'csharp.dart';
import 'dart.dart';
import 'java.dart';
import 'javascript.dart';
import 'jsonl.dart';
import 'python.dart';
import 'types.dart';

/// Every generator the recorder can offer, in order of preference.
///
/// Dart comes first because this is the Dart port: a recording made here is
/// most likely meant to become a Dart test. Within each language the test
/// runner flavour comes before the library one, as upstream orders them.
List<LanguageGenerator> languageSet() => <LanguageGenerator>[
      DartLanguageGenerator(DartLanguageMode.test),
      DartLanguageGenerator(DartLanguageMode.library),
      JavaScriptLanguageGenerator(true),
      JavaScriptLanguageGenerator(false),
      PythonLanguageGenerator(false, true),
      PythonLanguageGenerator(false, false),
      PythonLanguageGenerator(true, false),
      CSharpLanguageGenerator('mstest'),
      CSharpLanguageGenerator('nunit'),
      CSharpLanguageGenerator('xunit'),
      CSharpLanguageGenerator('library'),
      JavaLanguageGenerator('junit'),
      JavaLanguageGenerator('library'),
      JsonlLanguageGenerator(),
    ];

/// The attribute `getByTestId` looks at, `data-testid` unless changed.
///
/// This is process-wide, matching upstream: the attribute is a property of
/// the codebase under test, not of one page or context, and threading it
/// through every call would be noise.
String _testIdAttributeName = 'data-testid';

/// The attribute `getByTestId` currently looks at.
String get testIdAttributeName => _testIdAttributeName;

/// Changes the attribute `getByTestId` looks at, for every locator built
/// afterwards.
///
/// ```dart
/// setTestIdAttribute('data-qa');
/// await page.getByTestId('submit').click();  // [data-qa="submit"]
/// ```
///
/// Locators already built keep the attribute they were built with; the
/// attribute is resolved when the locator is created, not when it is used.
void setTestIdAttribute(String attributeName) {
  if (attributeName.isEmpty) {
    throw ArgumentError.value(
        attributeName, 'attributeName', 'Must not be empty');
  }
  _testIdAttributeName = attributeName;
}

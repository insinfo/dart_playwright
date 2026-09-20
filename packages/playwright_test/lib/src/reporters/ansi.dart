/// Matches an ANSI escape sequence.
///
/// Ported from upstream's `stripAnsiEscapes` in
/// `packages/isomorphic/stringUtils.ts`, which is where every reporter over
/// there gets its colors removed. The two alternatives are the OSC form, which
/// ends at a BEL, and the CSI form, which ends at a letter.
final RegExp _ansi = RegExp(
    '([\u001B\u009B][\\[\\]()#?]*'
    '(?:(?:(?:[a-zA-Z\\d]*(?:;[-a-zA-Z\\d/#&.:=?%@~_]*)*)?\u0007)'
    '|(?:(?:\\d{0,4}(?:;\\d{0,4})*)?[\\dA-PR-TZcf-ntqry=><~])))',
    multiLine: true);

/// Returns [text] without ANSI colors and cursor moves.
///
/// A report is read in a browser or by a CI parser, and neither one renders an
/// escape sequence -- they show it, which turns a readable failure into line
/// noise.
String stripAnsiEscapes(String text) => text.replaceAll(_ansi, '');

/// Characters XML forbids or discourages, stripped before writing.
///
/// Tab, newline and carriage return are deliberately not in the range: they
/// carry the shape of a stack trace, and a JUnit file without them is
/// unreadable. Same list as upstream's `discouragedXMLCharacters`.
final RegExp discouragedXmlCharacters = RegExp(
    '[\u0000-\u0008\u000b-\u000c\u000e-\u001f\u007f-\u0084\u0086-\u009f]');

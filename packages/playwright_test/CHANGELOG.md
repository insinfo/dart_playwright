# Changelog

## 0.1.0

First release.

### Fixtures

- `playwrightTest(description, body, options:)` runs a body once per engine
  named in the options, each as its own `dart test` case.
- `playwrightGroup(description, body)` closes the browsers the group opened.
- `PlaywrightFixtures` carries `browserName`, `browser`, `context` and `page`.
  The browser is shared per file and engine; the context and page are created
  fresh for each test and closed after it.
- `PlaywrightTestOptions` carries `browsers`, `headless`, `viewport`,
  `locale`, `timezoneId`, `colorScheme`, `hasTouch` and `artifactsPath`.
- A full-page screenshot is written when a test fails, and its path is added
  to the error.

### Assertions

All locator and page assertions retry until they pass or their timeout runs
out, and every one accepts `.not`.

- Locator: `toBeVisible`, `toBeHidden`, `toBeAttached`, `toBeEnabled`,
  `toBeDisabled`, `toBeEditable`, `toBeChecked`, `toBeFocused`, `toBeEmpty`,
  `toHaveText`, `toContainText`, `toHaveValue`, `toHaveAttribute`,
  `toHaveClass`, `toHaveCount`.
- Page: `toHaveTitle`, `toHaveURL`.
- API response: `toBeOK`.
- A failure reports both what was expected and what was last seen.

### Not included

This is a layer over `package:test`, not a runner: `dart test` keeps its CLI,
its reporters, its filtering and its parallelism. Video and trace on failure,
snapshot and screenshot assertions, projects, sharding and custom fixtures are
not here; the README says why for each.

# Pinned browser tooling

`chromedriver` here is pinned to one Chrome build. It is deliberately not on
PATH and not committed: fetch it with `make qa-driver`.

`flutter drive` on web talks WebDriver, and chromedriver refuses a session
unless its major version equals the browser's. Homebrew's cask is deprecated
(it fails macOS Gatekeeper) and tracks the newest release, so it drifts ahead
of stable Chrome and the pairing breaks with an error that reads like a Flutter
fault and is not:

    SessionNotCreatedException (500): session not created:
    This version of ChromeDriver only supports Chrome version 152
    Current browser version is 151.0.7922.138

Pinning turns that into a loud, early version check instead.

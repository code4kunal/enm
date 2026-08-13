/// The browser bits of the sign-in redirect, for platforms that have no
/// browser.
///
/// Only web is scaffolded today. This stub exists so an iOS or Android build
/// still compiles: the flow asks whether it is on the web before using any of
/// it, and Microsoft sign-in simply is not offered where it is not.
bool get isBrowser => false;

Uri currentUri() => Uri.base;

void redirectTo(Uri url) => throw UnsupportedError(
      'Microsoft sign-in needs a browser on this platform.',
    );

void clearQuery() {}

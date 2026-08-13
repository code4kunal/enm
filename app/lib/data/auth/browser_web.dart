import 'package:web/web.dart' as web;

/// The browser bits of the sign-in redirect.
bool get isBrowser => true;

Uri currentUri() => Uri.parse(web.window.location.href);

/// Leaves the app entirely — Entra takes over the tab and sends the browser
/// back to [redirect_uri] with a code.
void redirectTo(Uri url) => web.window.location.assign(url.toString());

/// Drops `?code=…&state=…` from the address bar once the code is spent.
///
/// The code is single-use and PKCE-bound, so this is tidiness rather than a
/// control — but leaving it in the URL means it lands in history, in bookmarks
/// and in any screenshot of the address bar.
void clearQuery() {
  final url = Uri.parse(web.window.location.href);
  final cleaned = url.replace(queryParameters: <String, String>{}).toString();
  web.window.history.replaceState(
    null,
    '',
    cleaned.endsWith('?') ? cleaned.substring(0, cleaned.length - 1) : cleaned,
  );
}

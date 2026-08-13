/// Raised for anything the user should see as an inline message rather than a
/// crash: bad credentials, a deactivated account, a duplicate code, a rejected
/// import. The message is safe to render verbatim.
///
/// Its own file so the sign-in flow can raise it without importing the whole
/// repository surface — which would be a cycle, since the repositories in turn
/// need the sign-in types.
class ApiException implements Exception {
  const ApiException(this.message, {this.fields = const <String, String>{}});

  final String message;

  /// Field-level errors keyed by form field, when the server supplies them.
  final Map<String, String> fields;

  @override
  String toString() => message;
}

/// Kept for call sites that read as authentication failures.
typedef AuthException = ApiException;

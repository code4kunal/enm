import '../models/site.dart';

/// SiteOps display names operators use for known E&M depots.
///
/// Checked only when the row's own `code` / exact name did not already match.
/// Kept tight on purpose: a catch-all "only one E&M site → use it" made every
/// SiteOps pick look like MBMT and froze the Bus No list on site change.
const kSiteOpsEnmAliases = <String, String>{
  'ghodbandar': 'MBMT',
  'ghodbunder': 'MBMT',
  'mira bhayandar': 'MBMT',
  'mira-bhayandar': 'MBMT',
  'ulhasnagar': 'UMT',
};

/// Map a SiteOps onboarding row onto an E&M depot code (`MBMT` / `GTI` / …).
///
/// Returns empty when there is no safe match. Callers must not invent a code
/// (e.g. "the only E&M site we know") — that made every SiteOps row look like
/// the same depot, so [SessionController.switchSite] no-op'd and Bus No lists
/// never refreshed.
String enmCodeForSiteOpsRow(
  Map<String, dynamic> j,
  List<Site> enmSites,
) {
  if (enmSites.isEmpty) return '';

  final raw =
      (j['code'] ?? j['site_code'])?.toString().trim().toUpperCase() ?? '';
  final looksLikeUuid = raw.contains('-') && raw.length >= 32;
  if (raw.isNotEmpty &&
      !looksLikeUuid &&
      enmSites.any((s) => s.code == raw)) {
    return raw;
  }

  final name = (j['name']?.toString() ?? '').trim().toLowerCase();
  if (name.isEmpty) return '';

  for (final s in enmSites) {
    final enmName = s.name.trim().toLowerCase();
    final enmCode = s.code.toLowerCase();
    if (enmName == name || enmCode == name) return s.code;
  }

  String? aliasHit(String key) {
    final code = kSiteOpsEnmAliases[key];
    if (code == null) return null;
    return enmSites.any((s) => s.code == code) ? code : null;
  }

  final fromAlias = aliasHit(name);
  if (fromAlias != null) return fromAlias;

  final tokens = name
      .split(RegExp(r'[^a-z0-9]+'))
      .where((t) => t.isNotEmpty)
      .toSet();
  for (final s in enmSites) {
    if (tokens.contains(s.code.toLowerCase())) return s.code;
  }
  for (final t in tokens) {
    final hit = aliasHit(t);
    if (hit != null) return hit;
  }

  final byNameLen = List<Site>.of(enmSites)
    ..sort((a, b) => b.name.length.compareTo(a.name.length));
  for (final s in byNameLen) {
    final enmName = s.name.trim().toLowerCase();
    if (enmName.length < 3) continue;
    if (enmName.contains(name) || name.contains(enmName)) return s.code;
  }

  return '';
}

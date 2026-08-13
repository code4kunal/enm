import 'dart:convert';

import 'package:share_plus/share_plus.dart';

import '../data/registers.dart';
import '../models/entry.dart';
import '../state/entries.dart';

/// Exports the current filtered result set as CSV.
///
/// Columns match the handoff: Register, Date, Site, Bus No, Details,
/// Entered by. Delivery goes through the platform share sheet, which covers
/// "save to Files" on mobile and a download on web without a second dependency.
abstract final class CsvExport {
  static const List<String> _columns = <String>[
    'Register',
    'Date',
    'Site',
    'Bus No',
    'Details',
    'Entered by',
  ];

  static String build(List<RegisterEntry> entries) {
    final rows = <String>[_columns.map(_escape).join(',')];
    for (final e in entries) {
      rows.add(
        <String>[
          requireRegister(e.registerId).name,
          e.date,
          e.site,
          e.busNumber,
          entrySummary(e),
          e.enteredBy,
        ].map(_escape).join(','),
      );
    }
    // CRLF so Excel on Windows opens it without a repair prompt.
    return rows.join('\r\n');
  }

  static String fileName(String site) =>
      'transvolt-em-register-${site.toLowerCase()}.csv';

  /// Returns the number of rows exported. Throws if the platform share sheet
  /// is unavailable; callers surface that as a toast.
  static Future<int> share(List<RegisterEntry> entries, String site) async {
    final csv = build(entries);
    final name = fileName(site);
    // BOM so Excel detects UTF-8 and renders the middot separators correctly.
    final bytes = utf8.encode('\u{FEFF}$csv');

    await Share.shareXFiles(
      <XFile>[
        XFile.fromData(bytes, mimeType: 'text/csv', name: name),
      ],
      fileNameOverrides: <String>[name],
      subject: 'Transvolt E&M register export — $site',
    );
    return entries.length;
  }

  /// RFC 4180: quote any field containing a comma, quote, CR or LF, and double
  /// embedded quotes.
  static String _escape(String value) {
    final needsQuotes = value.contains(RegExp(r'[",\r\n]'));
    if (!needsQuotes) return value;
    return '"${value.replaceAll('"', '""')}"';
  }
}

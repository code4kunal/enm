import 'dart:convert';
import 'dart:typed_data';

/// Minimal RFC 4180 reader used only by the fake import repository.
///
/// The real backend parses xlsx/xls/csv and owns validation; this exists so the
/// import flow is genuinely exercisable — and testable — without a server.
abstract final class CsvSource {
  /// Splits [bytes] into rows of cells, honouring quoted fields, escaped
  /// quotes and newlines inside quotes.
  static List<List<String>> parse(Uint8List bytes) {
    // Tolerate a UTF-8 BOM from Excel exports.
    var text = utf8.decode(bytes, allowMalformed: true);
    if (text.startsWith('\u{FEFF}')) text = text.substring(1);

    final rows = <List<String>>[];
    var row = <String>[];
    final cell = StringBuffer();
    var inQuotes = false;

    for (var i = 0; i < text.length; i++) {
      final ch = text[i];

      if (inQuotes) {
        if (ch == '"') {
          // A doubled quote inside a quoted field is a literal quote.
          if (i + 1 < text.length && text[i + 1] == '"') {
            cell.write('"');
            i++;
          } else {
            inQuotes = false;
          }
        } else {
          cell.write(ch);
        }
        continue;
      }

      switch (ch) {
        case '"':
          inQuotes = true;
        case ',':
          row.add(cell.toString());
          cell.clear();
        case '\r':
          // Swallow; the \n that follows ends the row.
          break;
        case '\n':
          row.add(cell.toString());
          cell.clear();
          rows.add(row);
          row = <String>[];
        default:
          cell.write(ch);
      }
    }

    // Flush a trailing row that has no terminating newline.
    if (cell.isNotEmpty || row.isNotEmpty) {
      row.add(cell.toString());
      rows.add(row);
    }

    // Blank rows are kept: dropping them would shift every later index, and
    // both `headerRow` and the row numbers reported in errors have to line up
    // with what the user sees in Excel. [table] skips them instead.
    return rows;
  }

  /// Reads [bytes] as a header row plus column-keyed data rows.
  ///
  /// [headerRow] is 1-based. [skipRows] discards data rows immediately after
  /// the header — units or sub-header rows.
  static ({List<String> columns, List<Map<String, String>> rows}) table(
    Uint8List bytes, {
    int headerRow = 1,
    int skipRows = 0,
  }) {
    final raw = parse(bytes);
    final headerIndex = (headerRow - 1).clamp(0, raw.isEmpty ? 0 : raw.length - 1);
    if (raw.isEmpty) {
      return (columns: <String>[], rows: <Map<String, String>>[]);
    }

    final columns = _dedupe(raw[headerIndex].map((c) => c.trim()).toList());
    final rows = <Map<String, String>>[];

    for (var i = headerIndex + 1 + skipRows; i < raw.length; i++) {
      final cells = raw[i];
      // Skip blank rows without disturbing the numbering.
      if (cells.every((c) => c.trim().isEmpty)) continue;
      final row = <String, String>{};
      for (var c = 0; c < columns.length; c++) {
        row[columns[c]] = c < cells.length ? cells[c].trim() : '';
      }
      // The source row number as Excel shows it, so errors are findable.
      row[r'$row'] = '${i + 1}';
      rows.add(row);
    }

    return (columns: columns, rows: rows);
  }

  /// Real sheets repeat blank or duplicated headers; make them addressable.
  static List<String> _dedupe(List<String> headers) {
    final seen = <String, int>{};
    return <String>[
      for (var i = 0; i < headers.length; i++)
        () {
          final base = headers[i].isEmpty ? 'Column ${i + 1}' : headers[i];
          final n = (seen[base] ?? 0) + 1;
          seen[base] = n;
          return n == 1 ? base : '$base ($n)';
        }(),
    ];
  }
}

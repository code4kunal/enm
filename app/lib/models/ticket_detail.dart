import 'entry.dart';

/// The full record behind one ticket — the source entry's own fields,
/// every Work Done session logged against it, and any photos. Powers the
/// Ticket Detail screen, reached either from the Tickets list or from a
/// Breakdown/Driver Complaint row's View action.
class TicketDetail {
  const TicketDetail({
    required this.ticketId,
    required this.displayId,
    required this.status,
    required this.sourceEntry,
    required this.linkedSessions,
    required this.photos,
  });

  final String ticketId;
  final String displayId;
  final String status;

  /// Null only for an inspection-sourced ticket (no register entry) — not
  /// reachable by this pass's UI, which only opens Ticket Detail for
  /// Breakdown/Driver Complaint rows.
  final RegisterEntry? sourceEntry;
  final List<Map<String, dynamic>> linkedSessions;
  final List<EntryPhoto> photos;

  factory TicketDetail.fromJson(
    Map<String, dynamic> json,
    RegisterEntry? Function(Map<String, dynamic>) parseEntry,
  ) {
    final source = json['source_entry'] as Map<String, dynamic>?;
    return TicketDetail(
      ticketId: json['ticket_id'] as String,
      displayId: json['display_id'] as String,
      status: json['status'] as String,
      sourceEntry: source == null ? null : parseEntry(source),
      linkedSessions:
          (json['linked_sessions'] as List<dynamic>? ?? <dynamic>[])
              .map((s) => Map<String, dynamic>.from(s as Map))
              .toList(),
      photos: (json['photos'] as List<dynamic>? ?? <dynamic>[])
          .map((p) => EntryPhoto.fromJson(Map<String, dynamic>.from(p as Map)))
          .toList(),
    );
  }
}

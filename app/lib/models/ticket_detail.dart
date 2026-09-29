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
    required this.title,
    required this.busNo,
    required this.sourceEntry,
    required this.linkedSessions,
    required this.photos,
    this.attendedAt,
    this.completedAt,
  });

  final String ticketId;
  final String displayId;
  final String status;

  /// Always present regardless of source shape -- the one thing every
  /// ticket has to show, even an inspection-sourced one with no entry.
  final String title;
  final String busNo;

  /// Null for an inspection-sourced ticket (no register entry) -- reachable
  /// whenever a Work Done session links to one, since linking doesn't
  /// filter by source kind. Screens must not assume this is non-null just
  /// because they only *open* Ticket Detail from Breakdown/Driver
  /// Complaint rows -- the ticket on the other end can be any kind.
  final RegisterEntry? sourceEntry;
  final List<Map<String, dynamic>> linkedSessions;
  final List<EntryPhoto> photos;

  /// HH:mm, site-local. Null until that stage of the reported->attended->
  /// completed timeline has actually happened.
  final String? attendedAt;
  final String? completedAt;

  factory TicketDetail.fromJson(
    Map<String, dynamic> json,
    RegisterEntry? Function(Map<String, dynamic>) parseEntry,
  ) {
    final source = json['source_entry'] as Map<String, dynamic>?;
    return TicketDetail(
      ticketId: json['ticket_id'] as String,
      displayId: json['display_id'] as String,
      status: json['status'] as String,
      title: json['title'] as String? ?? '',
      busNo: json['bus_no'] as String? ?? '',
      sourceEntry: source == null ? null : parseEntry(source),
      linkedSessions:
          (json['linked_sessions'] as List<dynamic>? ?? <dynamic>[])
              .map((s) => Map<String, dynamic>.from(s as Map))
              .toList(),
      photos: (json['photos'] as List<dynamic>? ?? <dynamic>[])
          .map((p) => EntryPhoto.fromJson(Map<String, dynamic>.from(p as Map)))
          .toList(),
      attendedAt: json['attended_at'] as String?,
      completedAt: json['completed_at'] as String?,
    );
  }
}

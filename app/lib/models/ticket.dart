import 'package:flutter/foundation.dart';

/// One open ticket, as returned by a title/ID search — the picker's option,
/// not the full ticket record (the app never needs more than this to link
/// a Work Done session to it).
@immutable
class TicketSearchResult {
  const TicketSearchResult({
    required this.ticketId,
    required this.title,
    required this.entryDate,
    required this.status,
  });

  final String ticketId;
  final String title;
  final String entryDate;
  final String status;

  factory TicketSearchResult.fromJson(Map<String, dynamic> json) =>
      TicketSearchResult(
        ticketId: json['ticket_id'] as String,
        title: json['title'] as String,
        entryDate: json['entry_date'] as String,
        status: json['status'] as String,
      );
}

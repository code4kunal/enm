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
    required this.sourceKind,
    this.displayId = '',
    this.busNo,
    this.driverName,
    this.route,
    this.defectText,
    this.defectType,
  });

  final String ticketId;
  final String title;
  final String entryDate;
  final String status;

  /// `breakdown` | `coolant` | `driver_complaint` | `daily_inspection` |
  /// `ten_day_inspection` | `pm_docking` | `pm_schedule` (legacy-only).
  /// The three inspection kinds have no register entry at all, which is
  /// what distinguishes them for display (see pendingInspectionTicketsProvider).
  final String sourceKind;

  /// The source entry's own display id ("BD-2026-…") — the id a person
  /// actually sees and would type to search. Empty for an inspection-
  /// sourced ticket (no entry to read one from).
  final String displayId;

  /// Prefill context for the Work Done linking form — null for an
  /// inspection-sourced ticket.
  final String? busNo;
  final String? driverName;
  final String? route;
  final String? defectText;
  final String? defectType;

  factory TicketSearchResult.fromJson(Map<String, dynamic> json) =>
      TicketSearchResult(
        ticketId: json['ticket_id'] as String,
        title: json['title'] as String,
        entryDate: json['entry_date'] as String,
        status: json['status'] as String,
        sourceKind: json['source_kind'] as String? ?? '',
        displayId: json['display_id'] as String? ?? '',
        busNo: json['bus_no'] as String?,
        driverName: json['driver_name'] as String?,
        route: json['route'] as String?,
        defectText: json['defect_text'] as String?,
        defectType: json['defect_type'] as String?,
      );
}

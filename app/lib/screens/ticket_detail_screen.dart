import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../models/entry_photo.dart';
import '../models/ticket_detail.dart';
import '../router.dart';
import '../state/entries.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/buttons.dart';
import '../widgets/chips.dart';
import '../widgets/dashed.dart';
import '../widgets/fade_up.dart';
import '../widgets/location_map.dart';

/// The full history behind one ticket — the source entry's own fields, the
/// reported/attended/completed timeline, every Work Done session logged
/// against it, and any photos. Reached from the Tickets list or a
/// Breakdown/Driver Complaint row's View action.
class TicketDetailScreen extends ConsumerWidget {
  const TicketDetailScreen({super.key, required this.ticketId});

  final String ticketId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(ticketDetailProvider(ticketId));

    return FadeUp(
      key: ValueKey<String>('ticket-detail-$ticketId'),
      child: detail.when(
        data: (t) => _Loaded(ticket: t),
        loading: () => const Padding(
          padding: EdgeInsets.symmetric(vertical: 40),
          child: Center(child: CircularProgressIndicator()),
        ),
        error: (_, __) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            BackLink(onTap: () => context.go(Routes.tickets)),
            const SizedBox(height: 16),
            const EmptyState(message: 'That ticket is no longer available.'),
          ],
        ),
      ),
    );
  }
}

class _Loaded extends StatelessWidget {
  const _Loaded({required this.ticket});

  final TicketDetail ticket;

  @override
  Widget build(BuildContext context) {
    final entry = ticket.sourceEntry;
    final data = entry?.data ?? const <String, String>{};
    final sessions = ticket.linkedSessions;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        BackLink(onTap: () => context.go(Routes.tickets)),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    ticket.displayId,
                    style: AppText.sans(size: 21, weight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    entry == null
                        ? ticket.busNo
                        : '${entry.busNumber} · ${data['shift'] != null ? 'Shift ${data['shift']}' : entry.date}',
                    style: AppText.sans(size: 13, color: T.secondary),
                  ),
                ],
              ),
            ),
            TagBadge(
              label: ticket.status == 'completed' ? 'Completed' : 'Open',
              background:
                  ticket.status == 'completed' ? T.greenTint : T.subtleFill,
              foreground:
                  ticket.status == 'completed' ? T.greenInk : T.secondary,
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (entry != null) ...<Widget>[
          _Card(
            title: 'Job & Reported Defect',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _row('Date', entry.date),
                if (data['shift'] != null) _row('Shift', data['shift']!),
                _row('Bus', entry.busNumber),
                if ((data['driver'] ?? '').isNotEmpty)
                  _row('Driver', data['driver']!),
                if ((data['route'] ?? '').isNotEmpty)
                  _row('Route', data['route']!),
                if ((data['loc'] ?? '').isNotEmpty)
                  _row('Location', data['loc']!),
                if ((data['defectType'] ?? '').isNotEmpty)
                  _row('Defect Type', data['defectType']!),
                if ((data['complaint'] ?? '').isNotEmpty)
                  _row('Reported', data['complaint']!),
                // Breakdown-only.
                if ((data['loss'] ?? '').isNotEmpty)
                  _row('Loss (km)', data['loss']!),
                if ((data['odo'] ?? '').isNotEmpty)
                  _row('Odometer (km)', data['odo']!),
                if ((data['remarks'] ?? '').isNotEmpty)
                  _row('Remarks', data['remarks']!),
                // Driver Complaint-only.
                if ((data['action'] ?? '').isNotEmpty)
                  _row('Rectification Action', data['action']!),
                if ((data['mechanic'] ?? '').isNotEmpty)
                  _row('Mechanic', data['mechanic']!),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (double.tryParse(data['latitude'] ?? '') != null &&
              double.tryParse(data['longitude'] ?? '') != null) ...<Widget>[
            _Card(
              title: 'Location',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  LocationMapView(
                    center: LatLng(
                      double.parse(data['latitude']!),
                      double.parse(data['longitude']!),
                    ),
                  ),
                  const SizedBox(height: 8),
                  _row(
                    'Coordinates',
                    '${data['latitude']}, ${data['longitude']} '
                        '(${(data['locationSource'] ?? 'manual').toUpperCase()})',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
        ] else ...<Widget>[
          // Inspection-sourced (or any future source shape without a
          // register Entry) -- no per-register fields to show, but the
          // ticket's own title/bus are always there.
          _Card(
            title: 'Job',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _row('Bus', ticket.busNo),
                _row('Item', ticket.title),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
        _Card(
          title: 'Time & Shift Timeline',
          child: Row(
            children: <Widget>[
              Expanded(
                child: _Metric(
                  label: 'Reported',
                  value:
                      entry == null ? '—' : (data['t_reported'] ?? entry.time),
                ),
              ),
              Expanded(
                child: _Metric(
                  label: 'Attended',
                  value: ticket.attendedAt ?? '—',
                ),
              ),
              Expanded(
                child: _Metric(
                  label: 'Completed',
                  value: ticket.completedAt ?? '—',
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _Card(
          title: 'Work sessions',
          child: sessions.isEmpty
              ? Text(
                  'No Work Done session logged against this ticket yet.',
                  style: AppText.sans(size: 13, color: T.muted),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    for (final indexed in sessions.asMap().entries) ...<Widget>[
                      if (indexed.key > 0)
                        const Divider(height: 20, color: T.border),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: <Widget>[
                          if (indexed.key == 0)
                            const TagBadge(
                              label: 'Originally logged',
                              background: T.blueTint,
                              foreground: T.blue,
                            ),
                          if (indexed.value['completes_ticket'] == true)
                            const TagBadge(
                              label: 'Completed by',
                              background: T.greenTint,
                              foreground: T.green,
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${indexed.value['entry_date']} · Shift ${indexed.value['shift'] ?? '—'} · '
                        '${(indexed.value['attendees'] as List<dynamic>? ?? const <dynamic>[]).map((a) => (a as Map)['name']).join(', ')}'
                        '${(indexed.value['supervisor'] as String?)?.isNotEmpty == true ? ' · Supervisor: ${indexed.value['supervisor']}' : ''}'
                        '${(indexed.value['attended_time'] as String?) != null ? ' · Attended: ${indexed.value['attended_time']}' : ''}'
                        '${(indexed.value['completion_time'] as String?) != null ? ' · Completed: ${indexed.value['completion_time']}' : ''}',
                        style: AppText.sans(size: 13),
                      ),
                      if ((indexed.value['spare_parts'] as List<dynamic>? ??
                              const <dynamic>[])
                          .isNotEmpty) ...<Widget>[
                        const SizedBox(height: 4),
                        Text(
                          'Spare parts: '
                          '${(indexed.value['spare_parts'] as List<dynamic>).map((p) => '${(p as Map)['name']} (${p['part_no']})').join(', ')}',
                          style: AppText.sans(size: 13, color: T.secondary),
                        ),
                      ],
                    ],
                  ],
                ),
        ),
        if (ticket.photos.isNotEmpty) ...<Widget>[
          const SizedBox(height: 12),
          _Card(
            title: 'Photos',
            child: Wrap(
              spacing: 10,
              runSpacing: 10,
              children: <Widget>[
                for (final photo in ticket.photos) _PhotoThumb(photo: photo),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: T.card,
        borderRadius: T.cardShape,
        border: Border.all(color: T.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(title, style: AppText.sans(size: 14, weight: FontWeight.w700)),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

Widget _row(String label, String value) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: RichText(
      text: TextSpan(
        children: <InlineSpan>[
          TextSpan(
            text: '$label: ',
            style: AppText.sans(
                size: 13, weight: FontWeight.w600, color: T.secondary),
          ),
          TextSpan(text: value, style: AppText.sans(size: 13, color: T.ink)),
        ],
      ),
    ),
  );
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(label, style: AppText.sans(size: 11, color: T.muted)),
        const SizedBox(height: 2),
        Text(value, style: AppText.sans(size: 15, weight: FontWeight.w700)),
      ],
    );
  }
}

class _PhotoThumb extends StatelessWidget {
  const _PhotoThumb({required this.photo});

  final EntryPhoto photo;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => showDialog<void>(
        context: context,
        builder: (context) => Dialog(
          child: InteractiveViewer(child: Image.network(photo.url)),
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.network(
          photo.url,
          width: 96,
          height: 96,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stack) => Container(
            width: 96,
            height: 96,
            color: T.subtleFill,
            alignment: Alignment.center,
            child: const Icon(Icons.broken_image_outlined, color: T.muted),
          ),
        ),
      ),
    );
  }
}

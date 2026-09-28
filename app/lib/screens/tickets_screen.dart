import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/ticket.dart';
import '../router.dart';
import '../state/providers.dart';
import '../state/session.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/chips.dart';
import '../widgets/dashed.dart';
import '../widgets/fade_up.dart';
import '../widgets/form_controls.dart';

/// Every ticket at the active site — open, completed, or both — searchable
/// by title or display id. Closes the "where can I see those tickets" gap:
/// today's app only ever showed tickets indirectly, as a picker inside the
/// Work Done form.
class TicketsScreen extends ConsumerStatefulWidget {
  const TicketsScreen({super.key});

  @override
  ConsumerState<TicketsScreen> createState() => _TicketsScreenState();
}

class _TicketsScreenState extends ConsumerState<TicketsScreen> {
  String _status = 'open';
  String _query = '';
  final TextEditingController _queryController = TextEditingController();

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final site = ref.watch(sessionProvider.select((s) => s.site));
    final siteName = ref.watch(siteDisplayNameProvider);
    final searchKey = (site: site, register: null, q: _query, status: _status);
    final results = ref.watch(ticketSearchProvider(searchKey));

    return FadeUp(
      key: ValueKey<String>('tickets-$siteName'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('Tickets', style: AppText.sans(size: 20, weight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(
            'Every breakdown, coolant, complaint, and PM ticket at $siteName.',
            style: AppText.sans(size: 13, color: T.secondary),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              for (final s in const <(String, String)>[
                ('open', 'Open'),
                ('completed', 'Completed'),
                ('all', 'All'),
              ])
                PillChip(
                  label: s.$2,
                  dense: true,
                  tone: ChipTone.green,
                  selected: _status == s.$1,
                  onTap: () => setState(() => _status = s.$1),
                ),
            ],
          ),
          const SizedBox(height: 10),
          AppTextField(
            controller: _queryController,
            placeholder: 'Search by title or display id (e.g. BD-2026-000123)…',
            onChanged: (v) => setState(() => _query = v),
          ),
          const SizedBox(height: 16),
          results.when(
            data: (tickets) => tickets.isEmpty
                ? const EmptyState(message: 'No tickets match.')
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      for (final t in tickets) ...<Widget>[
                        _TicketRow(ticket: t),
                        const SizedBox(height: 10),
                      ],
                    ],
                  ),
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (_, __) =>
                const EmptyState(message: 'Could not load tickets.'),
          ),
        ],
      ),
    );
  }
}

class _TicketRow extends StatelessWidget {
  const _TicketRow({required this.ticket});

  final TicketSearchResult ticket;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => context.go(Routes.ticketDetail(ticket.ticketId)),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: T.card,
          borderRadius: T.cardShape,
          border: Border.all(color: T.border),
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Wrap(
                    spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: <Widget>[
                      if (ticket.displayId.isNotEmpty)
                        TagBadge(
                          label: ticket.displayId,
                          background: T.subtleFill,
                          foreground: T.secondary,
                        ),
                      Text(
                        ticket.title,
                        style: AppText.sans(size: 14.5, weight: FontWeight.w600),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    ticket.entryDate,
                    style: AppText.sans(size: 12.5, color: T.secondary),
                  ),
                ],
              ),
            ),
            TagBadge(
              label: ticket.status == 'completed' ? 'Completed' : 'Open',
              background: ticket.status == 'completed' ? T.greenTint : T.subtleFill,
              foreground: ticket.status == 'completed' ? T.greenInk : T.secondary,
            ),
          ],
        ),
      ),
    );
  }
}

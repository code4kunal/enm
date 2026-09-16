import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../data/repositories.dart';
import '../../models/admin_estate.dart';
import '../../state/admin_estate.dart';
import '../../state/providers.dart';
import '../../state/toast.dart';
import '../../state/users.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../utils/dates.dart';
import '../../widgets/buttons.dart';
import '../../widgets/dashed.dart';
import '../../widgets/form_controls.dart';
import '../../widgets/sub_tabs.dart';

/// User-wise audit trail — every recorded action for super admins.
class AdminAuditPane extends ConsumerStatefulWidget {
  const AdminAuditPane({super.key});

  @override
  ConsumerState<AdminAuditPane> createState() => _AdminAuditPaneState();
}

class _AdminAuditPaneState extends ConsumerState<AdminAuditPane> {
  bool _exporting = false;
  final _actionController = TextEditingController();

  @override
  void dispose() {
    _actionController.dispose();
    super.dispose();
  }

  Future<void> _export() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    final f = ref.read(auditFiltersProvider);
    final toast = ref.read(toastProvider.notifier);
    try {
      final bytes = await ref.read(adminEstateRepositoryProvider).exportAuditCsv(
            actorId: f.actorId.isEmpty ? null : f.actorId,
            action: f.action.isEmpty ? null : f.action,
            objectType: f.objectType.isEmpty ? null : f.objectType,
            dateFrom: f.dateFrom.isEmpty ? null : f.dateFrom,
            dateTo: f.dateTo.isEmpty ? null : f.dateTo,
          );
      final file = XFile.fromData(
        Uint8List.fromList(bytes),
        mimeType: 'text/csv',
        name: 'enm-audit.csv',
      );
      await Share.shareXFiles(<XFile>[file], subject: 'E&M audit trail');
      toast.show('Audit CSV ready');
    } on ApiException catch (e) {
      toast.show(e.message);
    } catch (e) {
      toast.show('Export failed — $e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final filters = ref.watch(auditFiltersProvider);
    final ctl = ref.read(auditFiltersProvider.notifier);
    final async = ref.watch(auditLogProvider);
    final users = ref.watch(usersProvider).valueOrNull ?? const [];

    String? actorLabel;
    if (filters.actorId.isNotEmpty) {
      for (final u in users) {
        if (u.id == filters.actorId) {
          actorLabel = '${u.name} (${u.userId})';
          break;
        }
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('Audit trail', style: AppText.sectionTitle),
                  const SizedBox(height: 4),
                  Text(
                    'Every recorded action — filter by user and date.',
                    style: AppText.sans(size: 13, color: T.secondary),
                  ),
                ],
              ),
            ),
            FilledActionButton.ink(
              label: _exporting ? 'Exporting…' : 'Export CSV',
              onPressed: _exporting ? null : _export,
              fontSize: 13,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            ),
          ],
        ),
        const SizedBox(height: 14),
        LayoutBuilder(
          builder: (context, constraints) {
            final half = constraints.maxWidth < T.mobileBreakpoint
                ? constraints.maxWidth
                : (constraints.maxWidth - 12) / 2;
            return Wrap(
              spacing: 12,
              runSpacing: 12,
              children: <Widget>[
                SizedBox(
                  width: half,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      const FieldLabel(label: 'User'),
                      const SizedBox(height: 6),
                      AppSelect(
                        value: actorLabel ?? '',
                        options: [
                          for (final u in users) '${u.name} (${u.userId})',
                        ],
                        placeholder: 'All users',
                        onChanged: (label) {
                          if (label == null || label.isEmpty) {
                            ctl.setActorId('');
                            return;
                          }
                          for (final u in users) {
                            if ('${u.name} (${u.userId})' == label) {
                              ctl.setActorId(u.id);
                              return;
                            }
                          }
                          ctl.setActorId('');
                        },
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: half,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      const FieldLabel(label: 'Action'),
                      const SizedBox(height: 6),
                      AppTextField(
                        controller: _actionController,
                        placeholder: 'e.g. user_created',
                        onChanged: ctl.setAction,
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: half,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      const FieldLabel(label: 'From'),
                      const SizedBox(height: 6),
                      PickerField(
                        display: filters.dateFrom,
                        placeholder: 'yyyy-mm-dd',
                        onTap: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate:
                                Dates.parse(filters.dateFrom) ?? DateTime.now(),
                            firstDate: DateTime(2020),
                            lastDate: DateTime.now(),
                          );
                          if (picked != null) ctl.setFrom(Dates.iso(picked));
                        },
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: half,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      const FieldLabel(label: 'To'),
                      const SizedBox(height: 6),
                      PickerField(
                        display: filters.dateTo,
                        placeholder: 'yyyy-mm-dd',
                        onTap: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate:
                                Dates.parse(filters.dateTo) ?? DateTime.now(),
                            firstDate: DateTime(2020),
                            lastDate: DateTime.now(),
                          );
                          if (picked != null) ctl.setTo(Dates.iso(picked));
                        },
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 16),
        async.when(
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: 40),
            child: Center(child: CircularProgressIndicator(color: T.green)),
          ),
          error: (e, _) => InlineError(message: e.toString()),
          data: (page) => _AuditList(page: page),
        ),
      ],
    );
  }
}

class _AuditList extends ConsumerWidget {
  const _AuditList({required this.page});

  final AuditLogPage page;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filters = ref.watch(auditFiltersProvider);
    final ctl = ref.read(auditFiltersProvider.notifier);
    final totalPages = page.pageSize == 0
        ? 1
        : ((page.total + page.pageSize - 1) ~/ page.pageSize).clamp(1, 9999);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          '${page.total} event${page.total == 1 ? '' : 's'}',
          style: AppText.sans(size: 13, color: T.secondary),
        ),
        const SizedBox(height: 10),
        if (page.items.isEmpty)
          const EmptyState(message: 'No audit events match these filters.')
        else
          Column(
            children: <Widget>[
              for (final e in page.items) ...<Widget>[
                _AuditRow(entry: e),
                const SizedBox(height: 8),
              ],
            ],
          ),
        if (totalPages > 1) ...<Widget>[
          const SizedBox(height: 14),
          Row(
            children: <Widget>[
              OutlineActionButton(
                label: 'Previous',
                onPressed: filters.page <= 1
                    ? null
                    : () => ctl.setPage(filters.page - 1),
              ),
              const SizedBox(width: 12),
              Text(
                'Page ${filters.page} of $totalPages',
                style: AppText.sans(size: 13, color: T.secondary),
              ),
              const SizedBox(width: 12),
              OutlineActionButton(
                label: 'Next',
                onPressed: filters.page >= totalPages
                    ? null
                    : () => ctl.setPage(filters.page + 1),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _AuditRow extends StatelessWidget {
  const _AuditRow({required this.entry});

  final AuditLogEntry entry;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: T.card,
        borderRadius: T.cardSmShape,
        border: Border.all(color: T.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  entry.action,
                  style: AppText.mono(size: 13.5, weight: FontWeight.w700),
                ),
              ),
              Text(
                entry.createdAt.length > 19
                    ? entry.createdAt.substring(0, 19)
                    : entry.createdAt,
                style: AppText.meta,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${entry.actorLabel} · ${entry.objectType}/${entry.objectId}',
            style: AppText.sans(size: 12.5, color: T.secondary),
          ),
        ],
      ),
    );
  }
}

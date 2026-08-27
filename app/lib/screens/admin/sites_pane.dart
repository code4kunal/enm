import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories.dart';
import '../../models/site.dart';
import '../../state/providers.dart';
import '../../state/session.dart';
import '../../state/sites.dart';
import '../../state/toast.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../utils/dates.dart';
import '../../widgets/buttons.dart';
import '../../widgets/chips.dart';
import '../../widgets/dashed.dart';
import '../../widgets/form_controls.dart';
import '../../widgets/sub_tabs.dart';

/// One row from GET /siteops/sites for the onboard picker.
class _SiteOpsOption {
  const _SiteOpsOption({required this.id, required this.name});
  final String id;
  final String name;
}

/// Site onboarding. Super admin only — this is the estate roster.
class SitesPane extends ConsumerStatefulWidget {
  const SitesPane({super.key});

  @override
  ConsumerState<SitesPane> createState() => _SitesPaneState();
}

class _SitesPaneState extends ConsumerState<SitesPane> {
  SiteDraft? _draft;
  String? _error;
  bool _saving = false;
  List<_SiteOpsOption> _siteOpsOptions = const <_SiteOpsOption>[];
  bool _siteOpsLoading = false;

  final _codeController = TextEditingController();
  final _nameController = TextEditingController();
  final _addressController = TextEditingController();

  @override
  void dispose() {
    _codeController.dispose();
    _nameController.dispose();
    _addressController.dispose();
    super.dispose();
  }

  Future<void> _loadSiteOpsOptions() async {
    setState(() => _siteOpsLoading = true);
    try {
      final json = await ref.read(apiClientProvider).get('/siteops/sites');
      final data = (json is Map ? json['data'] : json) as List<dynamic>? ?? [];
      final options = data
          .cast<Map<String, dynamic>>()
          .map(
            (j) => _SiteOpsOption(
              id: j['id']?.toString() ?? '',
              name: j['name']?.toString() ?? '',
            ),
          )
          .where((o) => o.id.isNotEmpty)
          .toList()
        ..sort((a, b) => a.name.compareTo(b.name));
      if (mounted) {
        setState(() {
          _siteOpsOptions = options;
          _siteOpsLoading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _siteOpsOptions = const <_SiteOpsOption>[];
          _siteOpsLoading = false;
        });
      }
    }
  }

  void _open(SiteDraft draft) {
    _codeController.text = draft.code;
    _nameController.text = draft.name;
    _addressController.text = draft.address;
    setState(() {
      _draft = draft;
      _error = null;
    });
    if (!draft.isEdit) {
      unawaited(_loadSiteOpsOptions());
    }
  }

  void _close() => setState(() {
        _draft = null;
        _error = null;
      });

  Future<void> _save() async {
    final draft = _draft;
    if (draft == null || _saving) return;

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = await ref.read(sitesAdminProvider.notifier).save(
            draft.copyWith(
              code: _codeController.text,
              name: _nameController.text,
              address: _addressController.text,
            ),
          );
      if (!mounted) return;
      ref.read(toastProvider.notifier).show(
            draft.isEdit
                ? '${saved.code} updated'
                : '${saved.code} onboarded — checklists seeded'
                    '${saved.isLinkedToSiteOps ? ', fleet synced from SiteOps' : ''}'
                    ' — assign users next',
          );
      _close();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not save — $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _toggle(Site site) async {
    try {
      await ref
          .read(sitesAdminProvider.notifier)
          .setActive(site.code, !site.isActive);
      if (!mounted) return;
      ref.read(toastProvider.notifier).show(
            site.isActive
                ? '${site.code} deactivated — no new entries accepted'
                : '${site.code} reactivated',
          );
    } on ApiException catch (e) {
      if (mounted) ref.read(toastProvider.notifier).show(e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(sitesAdminProvider);
    final sites = async.valueOrNull ?? const <Site>[];
    final active = sites.where((s) => s.isActive).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ScreenHeader(
          title: 'Sites',
          subtitle: '$active active of ${sites.length}. Onboarding links a '
              'SiteOps site, seeds checklists for bus/truck, and pulls vehicles.',
          action: FilledActionButton(
            label: '+ Onboard site',
            onPressed: () => _open(const SiteDraft()),
            fontSize: 14,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          ),
        ),
        if (_draft != null) ...<Widget>[
          const SizedBox(height: 16),
          _SiteForm(
            draft: _draft!,
            codeController: _codeController,
            nameController: _nameController,
            addressController: _addressController,
            error: _error,
            saving: _saving,
            siteOpsOptions: _siteOpsOptions,
            siteOpsLoading: _siteOpsLoading,
            onCommissionedChanged: (d) =>
                setState(() => _draft = _draft!.copyWith(commissionedOn: d)),
            onSiteOpsChanged: (id) => setState(
              () => _draft = _draft!.copyWith(
                siteopsSiteId: id,
                clearSiteopsSiteId: id == null,
              ),
            ),
            onCategoriesChanged: (cats) => setState(
              () => _draft = _draft!.copyWith(operatingCategories: cats),
            ),
            onCancel: _close,
            onSave: _save,
          ),
        ],
        const SizedBox(height: 16),
        if (async.isLoading && sites.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 40),
            child: Center(child: CircularProgressIndicator(color: T.green)),
          )
        else if (sites.isEmpty)
          const EmptyState(message: 'No sites onboarded yet.')
        else
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (final s in sites) ...<Widget>[
                _SiteRow(
                  site: s,
                  onEdit: () => _open(SiteDraft.fromSite(s)),
                  onToggle: () => _toggle(s),
                ),
                const SizedBox(height: 8),
              ],
            ],
          ),
      ],
    );
  }
}

class _SiteForm extends StatelessWidget {
  const _SiteForm({
    required this.draft,
    required this.codeController,
    required this.nameController,
    required this.addressController,
    required this.error,
    required this.saving,
    required this.siteOpsOptions,
    required this.siteOpsLoading,
    required this.onCommissionedChanged,
    required this.onSiteOpsChanged,
    required this.onCategoriesChanged,
    required this.onCancel,
    required this.onSave,
  });

  final SiteDraft draft;
  final TextEditingController codeController;
  final TextEditingController nameController;
  final TextEditingController addressController;
  final String? error;
  final bool saving;
  final List<_SiteOpsOption> siteOpsOptions;
  final bool siteOpsLoading;
  final ValueChanged<String> onCommissionedChanged;
  final ValueChanged<String?> onSiteOpsChanged;
  final ValueChanged<List<String>> onCategoriesChanged;
  final VoidCallback onCancel;
  final VoidCallback onSave;

  void _toggleCategory(String category, bool selected) {
    final next = {...draft.operatingCategories};
    if (selected) {
      next.add(category);
    } else {
      next.remove(category);
    }
    if (next.isEmpty) return;
    onCategoriesChanged(next.toList()..sort());
  }

  @override
  Widget build(BuildContext context) {
    return Panel(
      accent: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(draft.title, style: AppText.sectionTitle),
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (context, constraints) {
              final gap = constraints.maxWidth * 0.04;
              final narrow = constraints.maxWidth < T.mobileBreakpoint;
              final half =
                  narrow ? constraints.maxWidth : (constraints.maxWidth - gap) / 2;

              return Wrap(
                spacing: gap,
                runSpacing: 16,
                children: <Widget>[
                  SizedBox(
                    width: half,
                    child: _field(
                      const FieldLabel(
                        label: 'Site code',
                        required: true,
                        hint: '— short, uppercase, permanent',
                      ),
                      AppTextField(
                        controller: codeController,
                        placeholder: 'MBMT',
                        mono: true,
                        uppercase: true,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: half,
                    child: _field(
                      const FieldLabel(label: 'Site name', required: true),
                      AppTextField(
                        controller: nameController,
                        placeholder: 'Mira Bhayandar Municipal Transport',
                      ),
                    ),
                  ),
                  if (!draft.isEdit) ...<Widget>[
                    SizedBox(
                      width: half,
                      child: _field(
                        const FieldLabel(
                          label: 'SiteOps site',
                          required: true,
                          hint: '— vehicles pull from here',
                        ),
                        siteOpsLoading
                            ? const Padding(
                                padding: EdgeInsets.symmetric(vertical: 12),
                                child: LinearProgressIndicator(color: T.green),
                              )
                            : DropdownButtonFormField<String>(
                                initialValue: draft.siteopsSiteId,
                                isExpanded: true,
                                decoration: const InputDecoration(
                                  border: OutlineInputBorder(),
                                  contentPadding: EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 10,
                                  ),
                                ),
                                hint: Text(
                                  siteOpsOptions.isEmpty
                                      ? 'No SiteOps sites available'
                                      : 'Select SiteOps site',
                                  style: AppText.sans(size: 14, color: T.muted),
                                ),
                                items: [
                                  for (final o in siteOpsOptions)
                                    DropdownMenuItem<String>(
                                      value: o.id,
                                      child: Text(
                                        o.name,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                ],
                                onChanged: saving ? null : onSiteOpsChanged,
                              ),
                      ),
                    ),
                    SizedBox(
                      width: half,
                      child: _field(
                        const FieldLabel(
                          label: 'Operations',
                          required: true,
                          hint: '— which checklists to seed',
                        ),
                        Row(
                          children: <Widget>[
                            FilterChip(
                              label: const Text('Bus'),
                              selected:
                                  draft.operatingCategories.contains('bus'),
                              onSelected: saving
                                  ? null
                                  : (v) => _toggleCategory('bus', v),
                            ),
                            const SizedBox(width: 8),
                            FilterChip(
                              label: const Text('Truck'),
                              selected:
                                  draft.operatingCategories.contains('truck'),
                              onSelected: saving
                                  ? null
                                  : (v) => _toggleCategory('truck', v),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                  SizedBox(
                    width: half,
                    child: _field(
                      const FieldLabel(label: 'Address'),
                      AppTextField(
                        controller: addressController,
                        placeholder: 'Mira Road (E), Thane',
                      ),
                    ),
                  ),
                  SizedBox(
                    width: half,
                    child: _field(
                      const FieldLabel(
                        label: 'Commissioned on',
                        hint: '— leave blank until it goes live',
                      ),
                      PickerField(
                        display: draft.commissionedOn ?? '',
                        placeholder: 'Not commissioned',
                        onTap: () async {
                          final current =
                              Dates.parse(draft.commissionedOn) ?? DateTime.now();
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: current,
                            firstDate: DateTime(current.year - 10),
                            lastDate: DateTime(current.year + 5),
                          );
                          if (picked != null) {
                            onCommissionedChanged(Dates.iso(picked));
                          }
                        },
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
          if (error != null) InlineError(message: error!),
          const SizedBox(height: 18),
          Row(
            children: <Widget>[
              OutlineActionButton(
                label: 'Cancel',
                onPressed: saving ? null : onCancel,
                fontSize: 15,
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledActionButton(
                  label: saving ? 'Saving…' : draft.cta,
                  onPressed: saving ? null : onSave,
                  fontSize: 15.5,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _field(Widget label, Widget control) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[label, control],
      );
}

class _SiteRow extends ConsumerWidget {
  const _SiteRow({
    required this.site,
    required this.onEdit,
    required this.onToggle,
  });

  final Site site;
  final VoidCallback onEdit;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(sessionProvider.select((s) => s.site));

    return Opacity(
      opacity: site.isActive ? 1 : 0.62,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: T.card,
          borderRadius: T.cardSmShape,
          border: Border.all(
            color: site.code == current ? T.green : T.border,
            width: site.code == current ? 1.5 : 1,
          ),
        ),
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 14,
          runSpacing: 12,
          children: <Widget>[
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: site.isActive ? T.ink : T.inactiveFill,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    site.code,
                    style: AppText.mono(
                      size: 13,
                      weight: FontWeight.w700,
                      color: site.isActive ? T.white : T.muted,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 300),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        site.name,
                        style: AppText.sans(size: 15, weight: FontWeight.w700),
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (site.address.isNotEmpty)
                        Text(
                          site.address,
                          style: AppText.sans(size: 12.5, color: T.muted),
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
              ],
            ),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                TagBadge(
                  label: '${site.vehicleCount} vehicles',
                  background: T.subtleFill,
                  foreground: T.secondary,
                  border: T.border,
                ),
                TagBadge(
                  label: '${site.userCount} users',
                  background: T.subtleFill,
                  foreground: T.secondary,
                  border: T.border,
                ),
                if (site.isLinkedToSiteOps)
                  const TagBadge(
                    label: 'SITEOPS',
                    background: T.blueTint,
                    foreground: T.blue,
                  ),
                if (!site.isCommissioned)
                  const TagBadge(
                    label: 'NOT COMMISSIONED',
                    background: T.amberTint,
                    foreground: T.amber,
                  ),
                if (!site.isActive)
                  const TagBadge(
                    label: 'INACTIVE',
                    background: T.inactiveFill,
                    foreground: T.muted,
                  ),
              ],
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                OutlineActionButton(
                  label: 'Edit',
                  onPressed: onEdit,
                  accent: T.green,
                  fontSize: 12.5,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
                ),
                const SizedBox(width: 8),
                OutlineActionButton(
                  label: site.isActive ? 'Deactivate' : 'Activate',
                  onPressed: onToggle,
                  foreground: site.isActive ? T.redInk : T.greenInk,
                  borderColor: site.isActive ? T.redBorderTint : T.green,
                  fontSize: 12.5,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories.dart';
import '../../models/site.dart';
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

  void _open(SiteDraft draft) {
    _codeController.text = draft.code;
    _nameController.text = draft.name;
    _addressController.text = draft.address;
    setState(() {
      _draft = draft;
      _error = null;
    });
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
                : '${saved.code} onboarded — assign users to it next',
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
          subtitle: '$active active of ${sites.length}. Onboarding a site makes '
              'it available to assign users, vehicles and a docking plan.',
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
            onCommissionedChanged: (d) =>
                setState(() => _draft = _draft!.copyWith(commissionedOn: d)),
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
    required this.onCommissionedChanged,
    required this.onCancel,
    required this.onSave,
  });

  final SiteDraft draft;
  final TextEditingController codeController;
  final TextEditingController nameController;
  final TextEditingController addressController;
  final String? error;
  final bool saving;
  final ValueChanged<String> onCommissionedChanged;
  final VoidCallback onCancel;
  final VoidCallback onSave;

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

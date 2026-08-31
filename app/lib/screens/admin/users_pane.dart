import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories.dart';
import '../../models/app_user.dart';
import '../../state/providers.dart';
import '../../state/session.dart';
import '../../state/toast.dart';
import '../../state/users.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/buttons.dart';
import '../../widgets/chips.dart';
import '../../widgets/code_square.dart';
import '../../widgets/dashed.dart';
import '../../widgets/form_controls.dart';
import '../../widgets/sub_tabs.dart';

/// User administration.
///
/// A super admin sees and creates everyone; a manager sees only staff on their
/// own sites and can mint supervisors and executives, never peers.
class UsersPane extends ConsumerStatefulWidget {
  const UsersPane({super.key});

  @override
  ConsumerState<UsersPane> createState() => _UsersPaneState();
}

class _UsersPaneState extends ConsumerState<UsersPane> {
  UserDraft? _draft;
  String? _error;
  bool _saving = false;
  bool _syncing = false;

  /// Shown once after a create or reset — the admin has to hand it over.
  ({String name, String password})? _issued;

  final _nameController = TextEditingController();
  final _idController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    _idController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _open(UserDraft draft) {
    _nameController.text = draft.name;
    _idController.text = draft.userId;
    _emailController.text = draft.email;
    _passwordController.clear();
    setState(() {
      _draft = draft;
      _error = null;
      _issued = null;
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
      final result = await ref.read(usersProvider.notifier).save(
            draft.copyWith(
              name: _nameController.text,
              userId: _idController.text,
              email: _emailController.text,
              password: _passwordController.text,
            ),
          );
      if (!mounted) return;
      _close();
      final temp = result.temporaryPassword;
      if (temp != null) {
        setState(() => _issued = (name: result.user.name, password: temp));
      }
      ref
          .read(toastProvider.notifier)
          .show(draft.isEdit ? 'User updated' : 'User created');
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not save — $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _toggleActive(AppUser user) async {
    try {
      await ref.read(usersProvider.notifier).setActive(user.id, !user.active);
      if (!mounted) return;
      ref.read(toastProvider.notifier).show(
            user.active
                ? '${user.name} deactivated — all sessions revoked'
                : '${user.name} reactivated',
          );
    } on ApiException catch (e) {
      if (mounted) ref.read(toastProvider.notifier).show(e.message);
    }
  }

  Future<void> _resetPassword(AppUser user) async {
    try {
      final temp = await ref.read(usersProvider.notifier).resetPassword(user.id);
      if (!mounted) return;
      setState(() => _issued = (name: user.name, password: temp));
      ref
          .read(toastProvider.notifier)
          .show('Password reset — all sessions revoked');
    } on ApiException catch (e) {
      if (mounted) ref.read(toastProvider.notifier).show(e.message);
    }
  }

  Future<void> _syncFromSiteOps() async {
    final site = ref.read(sessionProvider).site;
    if (site.isEmpty || _syncing) return;
    setState(() => _syncing = true);
    try {
      final json = await ref
          .read(apiClientProvider)
          .post('/sites/$site/users/sync-from-siteops');
      final r = json as Map<String, dynamic>;
      final synced = r['synced'] as int? ?? 0;
      final adopted = r['adopted'] as int? ?? 0;
      final parts = <String>[
        '$synced synced',
        if (adopted > 0) '$adopted adopted',
      ];
      if (!mounted) return;
      ref.read(toastProvider.notifier).show('Users: ${parts.join(', ')}.');
      ref.invalidate(usersProvider);
    } on ApiException catch (e) {
      if (mounted) ref.read(toastProvider.notifier).show(e.message);
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final async = ref.watch(usersProvider);
    final all = async.valueOrNull ?? const <AppUser>[];
    final visible = ref.watch(filteredUsersProvider);
    final filter = ref.watch(userFilterProvider);

    // A super admin assigns any site; a manager only their own.
    final assignableSites = session.governsAllSites
        ? ref.watch(siteCodesProvider)
        : session.availableSites;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ScreenHeader(
          title: 'Users',
          subtitle: session.governsAllSites
              ? 'Every account across the estate. Create logins, assign roles '
                  'and site access. Inactive users cannot sign in.'
              : 'Staff on your sites. You can create supervisors and '
                  'executives; promotion is a super-admin action.',
          action: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextButton.icon(
                onPressed: _syncing ? null : _syncFromSiteOps,
                icon: _syncing
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync, size: 18),
                label: Text(
                  _syncing ? 'Syncing…' : 'Sync now',
                  style: AppText.sans(size: 14, weight: FontWeight.w600),
                ),
              ),
              const SizedBox(width: 8),
              FilledActionButton(
                label: '+ Create user',
                onPressed: () => _open(
                  UserDraft(
                    role: session.user?.role.grantableRoles.last ??
                        UserRole.executive,
                  ),
                ),
                fontSize: 14,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
              ),
            ],
          ),
        ),

        if (_issued != null) ...<Widget>[
          const SizedBox(height: 16),
          _IssuedPassword(
            name: _issued!.name,
            password: _issued!.password,
            onDismiss: () => setState(() => _issued = null),
          ),
        ],

        if (_draft != null) ...<Widget>[
          const SizedBox(height: 16),
          _UserForm(
            draft: _draft!,
            sites: assignableSites,
            grantableRoles:
                session.user?.role.grantableRoles ?? const <UserRole>[],
            error: _error,
            saving: _saving,
            nameController: _nameController,
            idController: _idController,
            emailController: _emailController,
            passwordController: _passwordController,
            onDraftChanged: (d) => setState(() => _draft = d),
            onCancel: _close,
            onSave: _save,
          ),
        ],

        const SizedBox(height: 16),
        AppTextField(
          controller: _searchController,
          placeholder: 'Search name, User ID or email…',
          onChanged: ref.read(userQueryProvider.notifier).set,
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            _chip(UserFilter.all, 'All users (${all.length})', filter),
            _chip(
              UserFilter.active,
              'Active (${all.where((u) => u.active).length})',
              filter,
            ),
            _chip(
              UserFilter.inactive,
              'Inactive (${all.where((u) => !u.active).length})',
              filter,
            ),
          ],
        ),
        const SizedBox(height: 14),

        if (async.isLoading && all.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 40),
            child: Center(child: CircularProgressIndicator(color: T.green)),
          )
        else if (visible.isEmpty)
          const EmptyState(message: 'No users match.')
        else
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (final u in visible) ...<Widget>[
                _UserRow(
                  user: u,
                  isSelf: u.id == session.user?.id,
                  onEdit: () => _open(UserDraft.fromUser(u)),
                  onToggle: () => _toggleActive(u),
                  onReset: () => _resetPassword(u),
                ),
                const SizedBox(height: 8),
              ],
            ],
          ),
      ],
    );
  }

  Widget _chip(UserFilter value, String label, UserFilter current) => PillChip(
        label: label,
        selected: current == value,
        onTap: () => ref.read(userFilterProvider.notifier).set(value),
      );
}

/// One-time reveal of a generated password.
class _IssuedPassword extends StatelessWidget {
  const _IssuedPassword({
    required this.name,
    required this.password,
    required this.onDismiss,
  });

  final String name;
  final String password;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: T.greenTint,
        borderRadius: T.cardSmShape,
        border: Border.all(color: T.green),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Temporary password for $name',
            style: AppText.sans(
              size: 14,
              weight: FontWeight.w700,
              color: T.greenInk,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(
                child: SelectableText(
                  password,
                  style: AppText.mono(
                    size: 20,
                    weight: FontWeight.w700,
                    color: T.ink,
                  ),
                ),
              ),
              OutlineActionButton(
                label: 'Done',
                onPressed: onDismiss,
                fontSize: 13,
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Shown once. Hand it over now — they will be asked to change it at '
            'first sign-in.',
            style: AppText.sans(size: 12.5, color: T.greenInk),
          ),
        ],
      ),
    );
  }
}

class _UserForm extends StatelessWidget {
  const _UserForm({
    required this.draft,
    required this.sites,
    required this.grantableRoles,
    required this.error,
    required this.saving,
    required this.nameController,
    required this.idController,
    required this.emailController,
    required this.passwordController,
    required this.onDraftChanged,
    required this.onCancel,
    required this.onSave,
  });

  final UserDraft draft;
  final List<String> sites;
  final List<UserRole> grantableRoles;
  final String? error;
  final bool saving;
  final TextEditingController nameController;
  final TextEditingController idController;
  final TextEditingController emailController;
  final TextEditingController passwordController;
  final ValueChanged<UserDraft> onDraftChanged;
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
              final total = constraints.maxWidth;
              final gap = total * 0.04;
              final narrow = total < T.mobileBreakpoint;
              final half = narrow ? total : (total - gap) / 2;

              return Wrap(
                spacing: gap,
                runSpacing: 16,
                children: <Widget>[
                  SizedBox(
                    width: half,
                    child: _field(
                      const FieldLabel(label: 'Full name', required: true),
                      AppTextField(
                        controller: nameController,
                        placeholder: 'e.g. Sunil Patil',
                      ),
                    ),
                  ),
                  SizedBox(
                    width: half,
                    child: _field(
                      const FieldLabel(label: 'User ID', required: true),
                      AppTextField(
                        controller: idController,
                        placeholder: 'e.g. TV4105',
                        mono: true,
                        uppercase: true,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: half,
                    child: _field(
                      const FieldLabel(
                        label: 'Email',
                        hint: '— optional, enables Microsoft SSO',
                      ),
                      AppTextField(
                        controller: emailController,
                        placeholder: 'name@transvolt.in',
                      ),
                    ),
                  ),
                  SizedBox(
                    width: half,
                    child: _field(
                      FieldLabel(
                        label: draft.isEdit ? 'New password' : 'Password',
                        hint: '— leave blank to generate one',
                      ),
                      AppTextField(
                        controller: passwordController,
                        placeholder: 'Auto-generated if blank',
                        obscure: true,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: total,
                    child: _field(
                      const FieldLabel(label: 'Role', required: true),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: <Widget>[
                          for (final r in grantableRoles)
                            PillChip(
                              label: r.label,
                              selected: draft.role == r,
                              tone: ChipTone.green,
                              radius: T.controlShape,
                              onTap: () =>
                                  onDraftChanged(draft.copyWith(role: r)),
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (draft.needsSiteAccess)
                    SizedBox(
                      width: total,
                      child: _field(
                        const FieldLabel(
                          label: 'Site access',
                          required: true,
                          hint: '— select one or more',
                        ),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: <Widget>[
                            for (final s in sites)
                              PillChip(
                                label: s,
                                mono: true,
                                tone: ChipTone.green,
                                selected: draft.sites.contains(s),
                                onTap: () =>
                                    onDraftChanged(draft.toggleSite(s)),
                              ),
                          ],
                        ),
                      ),
                    )
                  else
                    SizedBox(
                      width: total,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        decoration: const BoxDecoration(
                          color: T.indigoTint,
                          borderRadius: T.controlShape,
                        ),
                        child: Text(
                          'A super admin reaches every site, including ones '
                          'onboarded later. No access list needed.',
                          style: AppText.sans(size: 13.5, color: T.indigo),
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

class _UserRow extends StatelessWidget {
  const _UserRow({
    required this.user,
    required this.isSelf,
    required this.onEdit,
    required this.onToggle,
    required this.onReset,
  });

  final AppUser user;
  final bool isSelf;
  final VoidCallback onEdit;
  final VoidCallback onToggle;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: user.active ? 1 : 0.62,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: T.card,
          borderRadius: T.cardSmShape,
          border: Border.all(color: T.border),
        ),
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 12,
          children: <Widget>[
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                InitialsAvatar(initials: user.initials, active: user.active),
                const SizedBox(width: 12),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 320),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 8,
                        runSpacing: 4,
                        children: <Widget>[
                          Text(
                            user.name,
                            style: AppText.sans(
                              size: 15,
                              weight: FontWeight.w700,
                            ),
                          ),
                          TagBadge(
                            label: user.role.label,
                            background: user.role.badgeBg,
                            foreground: user.role.badgeFg,
                          ),
                          if (isSelf)
                            const TagBadge(
                              label: 'YOU',
                              background: T.subtleFill,
                              foreground: T.secondary,
                              border: T.border,
                            ),
                          if (user.mustResetPassword)
                            const TagBadge(
                              label: 'PASSWORD PENDING',
                              background: T.amberTint,
                              foreground: T.amber,
                            ),
                          if (!user.active)
                            const TagBadge(
                              label: 'INACTIVE',
                              background: T.inactiveFill,
                              foreground: T.muted,
                            ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      RichText(
                        text: TextSpan(
                          style: AppText.sans(size: 12.5, color: T.muted),
                          children: <InlineSpan>[
                            TextSpan(
                              text: user.userId,
                              style: AppText.mono(
                                size: 12.5,
                                weight: FontWeight.w600,
                                color: T.muted,
                              ),
                            ),
                            TextSpan(text: user.emailLabel),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (user.governsAllSites)
              const TagBadge(
                label: 'ALL SITES',
                background: T.indigoTint,
                foreground: T.indigo,
              )
            else
              Wrap(
                spacing: 5,
                runSpacing: 5,
                children: <Widget>[
                  for (final s in user.sites)
                    TagBadge(
                      label: s,
                      background: T.subtleFill,
                      foreground: T.secondary,
                      border: T.border,
                      mono: true,
                    ),
                ],
              ),
            if (user.isPlatformManaged)
              const TagBadge(
                label: 'MANAGED IN SITEOPS',
                background: T.indigoTint,
                foreground: T.indigo,
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  OutlineActionButton(
                    label: 'Edit',
                    onPressed: onEdit,
                    accent: T.green,
                    fontSize: 12.5,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 13, vertical: 7),
                  ),
                  OutlineActionButton(
                    label: 'Reset password',
                    onPressed: onReset,
                    accent: T.blue,
                    fontSize: 12.5,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 13, vertical: 7),
                  ),
                  OutlineActionButton(
                    label: user.active ? 'Deactivate' : 'Activate',
                    // A manager cannot lock themselves out.
                    onPressed: isSelf && user.active ? null : onToggle,
                    foreground: user.active ? T.redInk : T.greenInk,
                    borderColor: user.active ? T.redBorderTint : T.green,
                    fontSize: 12.5,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 13, vertical: 7),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

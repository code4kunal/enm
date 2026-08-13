import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/repositories.dart';
import '../router.dart';
import '../state/session.dart';
import '../state/toast.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/buttons.dart';
import '../widgets/chips.dart';
import '../widgets/code_square.dart';
import '../widgets/fade_up.dart';
import '../widgets/form_controls.dart';
import '../widgets/sub_tabs.dart';

/// Account screen. Every user reaches this — it is the only place a password
/// can be changed by its owner, which is why it is not gated on any role.
class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  final _currentController = TextEditingController();
  final _nextController = TextEditingController();
  final _confirmController = TextEditingController();

  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _currentController.dispose();
    _nextController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _changePassword() async {
    if (_saving) return;

    final current = _currentController.text;
    final next = _nextController.text;
    final confirm = _confirmController.text;

    // Check locally first so an obvious slip costs no round trip.
    if (current.isEmpty || next.isEmpty) {
      setState(() => _error = 'Enter your current and new password');
      return;
    }
    if (next.length < 8) {
      setState(() => _error = 'New password must be at least 8 characters');
      return;
    }
    if (next == current) {
      setState(() => _error = 'The new password must differ from the current one');
      return;
    }
    if (next != confirm) {
      setState(() => _error = 'The two new passwords do not match');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      await ref.read(sessionProvider.notifier).changePassword(current, next);
      if (!mounted) return;
      _currentController.clear();
      _nextController.clear();
      _confirmController.clear();
      ref
          .read(toastProvider.notifier)
          .show('Password changed — other devices signed out');
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not change password — $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final user = session.user;

    if (user == null) return const SizedBox.shrink();

    return FadeUp(
      key: const ValueKey<String>('profile'),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: T.maxFormWidth),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              BackLink(onTap: () => context.go(Routes.home)),
              const SizedBox(height: 10),

              // Identity card.
              Panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        InitialsAvatar(initials: user.initials, size: 48),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Text(
                                user.name,
                                style: AppText.sans(
                                  size: 18,
                                  weight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Wrap(
                                spacing: 8,
                                runSpacing: 6,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: <Widget>[
                                  TagBadge(
                                    label: user.role.label,
                                    background: user.role.badgeBg,
                                    foreground: user.role.badgeFg,
                                  ),
                                  Text(
                                    user.userId,
                                    style: AppText.mono(
                                      size: 13,
                                      color: T.secondary,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 28,
                      runSpacing: 14,
                      children: <Widget>[
                        StatCell(
                          label: 'Sign-in',
                          value: user.canUseSso ? 'Microsoft SSO' : 'User ID',
                          mono: false,
                        ),
                        StatCell(
                          label: 'Email',
                          value: user.canUseSso ? user.email : 'Not set',
                          mono: false,
                          tone: user.canUseSso ? null : T.muted,
                        ),
                        StatCell(
                          label: 'Site access',
                          value: user.siteLabel.isEmpty
                              ? 'None'
                              : user.siteLabel,
                          mono: false,
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              if (session.mustResetPassword) ...<Widget>[
                const SizedBox(height: 14),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
                  decoration: BoxDecoration(
                    color: T.redTint,
                    borderRadius: T.cardSmShape,
                    border: Border.all(color: T.redBorderTint),
                  ),
                  child: Text(
                    'Your password was set by an administrator. Change it now '
                    'so only you know it.',
                    style: AppText.sans(
                      size: 14,
                      weight: FontWeight.w600,
                      color: T.redInkDeep,
                    ),
                  ),
                ),
              ],

              const SizedBox(height: 16),

              // Password change.
              Panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Text('Change password', style: AppText.sectionTitle),
                    const SizedBox(height: 4),
                    Text(
                      'Changing your password signs you out everywhere else.',
                      style: AppText.sans(size: 13.5, color: T.secondary),
                    ),
                    const SizedBox(height: 16),
                    const FieldLabel(label: 'Current password', required: true),
                    AppTextField(
                      controller: _currentController,
                      placeholder: 'Current password',
                      obscure: true,
                      onChanged: (_) => setState(() => _error = null),
                    ),
                    const SizedBox(height: 14),
                    const FieldLabel(
                      label: 'New password',
                      required: true,
                      hint: '— at least 8 characters',
                    ),
                    AppTextField(
                      controller: _nextController,
                      placeholder: 'New password',
                      obscure: true,
                      onChanged: (_) => setState(() => _error = null),
                    ),
                    const SizedBox(height: 14),
                    const FieldLabel(
                      label: 'Confirm new password',
                      required: true,
                    ),
                    AppTextField(
                      controller: _confirmController,
                      placeholder: 'Repeat the new password',
                      obscure: true,
                      onChanged: (_) => setState(() => _error = null),
                      onSubmitted: (_) => _changePassword(),
                    ),
                    if (_error != null) InlineError(message: _error!),
                    const SizedBox(height: 18),
                    FilledActionButton(
                      label: _saving ? 'Saving…' : 'Change password',
                      onPressed: _saving ? null : _changePassword,
                      fontSize: 15.5,
                      expand: true,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),
              Panel(
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text('Session', style: AppText.sectionTitle),
                          const SizedBox(height: 3),
                          Text(
                            'Signed in against the live API.',
                            style:
                                AppText.sans(size: 13.5, color: T.secondary),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    OutlineActionButton(
                      label: 'Sign out',
                      onPressed: () =>
                          ref.read(sessionProvider.notifier).signOut(),
                      foreground: T.redInk,
                      borderColor: T.redBorderTint,
                      fontSize: 14,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}

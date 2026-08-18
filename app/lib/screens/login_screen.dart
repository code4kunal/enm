import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/session.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/buttons.dart';
import '../widgets/chevron_backdrop.dart';
import '../widgets/chips.dart';
import '../widgets/fade_up.dart';
import '../widgets/form_controls.dart';
import '../data/auth/ms_sso.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _idController = TextEditingController();
  final _pwController = TextEditingController();

  @override
  void dispose() {
    _idController.dispose();
    _pwController.dispose();
    super.dispose();
  }

  void _submitCredentials() {
    ref.read(sessionProvider.notifier).signInWithCredentials(
          _idController.text,
          _pwController.text,
        );
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);

    return Scaffold(
      backgroundColor: T.loginBg,
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          const ChevronBackdrop(),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: FadeUp(
                  duration: T.loginFade,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(40, 44, 40, 36),
                      decoration: BoxDecoration(
                        color: T.card,
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: T.loginCardShadow,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          const _LoginMasthead(),
                          if (session.stage == AuthStage.choosingSite)
                            _SiteStage(session: session)
                          else
                            _SsoStage(
                              session: session,
                              idController: _idController,
                              pwController: _pwController,
                              onSubmit: _submitCredentials,
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LoginMasthead extends StatelessWidget {
  const _LoginMasthead();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Image.asset(
            'assets/images/transvolt-logo.png',
            width: 220,
            fit: BoxFit.contain,
            // The wordmark carries the brand; the semantic label replaces it
            // for screen readers.
            semanticLabel: 'Transvolt',
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'E & M MAINTENANCE',
          textAlign: TextAlign.center,
          style: AppText.sans(
            size: 13,
            weight: FontWeight.w600,
            color: T.green,
            letterSpacing: 0.22 * 13,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Ground operations register · All sites',
          textAlign: TextAlign.center,
          style: AppText.sans(size: 14, color: T.secondary),
        ),
      ],
    );
  }
}

/// Microsoft SSO + User ID credential fallback.
class _SsoStage extends ConsumerWidget {
  const _SsoStage({
    required this.session,
    required this.idController,
    required this.pwController,
    required this.onSubmit,
  });

  final SessionState session;
  final TextEditingController idController;
  final TextEditingController pwController;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(sessionProvider.notifier);
    final sso = ref.watch(ssoConfigProvider).valueOrNull ?? SsoConfig.off;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SizedBox(height: 32),
        // Only offered where the server says it is configured — otherwise the
        // card is just the User ID form, with no dead button on it.
        if (sso.usable) ...<Widget>[
          _MicrosoftButton(
            signing: session.signingIn,
            onTap: () => controller.signInWithMicrosoft(sso),
          ),
          const SizedBox(height: 22),
        ],
        Row(
          children: <Widget>[
            const Expanded(child: Divider(color: T.border)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                sso.usable ? 'OR SIGN IN WITH USER ID' : 'SIGN IN WITH USER ID',
                style: AppText.sans(
                  size: 12,
                  weight: FontWeight.w600,
                  color: T.muted,
                ),
              ),
            ),
            const Expanded(child: Divider(color: T.border)),
          ],
        ),
        const SizedBox(height: 16),
        AppTextField(
          controller: idController,
          placeholder: 'User ID (e.g. TV4021)',
          mono: true,
          uppercase: false,
          textInputAction: TextInputAction.next,
          onChanged: (_) => controller.clearError(),
        ),
        const SizedBox(height: 10),
        AppTextField(
          controller: pwController,
          placeholder: 'Password',
          obscure: true,
          textInputAction: TextInputAction.done,
          onChanged: (_) => controller.clearError(),
          onSubmitted: (_) => onSubmit(),
        ),
        if (session.error != null) ...<Widget>[
          const SizedBox(height: 10),
          Text(
            session.error!,
            style: AppText.sans(
              size: 13,
              weight: FontWeight.w600,
              color: T.red,
            ),
          ),
        ],
        const SizedBox(height: 10),
        FilledActionButton.ink(
          label: 'Sign in',
          onPressed: onSubmit,
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 18),
          expand: true,
        ),
        const SizedBox(height: 14),
        Text(
          'Ground staff without a Transvolt mail ID use the User ID issued by '
          'the site manager.',
          textAlign: TextAlign.center,
          style: AppText.sans(size: 12.5, color: T.muted),
        ),
      ],
    );
  }
}

/// White button with the Microsoft four-square mark. While connecting, a light
/// green highlight sweeps across it.
class _MicrosoftButton extends StatefulWidget {
  const _MicrosoftButton({required this.signing, required this.onTap});

  final bool signing;
  final VoidCallback onTap;

  @override
  State<_MicrosoftButton> createState() => _MicrosoftButtonState();
}

class _MicrosoftButtonState extends State<_MicrosoftButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    if (widget.signing) _sweep.repeat();
  }

  @override
  void didUpdateWidget(_MicrosoftButton old) {
    super.didUpdateWidget(old);
    if (widget.signing && !_sweep.isAnimating) {
      _sweep.repeat();
    } else if (!widget.signing && _sweep.isAnimating) {
      _sweep.stop();
      _sweep.value = 0;
    }
  }

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.signing ? null : widget.onTap,
        child: AnimatedContainer(
          duration: T.hoverLift,
          constraints: const BoxConstraints(minHeight: T.minTouchTarget),
          decoration: BoxDecoration(
            color: T.card,
            borderRadius: T.buttonShape,
            border: Border.all(
              color: _hovered ? T.ink : T.inputBorder,
              width: 1.5,
            ),
            // `0 4px 14px rgba(0,0,0,.08)` on hover.
            boxShadow: _hovered
                ? const <BoxShadow>[
                    BoxShadow(
                      color: Color(0x14000000),
                      blurRadius: 14,
                      offset: Offset(0, 4),
                    ),
                  ]
                : null,
          ),
          child: ClipRRect(
            borderRadius: T.buttonShape,
            child: Stack(
              children: <Widget>[
                Padding(
                  padding:
                      const EdgeInsets.symmetric(vertical: 15, horizontal: 18),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      const _MicrosoftMark(),
                      const SizedBox(width: 12),
                      Flexible(
                        child: Text(
                          widget.signing
                              ? 'Connecting to Microsoft…'
                              : 'Sign in with Microsoft',
                          style: AppText.sans(size: 16, weight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),
                if (widget.signing)
                  Positioned.fill(
                    child: AnimatedBuilder(
                      animation: _sweep,
                      builder: (context, _) => FractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        widthFactor: 0.4,
                        child: FractionalTranslation(
                          // -120% → 320% of the button width, matching the
                          // prototype's sweep keyframes.
                          translation: Offset(
                            (-1.2 + 4.4 * _sweep.value) / 0.4,
                            0,
                          ),
                          child: const DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.centerLeft,
                                end: Alignment.centerRight,
                                colors: <Color>[
                                  Color(0x00568A37),
                                  Color(0x26568A37),
                                  Color(0x00568A37),
                                ],
                              ),
                            ),
                            child: SizedBox.expand(),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MicrosoftMark extends StatelessWidget {
  const _MicrosoftMark();

  @override
  Widget build(BuildContext context) {
    const tile = 9.0;
    const gap = 2.0;
    Widget square(Color c) => Container(width: tile, height: tile, color: c);

    return SizedBox(
      width: tile * 2 + gap,
      height: tile * 2 + gap,
      child: Column(
        children: <Widget>[
          Row(
            children: <Widget>[
              square(const Color(0xFFF25022)),
              const SizedBox(width: gap),
              square(const Color(0xFF7FBA00)),
            ],
          ),
          const SizedBox(height: gap),
          Row(
            children: <Widget>[
              square(const Color(0xFF00A4EF)),
              const SizedBox(width: gap),
              square(const Color(0xFFFFB900)),
            ],
          ),
        ],
      ),
    );
  }
}

/// Site picker shown once authentication succeeds.
class _SiteStage extends ConsumerWidget {
  const _SiteStage({required this.session});

  final SessionState session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(sessionProvider.notifier);
    final sites = session.availableSites;
    final user = session.user;
    // Nothing to pick on a fresh install; a super admin goes straight in to
    // onboard the first site.
    final onboarding = sites.isEmpty && (user?.governsAllSites ?? false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SizedBox(height: 28),
        Text(
          onboarding
              ? 'Welcome, ${user?.name ?? ''} — no sites yet'
              : 'Welcome, ${user?.name ?? ''} — select your site',
          style: AppText.sans(size: 14, weight: FontWeight.w600),
        ),
        if (onboarding) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            'Onboard the first one from Admin → Sites.',
            style: AppText.sans(size: 13, color: T.muted, height: 1.4),
          ),
        ],
        if (sites.isEmpty && !onboarding) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            'No site has been assigned to you yet — ask a super admin for '
            'access.',
            style: AppText.sans(size: 13, color: T.muted, height: 1.4),
          ),
        ],
        const SizedBox(height: 14),
        // Two-column grid of the sites this user has access to.
        LayoutBuilder(
          builder: (context, constraints) {
            const gap = 10.0;
            final itemWidth = (constraints.maxWidth - gap) / 2;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: <Widget>[
                for (final d in sites)
                  SizedBox(
                    width: itemWidth,
                    child: PillChip(
                      label: d,
                      mono: true,
                      fontSize: 15,
                      radius: T.buttonShape,
                      selected: d == session.site,
                      tone: ChipTone.green,
                      onTap: () => controller.selectSite(d),
                    ),
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: 20),
        FilledActionButton(
          label: onboarding ? 'Continue' : 'Continue to ${session.site}',
          onPressed: (session.site.isEmpty && !onboarding)
              ? null
              : controller.enterApp,
          expand: true,
        ),
      ],
    );
  }
}

import 'package:flutter/widgets.dart';

/// Design tokens transcribed verbatim from the E&M Maintenance handoff.
///
/// Translucent values are written as explicit ARGB literals rather than
/// `withOpacity`/`withValues` so the file compiles cleanly on every Flutter
/// channel.
abstract final class T {
  // ── Text ────────────────────────────────────────────────────────────────
  /// Primary text and dark buttons.
  static const ink = Color(0xFF12161B);

  /// Ink at the hover/pressed step (dark button hover).
  static const inkHover = Color(0xFF2A3038);
  static const body = Color(0xFF3C4450);
  static const secondary = Color(0xFF5B6470);
  static const muted = Color(0xFF8A93A0);

  // ── Surfaces ────────────────────────────────────────────────────────────
  static const pageBg = Color(0xFFF2F3EF);
  static const card = Color(0xFFFFFFFF);
  static const border = Color(0xFFE3E6DF);
  static const inputBorder = Color(0xFFD6D9D2);

  /// Subtle fills: site select in the header, site chips, photo dropzone.
  static const subtleFill = Color(0xFFF7F8F5);
  static const dropzoneFill = Color(0xFFFAFBF8);
  static const dashed = Color(0xFFB9BFB4);
  static const cardHoverBorder = Color(0xFFC9CEC4);
  static const inactiveFill = Color(0xFFF1F2EF);

  // ── Brand green: primary action + active state ──────────────────────────
  static const green = Color(0xFF568A37);
  static const greenHover = Color(0xFF4A7A2E);
  static const greenTint = Color(0xFFF0F5EC);
  static const greenInk = Color(0xFF3E6B26);

  // ── Blue: links, WD register, Manager role ──────────────────────────────
  static const blue = Color(0xFF3D74C6);
  static const blueHover = Color(0xFF2C5CA5);
  static const blueTint = Color(0xFFEDF1F8);

  // ── Red: breakdowns + destructive ───────────────────────────────────────
  static const red = Color(0xFFC2452D);
  static const redHover = Color(0xFFA93A24);
  static const redTint = Color(0xFFFBEFEC);
  static const redBorderTint = Color(0xFFE8C4BB);
  static const redInk = Color(0xFFA93A24);
  static const redInkDeep = Color(0xFF8C3220);

  // ── Amber: DC register, Executive role ──────────────────────────────────
  static const amber = Color(0xFF8A6A2F);
  static const amberTint = Color(0xFFF5EEDD);

  /// PM register, and the Super Admin role badge.
  static const indigo = Color(0xFF5B5EA6);
  static const indigoTint = Color(0xFFEDEDF7);

  /// Login backdrop.
  static const loginBg = Color(0xFF0E1216);

  static const white = Color(0xFFFFFFFF);

  // ── Shape ───────────────────────────────────────────────────────────────
  static const rCard = Radius.circular(16);
  static const rCardSm = Radius.circular(12);
  static const rControl = Radius.circular(10);
  static const rButton = Radius.circular(12);
  static const rPill = Radius.circular(20);

  static const cardShape = BorderRadius.all(rCard);
  static const cardSmShape = BorderRadius.all(rCardSm);
  static const controlShape = BorderRadius.all(rControl);
  static const buttonShape = BorderRadius.all(rButton);
  static const pillShape = BorderRadius.all(rPill);

  /// Content column cap shared by header, tabs and main.
  static const maxContentWidth = 1080.0;

  /// Entry form column cap.
  static const maxFormWidth = 640.0;

  /// Single breakpoint: below this we swap top tabs for a bottom nav bar.
  static const mobileBreakpoint = 640.0;

  /// Minimum touch target; bottom nav items are 56.
  static const minTouchTarget = 44.0;

  // ── Elevation ───────────────────────────────────────────────────────────
  /// `0 6px 16px rgba(86,138,55,.3)` — primary CTA.
  static const ctaShadow = <BoxShadow>[
    BoxShadow(
      color: Color(0x4D568A37),
      blurRadius: 16,
      offset: Offset(0, 6),
    ),
  ];

  /// `0 30px 80px rgba(0,0,0,.5)` — login card.
  static const loginCardShadow = <BoxShadow>[
    BoxShadow(
      color: Color(0x80000000),
      blurRadius: 80,
      offset: Offset(0, 30),
    ),
  ];

  /// `0 10px 24px rgba(18,22,27,.09)` — register card hover lift.
  static const cardHoverShadow = <BoxShadow>[
    BoxShadow(
      color: Color(0x1712161B),
      blurRadius: 24,
      offset: Offset(0, 10),
    ),
  ];

  /// `0 -6px 20px rgba(18,22,27,.06)` — bottom nav.
  static const bottomNavShadow = <BoxShadow>[
    BoxShadow(
      color: Color(0x0F12161B),
      blurRadius: 20,
      offset: Offset(0, -6),
    ),
  ];

  /// `0 10px 30px rgba(0,0,0,.3)` — toast.
  static const toastShadow = <BoxShadow>[
    BoxShadow(
      color: Color(0x4D000000),
      blurRadius: 30,
      offset: Offset(0, 10),
    ),
  ];

  /// Focus ring: 3px `rgba(86,138,55,.15)`.
  static const focusRing = Color(0x26568A37);

  // ── Motion ──────────────────────────────────────────────────────────────
  static const easeOut = Cubic(.2, .8, .2, 1);
  static const viewFade = Duration(milliseconds: 350);
  static const loginFade = Duration(milliseconds: 600);
  static const hoverLift = Duration(milliseconds: 150);
  static const toastDuration = Duration(milliseconds: 2600);
}

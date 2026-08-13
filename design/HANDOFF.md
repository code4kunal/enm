# Handoff: Transvolt E&M Maintenance App

> Verbatim copy of the design handoff from the Claude Design project
> `243e46a5-e231-4419-bdf6-a81c34513b88` ("Flutter app for maintenance
> operations"). Kept unedited as the source of truth for the implementation in
> `../app`.

## Overview
A cross-platform (web / mobile / tablet) app for Transvolt's Engineering & Maintenance ground operations across 8 depots (MBMT, UMT, NTSPL, Julwania, VECV, STAR, GTI, KANDLA). Ground staff digitize their 5 physical registers: Daily Work Done, Coolant Topping, Driver Complaints, Breakdown Report, PM Schedule Attention. Includes login (Microsoft SSO + User ID/password), register entry forms mirroring the paper registers, searchable/filterable register views with edit, an open-breakdown tracker, CSV export, and a user administration section.

Target implementation: **Flutter** (or React Native). Responsive: single codebase, breakpoint at 640px (bottom nav on mobile, top tabs on wider screens).

## About the Design Files
The files in this bundle are **design references created in HTML** — an interactive prototype showing intended look and behavior, NOT production code. Recreate these designs in the target Flutter/React Native codebase using its established patterns (e.g. Flutter Material 3 with a custom theme, go_router, Riverpod/Bloc — dev team's choice). Open `Transvolt EM App.dc.html` in a browser to click through every flow.

## Fidelity
**High-fidelity.** Colors, typography, spacing, radii, and interactions are final. Recreate pixel-faithfully with platform-native widgets.

## Design Tokens
Colors:
- Ink (primary text / dark buttons): #12161B
- Body text: #3C4450 · Secondary: #5B6470 · Muted: #8A93A0
- Page background: #F2F3EF · Card: #FFFFFF · Border: #E3E6DF · Input border: #D6D9D2
- Brand green (primary action, active states): #568A37 · hover #4A7A2E · tint bg #F0F5EC · dark text on tint #3E6B26
- Blue (links, WD register, Manager role): #3D74C6 · tint #EDF1F8
- Red (breakdown, destructive): #C2452D · hover #A93A24 · tint #FBEFEC · border tint #E8C4BB · dark text #A93A24 / #8C3220
- Amber (DC register, Executive role): #8A6A2F · tint #F5EEDD
- Indigo (PM register): #5B5EA6
- Login page background: #0E1216

Typography: 'IBM Plex Sans' (400/500/600/700) for UI; 'IBM Plex Mono' (500/600) for bus numbers, depot codes, user IDs, times, numeric values. Google Fonts.
Sizes: page titles 20–22px/700, card titles 15–16px/700, body 14–15px, labels 13px/600, meta 12–12.5px, inputs 16px (17px mono for bus/number).

Spacing & shape: cards radius 12–16px, inputs/buttons radius 10–12px, chips radius 20px (pill). Card padding 14–22px. Grid/flex gaps 8–16px. Content max-width 1080px.
Focus state: green border + 3px rgba(86,138,55,.15) ring. Shadows: cards none (1px border), primary CTA 0 6px 16px rgba(86,138,55,.3), login card 0 30px 80px rgba(0,0,0,.5).
Minimum touch target 44px (mobile nav items 56px).

## Screens / Views

### 1. Login
Dark (#0E1216) full screen with 3 blurred animated chevron shapes (brand green + blue, opacity .08–.14, clip-path chevrons, slow 11–16s drift loops). Centered white card (max-width 420px, radius 20px, padding 44/40/36):
- Transvolt logo (assets/transvolt-logo.png, 220px wide, centered)
- "E & M MAINTENANCE" 13px/600, letter-spacing .22em, green
- Subtitle "Ground operations register · All depots" 14px secondary
- "Sign in with Microsoft" button: white, 1.5px #D6D9D2 border, MS 4-square logo, 16px/600. While connecting: label swaps to "Connecting to Microsoft…" with a light green sweep animation (1.1s loop). Simulated 1.4s then proceeds.
- Divider "OR SIGN IN WITH USER ID"
- User ID input (mono, uppercase) + Password input + black "Sign in" button. Validation: both required, inline red error 13px. For ground staff without official mail IDs.
- Depot select stage (after either sign-in): welcome line, 2-column grid of 8 depot buttons (mono labels, selected = green border + #F0F5EC bg), green "Continue to {depot}" CTA.

### 2. App shell
Sticky white header: logo (20px h), divider, "E&M" green 13px/700 ls .14em, spacer, depot select (mono, #F7F8F5 bg), avatar circle (initials, black bg; tap = sign out).
- ≥640px: tab row under header — Home / Registers / Breakdowns / Admin; active = 3px green bottom border, ink text; Breakdowns shows red count badge when open breakdowns exist.
- <640px: tabs hidden; fixed bottom nav bar (white, top border, -6px soft shadow, safe-area inset): 4 items, 56px min height, active = green label 700 + 4px green top indicator bar; badge floats top-right of item. Content bottom padding 96px. Toast appears at 84px above bottom.

### 3. Home
Optional red alert banner "{n} open breakdowns at {depot} — tap to view" (tint bg, dot, navigates to Breakdowns). Greeting (time-of-day + name), date + depot line. Register cards grid (auto-fill minmax 190px): colored code square 40px (register color, mono 2-letter code), count today, register name, "+ New entry" green 12.5px/700. Hover: lift -2px + shadow. Below: "Today's entries · {depot}" list — code chip, bus no (mono), time · by, one-line snippet (ellipsis). Dashed-border empty state.

### 4. Register entry form (new + edit)
Max-width 640px, fadeUp in. Back link, colored code square 44px + register name + "{depot} depot · New entry|Editing entry". White card with wrapped 2-col fields (mobile: all 100%; time triplet stays 31% on desktop). Field types:
- bus: SELECT from bus master (mono), "MASTER" badge on label
- select: Source of Defect, Type of Defect — from master lists, MASTER badge
- date / time natives; num with unit suffix (litres/km); textarea; seg (Shift A/B/C as 3 toggle buttons, selected = solid green); text
- Required fields marked with red *. Save validates Bus No + Date.
- Photo attach: full-width dashed button toggling "+ Attach photo (optional)" ↔ "1 photo attached ✓" (green tint).
Footer: Cancel (outline) + Save entry (green, full flex, shadow). Toast confirms.

Register fields (exact register columns):
- Daily Work Done (WD, blue): Shift(A/B/C), Date*, Bus No*, Reported Defects*, Source of Defect(master), Type of Defect(master), Attended Details, Spare Parts Used, Name & No. of Employee
- Coolant Topping (CT, green): Date*, Bus No*, BCS Topping (litres), TCS Topping (litres), Topped up by
- Driver Complaints (DC, amber): Date*, Bus No*, Type of Defect(master), Driver Complaint Reported*, Rectification Action Taken, Name of the Mechanic
- Breakdown Report (BD, red): Date*, Bus No*, Driver ID, Location, Complaint Reported by the Driver*, B/Down Time, Mechanic Reported Time, Bus Attended Time, Loss KM, Bus Attended Details, Remarks. New breakdowns start status OPEN.
- PM Schedule Attention (PM, indigo): Date*, Bus No*, Type of Defect(master), Defects Noticed*, Action Taken, Reason for Balance Job, Spare Parts Used, Name of Employees

### 5. Registers (view/search/edit)
Search input + black "Export Excel (CSV)" button. Register filter chips (All + 5 registers; selected = solid black pill). Period chips: Today / Last 7 days / This month / Custom range / All (selected = green tint pill); Custom shows two date inputs. Result count line. Entry rows: code chip (solid register color), bus no mono, date · depot · by, Edit button (outline, green on hover) → opens the entry form prefilled; save updates in place. Entries sorted date desc, scoped to current depot.

### 6. Breakdown tracker
"+ Report breakdown" red button → BD form. Cards: bus no mono, OPEN (red tint) / RESOLVED (green tint) pill, date · location, complaint, metrics row (B/Down, Attended, computed Time taken, Loss KM — mono values), "Mark resolved" outline-green button on open items. Open cards get red-tinted border.

### 7. Admin (user administration)
Visible to Manager/admin roles only in production. Header + green "+ Create user". Create/edit card: Full name*, User ID* (mono uppercase), Email (optional — enables SSO; without it user logs in via User ID), Role (Manager/Supervisor/Executive toggle, selected solid green), Depot access* multi-select pill chips (all 8 depots). Validation: name+ID required, ≥1 depot, unique User ID. Filter chips All/Active/Inactive with counts. User rows: avatar initials (black; grey when inactive), name, role badge (Manager blue / Supervisor green / Executive amber tints), INACTIVE badge, User ID + email-or-"No mail ID (User ID login)", depot chips, Edit + Deactivate/Activate. Inactive = soft delete: row at 62% opacity, login must be blocked server-side; record retained and reactivatable.

## Interactions & Behavior
- Animations: fadeUp 0.35s cubic-bezier(.2,.8,.2,1) on every view change; login card 0.6s; card hover lift 0.15s; toast bottom-center dark pill, auto-dismiss 2.6s.
- Auto-fill: Date defaults to today; Shift auto-picks by clock (A <14h, B <22h, else C).
- Bus No normalized uppercase/no spaces (MH40LY1894 format).
- CSV export downloads current filtered set: Register, Date, Depot, Bus No, Details, Entered by.
- Breakdown "Time taken" computed from B/Down → Attended times (handles midnight wrap).
- Depot switcher re-scopes all lists; breakdown badge/banner reflect open count of current depot.

## State Management
Prototype state (single store) → map to app state: auth {stage, user}, depot, tab, activeReg + form + editingId, entries[], users[], filters {q, regFilter, dateMode, dFrom, dTo, userFilter}, toast, viewport width.
Production: entries and users from API; master data service supplies bus list (per depot), defect sources, defect types; auth via Microsoft Entra ID (MSAL) + credential login for non-SSO staff; role-based access (Admin tab gated); inactive users rejected at auth.

## Master Data (mocked in prototype — fetch from master-data service)
- Buses: MH40LY1894, MH40LY1721, MH40LY1650, MH40LY1802, MH40LY1688, MH40LY1733, MH12ST4410, MH12ST4415
- Sources of Defect: Driver report, Daily inspection, PM schedule, Breakdown, Depot supervisor, Other
- Defect Types: Electrical / HV, Electrical / LV, AC & HVAC, Brakes & air system, Doors, Suspension & axle, Body & interior, Tyres, Cooling system, Software / telematics, Other
- Depots: MBMT, UMT, NTSPL, Julwania, VECV, STAR, GTI, KANDLA
- Roles: Manager, Supervisor, Executive

## Assets
- assets/transvolt-logo.png — Transvolt logo (client-provided). Use SVG/high-res source in production.
- Fonts: IBM Plex Sans, IBM Plex Mono (Google Fonts / bundle in app).

## Files
- `Transvolt EM App.dc.html` — the full interactive prototype (all screens & flows)
- `assets/transvolt-logo.png` — logo used by the prototype

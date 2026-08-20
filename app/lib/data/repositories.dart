import 'package:flutter/foundation.dart';

export 'api_exception.dart';

import 'api_exception.dart';
import 'auth/ms_sso.dart';

import '../models/app_user.dart';
import '../models/entry.dart';
import '../models/site.dart';
import '../models/site_config.dart';
import '../models/checklist.dart';
import '../models/inspection.dart';
import '../models/report.dart';
import '../models/site_import.dart';

/// Contracts the UI is written against. Every implementation in `data/fake/` is
/// a stub; swapping in HTTP clients is a change to `state/providers.dart` and
/// nothing above it.



// ─── Sites ────────────────────────────────────────────────────────────────

/// Site onboarding and the site roster. Writes are super-admin only; every
/// authenticated user may read the sites they can reach.
abstract interface class SiteRepository {
  /// All sites for a super admin; the caller's granted sites otherwise.
  Future<List<Site>> fetchSites();

  Future<Site> createSite({
    required String code,
    required String name,
    String timezone,
    String address,
    String? commissionedOn,
  });

  Future<Site> updateSite(Site site);

  /// Soft delete. History is retained; the site leaves the switcher and accepts
  /// no new entries.
  Future<Site> setActive(String code, bool active);

  /// Site codes are unique and immutable once entries reference them.
  Future<bool> isCodeTaken(String code);
}

// ─── Vehicles ─────────────────────────────────────────────────────────────

/// One vehicle's latest odometer reading, as reported by telematics.
@immutable
class OdometerReading {
  const OdometerReading({
    required this.vehicleId,
    required this.registrationNo,
    required this.odometerKm,
    required this.recordedAt,
  });

  final String vehicleId;
  final String registrationNo;
  final int odometerKm;

  /// ISO timestamp the reading was taken, not when it was fetched.
  final String recordedAt;

  factory OdometerReading.fromJson(Map<String, dynamic> json) =>
      OdometerReading(
        vehicleId: json['vehicle_id'] as String? ?? '',
        registrationNo: json['registration_no'] as String? ?? '',
        odometerKm: (json['odometer_km'] as num?)?.round() ?? 0,
        recordedAt: json['recorded_at'] as String? ?? '',
      );
}

/// Result of one scheduled odometer pull.
@immutable
class OdometerSyncResult {
  const OdometerSyncResult({
    required this.readings,
    required this.syncedAt,
    this.skipped = 0,
  });

  final List<OdometerReading> readings;
  final String syncedAt;

  /// Vehicles the provider had nothing new for.
  final int skipped;

  int get updated => readings.length;

  factory OdometerSyncResult.fromJson(Map<String, dynamic> json) =>
      OdometerSyncResult(
        readings: <OdometerReading>[
          for (final r in (json['readings'] as List<dynamic>? ?? <dynamic>[]))
            OdometerReading.fromJson(r as Map<String, dynamic>),
        ],
        syncedAt: json['synced_at'] as String? ?? '',
        skipped: json['skipped'] as int? ?? 0,
      );
}

/// A site's fleet. Backs the "Bus No" dropdown on every register.
abstract interface class VehicleRepository {
  Future<List<Vehicle>> fetchVehicles({
    required String siteCode,
    bool includeInactive = false,
  });

  Future<Vehicle> createVehicle({
    required String siteCode,
    required String registrationNo,
    String make,
    String model,
    double? batteryCapacityKwh,
  });

  Future<Vehicle> updateVehicle(Vehicle vehicle);

  /// Retired vehicles stay on past entries but leave the entry dropdown.
  Future<Vehicle> setActive(String id, bool active);

  /// Pulls the latest odometer for every vehicle on the site.
  ///
  /// Called on a timer rather than on demand: the maintenance schedule is
  /// distance-driven, so a stale odometer silently stops the site knowing what
  /// is due. The server owns the telematics integration; this just asks it to
  /// refresh and reports what changed.
  Future<OdometerSyncResult> syncOdometers({required String siteCode});

  /// Records a manual reading, for vehicles with no telematics feed.
  Future<Vehicle> setOdometer({
    required String vehicleId,
    required int odometerKm,
  });

  /// Marks a service as completed, anchoring the next due point.
  Future<Vehicle> recordService({
    required String vehicleId,
    required String planCode,
    required int odometerKm,
    required String servicedOn,
  });
}

// ─── Master data ──────────────────────────────────────────────────────────

/// Which editable dropdown list a call targets.
enum MasterListKind {
  defectSources('Defect sources'),
  defectTypes('Defect types');

  const MasterListKind(this.label);

  final String label;
}

/// Reference data. Vehicle lists are per site; defect sources and types are
/// tenant-wide and maintained by super admins.
abstract interface class MasterDataRepository {
  Future<List<String>> siteCodes();

  /// Active registration numbers for the site's entry dropdown.
  Future<List<String>> vehicleNumbers({required String siteCode});

  Future<List<String>> defectSources();

  Future<List<String>> defectTypes();

  /// Active staff at a site, for the "attended by" and "supervisor" pickers.
  Future<List<String>> staff({required String siteCode});

  /// Active technicians for Daily Work Done's "Attended By" picker.
  Future<List<String>> technicianStaff({required String siteName, String? siteId});

  /// Active supervisors for Daily Work Done's "Supervisor (Floor)" picker.
  Future<List<String>> supervisorStaff({required String siteName, String? siteId});

  /// Active mechanics for Driver Complaints' "Name of the Mechanic" picker.
  Future<List<String>> mechanicStaff({required String siteName, String? siteId});

  /// Full rows, including inactive, for the master-data editor.
  Future<List<MasterListItem>> masterList(MasterListKind kind);

  Future<MasterListItem> addMasterItem(MasterListKind kind, String name);

  Future<MasterListItem> updateMasterItem(
    MasterListKind kind,
    MasterListItem item,
  );
}

/// Everything the entry form needs, resolved in one round trip.
@immutable
class MasterData {
  const MasterData({
    required this.sites,
    required this.vehicles,
    required this.defectSources,
    required this.defectTypes,
    this.staff = const <String>[],
    this.technicianStaff = const <String>[],
    this.supervisorStaff = const <String>[],
    this.mechanicStaff = const <String>[],
  });

  final List<String> sites;

  /// Vehicles for the site this bundle was loaded against.
  final List<String> vehicles;
  final List<String> defectSources;
  final List<String> defectTypes;

  /// The site's people, for the "attended by" and "supervisor" dropdowns.
  final List<String> staff;

  /// Technician names for Daily Work Done's attended-by dropdown.
  final List<String> technicianStaff;

  /// Supervisor names for Daily Work Done's supervisor dropdown.
  final List<String> supervisorStaff;

  /// Mechanic names for Driver Complaints' mechanic dropdown.
  final List<String> mechanicStaff;

  static const empty = MasterData(
    sites: <String>[],
    vehicles: <String>[],
    defectSources: <String>[],
    defectTypes: <String>[],
    staff: <String>[],
    technicianStaff: <String>[],
    supervisorStaff: <String>[],
    mechanicStaff: <String>[],
  );
}

// ─── Site configuration ───────────────────────────────────────────────────

/// Docking and charging parameters, maintained per site by its manager.
abstract interface class SiteConfigRepository {
  Future<SiteConfig> fetchConfig(String siteCode);

  /// Rejects an incoherent config with [ApiException]; the client checks the
  /// same rules first so the user sees them before a round trip.
  Future<SiteConfig> saveConfig(SiteConfig config);
}

// ─── Imports ──────────────────────────────────────────────────────────────

/// Per-site spreadsheet ingestion.
///
/// Parsing and validation live on the server so there is exactly one
/// implementation and one row-error report. The client uploads bytes, shows the
/// preview, and commits the same staged upload it previewed.
abstract interface class ImportRepository {
  Future<List<ImportProfile>> fetchProfiles(String siteCode);

  Future<ImportProfile> saveProfile(ImportProfile profile);

  Future<void> deleteProfile(String profileId);

  /// Opens an uploaded file and reports its sheets, headers and sample rows so
  /// the user can bind columns. Runs before a profile is complete.
  Future<SourceInspection> inspect({
    required String siteCode,
    required String fileName,
    required Uint8List bytes,
    String? sheetName,
    int headerRow,
  });

  /// Dry run: maps and validates every row, writes nothing. The returned
  /// [ImportPreview.token] is what [commit] consumes.
  Future<ImportPreview> preview({
    required ImportProfile profile,
    required String fileName,
    required Uint8List bytes,
  });

  /// Applies a previously previewed upload. Rejected rows are skipped.
  Future<ImportRun> commit({
    required String siteCode,
    required String token,
  });

  Future<List<ImportRun>> fetchRuns(String siteCode);
}

// ─── Inspection schedule ──────────────────────────────────────────────────

/// The reactive inspection calendar and the alert log.
///
/// The server owns the planning: it reads what the registers say actually
/// happened and lays out the rotation. The client shows the calendar, lets a
/// manager adjust it, and can ask for a run rather than waiting for 22:00.
abstract interface class InspectionRepository {
  /// Bookings in a date range, grouped by day, empty days included.
  Future<InspectionCalendar> fetchCalendar({
    required String siteCode,
    required String from,
    required String to,
  });

  /// Runs the generator now. Safe to call repeatedly.
  Future<GenerationResult> generate(String siteCode);

  Future<InspectionSlot> createSlot({
    required String siteCode,
    required String vehicleId,
    required int workTypeId,
    required String scheduledOn,
    String notes,
  });

  /// Any hand edit pins the slot so the generator stops moving it.
  Future<InspectionSlot> updateSlot(
    InspectionSlot slot, {
    String? scheduledOn,
    SlotStatus? status,
    String? notes,
  });

  Future<void> deleteSlot(String slotId);

  Future<List<InspectionPlan>> fetchPlans(String siteCode);

  Future<List<InspectionPlan>> savePlans(
    String siteCode,
    List<InspectionPlan> plans,
  );

  Future<List<SiteAlert>> fetchAlerts(String siteCode, {String status});

  Future<SiteAlert> acknowledgeAlert(String alertId);
}

// ─── Checklists and inspections ───────────────────────────────────────────

/// A site's inspection checklists, and the sweeps that fill them in.
///
/// A daily inspection and a ten-day service are different jobs with different
/// sheets, so each work type carries its own checklist and its own form. The
/// checklist is site data: nothing is invented, and an empty one is a real
/// state the form reports rather than papering over.
abstract interface class ChecklistRepository {
  /// One checklist per inspection type at this site.
  Future<List<Checklist>> fetchChecklists(String siteCode);

  /// Replaces a checklist wholesale. A line already answered by an inspection
  /// is retired rather than deleted, so past sweeps keep reading correctly.
  Future<Checklist> saveChecklist(String siteCode, Checklist checklist);

  /// Records one completed inspection, discharging its booking.
  Future<InspectionEntry> recordInspection({
    required String siteCode,
    required String vehicleId,
    required int workTypeId,
    required String inspectedOn,
    String? entryTime,
    String? doneBy,
    String? supervisor,
    int? odometerKm,
    String? remarks,
    required List<InspectionResult> results,
  });

  Future<List<InspectionEntry>> fetchInspections(
    String siteCode, {
    int? workTypeId,
  });

  /// What has already been swept today — the Home feed.
  Future<List<InspectionEntry>> todaysInspections(String siteCode);
}

// ─── Reports ──────────────────────────────────────────────────────────────

/// The depot's own reports, derived from the registers rather than typed a
/// second time.
///
/// The server owns every calculation: it knows what a breakdown's defect type
/// rolls up to, which buses were off the road on a date, and what a bus's last
/// PM found. The client asks for a day and renders it.
abstract interface class ReportRepository {
  /// One day of the Daily Maintenance Report.
  Future<DmrDay> fetchDmr({required String siteCode, required String date});

  /// Records the lines nothing else in the system observes. Values are keyed
  /// by [DmrLine.key]; a null clears one.
  Future<DmrDay> saveDmrEntered({
    required String siteCode,
    required String date,
    required Map<String, int?> values,
    String? notes,
  });

  /// Freezes the derived lines as reported. Runs nightly; this is on demand.
  Future<DmrDay> snapshotDmr({
    required String siteCode,
    required String date,
  });

  /// The month grid, for trends and for spotting gaps.
  Future<DmrMonth> fetchDmrMonth({
    required String siteCode,
    required String month,
  });

  /// The defective-bus list as it stood on one morning.
  Future<List<OffRoadCase>> fetchOffRoad({
    required String siteCode,
    required String date,
  });

  Future<OffRoadCase> saveOffRoad({
    required String siteCode,
    required String vehicleId,
    required String issue,
    required DefectCategory category,
    String? offRoadSince,
    String? actionTaken,
    int? expectedDays,
    String? spareParts,
    String? remarks,
    bool awaitingVendor,
  });

  Future<OffRoadCase> closeOffRoad({
    required String caseId,
    required String returnedOn,
  });

  /// Every breakdown that day, with its investigation where one has started.
  /// Carries the nearest date with breakdowns when this one has none.
  Future<InvestigationDay> fetchInvestigations({
    required String siteCode,
    required String date,
  });

  /// Opens one, pre-filled from what is already known about the bus.
  Future<Investigation> openInvestigation(String entryId);

  Future<Investigation> saveInvestigation(
    String entryId, {
    String? findings,
    String? investigationAction,
    String? lastPmFindings,
    String? relatedComplaints,
  });

  /// Which control charts exist, and which of them have data behind them.
  Future<List<ChartKind>> fetchChartKinds();

  /// One Annexure-IV chart: the fleet down, the days across. The window is at
  /// most a month — a wider grid is a download, not something to read.
  Future<ControlChart> fetchControlChart({
    required String siteCode,
    required String kind,
    required String fromDate,
    required String toDate,
  });

  /// The components worth tracking, in the history card's order.
  Future<List<UnitType>> fetchUnitTypes();

  /// The Unit Failure Statement: every unit that came off in a month.
  Future<List<FittedUnit>> fetchUnitFailures({
    required String siteCode,
    required String month,
  });

  /// What is on a bus right now.
  Future<List<FittedUnit>> fetchFittedUnits({
    required String siteCode,
    required String vehicleId,
  });

  /// Put a component on a bus. The odometer defaults to the bus's last
  /// reading, so leaving it out is the normal case.
  Future<FittedUnit> fitUnit({
    required String siteCode,
    required String vehicleId,
    required int unitTypeId,
    required String fittedOn,
    String? unitNo,
    int? fittedOdometerKm,
    String? remarks,
  });

  /// Take it off — which is what puts it on the failure statement.
  Future<FittedUnit> removeUnit(
    String unitId, {
    required String removedOn,
    int? removedOdometerKm,
    String? removalReason,
    String? remarks,
  });

  /// One bus's history card: units down, months across.
  Future<BusHistory> fetchBusHistory({
    required String siteCode,
    required String vehicleId,
    required String toMonth,
  });

  /// A report as a printable file, ready to hand to the platform share sheet.
  ///
  /// One method rather than seven so no screen has to know a URL — the
  /// repository is still the only thing that does. Which of the optional
  /// scopes matter depends on [doc]; the rest are ignored.
  Future<ReportFile> downloadReport(
    ReportDoc doc, {
    required String siteCode,
    String? date,
    String? month,
    String? chartKind,
    String? fromDate,
    String? toDate,
    String? vehicleId,
  });
}

/// The reports that can be printed.
enum ReportDoc {
  dmrDay,
  dmrMonth,
  controlChart,
  offRoad,
  investigations,
  unitFailures,
  busHistory,
}

/// A downloaded file: what the server called it, and its bytes.
class ReportFile {
  const ReportFile({required this.name, required this.bytes});

  final String name;
  final Uint8List bytes;
}

// ─── Entries ──────────────────────────────────────────────────────────────

/// Register entries. All reads are site-scoped — the site switcher in the
/// header is the single tenant boundary the UI exposes.
abstract interface class EntryRepository {
  Future<List<RegisterEntry>> fetchEntries({required String site});

  Future<RegisterEntry> createEntry(RegisterEntry entry);

  Future<RegisterEntry> updateEntry(RegisterEntry entry);

  /// Used by the breakdown tracker's "Mark resolved".
  Future<RegisterEntry> setStatus(String entryId, EntryStatus status);
}

// ─── Users ────────────────────────────────────────────────────────────────

/// User administration. [setActive] is a soft delete: the record is retained
/// and reactivatable, and auth rejects inactive users server-side.
abstract interface class UserRepository {
  /// Every user for a super admin; users on the caller's sites otherwise.
  Future<List<AppUser>> fetchUsers();

  /// Returns the created user together with the temporary password the admin
  /// must hand over. The password is shown once and never retrievable again.
  Future<({AppUser user, String temporaryPassword})> createUser({
    required String name,
    required String userId,
    required String email,
    required UserRole role,
    required List<String> sites,
    String? password,
  });

  Future<AppUser> updateUser(AppUser user);

  Future<AppUser> setActive(String id, bool active);

  /// Issues a new temporary password and revokes every live session.
  Future<String> resetPassword(String id, {String? password});

  /// User IDs are unique across the tenant. [exceptId] lets an edit keep its
  /// own ID without tripping the check.
  Future<bool> isUserIdTaken(String userId, {String? exceptId});
}

// ─── Auth ─────────────────────────────────────────────────────────────────

/// Microsoft Entra ID (MSAL) for staff with a Transvolt mail ID, plus a
/// credential path for ground staff who have none.
abstract interface class AuthRepository {
  /// Whether this deployment offers Microsoft sign-in. Never throws — a
  /// sign-in screen that cannot reach the server still offers the password
  /// form.
  Future<SsoConfig> ssoConfig();

  /// Sends the browser to Microsoft. Does not return on success: the page is
  /// replaced, and the app finishes the job on the next load.
  Future<void> beginMicrosoftSignIn(SsoConfig config);

  /// Finishes a redirect from Microsoft. Null when this load is not one.
  Future<AppUser?> completeMicrosoftSignIn(SsoConfig config);

  Future<AppUser> signInWithCredentials({
    required String userId,
    required String password,
  });

  /// Clears `must_reset_password` and revokes other devices.
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  });

  Future<void> signOut();
}

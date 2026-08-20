import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/repositories.dart';
import 'providers.dart';
import 'session.dart';
import 'sites.dart';
import 'schedule.dart';

/// What the last scheduled odometer pull did.
@immutable
class OdometerSyncState {
  const OdometerSyncState({
    this.running = false,
    this.lastSyncedAt,
    this.lastUpdatedCount = 0,
    this.error,
  });

  final bool running;

  /// ISO timestamp of the last successful pull this session.
  final String? lastSyncedAt;
  final int lastUpdatedCount;

  /// Last failure. Kept rather than thrown: a telematics outage should show as
  /// a stale badge, not as a crash in the middle of a mechanic's shift.
  final String? error;

  bool get hasSynced => lastSyncedAt != null;

  OdometerSyncState copyWith({
    bool? running,
    String? lastSyncedAt,
    int? lastUpdatedCount,
    String? error,
    bool clearError = false,
  }) {
    return OdometerSyncState(
      running: running ?? this.running,
      lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
      lastUpdatedCount: lastUpdatedCount ?? this.lastUpdatedCount,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Keeps every vehicle's odometer current on a schedule.
///
/// The maintenance plan is distance-driven, so a stale odometer silently stops
/// the site knowing what is due. Rather than refreshing when someone happens to
/// open the fleet screen, this polls on the interval the site configured, and
/// re-arms itself whenever the site or that interval changes.
class OdometerSyncController extends Notifier<OdometerSyncState> {
  Timer? _timer;
  String? _lastSyncedSite;

  @override
  OdometerSyncState build() {
    final site = ref.watch(sessionProvider.select((s) => s.site));
    final signedIn =
        ref.watch(sessionProvider.select((s) => s.stage)) == AuthStage.signedIn;
    final config = ref.watch(siteConfigProvider).valueOrNull;

    ref.onDispose(() => _timer?.cancel());

    if (!signedIn || site.isEmpty) {
      _lastSyncedSite = null;
      _timer?.cancel();
    } else if (config != null) {
      if (config.odometerSync.enabled) {
        if (_lastSyncedSite != site) {
          _lastSyncedSite = site;
          _timer?.cancel();
          final interval = config.odometerSync.interval;
          _timer = Timer.periodic(interval, (_) => syncNow());
          // Pull once on arrival rather than waiting a whole interval for the first
          // reading — a manager opening the app wants today's numbers.
          scheduleMicrotask(syncNow);
        }
      } else {
        _lastSyncedSite = null;
        _timer?.cancel();
      }
    }

    return const OdometerSyncState();
  }

  /// Runs a pull immediately. Safe to call while one is in flight — it returns.
  Future<void> syncNow() async {
    if (state.running) return;
    final site = ref.read(sessionProvider).site;
    if (site.isEmpty) return;

    state = state.copyWith(running: true, clearError: true);
    try {
      final result =
          await ref.read(vehicleRepositoryProvider).syncOdometers(siteCode: site);
      state = state.copyWith(
        running: false,
        lastSyncedAt: result.syncedAt,
        lastUpdatedCount: result.updated,
      );
      // Fresh readings change what is due, so the fleet and its schedule
      // both have to be re-read.
      ref.invalidate(vehiclesProvider);
      ref.invalidate(calendarProvider);
      ref.invalidate(alertsProvider);
    } on ApiException catch (e) {
      state = state.copyWith(running: false, error: e.message);
    }
  }
}

final odometerSyncProvider =
    NotifierProvider<OdometerSyncController, OdometerSyncState>(
  OdometerSyncController.new,
);

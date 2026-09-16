import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/admin_estate.dart';
import 'providers.dart';

/// Period for Admin Summary / project reports.
enum AdminSummaryPeriod {
  today('today', 'Today'),
  week('week', 'Last 7 days'),
  month('month', 'This month'),
  custom('custom', 'Custom');

  const AdminSummaryPeriod(this.wire, this.label);
  final String wire;
  final String label;
}

class AdminSummaryFilters {
  const AdminSummaryFilters({
    this.period = AdminSummaryPeriod.month,
    this.dateFrom = '',
    this.dateTo = '',
  });

  final AdminSummaryPeriod period;
  final String dateFrom;
  final String dateTo;

  AdminSummaryFilters copyWith({
    AdminSummaryPeriod? period,
    String? dateFrom,
    String? dateTo,
  }) {
    return AdminSummaryFilters(
      period: period ?? this.period,
      dateFrom: dateFrom ?? this.dateFrom,
      dateTo: dateTo ?? this.dateTo,
    );
  }
}

class AdminSummaryFiltersController extends Notifier<AdminSummaryFilters> {
  @override
  AdminSummaryFilters build() => const AdminSummaryFilters();

  void setPeriod(AdminSummaryPeriod p) => state = state.copyWith(period: p);

  void setFrom(String v) => state = state.copyWith(dateFrom: v);

  void setTo(String v) => state = state.copyWith(dateTo: v);
}

final adminSummaryFiltersProvider =
    NotifierProvider<AdminSummaryFiltersController, AdminSummaryFilters>(
  AdminSummaryFiltersController.new,
);

final adminSummaryProvider = FutureProvider<AdminSummary>((ref) async {
  final f = ref.watch(adminSummaryFiltersProvider);
  return ref.watch(adminEstateRepositoryProvider).fetchSummary(
        period: f.period.wire,
        dateFrom: f.period == AdminSummaryPeriod.custom ? f.dateFrom : null,
        dateTo: f.period == AdminSummaryPeriod.custom ? f.dateTo : null,
      );
});

class AuditFilters {
  const AuditFilters({
    this.actorId = '',
    this.action = '',
    this.objectType = '',
    this.dateFrom = '',
    this.dateTo = '',
    this.page = 1,
  });

  final String actorId;
  final String action;
  final String objectType;
  final String dateFrom;
  final String dateTo;
  final int page;

  AuditFilters copyWith({
    String? actorId,
    String? action,
    String? objectType,
    String? dateFrom,
    String? dateTo,
    int? page,
  }) {
    return AuditFilters(
      actorId: actorId ?? this.actorId,
      action: action ?? this.action,
      objectType: objectType ?? this.objectType,
      dateFrom: dateFrom ?? this.dateFrom,
      dateTo: dateTo ?? this.dateTo,
      page: page ?? this.page,
    );
  }
}

class AuditFiltersController extends Notifier<AuditFilters> {
  @override
  AuditFilters build() => const AuditFilters();

  void setActorId(String v) => state = state.copyWith(actorId: v, page: 1);
  void setAction(String v) => state = state.copyWith(action: v, page: 1);
  void setObjectType(String v) =>
      state = state.copyWith(objectType: v, page: 1);
  void setFrom(String v) => state = state.copyWith(dateFrom: v, page: 1);
  void setTo(String v) => state = state.copyWith(dateTo: v, page: 1);
  void setPage(int p) => state = state.copyWith(page: p);
}

final auditFiltersProvider =
    NotifierProvider<AuditFiltersController, AuditFilters>(
  AuditFiltersController.new,
);

final auditLogProvider = FutureProvider<AuditLogPage>((ref) async {
  final f = ref.watch(auditFiltersProvider);
  return ref.watch(adminEstateRepositoryProvider).fetchAudit(
        page: f.page,
        pageSize: 50,
        actorId: f.actorId.isEmpty ? null : f.actorId,
        action: f.action.isEmpty ? null : f.action,
        objectType: f.objectType.isEmpty ? null : f.objectType,
        dateFrom: f.dateFrom.isEmpty ? null : f.dateFrom,
        dateTo: f.dateTo.isEmpty ? null : f.dateTo,
      );
});

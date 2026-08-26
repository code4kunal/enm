import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Currently selected SiteOps site (UUID + display name + mapped E&M code).
///
/// Survives a page reload. The header switcher is SiteOps-sourced; [enmCode]
/// is what [sessionProvider] / master-data use for E&M APIs (MBMT, GTI, …).
class SelectedSiteState {
  const SelectedSiteState({
    this.id,
    this.name = '',
    this.enmCode = '',
  });

  final String? id;
  final String name;

  /// E&M depot code mapped from this SiteOps row, when known.
  final String enmCode;

  bool get hasSiteOpsId => id != null && id!.isNotEmpty;
}

class SelectedSiteNotifier extends StateNotifier<SelectedSiteState> {
  SelectedSiteNotifier() : super(const SelectedSiteState()) {
    _ready = _restore();
  }

  static const _idKey = 'transvolt.siteops_site_id';
  static const _nameKey = 'transvolt.siteops_site_name';
  static const _enmKey = 'transvolt.siteops_enm_code';

  late final Future<void> _ready;

  /// Completes after prefs have been read — await before the header loads sites.
  Future<void> get ready => _ready;

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final id = prefs.getString(_idKey);
      final name = prefs.getString(_nameKey) ?? '';
      final enm = prefs.getString(_enmKey) ?? '';
      if (id != null && id.isNotEmpty) {
        state = SelectedSiteState(id: id, name: name, enmCode: enm);
      }
    } on Exception {
      // Best-effort — header reload will re-select.
    } on Error {
      // Same.
    }
  }

  Future<void> select(
    String id,
    String name, {
    String enmCode = '',
  }) async {
    state = SelectedSiteState(
      id: id.isEmpty ? null : id,
      name: name,
      enmCode: enmCode.trim().toUpperCase(),
    );
    try {
      final prefs = await SharedPreferences.getInstance();
      if (id.isEmpty) {
        await prefs.remove(_idKey);
      } else {
        await prefs.setString(_idKey, id);
      }
      if (name.isEmpty) {
        await prefs.remove(_nameKey);
      } else {
        await prefs.setString(_nameKey, name);
      }
      final code = enmCode.trim().toUpperCase();
      if (code.isEmpty) {
        await prefs.remove(_enmKey);
      } else {
        await prefs.setString(_enmKey, code);
      }
    } on Exception {
      // In-memory selection still stands.
    } on Error {
      // Same.
    }
  }

  Future<void> clear() async {
    state = const SelectedSiteState();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_idKey);
      await prefs.remove(_nameKey);
      await prefs.remove(_enmKey);
    } on Exception {
      // ignore
    } on Error {
      // ignore
    }
  }
}

final selectedSiteProvider =
    StateNotifierProvider<SelectedSiteNotifier, SelectedSiteState>(
  (ref) => SelectedSiteNotifier(),
);

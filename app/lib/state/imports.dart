import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/import_targets.dart';
import '../data/repositories.dart';
import '../models/site_import.dart';
import 'providers.dart';
import 'session.dart';

/// Saved import profiles for the active site.
final importProfilesProvider = FutureProvider<List<ImportProfile>>((ref) {
  final site = ref.watch(sessionProvider.select((s) => s.site));
  if (site.isEmpty) {
    return Future<List<ImportProfile>>.value(const <ImportProfile>[]);
  }
  return ref.watch(importRepositoryProvider).fetchProfiles(site);
});

/// Committed import history for the active site.
final importRunsProvider = FutureProvider<List<ImportRun>>((ref) {
  final site = ref.watch(sessionProvider.select((s) => s.site));
  if (site.isEmpty) return Future<List<ImportRun>>.value(const <ImportRun>[]);
  return ref.watch(importRepositoryProvider).fetchRuns(site);
});

/// Where the import wizard is.
enum ImportStage {
  /// Choosing or defining a profile.
  profile,

  /// File chosen, columns read, binding source columns to target fields.
  mapping,

  /// Dry run rendered; awaiting commit.
  preview,

  /// Committed.
  done,
}

/// The whole in-flight import. One object because every step depends on the
/// previous one, and abandoning halfway must drop all of it together.
@immutable
class ImportSession {
  const ImportSession({
    required this.stage,
    this.profile,
    this.fileName,
    this.bytes,
    this.inspection,
    this.preview,
    this.run,
    this.busy = false,
    this.error,
  });

  final ImportStage stage;
  final ImportProfile? profile;
  final String? fileName;

  /// Kept client-side so preview can be re-run after a mapping change without
  /// asking the user to pick the file again.
  final Uint8List? bytes;

  final SourceInspection? inspection;
  final ImportPreview? preview;
  final ImportRun? run;
  final bool busy;
  final String? error;

  bool get hasFile => bytes != null;

  List<TargetField> get targetFields =>
      profile == null ? const <TargetField>[] : targetFieldsFor(profile!.target);

  bool get mappingComplete =>
      profile != null && profile!.isComplete(targetFields);

  ImportSession copyWith({
    ImportStage? stage,
    ImportProfile? profile,
    String? fileName,
    Uint8List? bytes,
    SourceInspection? inspection,
    ImportPreview? preview,
    ImportRun? run,
    bool? busy,
    String? error,
    bool clearError = false,
    bool clearPreview = false,
  }) {
    return ImportSession(
      stage: stage ?? this.stage,
      profile: profile ?? this.profile,
      fileName: fileName ?? this.fileName,
      bytes: bytes ?? this.bytes,
      inspection: inspection ?? this.inspection,
      preview: clearPreview ? null : (preview ?? this.preview),
      run: run ?? this.run,
      busy: busy ?? this.busy,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class ImportController extends Notifier<ImportSession> {
  @override
  ImportSession build() {
    // An in-flight import belongs to one site; switching sites abandons it.
    ref.watch(sessionProvider.select((s) => s.site));
    return const ImportSession(stage: ImportStage.profile);
  }

  ImportRepository get _repo => ref.read(importRepositoryProvider);

  String get _site => ref.read(sessionProvider).site;

  void reset() => state = const ImportSession(stage: ImportStage.profile);

  /// Picks an existing profile, or starts a blank one for [target].
  void chooseProfile(ImportProfile profile) {
    state = ImportSession(stage: ImportStage.profile, profile: profile);
  }

  ImportProfile newProfile(ImportTarget target, String name) => ImportProfile(
        id: 'draft-${DateTime.now().microsecondsSinceEpoch}',
        siteCode: _site,
        name: name,
        target: target,
      );

  /// Reads the chosen file's headers so the user can bind columns.
  Future<void> attachFile(String fileName, Uint8List bytes) async {
    final profile = state.profile;
    if (profile == null) return;

    state = state.copyWith(busy: true, clearError: true, clearPreview: true);
    try {
      final inspection = await _repo.inspect(
        siteCode: _site,
        fileName: fileName,
        bytes: bytes,
        sheetName: profile.sheetName,
        headerRow: profile.headerRow,
      );
      state = state.copyWith(
        stage: ImportStage.mapping,
        fileName: fileName,
        bytes: bytes,
        inspection: inspection,
        // A fresh sheet with unbound fields gets a best-effort auto-map.
        profile: _autoMap(profile, inspection),
        busy: false,
      );
    } on ApiException catch (e) {
      state = state.copyWith(busy: false, error: e.message);
    }
  }

  /// Binds source columns to target fields whose names obviously match, so the
  /// user confirms rather than types. Existing bindings are never overwritten.
  ImportProfile _autoMap(ImportProfile profile, SourceInspection inspection) {
    var next = profile;
    final normalisedColumns = <String, String>{
      for (final c in inspection.columns) _slug(c): c,
    };

    for (final field in targetFieldsFor(profile.target)) {
      if (next.mappingFor(field.key)?.isBound ?? false) continue;
      final match = normalisedColumns[_slug(field.label)] ??
          normalisedColumns[_slug(field.key)];
      if (match != null) {
        next = next.withMapping(
          ColumnMapping(targetKey: field.key, sourceColumn: match),
        );
      }
    }
    return next;
  }

  static String _slug(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  void bind(String targetKey, String? sourceColumn) {
    final profile = state.profile;
    if (profile == null) return;
    state = state.copyWith(
      profile: profile.withMapping(
        ColumnMapping(targetKey: targetKey, sourceColumn: sourceColumn ?? ''),
      ),
      clearPreview: true,
      clearError: true,
    );
  }

  void bindConstant(String targetKey, String value) {
    final profile = state.profile;
    if (profile == null) return;
    state = state.copyWith(
      profile: profile.withMapping(
        ColumnMapping(
          targetKey: targetKey,
          sourceColumn: '',
          constantValue: value,
        ),
      ),
      clearPreview: true,
      clearError: true,
    );
  }

  void setHeaderRow(int row) {
    final profile = state.profile;
    if (profile == null) return;
    state = state.copyWith(profile: profile.copyWith(headerRow: row));
  }

  void setSkipRows(int rows) {
    final profile = state.profile;
    if (profile == null) return;
    state = state.copyWith(profile: profile.copyWith(skipRows: rows));
  }

  void renameProfile(String name) {
    final profile = state.profile;
    if (profile == null) return;
    state = state.copyWith(profile: profile.copyWith(name: name));
  }

  /// Persists the mapping so the same sheet can be imported again next month.
  Future<void> saveProfile() async {
    final profile = state.profile;
    if (profile == null) return;
    state = state.copyWith(busy: true, clearError: true);
    try {
      final saved = await _repo.saveProfile(profile);
      state = state.copyWith(profile: saved, busy: false);
      ref.invalidate(importProfilesProvider);
    } on ApiException catch (e) {
      state = state.copyWith(busy: false, error: e.message);
    }
  }

  Future<void> deleteProfile(String id) async {
    await _repo.deleteProfile(id);
    ref.invalidate(importProfilesProvider);
    reset();
  }

  /// Dry run. Nothing is written until [commit].
  Future<void> runPreview() async {
    final profile = state.profile;
    final bytes = state.bytes;
    final fileName = state.fileName;
    if (profile == null || bytes == null || fileName == null) return;

    state = state.copyWith(busy: true, clearError: true);
    try {
      final preview = await _repo.preview(
        profile: profile,
        fileName: fileName,
        bytes: bytes,
      );
      state = state.copyWith(
        stage: ImportStage.preview,
        preview: preview,
        busy: false,
      );
    } on ApiException catch (e) {
      state = state.copyWith(busy: false, error: e.message);
    }
  }

  void backToMapping() =>
      state = state.copyWith(stage: ImportStage.mapping, clearPreview: true);

  Future<void> commit() async {
    final preview = state.preview;
    if (preview == null) return;

    state = state.copyWith(busy: true, clearError: true);
    try {
      final run = await _repo.commit(siteCode: _site, token: preview.token);
      state = state.copyWith(stage: ImportStage.done, run: run, busy: false);

      // An import rewrites the things every other screen reads.
      ref.invalidate(importRunsProvider);
      ref.invalidate(importProfilesProvider);
      ref.invalidate(masterDataProvider);
      ref.invalidate(siteConfigProvider);
    } on ApiException catch (e) {
      state = state.copyWith(busy: false, error: e.message);
    }
  }
}

final importControllerProvider =
    NotifierProvider<ImportController, ImportSession>(ImportController.new);

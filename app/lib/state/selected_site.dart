import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Holds the currently selected SiteOps site (id + name).
class SelectedSiteState {
  const SelectedSiteState({this.id, this.name = ''});
  final String? id;
  final String name;
}

class SelectedSiteNotifier extends StateNotifier<SelectedSiteState> {
  SelectedSiteNotifier() : super(const SelectedSiteState());

  void select(String id, String name) {
    state = SelectedSiteState(id: id, name: name);
  }
}

final selectedSiteProvider =
    StateNotifierProvider<SelectedSiteNotifier, SelectedSiteState>(
  (ref) => SelectedSiteNotifier(),
);

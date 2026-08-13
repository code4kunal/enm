import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/tokens.dart';

/// Bottom-centre dark pill, auto-dismissing after 2.6s. Null means hidden.
///
/// A dedicated controller rather than a `SnackBar` because the toast has to
/// float above the mobile bottom nav (84px) and sit at 24px on desktop, which
/// `ScaffoldMessenger` will not do without fighting it.
class ToastController extends Notifier<String?> {
  Timer? _timer;

  @override
  String? build() {
    ref.onDispose(() => _timer?.cancel());
    return null;
  }

  void show(String message) {
    _timer?.cancel();
    state = message;
    _timer = Timer(T.toastDuration, () => state = null);
  }

  void dismiss() {
    _timer?.cancel();
    state = null;
  }
}

final toastProvider =
    NotifierProvider<ToastController, String?>(ToastController.new);

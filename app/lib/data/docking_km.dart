/// Docking (P.M) KM ladder — keep in sync with `backend/app/seeds/docking_km.py`.
const List<int> kDockingMilestoneKm = <int>[
  3000,
  10000,
  20000,
  30000,
  40000,
  50000,
  60000,
  70000,
  80000,
  90000,
  100000,
  110000,
  120000,
];

const List<String> kDockingBusTypes = <String>[
  '9M',
  '12M AC',
  '12M Non-AC',
];

String formatDockingKm(int km) {
  if (km >= 100000) {
    final lakh = km / 100000;
    final s = lakh == lakh.roundToDouble()
        ? lakh.toStringAsFixed(0)
        : lakh.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');
    return '$s lakh';
  }
  return '${km ~/ 1000}k';
}

import 'package:flutter/material.dart';

import '../services/location_service.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// Captures where a Breakdown/Driver Complaint happened — GPS on open,
/// falling back to manual lat/long entry if denied or unavailable. The
/// [service] is passed in rather than read from a provider so this widget
/// stays trivially testable without a ProviderScope.
class LocationCaptureField extends StatefulWidget {
  const LocationCaptureField({
    super.key,
    required this.service,
    required this.onCaptured,
    this.alreadyCaptured = false,
  });

  final LocationService service;
  final void Function(double latitude, double longitude, String source)
      onCaptured;

  /// True once the entry already has a location (editing an existing one,
  /// or a GPS/manual capture already happened this session) — GPS is only
  /// attempted for a genuinely new, not-yet-captured entry so reopening the
  /// form never silently overwrites what was recorded at the time.
  final bool alreadyCaptured;

  @override
  State<LocationCaptureField> createState() => _LocationCaptureFieldState();
}

enum _Status { checking, captured, manual }

class _LocationCaptureFieldState extends State<LocationCaptureField> {
  late _Status _status = widget.alreadyCaptured ? _Status.captured : _Status.checking;
  final TextEditingController _latController = TextEditingController();
  final TextEditingController _lngController = TextEditingController();

  @override
  void initState() {
    super.initState();
    if (_status == _Status.checking) _tryGps();
  }

  @override
  void dispose() {
    _latController.dispose();
    _lngController.dispose();
    super.dispose();
  }

  Future<void> _tryGps() async {
    final fix = await widget.service.currentPosition();
    if (!mounted) return;
    if (fix == null) {
      setState(() => _status = _Status.manual);
      return;
    }
    widget.onCaptured(fix.latitude, fix.longitude, 'gps');
    setState(() => _status = _Status.captured);
  }

  void _saveManual() {
    final lat = double.tryParse(_latController.text);
    final lng = double.tryParse(_lngController.text);
    if (lat == null || lng == null) return;
    widget.onCaptured(lat, lng, 'manual');
    setState(() => _status = _Status.captured);
  }

  @override
  Widget build(BuildContext context) {
    switch (_status) {
      case _Status.checking:
        return Text(
          'Locating…',
          style: AppText.sans(size: 12.5, color: T.secondary),
        );
      case _Status.captured:
        return Text(
          'Location captured ✓',
          style: AppText.sans(size: 12.5, color: T.greenInk, weight: FontWeight.w600),
        );
      case _Status.manual:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Location not captured — enter it manually (optional)',
              style: AppText.sans(size: 12.5, color: T.secondary),
            ),
            const SizedBox(height: 6),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _latController,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true, signed: true),
                    decoration: const InputDecoration(hintText: 'Latitude'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _lngController,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true, signed: true),
                    decoration: const InputDecoration(hintText: 'Longitude'),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: _saveManual,
                  child: const Text('Save'),
                ),
              ],
            ),
          ],
        );
    }
  }
}

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../services/location_service.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'location_map.dart';

/// Depot region default center for the map picker when nothing has been
/// captured yet (Mumbai metropolitan area) -- just a starting viewport,
/// never itself submitted as a location.
const LatLng _defaultMapCenter = LatLng(19.0760, 72.8777);

/// Captures where a Breakdown/Driver Complaint happened.
///
/// Deliberately never automatic: the user enters lat/long by hand, taps
/// "Use my location" (a real GPS fix, but only on request), or picks a
/// point on the map. The [service] is passed in rather than read from a
/// provider so this widget stays trivially testable without a ProviderScope.
class LocationCaptureField extends StatefulWidget {
  const LocationCaptureField({
    super.key,
    required this.service,
    required this.onCaptured,
    this.initialLatitude,
    this.initialLongitude,
  });

  final LocationService service;
  final void Function(double latitude, double longitude, String source)
      onCaptured;

  /// Pre-fills manual entry when editing an entry that already has a
  /// captured location.
  final double? initialLatitude;
  final double? initialLongitude;

  @override
  State<LocationCaptureField> createState() => _LocationCaptureFieldState();
}

enum _Mode { entry, map }

class _LocationCaptureFieldState extends State<LocationCaptureField> {
  late _Mode _mode = _Mode.entry;
  late bool _captured =
      widget.initialLatitude != null && widget.initialLongitude != null;
  late final TextEditingController _latController =
      TextEditingController(text: widget.initialLatitude?.toString() ?? '');
  late final TextEditingController _lngController =
      TextEditingController(text: widget.initialLongitude?.toString() ?? '');

  @override
  void dispose() {
    _latController.dispose();
    _lngController.dispose();
    super.dispose();
  }

  LatLng get _mapCenter {
    final lat = double.tryParse(_latController.text);
    final lng = double.tryParse(_lngController.text);
    if (lat == null || lng == null) return _defaultMapCenter;
    return LatLng(lat, lng);
  }

  void _saveManual() {
    final lat = double.tryParse(_latController.text);
    final lng = double.tryParse(_lngController.text);
    if (lat == null || lng == null) return;
    widget.onCaptured(lat, lng, 'manual');
    setState(() => _captured = true);
  }

  Future<void> _useMyLocation() async {
    final fix = await widget.service.currentPosition();
    if (!mounted || fix == null) return;
    _latController.text = fix.latitude.toString();
    _lngController.text = fix.longitude.toString();
    widget.onCaptured(fix.latitude, fix.longitude, 'gps');
    setState(() => _captured = true);
  }

  void _confirmMapPick(double lat, double lng) {
    _latController.text = lat.toString();
    _lngController.text = lng.toString();
    widget.onCaptured(lat, lng, 'map');
    setState(() {
      _captured = true;
      _mode = _Mode.entry;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_captured && _mode == _Mode.entry) {
      return Row(
        children: <Widget>[
          Text(
            'Location captured ✓ (${_latController.text}, ${_lngController.text})',
            style: AppText.sans(size: 12.5, color: T.greenInk, weight: FontWeight.w600),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: () => setState(() => _captured = false),
            child: const Text('Edit'),
          ),
        ],
      );
    }

    if (_mode == _Mode.map) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Tap the map to place a marker at the exact spot',
            style: AppText.sans(size: 12.5, color: T.secondary),
          ),
          const SizedBox(height: 6),
          LocationMapView(center: _mapCenter, onTap: _confirmMapPick),
          const SizedBox(height: 6),
          TextButton(
            onPressed: () => setState(() => _mode = _Mode.entry),
            child: const Text('Back to manual entry'),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'Location (optional) — enter coordinates, use your current '
          'location, or pick a point on the map',
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
            TextButton(onPressed: _saveManual, child: const Text('Save')),
          ],
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          children: <Widget>[
            OutlinedButton.icon(
              onPressed: _useMyLocation,
              icon: const Icon(Icons.my_location, size: 16),
              label: const Text('Use my location'),
            ),
            OutlinedButton.icon(
              onPressed: () => setState(() => _mode = _Mode.map),
              icon: const Icon(Icons.map_outlined, size: 16),
              label: const Text('Pick on map'),
            ),
          ],
        ),
      ],
    );
  }
}

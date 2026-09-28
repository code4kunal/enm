import 'package:geolocator/geolocator.dart';

/// A GPS fix, or null if unavailable/denied. Never throws — the caller
/// decides what "no GPS" means (usually: show a manual fallback).
class LocationService {
  const LocationService();

  Future<({double latitude, double longitude})?> currentPosition() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return null;
      }
      final position = await Geolocator.getCurrentPosition();
      return (latitude: position.latitude, longitude: position.longitude);
    } catch (_) {
      return null;
    }
  }
}

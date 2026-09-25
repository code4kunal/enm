/// Translation between the app's register field keys and the API's per-register
/// `data` field names.
///
/// The app keys come from the paper registers (`bus`, `bcs`, `employee`); the
/// API keys are the column names on each register's table (`bus_no`,
/// `bcs_litres`, `topped_by`). Both are legitimate in their own layer, so the
/// mapping lives here rather than either side bending to the other. The API
/// rejects unknown keys outright (`extra="forbid"`), so an unmapped key is a
/// 400, not a silently dropped value.
abstract final class RegisterFieldMap {
  /// app key -> API key, per register id.
  static const Map<String, Map<String, String>> _toWire =
      <String, Map<String, String>>{
    'work': <String, String>{
      'shift': 'shift',
      'bus': 'bus_no',
      'defects': 'reported_defects',
      'source': 'defect_source',
      'defectType': 'defect_type',
      'attended': 'attended_details',
      'spares': 'spare_parts_used',
      'supervisor': 'supervisor',
      'ticketId': 'ticket_id',
      'completesTicket': 'completes_ticket',
      'completionTime': 'completion_time',
      'attendeeUserIds': 'attendee_user_ids',
    },
    'coolant': <String, String>{
      'bus': 'bus_no',
      'bcs': 'bcs_litres',
      'tcs': 'tcs_litres',
      'employee': 'topped_by',
      'supervisor': 'supervisor',
    },
    'complaint': <String, String>{
      'bus': 'bus_no',
      'defectType': 'defect_type',
      'complaint': 'complaint',
      'action': 'rectification_action',
      'mechanic': 'mechanic',
      'supervisor': 'supervisor',
    },
    'breakdown': <String, String>{
      'bus': 'bus_no',
      'defectType': 'defect_type',
      'driver': 'driver_id',
      'route': 'route',
      'loc': 'location',
      'complaint': 'complaint',
      't_reported': 'reported_time',
      't_att': 'attended_time',
      'loss': 'loss_km',
      'attended': 'attended_details',
      'remarks': 'remarks',
      'supervisor': 'supervisor',
    },
    'pm': <String, String>{
      'bus': 'bus_no',
      'defectType': 'defect_type',
      'defects': 'defects_noticed',
      'action': 'action_taken',
      'balance': 'balance_job_reason',
      'spares': 'spare_parts_used',
      'employee': 'employees',
      'supervisor': 'supervisor',
    },
  };

  static final Map<String, Map<String, String>> _fromWire =
      <String, Map<String, String>>{
    for (final entry in _toWire.entries)
      entry.key: <String, String>{
        for (final pair in entry.value.entries) pair.value: pair.key,
      },
  };

  /// Numeric API fields, sent as numbers rather than strings.
  static const Set<String> _numericWireKeys = <String>{
    'bcs_litres',
    'tcs_litres',
    'loss_km',
  };

  /// Fields the API sends/accepts as a JSON boolean, not a string.
  static const Set<String> _boolWireKeys = <String>{'completes_ticket'};

  /// Fields the API sends/accepts as a JSON array — the form stores them as
  /// a single comma-joined string, same trick `_numericWireKeys` uses for
  /// numbers.
  static const Set<String> _listWireKeys = <String>{'attendee_user_ids'};

  /// Converts the form's values into the register's API payload.
  ///
  /// Blank values are dropped rather than sent as empty strings — the API's
  /// required fields reject those, and its optional ones mean "absent".
  static Map<String, dynamic> toWire(
    String registerId,
    Map<String, String> data,
  ) {
    final map = _toWire[registerId];
    if (map == null) return <String, dynamic>{};

    final out = <String, dynamic>{};
    for (final entry in data.entries) {
      final wireKey = map[entry.key];
      if (wireKey == null) continue;
      final value = entry.value.trim();
      if (value.isEmpty) continue;

      if (_numericWireKeys.contains(wireKey)) {
        final number = num.tryParse(value);
        if (number != null) out[wireKey] = number;
        continue;
      }
      if (_boolWireKeys.contains(wireKey)) {
        out[wireKey] = value == 'true';
        continue;
      }
      if (_listWireKeys.contains(wireKey)) {
        out[wireKey] = value.split(',').where((s) => s.isNotEmpty).toList();
        continue;
      }
      out[wireKey] = value;
    }
    return out;
  }

  /// Converts an API `data` object back into the form's keys.
  ///
  /// Everything becomes a string because that is what the form holds; numbers
  /// keep their printed form so `1.5` does not become `1.5000`.
  static Map<String, String> fromWire(
    String registerId,
    Map<String, dynamic> data,
  ) {
    final map = _fromWire[registerId];
    final out = <String, String>{};
    if (map == null) return out;

    for (final entry in data.entries) {
      if (registerId == 'work' && entry.key == 'attendees') {
        final ids = (entry.value as List<dynamic>? ?? <dynamic>[])
            .map((a) => (a as Map<String, dynamic>)['user_id'] as String)
            .join(',');
        out['attendeeUserIds'] = ids;
        continue;
      }
      final appKey = map[entry.key];
      if (appKey == null) continue;
      final value = entry.value;
      if (value == null) continue;
      if (value is bool) {
        out[appKey] = value.toString();
        continue;
      }
      out[appKey] = value is String ? value : _printNumber(value);
    }
    return out;
  }

  /// Trims the trailing `.0` the API's Decimal serialisation can produce, so a
  /// round trip does not turn "2" into "2.0" on screen.
  static String _printNumber(Object value) {
    if (value is num && value == value.roundToDouble() && value.abs() < 1e15) {
      return value.toInt().toString();
    }
    return value.toString();
  }

  /// The API key holding the bus number, shared by every register.
  static const String busWireKey = 'bus_no';
}

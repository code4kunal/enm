import "dart:async";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../data/api/siteops_client.dart";
import "../state/selected_site.dart";
import "../theme/app_theme.dart";
import "../theme/tokens.dart";

// ─── Model ────────────────────────────────────────────────────────────────────

class _Vehicle {
  const _Vehicle({
    required this.id, required this.vehicleNo, required this.code,
    required this.ttNo, required this.vehicleTypeName, required this.vehicleTypeId,
    required this.make, required this.model, required this.fuel, required this.variant,
    required this.engineNo, required this.chassisNo, required this.macId,
    required this.capacity, required this.acNac, required this.lastOdo,
    required this.status, required this.isActive, required this.isFitnessExpired,
    required this.fitnessExpiry, required this.sites, required this.manufactureYear,
    required this.dateOfReg, required this.rtoLoc, required this.financierName,
    required this.fitnessCertNo,
  });

  final String id, vehicleNo, code, ttNo, vehicleTypeName, vehicleTypeId;
  final String make, model, fuel, variant, engineNo, chassisNo, macId;
  final String capacity, acNac, lastOdo, status, fitnessExpiry;
  final String manufactureYear, dateOfReg, rtoLoc, financierName, fitnessCertNo;
  final bool isActive, isFitnessExpired;
  final List<Map<String, dynamic>> sites;

  factory _Vehicle.fromJson(Map<String, dynamic> j) {
    final sitesList = (j["sites"] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>()
        .toList();
    return _Vehicle(
      id: j["id"]?.toString() ?? "",
      vehicleNo: j["vehicle_no"]?.toString() ?? "",
      code: j["code"]?.toString() ?? "",
      ttNo: j["tt_no"]?.toString() ?? "",
      vehicleTypeName: j["vehicle_type_name"]?.toString() ?? "",
      vehicleTypeId: j["vehicle_type_id"]?.toString() ?? "",
      make: j["make"]?.toString() ?? "",
      model: j["model"]?.toString() ?? "",
      variant: j["variant"]?.toString() ?? "",
      fuel: j["fuel"]?.toString() ?? "",
      engineNo: j["engine_no"]?.toString() ?? "",
      chassisNo: j["chassis_no"]?.toString() ?? "",
      macId: j["mac_id"]?.toString() ?? "",
      capacity: j["capacity"]?.toString() ?? "",
      acNac: j["ac_nac"]?.toString() ?? "",
      lastOdo: j["last_odo"]?.toString() ?? "",
      status: j["status"]?.toString() ?? "",
      isActive: j["is_active"] as bool? ?? true,
      isFitnessExpired: j["is_fitness_expired"] as bool? ?? false,
      fitnessExpiry: j["fitness_expiry_date"]?.toString() ?? "",
      manufactureYear: j["manufacture_year"]?.toString() ?? "",
      dateOfReg: j["date_of_reg"]?.toString() ?? "",
      rtoLoc: j["rto_loc"]?.toString() ?? "",
      financierName: j["financier_name"]?.toString() ?? "",
      fitnessCertNo: j["fitness_cert_no"]?.toString() ?? "",
      sites: sitesList,
    );
  }
}

// ─── Screen ───────────────────────────────────────────────────────────────────

class VehicleMasterScreen extends ConsumerStatefulWidget {
  const VehicleMasterScreen({super.key});

  @override
  ConsumerState<VehicleMasterScreen> createState() => _VehicleMasterScreenState();
}

class _VehicleMasterScreenState extends ConsumerState<VehicleMasterScreen> {
  static const _pageSize = 10;

  final _searchCtrl = TextEditingController();
  Timer? _debounce;
  List<_Vehicle> _records = [];
  List<Map<String, dynamic>> _vehicleTypes = [];
  List<Map<String, dynamic>> _allSites = [];
  int _totalCount = 0;
  int _currentPage = 1;
  bool _isLoading = false;
  String? _error;
  String? _lastSiteId;

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(_onSearchChanged);
    _fetchLookups();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final siteId = ref.read(selectedSiteProvider).id;
      if (siteId != null && siteId.isNotEmpty) {
        _lastSiteId = siteId;
        _fetch(siteId);
      }
    });
  }
  
  Future<void> _fetchLookups() async {
    try {
      final vtJson = await siteOpsClient.get("/master/vehicle-types?pagination=false");
      final vtData = vtJson is Map ? vtJson["data"] as List<dynamic>? ?? [] : [];
      _vehicleTypes = vtData.map((e) => e as Map<String, dynamic>).toList();
      
      final stJson = await siteOpsClient.get("/onboarding/sites/dropdown");
      final stData = stJson is Map ? stJson["data"] as List<dynamic>? ?? [] : [];
      _allSites = stData.map((e) => e as Map<String, dynamic>).toList();
      if (mounted) setState(() {});
    } catch (_) {}
  }

  @override
  void dispose() {
    _searchCtrl.removeListener(_onSearchChanged);
    _searchCtrl.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onSearchChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      setState(() => _currentPage = 1);
      _fetch(ref.read(selectedSiteProvider).id);
    });
  }

  Future<void> _fetch(String? siteId) async {
    if (siteId == null || siteId.isEmpty) return;
    setState(() { _isLoading = true; _error = null; });
    try {
      final q = <String, String>{
        "page_size": "$_pageSize",
        "page": "$_currentPage",
        "site_id": siteId,
        if (_searchCtrl.text.trim().isNotEmpty) "search": _searchCtrl.text.trim(),
      };
      final json = await siteOpsClient.get("/master/vehicles", query: q);
      final data = json is Map ? json : <String, dynamic>{};
      final items = (data["data"] ?? []) as List<dynamic>;
      final pag = data["pagination"] as Map<String, dynamic>? ?? {};
      if (!mounted) return;
      setState(() {
        _records = items.map((e) => _Vehicle.fromJson(e as Map<String, dynamic>)).toList();
        _totalCount = (pag["total_items"] as int?) ?? items.length;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString().replaceAll("Exception: ", ""));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  int get _totalPages => (_totalCount / _pageSize).ceil().clamp(1, 9999);

  void _goToPage(int page) {
    if (page < 1 || page > _totalPages) return;
    setState(() => _currentPage = page);
    _fetch(ref.read(selectedSiteProvider).id);
  }

  // ─── Form Modal ──────────────────────────────────────────────────────────

  Future<void> _showFormModal({_Vehicle? existing}) async {
    final ctrls = {
      "vehicle_no": TextEditingController(text: existing?.vehicleNo ?? ""),
      "code":       TextEditingController(text: existing?.code ?? ""),
      "tt_no":      TextEditingController(text: existing?.ttNo ?? ""),
      
      "make":       TextEditingController(text: existing?.make ?? ""),
      "model":      TextEditingController(text: existing?.model ?? ""),
      "variant":    TextEditingController(text: existing?.variant ?? ""),
      "capacity":   TextEditingController(text: existing?.capacity ?? ""),
      "last_odo":   TextEditingController(text: existing?.lastOdo ?? ""),
      
      "engine_no":  TextEditingController(text: existing?.engineNo ?? ""),
      "chassis_no": TextEditingController(text: existing?.chassisNo ?? ""),
      "mac_id":     TextEditingController(text: existing?.macId ?? ""),
      
      "date_of_reg":TextEditingController(text: existing?.dateOfReg ?? ""),
      "rto_loc":    TextEditingController(text: existing?.rtoLoc ?? ""),
      "financier_name": TextEditingController(text: existing?.financierName ?? ""),
      
      "fitness_cert_no": TextEditingController(text: existing?.fitnessCertNo ?? ""),
      "fitness_expiry_date": TextEditingController(text: existing?.fitnessExpiry ?? ""),
    };
    
    String? selectedVehicleType = existing?.vehicleTypeId.isNotEmpty == true ? existing?.vehicleTypeId : null;
    String? selectedAcNac = existing?.acNac.isNotEmpty == true ? existing?.acNac : null;
    String? selectedFuel = existing?.fuel.isNotEmpty == true ? existing?.fuel : null;
    String? selectedYear = existing?.manufactureYear.isNotEmpty == true ? existing?.manufactureYear : null;
    String? selectedStatus = existing?.status.isNotEmpty == true ? existing?.status : null;
    bool isActive = existing?.isActive ?? true;
    
    List<String> selectedSites = existing?.sites.map((s) => s["id"].toString()).toList() ?? [];
    if (selectedSites.isEmpty && ref.read(selectedSiteProvider).id != null) {
      selectedSites.add(ref.read(selectedSiteProvider).id!);
    }

    String? err;
    bool saving = false;
    
    final currentYear = DateTime.now().year;
    final years = List.generate(currentYear - 1950 + 1, (i) => (1950 + i).toString()).reversed.toList();

    // Helper to prevent material dropdown crash if value is not in items list
    String? sanitizeDropdown(String? val, List<String> allowed) {
      if (val == null) return null;
      if (allowed.contains(val)) return val;
      return null;
    }


    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setDlg) {
        final allowedVTypes = _vehicleTypes.map((vt) => vt["id"].toString()).toList();
        final allowedAc = ["12M AC", "12M NAC", "9M AC", "9M NAC", "Other"];
        final allowedFuel = ["Electric", "Diesel", "CNG", "Petrol"];
        final allowedStatus = ["Active", "Inactive", "Maintenance", "Retired"];
        Widget fld(String key, String label, {String hint = ""}) => Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: AppText.sans(size: 12, color: T.secondary)),
            const SizedBox(height: 4),
            TextField(
              controller: ctrls[key],
              style: AppText.sans(size: 14),
              decoration: InputDecoration(
                hintText: hint.isEmpty ? label : hint,
                hintStyle: AppText.sans(size: 13, color: T.muted),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: T.inputBorder)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: T.inputBorder)),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: T.green, width: 1.5)),
              ),
            ),
          ]),
        );
        
        Widget ddl(String label, String? val, List<DropdownMenuItem<String>> items, Function(String?) onChanged) => Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: AppText.sans(size: 12, color: T.secondary)),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: T.inputBorder),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: val,
                  isExpanded: true,
                  isDense: false,
                  hint: Text("Select $label", style: AppText.sans(size: 13, color: T.muted)),
                  items: items,
                  onChanged: (v) => setDlg(() => onChanged(v)),
                ),
              ),
            ),
          ]),
        );
        
        Widget secLabel(String title) => Padding(
          padding: const EdgeInsets.only(top: 16, bottom: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: AppText.sans(size: 14, weight: FontWeight.w700, color: T.green)),
              const SizedBox(height: 4),
              Container(height: 1, color: T.border),
            ],
          ),
        );

        return Dialog(
          backgroundColor: T.card,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: SizedBox(
            width: 700,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(28, 28, 28, 0),
                  child: Row(children: [
                    Expanded(child: Text(
                      existing == null ? "Add Vehicle" : "Update Vehicle",
                      style: AppText.sans(size: 18, weight: FontWeight.w700),
                    )),
                    IconButton(onPressed: () => Navigator.of(ctx).pop(),
                        icon: const Icon(Icons.close, size: 20)),
                  ]),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      if (err != null) ...[
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(color: T.red.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(8)),
                          child: Text(err!, style: AppText.sans(size: 13, color: T.red)),
                        ),
                        const SizedBox(height: 12),
                      ],
                      
                      secLabel("General Information"),
                      Row(
                        children: [
                          Expanded(child: fld("vehicle_no", "Vehicle Number *", hint: "e.g. MH01AB1234")),
                          const SizedBox(width: 16),
                          Expanded(child: fld("code", "Vehicle Code", hint: "Internal Ref Code")),
                        ],
                      ),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: fld("tt_no", "TT Number", hint: "e.g. TT-01")),
                          const SizedBox(width: 16),
                          Expanded(child: Padding(
                            padding: const EdgeInsets.only(bottom: 14),
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text("Sites *", style: AppText.sans(size: 12, color: T.secondary)),
                              const SizedBox(height: 4),
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: T.inputBorder),
                                ),
                                child: Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    for (final s in _allSites)
                                      FilterChip(
                                        label: Text(s["name"] ?? "", style: AppText.sans(size: 12)),
                                        selected: selectedSites.contains(s["id"]),
                                        onSelected: (val) {
                                          setDlg(() {
                                            if (val) selectedSites.add(s["id"]);
                                            else selectedSites.remove(s["id"]);
                                          });
                                        },
                                      )
                                  ],
                                ),
                              ),
                            ]),
                          )),
                        ],
                      ),
                      
                      secLabel("Technical Specifications"),
                      Row(
                        children: [
                          Expanded(child: fld("make", "Make", hint: "e.g. Tata")),
                          const SizedBox(width: 16),
                          Expanded(child: fld("model", "Model", hint: "e.g. LPO 1618")),
                        ],
                      ),
                      Row(
                        children: [
                          Expanded(child: fld("variant", "Variant", hint: "Standard / BS-VI")),
                          const SizedBox(width: 16),
                          Expanded(child: ddl("Vehicle Type *", sanitizeDropdown(selectedVehicleType, allowedVTypes), [
                            for (final vt in _vehicleTypes)
                              DropdownMenuItem(value: vt["id"], child: Text(vt["type"] ?? ""))
                          ], (v) => selectedVehicleType = v)),
                        ],
                      ),
                      Row(
                        children: [
                          Expanded(child: ddl("AC / Non-AC", sanitizeDropdown(selectedAcNac, allowedAc), [
                            for (final a in ["12M AC", "12M NAC", "9M AC", "9M NAC", "Other"])
                              DropdownMenuItem(value: a, child: Text(a))
                          ], (v) => selectedAcNac = v)),
                          const SizedBox(width: 16),
                          Expanded(child: ddl("Fuel Type", sanitizeDropdown(selectedFuel, allowedFuel), [
                            for (final f in ["Electric", "Diesel", "CNG", "Petrol"])
                              DropdownMenuItem(value: f, child: Text(f))
                          ], (v) => selectedFuel = v)),
                        ],
                      ),
                      Row(
                        children: [
                          Expanded(child: fld("capacity", "Seating Capacity", hint: "e.g. 50 + 1")),
                          const SizedBox(width: 16),
                          Expanded(child: fld("last_odo", "Last Odometer", hint: "Current reading")),
                        ],
                      ),
                      
                      secLabel("Engine & Identity"),
                      Row(
                        children: [
                          Expanded(child: fld("engine_no", "Engine Number *", hint: "Unique Engine ID")),
                          const SizedBox(width: 16),
                          Expanded(child: fld("chassis_no", "Chassis Number *", hint: "Unique Chassis ID")),
                        ],
                      ),
                      Row(
                        children: [
                          Expanded(child: fld("mac_id", "MAC ID / Device ID *", hint: "Hardware ID")),
                          const SizedBox(width: 16),
                          const Spacer(),
                        ],
                      ),
                      
                      secLabel("Registration & Financial"),
                      Row(
                        children: [
                          Expanded(child: ddl("Manufacturing Year", sanitizeDropdown(selectedYear, years), [
                            for (final y in years) DropdownMenuItem(value: y, child: Text(y))
                          ], (v) => selectedYear = v)),
                          const SizedBox(width: 16),
                          Expanded(child: fld("date_of_reg", "Date of Registration", hint: "YYYY-MM-DD")),
                        ],
                      ),
                      Row(
                        children: [
                          Expanded(child: fld("rto_loc", "RTO Location", hint: "City / District")),
                          const SizedBox(width: 16),
                          Expanded(child: fld("financier_name", "Financier Name", hint: "Bank / Institution Name")),
                        ],
                      ),
                      
                      secLabel("Maintenance & Documents"),
                      Row(
                        children: [
                          Expanded(child: fld("fitness_cert_no", "Fitness Certificate No", hint: "Cert ID No")),
                          const SizedBox(width: 16),
                          Expanded(child: fld("fitness_expiry_date", "Fitness Expiry Date", hint: "YYYY-MM-DD")),
                        ],
                      ),
                      Row(
                        children: [
                          Expanded(child: ddl("Status", sanitizeDropdown(selectedStatus, allowedStatus), [
                            for (final s in ["Active", "Inactive", "Maintenance", "Retired"]) DropdownMenuItem(value: s, child: Text(s))
                          ], (v) => selectedStatus = v)),
                          const SizedBox(width: 16),
                          Expanded(child: Padding(
                            padding: const EdgeInsets.only(bottom: 14),
                            child: Row(
                              children: [
                                Checkbox(value: isActive, onChanged: (v) => setDlg(() => isActive = v ?? true), activeColor: T.green),
                                Text("Active", style: AppText.sans(size: 14)),
                              ],
                            ),
                          )),
                        ],
                      ),
                      const SizedBox(height: 20),
                    ]),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(28.0),
                  child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      child: Text("Cancel", style: AppText.sans(size: 14, color: T.secondary)),
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: T.green, foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                      ),
                      onPressed: saving ? null : () async {
                        final vNo = ctrls["vehicle_no"]!.text.trim();
                        final eng = ctrls["engine_no"]!.text.trim();
                        final cha = ctrls["chassis_no"]!.text.trim();
                        final mac = ctrls["mac_id"]!.text.trim();
                        if (vNo.isEmpty || eng.isEmpty || cha.isEmpty || mac.isEmpty) {
                          setDlg(() => err = "Vehicle No, Engine No, Chassis No and MAC ID are required.");
                          return;
                        }
                        if (selectedSites.isEmpty) {
                          setDlg(() => err = "At least one site must be selected.");
                          return;
                        }
                        if (selectedVehicleType == null) {
                          setDlg(() => err = "Vehicle Type is required.");
                          return;
                        }
                        
                        setDlg(() => saving = true);
                        try {
                          final payload = {
                            "vehicle_no": vNo, "engine_no": eng,
                            "chassis_no": cha, "mac_id": mac,
                            "site_ids": selectedSites,
                            "vehicle_type_id": selectedVehicleType,
                            if (ctrls["code"]!.text.trim().isNotEmpty) "code": ctrls["code"]!.text.trim(),
                            if (ctrls["make"]!.text.trim().isNotEmpty) "make": ctrls["make"]!.text.trim(),
                            if (ctrls["model"]!.text.trim().isNotEmpty) "model": ctrls["model"]!.text.trim(),
                            if (ctrls["variant"]!.text.trim().isNotEmpty) "variant": ctrls["variant"]!.text.trim(),
                            if (ctrls["tt_no"]!.text.trim().isNotEmpty) "tt_no": ctrls["tt_no"]!.text.trim(),
                            if (ctrls["capacity"]!.text.trim().isNotEmpty) "capacity": ctrls["capacity"]!.text.trim(),
                            if (ctrls["last_odo"]!.text.trim().isNotEmpty) "last_odo": double.tryParse(ctrls["last_odo"]!.text.trim()) ?? 0.0,
                            if (ctrls["date_of_reg"]!.text.trim().isNotEmpty) "date_of_reg": ctrls["date_of_reg"]!.text.trim(),
                            if (ctrls["rto_loc"]!.text.trim().isNotEmpty) "rto_loc": ctrls["rto_loc"]!.text.trim(),
                            if (ctrls["financier_name"]!.text.trim().isNotEmpty) "financier_name": ctrls["financier_name"]!.text.trim(),
                            if (ctrls["fitness_cert_no"]!.text.trim().isNotEmpty) "fitness_cert_no": ctrls["fitness_cert_no"]!.text.trim(),
                            if (ctrls["fitness_expiry_date"]!.text.trim().isNotEmpty) "fitness_expiry_date": ctrls["fitness_expiry_date"]!.text.trim(),
                            if (selectedAcNac != null) "ac_nac": selectedAcNac,
                            if (selectedFuel != null) "fuel": selectedFuel,
                            if (selectedYear != null) "manufacture_year": int.parse(selectedYear!),
                            if (selectedStatus != null) "status": selectedStatus,
                            "is_active": isActive,
                          };
                          
                          if (existing == null) {
                            await siteOpsClient.multipart("POST", "/master/vehicles", payload);
                          } else {
                            await siteOpsClient.multipart("PATCH", "/master/vehicles/${existing.id}", payload);
                          }
                          if (ctx.mounted) Navigator.of(ctx).pop();
                          _fetch(ref.read(selectedSiteProvider).id);
                          _toast(existing == null ? "Vehicle created!" : "Vehicle updated!");
                        } catch (e) {
                          setDlg(() { saving = false; err = e.toString().replaceAll("Exception: ", ""); });
                        }
                      },
                      child: Text(saving ? "Saving…" : "Save",
                          style: AppText.sans(size: 14, weight: FontWeight.w600, color: Colors.white)),
                    ),
                  ]),
                ),
              ],
            ),
          ),
        );
      }),
    );
    for (final c in ctrls.values) {
      c.dispose();
    }
  }

  // ─── Delete ───────────────────────────────────────────────────────────────

  Future<void> _confirmDelete(_Vehicle v) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: T.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text("Delete Vehicle", style: AppText.sans(size: 17, weight: FontWeight.w700)),
        content: Text('Delete "${v.vehicleNo}"? This cannot be undone.',
            style: AppText.sans(size: 14, color: T.secondary)),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false),
              child: Text("Cancel", style: AppText.sans(size: 14, color: T.secondary))),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true),
              child: Text("Delete", style: AppText.sans(size: 14, color: T.red, weight: FontWeight.w700))),
        ],
      ),
    );
    if (ok == true) {
      try {
        await siteOpsClient.delete("/master/vehicles/${v.id}");
        _fetch(ref.read(selectedSiteProvider).id);
        _toast("Vehicle deleted.");
      } catch (e) {
        _toast(e.toString().replaceAll("Exception: ", ""), isError: true);
      }
    }
  }

  void _toast(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: AppText.sans(size: 14, color: Colors.white)),
      backgroundColor: isError ? T.red : T.green,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      margin: const EdgeInsets.all(16),
    ));
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // Watch for site changes and re-fetch
    final site = ref.watch(selectedSiteProvider);
    if (site.id != null && site.id!.isNotEmpty && site.id != _lastSiteId) {
      _lastSiteId = site.id;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() => _currentPage = 1);
        _fetch(site.id);
      });
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Header ──────────────────────────────────────────────────────────
        Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text("Vehicle Master", style: AppText.sans(size: 20, weight: FontWeight.w700)),
            if (site.name.isNotEmpty)
              Text("Site: ${site.name}", style: AppText.sans(size: 13, color: T.secondary)),
          ])),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: T.green, foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
            ),
            onPressed: () => _showFormModal(),
            icon: const Icon(Icons.add, size: 18, color: Colors.white),
            label: Text("Add Vehicle",
                style: AppText.sans(size: 14, weight: FontWeight.w600, color: Colors.white)),
          ),
        ]),
        const SizedBox(height: 16),

        // ── Search ──────────────────────────────────────────────────────────
        Container(
          decoration: BoxDecoration(color: T.card, borderRadius: T.controlShape,
              border: Border.all(color: T.inputBorder, width: 1.5)),
          child: TextField(
            controller: _searchCtrl,
            style: AppText.sans(size: 14),
            decoration: InputDecoration(
              hintText: "Search vehicles…",
              hintStyle: AppText.sans(size: 14, color: T.muted),
              prefixIcon: const Icon(Icons.search, size: 18, color: T.muted),
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            ),
          ),
        ),
        const SizedBox(height: 16),

        // ── Body ────────────────────────────────────────────────────────────
        if (_isLoading)
          const Padding(
            padding: EdgeInsets.only(top: 60),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 40),
            child: Center(child: Column(children: [
              Text(_error!, style: AppText.sans(size: 14, color: T.red)),
              const SizedBox(height: 12),
              OutlinedButton(onPressed: () => _fetch(site.id), child: const Text("Retry")),
            ])),
          )
        else if (site.id == null || site.id!.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 40),
            child: Center(child: Text("Select a site from the header dropdown.",
                style: AppText.sans(size: 14, color: T.secondary))),
          )
        else if (_records.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 40),
            child: Center(child: Text("No vehicles found for this site.",
                style: AppText.sans(size: 14, color: T.secondary))),
          )
        else ...[
          _buildTable(),
          const SizedBox(height: 8),
          _buildPagination(),
        ],
      ],
    );
  }

  // ─── Table ───────────────────────────────────────────────────────────────

  Widget _buildTable() {
    return Container(
      decoration: BoxDecoration(
        color: T.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: T.border),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header row
            Container(
              decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: T.border))),
              child: Row(children: [
                _hCell("Sr No", 60),
                _hCell("Vehicle No", 140),
                _hCell("Type", 110),
                _hCell("Make / Model", 170),
                _hCell("Engine No", 130),
                _hCell("Chassis No", 130),
                _hCell("Fuel", 80),
                _hCell("Status", 90),
                _hCell("Fitness Expiry", 120),
                _hCell("Actions", 130),
              ]),
            ),
            // Data rows
            for (int i = 0; i < _records.length; i++) ...[
              if (i > 0) const Divider(height: 1, color: T.border),
              _buildRow(i, _records[i]),
            ],
          ],
        ),
      ),
    );
  }

  Widget _hCell(String label, double w) => SizedBox(
    width: w,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      child: Text(label, style: AppText.sans(size: 12, weight: FontWeight.w700, color: T.secondary)),
    ),
  );

  Widget _cell(String text, double w, {Color color = T.ink, FontWeight? weight}) => SizedBox(
    width: w,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
      child: Text(
        text.isEmpty || text == "null" ? "—" : text,
        overflow: TextOverflow.ellipsis,
        style: AppText.sans(size: 13, color: color, weight: weight ?? FontWeight.normal),
      ),
    ),
  );

  Widget _buildRow(int idx, _Vehicle v) {
    final srNo = (_currentPage - 1) * _pageSize + idx + 1;
    final makeModel = [v.make, v.model].where((s) => s.isNotEmpty && s != "null").join(" / ");
    return Row(children: [
      _cell("$srNo", 60, color: T.secondary),
      _cell(v.vehicleNo, 140, weight: FontWeight.w600),
      _cell(v.vehicleTypeName, 110),
      _cell(makeModel.isEmpty ? "—" : makeModel, 170),
      _cell(v.engineNo, 130),
      _cell(v.chassisNo, 130),
      _cell(v.fuel, 80),

      // Status badge
      SizedBox(width: 90, child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: v.isActive ? T.green.withOpacity(0.12) : T.red.withOpacity(0.1),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            v.status.isEmpty ? (v.isActive ? "Active" : "Inactive") : v.status,
            style: AppText.mono(size: 10, color: v.isActive ? T.green : T.red, weight: FontWeight.w700),
          ),
        ),
      )),

      // Fitness expiry
      SizedBox(width: 120, child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
        child: v.isFitnessExpired
            ? Text("Expired", style: AppText.mono(size: 11, color: T.red, weight: FontWeight.w700))
            : Text(v.fitnessExpiry.isEmpty ? "—" : v.fitnessExpiry,
                style: AppText.sans(size: 12, color: T.secondary)),
      )),

      // Actions
      SizedBox(width: 130, child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(children: [
          _btn("Edit", Icons.edit_outlined, T.green, () => _showFormModal(existing: v)),
          const SizedBox(width: 6),
          _btn("Delete", Icons.delete_outline, T.red, () => _confirmDelete(v)),
        ]),
      )),
    ]);
  }

  Widget _btn(String label, IconData icon, Color color, VoidCallback onTap) =>
    InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(color: color.withOpacity(0.08), borderRadius: BorderRadius.circular(6)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 3),
          Text(label, style: AppText.sans(size: 11, color: color, weight: FontWeight.w600)),
        ]),
      ),
    );

  // ─── Pagination ───────────────────────────────────────────────────────────

  Widget _buildPagination() {
    final start = (_currentPage - 2).clamp(1, _totalPages);
    final end = (start + 4).clamp(1, _totalPages);
    return Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
      Text("Showing ${_records.length} of $_totalCount vehicles",
          style: AppText.sans(size: 13, color: T.secondary)),
      Row(children: [
        IconButton(
          onPressed: _currentPage > 1 ? () => _goToPage(_currentPage - 1) : null,
          icon: const Icon(Icons.chevron_left), iconSize: 20),
        for (int p = start; p <= end; p++) _pageBtn(p),
        IconButton(
          onPressed: _currentPage < _totalPages ? () => _goToPage(_currentPage + 1) : null,
          icon: const Icon(Icons.chevron_right), iconSize: 20),
      ]),
    ]);
  }

  Widget _pageBtn(int page) {
    final active = page == _currentPage;
    return InkWell(
      onTap: () => _goToPage(page),
      borderRadius: BorderRadius.circular(6),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 2),
        width: 32, height: 32,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? T.green : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text("$page", style: AppText.sans(size: 13, weight: FontWeight.w600,
            color: active ? Colors.white : T.secondary)),
      ),
    );
  }
}

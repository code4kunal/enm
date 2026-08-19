"""What each import target accepts.

Mirrors `../app/lib/data/import_targets.dart`. Register targets take the
register's own field keys — the *app* keys from `registers.dart` (`bus`,
`defects`, `employee`), not the API's column names — because that is what the
client's mapping UI binds against. `app/lib/data/api/field_map.dart` is the
matching translation on the other side; this file carries it for imports.
"""
from __future__ import annotations

from dataclasses import dataclass

from app.models.enums import ImportTarget, Register


@dataclass(frozen=True, slots=True)
class TargetField:
    key: str
    label: str
    required: bool = False


#: Register app-key -> API `data` key. Must match `field_map.dart`.
REGISTER_FIELD_MAP: dict[Register, dict[str, str]] = {
    Register.work_done: {
        "shift": "shift",
        "bus": "bus_no",
        "defects": "reported_defects",
        "source": "defect_source",
        "defectType": "defect_type",
        "attended": "attended_details",
        "spares": "spare_parts_used",
        "supervisor": "supervisor",
        "employee": "employee",
    },
    Register.coolant: {
        "bus": "bus_no",
        "bcs": "bcs_litres",
        "tcs": "tcs_litres",
        "supervisor": "supervisor",
        "employee": "topped_by",
    },
    Register.driver_complaint: {
        "bus": "bus_no",
        "defectType": "defect_type",
        "complaint": "complaint",
        "action": "rectification_action",
        "supervisor": "supervisor",
        "mechanic": "mechanic",
    },
    Register.breakdown: {
        "bus": "bus_no",
        "defectType": "defect_type",
        "driver": "driver_id",
        "route": "route",
        "loc": "location",
        "complaint": "complaint",
        "t_bd": "breakdown_time",
        "t_mech": "mechanic_reported_time",
        "t_att": "attended_time",
        "loss": "loss_km",
        "attended": "attended_details",
        "supervisor": "supervisor",
        "remarks": "remarks",
    },
    Register.pm_schedule: {
        "bus": "bus_no",
        "defectType": "defect_type",
        "defects": "defects_noticed",
        "action": "action_taken",
        "balance": "balance_job_reason",
        "spares": "spare_parts_used",
        "supervisor": "supervisor",
        "employee": "employees",
    },
}

#: Values the API expects as numbers rather than strings.
NUMERIC_WIRE_KEYS = frozenset({"bcs_litres", "tcs_litres", "loss_km"})
TIME_WIRE_KEYS = frozenset(
    {"breakdown_time", "mechanic_reported_time", "attended_time"}
)

#: Register field definitions, in the order the paper register reads.
_REGISTER_FIELDS: dict[Register, list[TargetField]] = {
    Register.work_done: [
        TargetField("shift", "Shift"),
        TargetField("date", "Date", required=True),
        TargetField("bus", "Bus No", required=True),
        TargetField("defects", "Reported Defects", required=True),
        TargetField("source", "Source of Defect"),
        TargetField("defectType", "Type of Defect"),
        TargetField("attended", "Attended Details"),
        TargetField("spares", "Spare Parts Used"),
        TargetField("employee", "Name & No. of Employee"),
        TargetField("supervisor", "Supervisor (floor)"),
    ],
    Register.coolant: [
        TargetField("date", "Date", required=True),
        TargetField("bus", "Bus No", required=True),
        TargetField("bcs", "BCS Topping"),
        TargetField("tcs", "TCS Topping"),
        TargetField("employee", "Topped up by"),
        TargetField("supervisor", "Supervisor (floor)"),
    ],
    Register.driver_complaint: [
        TargetField("date", "Date", required=True),
        TargetField("bus", "Bus No", required=True),
        TargetField("defectType", "Type of Defect"),
        TargetField("complaint", "Driver Complaint Reported", required=True),
        TargetField("action", "Rectification Action Taken"),
        TargetField("mechanic", "Name of the Mechanic"),
        TargetField("supervisor", "Supervisor (floor)"),
    ],
    Register.breakdown: [
        TargetField("date", "Date", required=True),
        TargetField("bus", "Bus No", required=True),
        TargetField("defectType", "Type of Defect"),
        TargetField("driver", "Driver ID"),
        TargetField("route", "Route"),
        TargetField("loc", "Location of Breakdown"),
        TargetField("complaint", "Complaint Reported by the Driver", required=True),
        TargetField("t_bd", "B/Down Time"),
        TargetField("t_mech", "Mechanic Reported Time"),
        TargetField("t_att", "Bus Attended Time"),
        TargetField("loss", "Loss KM"),
        TargetField("attended", "Bus Attended Details"),
        TargetField("remarks", "Remarks"),
        TargetField("supervisor", "Supervisor (floor)"),
    ],
    Register.pm_schedule: [
        TargetField("date", "Date", required=True),
        TargetField("bus", "Bus No", required=True),
        TargetField("defectType", "Type of Defect"),
        TargetField("defects", "Defects Noticed", required=True),
        TargetField("action", "Action Taken"),
        TargetField("balance", "Reason for Balance Job (if any)"),
        TargetField("spares", "Spare Parts Used"),
        TargetField("employee", "Name of Employees"),
        TargetField("supervisor", "Supervisor (floor)"),
    ],
}

#: The snag report: one sheet that feeds every register.
#:
#: A site writes one row per job — a breakdown, a daily inspection, a docking —
#: and the TYPE OF WORK column says which register it belongs in. The routing
#: itself is data (`work_types`), not a table in this file.
SNAG_FIELDS: list[TargetField] = [
    TargetField("date", "Date", required=True),
    TargetField("bus", "Vehicle No", required=True),
    TargetField("work_type", "Type of Work", required=True),
    TargetField("complaint", "Driver Complaint", required=True),
    TargetField("defectType", "Group"),
    TargetField("odometer_km", "Kms"),
    TargetField("action", "Action Taken"),
    TargetField("spares", "Part Used"),
    TargetField("employee", "Attend By"),
    TargetField("driver", "Driver No"),
    TargetField("route", "Route"),
    TargetField("loc", "Location"),
    TargetField("t_bd", "Reporting Time"),
    TargetField("t_mech", "Mech. Attend Time"),
    TargetField("t_att", "Complaint Resolving Time"),
    TargetField("loss", "Loss Kms"),
    TargetField("supervisor", "Supervisor (floor)"),
    TargetField("status", "Complaint Status"),
    TargetField("remarks", "Remarks"),
]

#: Required on a row that becomes a register entry, and meaningless on one that
#: TYPE OF WORK routes to an inspection — a checklist sweep has no driver
#: complaint. MBMT's sheet happens to fill the column on those rows anyway
#: ("DAILY INSPECTION"), which is the only reason this never bit.
SNAG_REGISTER_ONLY_REQUIRED = frozenset({"complaint"})

#: Snag key -> the register field key it becomes, per register. Anything absent
#: from a register's map is simply not carried onto that register.
SNAG_TO_REGISTER: dict[Register, dict[str, str]] = {
    Register.breakdown: {
        "bus": "bus",
        "supervisor": "supervisor",
        "defectType": "defectType",
        "complaint": "complaint",
        "driver": "driver",
        "route": "route",
        "loc": "loc",
        "t_bd": "t_bd",
        "t_mech": "t_mech",
        "t_att": "t_att",
        "loss": "loss",
        "action": "attended",
        "remarks": "remarks",
    },
    Register.driver_complaint: {
        "bus": "bus",
        "supervisor": "supervisor",
        "defectType": "defectType",
        "complaint": "complaint",
        "action": "action",
        "employee": "mechanic",
    },
    Register.work_done: {
        "bus": "bus",
        "supervisor": "supervisor",
        "defectType": "defectType",
        "complaint": "defects",
        "action": "attended",
        "spares": "spares",
        "employee": "employee",
    },
    Register.pm_schedule: {
        "bus": "bus",
        "supervisor": "supervisor",
        "defectType": "defectType",
        "complaint": "defects",
        "action": "action",
        "spares": "spares",
        "employee": "employee",
    },
    Register.coolant: {"bus": "bus",
        "supervisor": "supervisor", "employee": "employee"},
}

_MASTER_FIELDS: dict[ImportTarget, list[TargetField]] = {
    ImportTarget.vehicles: [
        TargetField("registration_no", "Registration No", required=True),
        TargetField("make", "Make"),
        TargetField("model", "Model"),
        TargetField("battery_capacity_kwh", "Battery capacity"),
        TargetField("is_active", "Active"),
    ],
    ImportTarget.defect_sources: [
        TargetField("name", "Name", required=True),
        TargetField("sort_order", "Sort order"),
        TargetField("is_active", "Active"),
    ],
    ImportTarget.service_schedule: [
        TargetField("code", "Service code", required=True),
        TargetField("name", "Service name", required=True),
        TargetField("interval_km", "Interval (km)"),
        TargetField("interval_days", "Interval (days)"),
        TargetField("notes", "Notes"),
        TargetField("is_active", "Active"),
    ],
    ImportTarget.odometers: [
        TargetField("registration_no", "Registration No", required=True),
        TargetField("odometer_km", "Odometer", required=True),
        TargetField("recorded_at", "Reading taken on"),
    ],
}
_MASTER_FIELDS[ImportTarget.defect_types] = _MASTER_FIELDS[ImportTarget.defect_sources]


def fields_for(target: ImportTarget) -> list[TargetField]:
    if target is ImportTarget.snag_report:
        return SNAG_FIELDS
    register = target.register
    if register is not None:
        # Historical rows carry their own author; without it the import is
        # attributed to whoever ran it.
        return [
            *_REGISTER_FIELDS[register],
            TargetField("entered_by", "Entered by"),
        ]
    return _MASTER_FIELDS[target]

from app.models.audit import AuditLog
from app.models.base import Base
from app.models.checklist import (
    ChecklistItem,
    ChecklistTemplate,
    InspectionEntry,
    InspectionResult,
)
from app.models.entry import (
    REGISTER_MODELS,
    BreakdownEntry,
    CoolantEntry,
    DriverComplaintEntry,
    Entry,
    PMScheduleEntry,
    WorkDoneEntry,
)
from app.models.inspection import Alert, InspectionPlan, InspectionSlot
from app.models.job_card import JobCard, JobCardComponent
from app.models.master import (
    DefectSource,
    DefectType,
    OdometerReading,
    Site,
    Vehicle,
    WorkType,
)
from app.models.notification import Notification
from app.models.report import (
    BreakdownInvestigation,
    DmrDay,
    FittedUnit,
    OffRoadCase,
    UnitType,
)
from app.models.site_config import ServicePlan, ShiftWindow, SiteConfig
from app.models.site_import import (
    SiteImportMapping,
    SiteImportProfile,
    SiteImportRun,
)
from app.models.sync import SyncCursor
from app.models.user import DeviceToken, RefreshToken, User, UserSiteAccess

__all__ = [
    "REGISTER_MODELS",
    "Alert",
    "AuditLog",
    "ChecklistItem",
    "ChecklistTemplate",
    "Base",
    "BreakdownEntry",
    "BreakdownInvestigation",
    "CoolantEntry",
    "DefectSource",
    "DefectType",
    "DeviceToken",
    "DmrDay",
    "DriverComplaintEntry",
    "Entry",
    "FittedUnit",
    "InspectionEntry",
    "InspectionPlan",
    "InspectionResult",
    "InspectionSlot",
    "JobCard",
    "JobCardComponent",
    "Notification",
    "OffRoadCase",
    "OdometerReading",
    "PMScheduleEntry",
    "RefreshToken",
    "ServicePlan",
    "ShiftWindow",
    "Site",
    "SiteConfig",
    "SiteImportMapping",
    "SiteImportProfile",
    "SiteImportRun",
    "SyncCursor",
    "User",
    "UnitType",
    "UserSiteAccess",
    "Vehicle",
    "WorkType",
    "WorkDoneEntry",
]

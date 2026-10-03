"""`kci_platform`: the platform seam of the kci deploy side.

The catalog (`kci_resource_proto`) says WHAT an author can deploy and the
engine (`kci_iac`) knows how to reconcile a graph of nodes; this package is
the seam between them, and it names no platform:

  * catalog.mojo     — the catalog's types as data (arm number, portability,
                       exposed outputs, accepted access).
  * platform_id.mojo — the opaque `PlatformId` (equality and printing only).
  * adapter.mojo     — the `AdapterSet` trait a platform implements, typed
                       absences (ABSENT_BY_DESIGN / NOT_YET) and `Finding`.
  * registry.mojo    — the linked platforms, and the rule that every
                       platform declares every catalog type.
  * validate.mojo    — the validate phase: graph, coverage and limit
                       findings, collected in one pass; the refusal text.
  * deploy.mojo      — plan / apply / destroy: validate first, lower with
                       the lowering contract checked, then the engine; and
                       the plan grouped by authored resource.
  * conformance.mojo — the conformance kit every platform runs.

The in-memory reference platforms that exercise all of it live in
`kci_platform_mem`.
"""

from kci_platform.platform_id import PlatformId
from kci_platform.catalog import (
    Catalog,
    CatalogType,
    PORTABLE,
    PLATFORM_BOUND,
    FIELD_SERVICE,
    FIELD_JOB,
    OUTPUT_URL,
    OUTPUT_HOST,
    ACCESS_CALL,
    body_field,
    portability_word,
)
from kci_platform.adapter import (
    AdapterSet,
    Absence,
    Finding,
    ABSENT_BY_DESIGN,
    NOT_YET,
    FINDING_GRAPH,
    FINDING_COVERAGE,
    FINDING_LIMIT,
    absence_word,
)
from kci_platform.registry import (
    Registry,
    PlatformEntry,
    describe,
    declaration_problems,
)
from kci_platform.validate import graph_findings, validate_for, refusal_text
from kci_platform.deploy import (
    refuse_unless_valid,
    lower_resources,
    plan_resources,
    apply_resources,
    destroy_resources,
    group_plan,
)
from kci_platform.conformance import ConformanceTarget, run_conformance

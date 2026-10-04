"""`kci_cloud`: the clouds of the kci deploy side.

The catalog (`kci_resource_proto`) says WHAT an author can deploy and the
engine (`kci_reconciler`) knows how to reconcile a graph of nodes; this
package sits between them. A CLOUD is the deploy target of a cell (`gcp`,
`aws`, `fake`): the id of a cloud adapter built into kci. It is not a
platform; a platform is an OS and a CPU (`Image.platform`). Every cloud is
built into kci, so the list of clouds is closed and nothing here is a plugin
interface. This package names no cloud:

  * catalog.mojo     — the catalog's types as data (arm number, portability,
                       exposed outputs, accepted access).
  * cloud_id.mojo    — the opaque `CloudId` (equality and printing only).
  * adapter.mojo     — the `CloudAdapter` trait every built-in cloud
                       implements (an internal module boundary, not frozen):
                       coverage, `configure` with the cell's settings, the
                       public mechanism, limits, the artifact a resource
                       needs, lowering to DATA (`LoweredNode`) and `realize`,
                       bootstrap resources, the label rule, `list_owned`,
                       `whoami`, `trust_render` / `trust_check`; typed
                       absences (ABSENT_BY_DESIGN / NOT_YET) and `Finding`.
  * labels.mojo      — the standard label rule (encode, decode, check).
  * clouds.mojo      — `Clouds`, the closed list of built-in clouds:
                       `resolve` (with a typo suggestion), and the rule that
                       every cloud declares every catalog type.
  * validate.mojo    — the validate phase: graph, coverage and limit
                       findings, collected in one pass; the refusal text.
  * deploy.mojo      — plan / apply / destroy in a cell: configure and
                       validate first, lower to data with the lowering
                       contract checked (`lowering_json` for golden tests),
                       add the roles `list_owned` says the file turned off,
                       realize, then the engine's owned scope; an apply
                       returns an `ApplyOutcome` (applied, landed, pending,
                       error, leftover); and the plan grouped by authored
                       resource.
  * conformance.mojo — the conformance kit every cloud runs (eleven steps,
                       from label stamping to two interleaved applies).

The fake clouds (working in-memory clouds, not mocks) that exercise all of it live in
`kci_cloud_fake`.
"""

from kci_cloud.cloud_id import CloudId
from kci_cloud.catalog import (
    Catalog,
    CatalogType,
    PORTABLE,
    CLOUD_BOUND,
    FIELD_SERVICE,
    FIELD_JOB,
    OUTPUT_URL,
    OUTPUT_HOST,
    ACCESS_CALL,
    body_field,
    portability_word,
)
from kci_cloud.adapter import (
    CloudAdapter,
    Absence,
    Finding,
    Setting,
    ResolvedArtifact,
    CellContext,
    ArtifactNeed,
    BootstrapItem,
    OwnedRecord,
    Principal,
    LoweredNode,
    RUN_UNKNOWN,
    ABSENT_BY_DESIGN,
    NOT_YET,
    FINDING_GRAPH,
    FINDING_COVERAGE,
    FINDING_LIMIT,
    FINDING_CELL,
    absence_word,
)
from kci_cloud.labels import (
    LABEL_VALUE_MAX,
    encode_label_value,
    decode_label_value,
    standard_label_rule,
    standard_identity_of,
    label_problems,
)
from kci_cloud.clouds import (
    Clouds,
    CloudEntry,
    describe,
    declaration_problems,
)
from kci_cloud.validate import (
    graph_findings,
    validate_for,
    refusal_text,
    id_problem,
    image_platform,
    ID_MAX_BYTES,
    V1_IMAGE_PLATFORM,
)
from kci_cloud.deploy import (
    ApplyOutcome,
    Removals,
    refuse_unless_valid,
    lower_data,
    lowering_json,
    realize_graph,
    removals,
    lower_resources,
    plan_resources,
    apply_resources,
    destroy_resources,
    group_plan,
)
from kci_cloud.conformance import ConformanceTarget, run_conformance

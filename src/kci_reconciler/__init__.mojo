"""`kci_reconciler` — the provider-neutral RESOURCE-GRAPH deploy engine core.

  (open-core; no cloud, provider or deployment coupling).

The engine that reconciles a GRAPH of desired resources against LIVE actual
state, provider-neutrally. A deploy is a `ResourceGraph` of `Resource` nodes
(each a concrete provider conformer, type-erased into `ErasedResource`); the
engine topo-sorts the graph and drives the reconcile verbs (plan / apply /
rollback / destroy) over a `StateStore` (the write-ahead intent ledger) and a
per-call `Creds` (the caller supplies credentials; the engine never mints them).

WHAT LIVES HERE (the four concerns):
  * resource.mojo        — the neutral `Resource` trait + the value PODs
                           (ResourceStatus / ChangeAction / Creds) + the RES_* /
                           RETAIN_* / CONVERGE_* / VERB_* codes.
  * erased_resource.mojo — `ErasedResource` (the runtime-erased `Resource`
                           facade + `erase[R]`) so the graph holds N distinct
                           conformer types uniformly.
  * graph.mojo           — `ResourceGraph` (the DAG of erased nodes) + `topo_sort`
                           (Kahn) + `reverse_order`.
  * state.mojo           — the `StateStore` trait (write-ahead intent) +
                           `IntentTicket` + the `InMemoryStateStore` OSS default /
                           test double.
  * outputs.mojo         — apply-time value flow: `Outputs` (what a node
                           produced), `InputRef` (what a node reads from
                           another; also a graph edge), `ResolvedInputs`, and
                           the UNBOUND refusal.
  * fault_domain.mojo    — WHOSE FAULT a failure is (FAULT_* + the raise-site
                           token + `FaultAttribution`), with the unclassified
                           case reading as OURS.
  * deploy_fault.mojo    — the PERMANENT and IN-FLIGHT marks a raiser stamps
                           on a fault (stop retrying at once only on a proven-
                           permanent fault; reset the fault streak only for an
                           accepted, bounded wait), prefix-checked so a message
                           that quotes a marked fault inherits nothing.
  * ownership.mojo       — the cell scope: `ResourceKey (machine, cell,
                           resource)` (the store key), `OwnerStamp` (the
                           identity an object carries, born with it),
                           `Provenance` (annotations, never compared),
                           `CellScope`, and the ownership rule (foreign and
                           conflict refuse before any change).
  * cell_walk.mojo       — the owned pre-flight, the closed-world removal
                           rule and the confirmed-gone delete, shared by the
                           verbs.
  * digest.mojo          — `ModelledDigest`: every modelled field, never
                           provenance.
  * unpinned_plan.mojo   — what a plan renders for a service's or job's image
                           whose build step has not run yet
                           (`UNPINNED-NOT-A-DIGEST:<step>/<name>`), refused
                           unless the caller passes an `UnpinnedImages`
                           record, which lists each one by node and step
                           output.
  * engine.mojo          — the verbs (`plan_graph` / `apply_graph` /
                           `apply_graph_tracked` / `rollback_create` /
                           `destroy_graph`, and the owned forms
                           `plan_graph_owned` / `apply_graph_owned` /
                           `destroy_graph_owned`) + `AppliedNode`.

A per-provider conformer (a GCP CloudRunService, an AWS Lambda, an on-prem unit)
is a SEPARATE package that imports `kci_reconciler` and implements `Resource`; the
engine core here names NO provider. Mojo 1.0.0b2 (def-only).
"""

from kci_reconciler.resource import (
    Resource,
    ResourceStatus,
    ChangeAction,
    Creds,
    RES_ABSENT,
    RES_PRESENT_MATCHED,
    RES_PRESENT_DRIFTED,
    RES_CONVERGING,
    RES_FAILED,
    RETAIN_DELETE,
    RETAIN_KEEP,
    RETAIN_UNDELETABLE,
    CONVERGE_NOOP,
    CONVERGE_IN_PLACE,
    CONVERGE_REPLACE,
    VERB_NOOP,
    VERB_CREATE,
    VERB_UPDATE,
    VERB_REPLACE,
    VERB_DELETE,
    VERB_KNOWN_AFTER_APPLY,
)
from kci_reconciler.outputs import (
    InputRef,
    Outputs,
    ResolvedInputs,
    UNBOUND_TOKEN,
    unbound_error,
)
from kci_reconciler.fault_domain import (
    FAULT_UNSET,
    FAULT_OURS,
    FAULT_CUSTOMER,
    FAULT_PROVIDER,
    FaultAttribution,
    is_our_responsibility,
    fault_domain_is_classified,
    fault_domain_word,
    fault_domain_of_word,
    fault_error,
    fault_tag,
    fault_domain_of_error,
    fault_message_of_error,
)
from kci_reconciler.deploy_fault import (
    PERMANENT_FAULT_PREFIX,
    IN_FLIGHT_FAULT_MARKER,
    IN_FLIGHT_FAULT_PREFIX,
    fault_is_permanent,
    mark_permanent_fault,
    fault_is_in_flight,
    mark_in_flight_fault,
    fault_is_retryable,
    deploy_fault_message,
    carry_deploy_fault_mark,
)
from kci_reconciler.erased_resource import ErasedResource
from kci_reconciler.graph import (
    ResourceGraph,
    topo_sort,
    dag_topo_order,
    reverse_order,
)
from kci_reconciler.state import (
    StateStore,
    IntentTicket,
    InMemoryStateStore,
    INTENT_PROVISIONING,
    INTENT_CONFIRMED,
    INTENT_REAPED,
)
from kci_reconciler.ownership import (
    Label,
    ResourceKey,
    Provenance,
    OwnerStamp,
    CellScope,
    KCI_SCHEME,
    LABEL_MANAGED_BY,
    LABEL_MACHINE,
    LABEL_CELL,
    LABEL_RESOURCE,
    LABEL_ROLE,
    LABEL_SCHEME,
    MANAGED_BY_KCI,
    REFUSED_TOKEN,
    ownership_problem,
)
from kci_reconciler.digest import (
    ModelledDigest,
    is_provenance,
    PROVENANCE_PREFIX,
    PROVENANCE_RUN_ID,
    PROVENANCE_REVISION,
)
from kci_reconciler.engine import (
    AppliedNode,
    UndeletableSkip,
    undeletable_report_lines,
    plan_graph,
    plan_graph_owned,
    apply_graph,
    apply_graph_tracked,
    apply_graph_owned,
    rollback_create,
    destroy_graph,
    destroy_graph_owned,
)
from kci_reconciler.unpinned_plan import (
    UNPINNED_PLAN_DIGEST_PREFIX,
    UNPINNED_KIND_SERVICE,
    UNPINNED_KIND_JOB,
    UnpinnedImage,
    UnpinnedImages,
    is_unpinned_plan_digest,
    unpinned_build_ref,
    unpinned_image_digest,
)

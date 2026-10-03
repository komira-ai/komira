"""`kci_iac` — the provider-neutral RESOURCE-GRAPH deploy engine core.

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
  * engine.mojo          — the verbs (`plan_graph` / `apply_graph` /
                           `apply_graph_tracked` / `rollback_create` /
                           `destroy_graph`) + `AppliedNode`.

A per-provider conformer (a GCP CloudRunService, an AWS Lambda, an on-prem unit)
is a SEPARATE package that imports `kci_iac` and implements `Resource`; the
engine core here names NO provider. Mojo 1.0.0b2 (def-only).
"""

from kci_iac.resource import (
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
from kci_iac.outputs import (
    InputRef,
    Outputs,
    ResolvedInputs,
    UNBOUND_TOKEN,
    unbound_error,
)
from kci_iac.fault_domain import (
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
from kci_iac.erased_resource import ErasedResource
from kci_iac.graph import (
    ResourceGraph,
    topo_sort,
    dag_topo_order,
    reverse_order,
)
from kci_iac.state import (
    StateStore,
    IntentTicket,
    InMemoryStateStore,
    INTENT_PROVISIONING,
    INTENT_CONFIRMED,
    INTENT_REAPED,
)
from kci_iac.engine import (
    AppliedNode,
    UndeletableSkip,
    undeletable_report_lines,
    plan_graph,
    apply_graph,
    apply_graph_tracked,
    rollback_create,
    destroy_graph,
)

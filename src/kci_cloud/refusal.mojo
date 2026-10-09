# =============================================================================
# kci_cloud/refusal.mojo: a refused run, as a value.
# =============================================================================
#
# A plan or an apply that kci refuses changes nothing, and its caller must
# say REFUSED (exit 3), not FAILED: a read that failed is another outcome
# with other advice. Reading the message to tell them apart is not a
# classification, so a refusal is a `Refusal` value carrying its findings,
# handed to the caller beside the raise or the outcome (deploy.mojo:
# `plan_report` and `apply_resources` with a `refusal` argument, and
# `ApplyOutcome.refusal`).
#
# TWO SOURCES.
#   * kci_cloud's own (`graph_refusal`, `by_engine` False): a validate,
#     expansion or cell finding, a changed cloud name or table key, and every
#     adoption finding (FINDING_ADOPTION). Built where the findings are,
#     before any effect; `text` is validate.refusal_text of the findings,
#     the text the verb raises.
#   * The engine's (`engine_refusal`, `by_engine` True): its owned
#     pre-flight refused a foreign or conflicting object, or a node that
#     cannot stamp, before any change. The engine (kci_reconciler) raises
#     its refusal as text; this is the ONE place kci_cloud reads that text.
#     The read is structural, not a prefix: the text is split into its
#     problem lines and rendered again by the engine's own renderer
#     (`kci_reconciler.ownership.refusal_text`) for this scope and verb;
#     only a byte-equal text with at least one problem is a refusal. Any
#     other engine error (a presence read that raised, a cycle in the
#     realized graph, a create that timed out) is not.
#
# Value-typed: String / List only. No pointer.
# =============================================================================

from kci_reconciler import CellScope
from kci_reconciler.ownership import refusal_text as engine_refusal_text

from kci_cloud.adapter import FINDING_OWNERSHIP, Finding
from kci_cloud.cloud_id import CloudId
from kci_cloud.compose_refs import owner_of_node
from kci_cloud.validate import refusal_text


struct Refusal(Copyable, Movable, Deinitable):
    """Why a run was refused before any change: `findings` (never empty),
    whether the engine made it (`by_engine`) or kci_cloud did, and `text`,
    the message the verb raised or returned with it."""

    var by_engine: Bool
    var findings: List[Finding]
    var text: String

    def __init__(out self, by_engine: Bool, var findings: List[Finding], text: String):
        self.by_engine = by_engine
        self.findings = findings^
        self.text = text.copy()

    def __init__(out self, *, copy: Self):
        self.by_engine = copy.by_engine
        self.findings = copy.findings.copy()
        self.text = copy.text.copy()


def graph_refusal(cloud: CloudId, findings: List[Finding]) -> Refusal:
    """kci_cloud's refusal of `findings` on `cloud`, with the one refusal
    text (validate.refusal_text)."""
    return Refusal(False, findings.copy(), refusal_text(cloud, findings))


def engine_refusal(scope: CellScope, verb: String, error: String) -> Optional[Refusal]:
    """The engine's ownership refusal that `error` is, for `verb` ("plan",
    "apply") in `scope`, or None when `error` is any other engine error
    (the header). Each problem line `<node>: <why>` is one FINDING_OWNERSHIP
    finding: the node's owner, the node, the reason."""
    var problems = List[String]()
    var sep = String("\n  ")
    var at = error.find(sep)
    if at < 0:
        return None
    var start = at + sep.byte_length()
    while True:
        var next = error.find(sep, start)
        if next < 0:
            problems.append(String(error[byte=start : error.byte_length()]))
            break
        problems.append(String(error[byte=start:next]))
        start = next + sep.byte_length()
    if engine_refusal_text(scope, verb, problems) != error:
        return None
    var findings = List[Finding]()
    for i in range(len(problems)):
        ref line = problems[i]
        var colon = line.find(": ")
        if colon <= 0:
            return None
        var node = String(line[byte=0:colon])
        var why = String(line[byte = colon + 2 : line.byte_length()])
        findings.append(Finding(FINDING_OWNERSHIP, owner_of_node(node), node, why))
    return Refusal(True, findings^, error)

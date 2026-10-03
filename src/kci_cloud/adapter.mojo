# =============================================================================
# kci_cloud/adapter.mojo: what a cloud adapter built into kci provides.
# =============================================================================
#
# A CLOUD ADAPTER is everything kci knows about one cloud: which catalog
# types it hosts, why it does not host the others, what values it refuses,
# and how it turns one authored resource into engine nodes. Every adapter is
# built into kci; `main` is the one place that lists them. This trait is an
# INTERNAL module boundary that keeps kci testable against the in-memory
# clouds. It is not a plugin interface and not frozen: it changes in an
# ordinary pull request, together with every adapter.
#
# WHY ONE TRAIT PER CLOUD AND NOT AN ERASED LIST OF PER-TYPE ADAPTERS. The
# questions asked across clouds (which built-in cloud hosts a type, is a
# declaration legal) need only DATA, so `Clouds` holds a plain description
# of each adapter (`clouds.describe`). The one call that needs an adapter's
# code, lowering, is made on the adapter of the stage's cell, through a
# generic function. So no function-pointer table is needed here; the
# engine's `ErasedResource` remains the only erasure, one level down.
#
# THE CONTRACT, each held by a test in this package or by the conformance kit:
#   * `implemented` and `absences` together name every catalog type exactly
#     once (`clouds.declaration_problems`): a new type forces a decision on
#     every cloud.
#   * ABSENT_BY_DESIGN is legal only for a CLOUD_BOUND type, NOT_YET only
#     for a PORTABLE one, and an adapter that calls itself complete has no
#     NOT_YET.
#   * `check` is pure and returns EVERY finding for one resource; it is only
#     asked about types the adapter implements.
#   * `lower` is pure (no network, no clock): resource in, nodes out, node ids
#     `<resource id>/<role>`, every node's `owner()` the resource id.
# =============================================================================

from kci_reconciler import ResourceGraph
from kci_resource_proto.resource import Resource

from kci_cloud.cloud_id import CloudId


comptime ABSENT_BY_DESIGN: Int = 1
"""This cloud will not host the type; legal only for CLOUD_BOUND."""
comptime NOT_YET: Int = 2
"""This cloud does not host the type yet; legal only for PORTABLE."""


def absence_word(kind: Int) -> String:
    if kind == ABSENT_BY_DESIGN:
        return String("ABSENT_BY_DESIGN")
    if kind == NOT_YET:
        return String("NOT_YET")
    return String("ABSENCE_UNSET")


struct Absence(Copyable, Movable, Deinitable):
    """A catalog type a cloud does not host, and why."""

    var field: Int
    var kind: Int
    var reason: String

    def __init__(out self, field: Int, kind: Int, reason: String):
        self.field = field
        self.kind = kind
        self.reason = reason

    def __init__(out self, *, copy: Self):
        self.field = copy.field
        self.kind = copy.kind
        self.reason = copy.reason.copy()


comptime FINDING_GRAPH: Int = 1
"""Wrong whatever the cloud: an id, a reference, an access verb."""
comptime FINDING_COVERAGE: Int = 2
"""The chosen cloud has no adapter for the resource's type."""
comptime FINDING_LIMIT: Int = 3
"""The cloud hosts the type but refuses one of its values or shapes."""


struct Finding(Copyable, Movable, Deinitable):
    """One reason a graph cannot be applied. `field_path` is where in the
    author's file (`service.request_timeout`); `citation` is where the limit
    is documented, and `unverified` says the citation was not checked
    against the cloud."""

    var kind: Int
    var resource_id: String
    var field_path: String
    var reason: String
    var citation: String
    var unverified: Bool

    def __init__(
        out self,
        kind: Int,
        resource_id: String,
        field_path: String,
        reason: String,
        citation: String = String(""),
        unverified: Bool = False,
    ):
        self.kind = kind
        self.resource_id = resource_id
        self.field_path = field_path
        self.reason = reason
        self.citation = citation
        self.unverified = unverified

    def __init__(out self, *, copy: Self):
        self.kind = copy.kind
        self.resource_id = copy.resource_id.copy()
        self.field_path = copy.field_path.copy()
        self.reason = copy.reason.copy()
        self.citation = copy.citation.copy()
        self.unverified = copy.unverified


trait CloudAdapter(Movable):
    """Everything kci knows about one cloud. See the file header."""

    def cloud_id(self) -> CloudId:
        """The opaque id of this cloud (a cell's `cloud`, `--cloud=<id>`)."""
        ...

    def complete(self) -> Bool:
        """True iff the adapter claims to host every PORTABLE type."""
        ...

    def implemented(self) -> List[Int]:
        """The `Resource.body` field numbers this adapter lowers."""
        ...

    def absences(self) -> List[Absence]:
        """Every catalog type this adapter does not lower, each with a reason."""
        ...

    def check(self, r: Resource) -> List[Finding]:
        """Every value or shape of `r` this cloud refuses. Pure."""
        ...

    def lower(mut self, r: Resource, mut graph: ResourceGraph) raises:
        """Add `r`'s engine nodes to `graph`. Pure: no network, no clock."""
        ...

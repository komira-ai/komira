# =============================================================================
# ScanResolver — the EXECUTION-TIME registry, tier 1. Lives in `komira_scan_source`.
# =============================================================================
#
# TWO TIERS, AND WHY. A core-resident trait CANNOT SPELL a type that lives
# above core (see `komira_plan_expr/fs_resolver.mojo`). `MorselSourceImpl`
# lives in `komira_morsel`, which depends on the core packages. So the
# execution-time surface splits:
#
#   TIER 1 (here, in core)  — identity and freshness. `epoch`, `is_bound`,
#                             `resolve_snapshot`. Names no source type.
#   TIER 2 (komira_morsel) — `ScanMorselResolver(ScanResolver)` adds
#                             `open_scan(...) -> MorselSource`, for a kind
#                             whose payload the engine pulls.
#   CONFORMER (a top package) — deps on core, morsel, and every package
#                             that owns a kind.
#
# `UnboundScanResolver` is the DEFAULTED comptime resolver: a call site that
# does not name a resolver behaves exactly as if nothing were bound. It is the
# direct analogue of `LocalOnlyResolver` (fs_resolver.mojo) — a zero-field
# POD that answers "nothing is bound", so a spine threading
# `[RES: ScanResolver = UnboundScanResolver]` by default takes no branch.
#
# =============================================================================
# THE OWNERSHIP RULE — the real cost of this design, named rather than buried.
# =============================================================================
#
# "An Arc in the IR is self-keeping; a handle can dangle."
# This IS a safety trade-off on one axis: `ArcPointer[Slab[RecordBatch]]` in
# the plan is a COMPILE-TIME guarantee that the batches outlive every clone of
# the plan; `handle: Int` is not. We trade a type-system guarantee for layering
# and serializability.
#
#   THE RULE: the registry outlives every execution that resolves against it,
#   and a handle is valid ONLY within the registry that minted it.
#
# Three mechanisms, in decreasing order of strength:
#
#   1. THE REGISTRY HOLDS THE ARC. For an in-memory kind the conformer owns the
#      `ArcPointer`. The batches are still refcount-kept — the keep-alive moved
#      OUT OF THE IR rather than being deleted. The dangling window narrows
#      from "any use-after-free" to the one auditable case "registry dropped
#      while a plan referencing it is replayed".
#   2. EPOCH CHECK (`check_binding` below). Every registry stamps a
#      process-unique monotonic epoch into the bindings it binds, and
#      resolution RAISES on mismatch. This converts a use-after-free into a
#      deterministic, named error — a tcmalloc crash becomes a test assertion.
#   3. OWNERSHIP PLACEMENT. The conformer is owned by `EngineContext`,
#      constructed before plan compile and dropped after the last execution
#      that can reference the plan.
#
# The type system cannot express "this handle borrows from that registry"
# across a serialization boundary — that is inherent to making the plan
# serializable at all. The epoch check is the price, and it is the honest one.
# =============================================================================

from std.memory import ArcPointer

from komira_arrow.record_batch import RecordBatch
from komira_collections.slab import Slab
from komira_scan_source.scan_binding import (
    ScanBinding,
    SCAN_EPOCH_NONE,
    SCAN_HANDLE_UNBOUND,
    SNAPSHOT_LIVE,
)


trait ScanResolver(Movable, Deinitable):
    """Execution-time resolution, tier 1 — only what core can spell."""

    def epoch(self) -> UInt64:
        """This registry's process-unique monotonic epoch. `SCAN_EPOCH_NONE`
        means "binds nothing", which is what `UnboundScanResolver` returns."""
        ...

    def is_bound(self, kind_id: UInt32, handle: Int) -> Bool:
        """True iff this resolver holds a payload at `handle` for `kind_id`."""
        ...

    def resolve_snapshot(self, binding: ScanBinding) raises -> UInt64:
        """Re-read the CURRENT snapshot token for `binding` at execution start.

        THE method that makes SNAPSHOT_LIVE safe. Its result goes into a
        PER-EXECUTION copy of the binding (`ScanBinding.with_snapshot_token`),
        never back into a cached plan.
        """
        ...


trait ScanPayloadResolver(ScanResolver):
    """TIER 1b — a `ScanResolver` that can also HAND BACK a CORE-TYPED payload.

    ⚠ WHY THIS IS A REFINEMENT AND NOT A METHOD ON `ScanResolver`. Tier 1's
    contract is "identity and freshness only", and that wording is load-bearing:
    it is what lets `UnboundScanResolver` be a zero-field POD that every
    call site that names no resolver can default to. Adding `payload_arc` to tier 1 would
    force every conformer to answer a question about bytes, including the one
    whose entire job is to hold none.

    ⚠ AND WHY IT IS NOT TIER 2 EITHER. Tier 2 puts the payload-handing surface
    in `komira_morsel` because `MorselSourceImpl` lives above core. That reason
    does NOT apply here: `ArcPointer[Slab[RecordBatch]]` is `std.memory` +
    the core packages + the core packages, every one a type core
    already spells — the same reasoning that puts `ScanRegistry` itself in
    core. A kind whose payload is a core type needs no package above core;
    this trait is that rule given a name. Tier 2 (`ScanMorselResolver`) is
    the right shape for a kind whose payload the engine PULLS.
    The single conformer is `ScanRegistry` — this trait lets a call site
    name "a thing I can resolve an in-memory payload against" without naming
    the concrete registry.
    """

    def payload_arc(
        self, handle: Int
    ) raises -> ArcPointer[Slab[RecordBatch]]:
        """The payload for `handle`, as a REFCOUNT BUMP — O(1) in resident
        bytes, never a batch copy.

        BY VALUE and not as a `ref` into the resolver, deliberately: a `ref`
        would borrow the resolver for as long as the caller holds the batches,
        which is precisely the coupling a handle exists to remove.

        Raises for a handle this resolver never minted or has evicted. A caller
        that wants a non-raising answer asks `is_bound` first; a caller that
        wants the NAMED epoch/eviction diagnosis calls `check_binding`.
        """
        ...


@fieldwise_init
struct UnboundScanResolver(ScanResolver, Movable, Deinitable):
    """The DEFAULTED comptime resolver — `[RES: ScanResolver = UnboundScanResolver]`.

    Binds nothing, resolves nothing, names no source type. A zero-field POD, so
    threading it costs nothing and monomorphizes to a constant-folded branch.

    The default answer is "no binding exists", so a call site that does not
    name a resolver takes no binding branch. Direct analogue of
    `LocalOnlyResolver` (fs_resolver.mojo).
    """

    def epoch(self) -> UInt64:
        return SCAN_EPOCH_NONE

    def is_bound(self, kind_id: UInt32, handle: Int) -> Bool:
        return False

    def resolve_snapshot(self, binding: ScanBinding) raises -> UInt64:
        """An unbound resolver cannot refresh anything, so it returns the token
        the binding already carries. For SNAPSHOT_NONE / SNAPSHOT_PINNED that
        is the correct and complete answer. For SNAPSHOT_LIVE it means "no
        refresh happened" — the caller that needs freshness must be running
        against a real registry, and `check_binding` below is what catches a
        binding that was minted by one."""
        return binding.snapshot_token


comptime SCAN_BINDING_EPOCH_MISMATCH: StaticString = (
    "SCAN_BINDING_EPOCH_MISMATCH"
)
"""NAMED ERROR — a handle minted by a registry that no longer exists.

THE named error of this design. `ArcPointer` in the IR is a COMPILE-TIME
keep-alive and `handle: Int` is not, so the price of layering +
serializability is that a dangling handle becomes a RUNTIME condition. This
token is what that condition is called.

It is a stable machine-greppable token deliberately, not prose: a test
asserting on prose is a test that a copy-edit can silently defeat. The prose
below it stays — a reader needs both.
"""

comptime SCAN_BINDING_HANDLE_NOT_BOUND: StaticString = (
    "SCAN_BINDING_HANDLE_NOT_BOUND"
)
"""NAMED ERROR — the epoch matches but the registry has no payload at the slot.

Distinct from `SCAN_BINDING_EPOCH_MISMATCH` and worth a distinct name: the
registry is the RIGHT one and is still alive, but this entry has been evicted
from it. Same-named errors for a dead registry and a live registry with an
evicted slot would make the two indistinguishable in a log, and they call for
different fixes (ownership placement vs. eviction policy).
"""

comptime SCAN_INMEM_LEAF_UNBOUND: StaticString = "SCAN_INMEM_LEAF_UNBOUND"
"""NAMED ERROR — a binding-resolving payload-read site was reached by a node that carries
no binding at all.

Distinct from the two above on the axis that matters: those two are about a
handle that will not resolve (a dead registry, an evicted slot). This one is
about there being NO HANDLE — the node was never bound, so no execution route
ran the entry-time bind pass for it.

⚠ THE DESIGN CHOICE THIS ENCODES IS "RAISE, NOT DECLINE". A binding-resolving reader
whose node is unbound has an obvious conservative arm available — decline, and
let the caller's fallback serve the shape. That arm is WRONG here: the
fallback returns BYTE-IDENTICAL rows off a slower route, so an execution path
nobody wired looks exactly like one that works, and no value assertion
anywhere can tell them apart. Raising by name makes every unwired route name
itself.
"""


def check_binding[RES: ScanResolver](
    resolver: RES, binding: ScanBinding
) raises:
    """MECHANISM 2 OF THE OWNERSHIP RULE — the epoch check.

    Raises rather than returning a Bool: a handle minted by a dead registry is
    not a condition a caller should be able to ignore. This is the whole
    difference between "a tcmalloc crash three frames later" and "a named test
    assertion at the point of the mistake".

    An UNBOUND binding is legal and is not an error.

    ⚠ THE PRODUCTION CALLER IS `komira_plan_ir/scan_binding_gate.mojo
    :check_plan_scan_bindings`, wired at every terminal execution route on
    `EngineContext`. Without it, a plan carrying a handle minted by a dead
    registry would execute as a SILENT NO-OP; this function must keep a
    production caller.
    """
    if binding.handle == SCAN_HANDLE_UNBOUND:
        return
    var ep = resolver.epoch()
    if binding.registry_epoch != ep:
        raise Error(
            String(SCAN_BINDING_EPOCH_MISMATCH)
            + String(": ScanBinding '")
            + binding.name
            + String("' carries a handle minted by registry epoch ")
            + String(binding.registry_epoch)
            + String(" but is being resolved against epoch ")
            + String(ep)
            + String(" — the registry that minted it is gone")
        )
    if not resolver.is_bound(binding.kind_id, binding.handle):
        raise Error(
            String(SCAN_BINDING_HANDLE_NOT_BOUND)
            + String(": ScanBinding '")
            + binding.name
            + String("' handle ")
            + String(binding.handle)
            + String(" is not bound in this registry")
        )


def resolve_for_execution[RES: ScanResolver](
    resolver: RES, binding: ScanBinding
) raises -> ScanBinding:
    """Produce the PER-EXECUTION binding: epoch-checked, and with a LIVE
    snapshot token freshly resolved.

    ⚠ RETURNS A COPY BY CONSTRUCTION. A SNAPSHOT_LIVE token may
    never be written back into the cached plan, so this cannot be a `mut self`
    refresh. The cached plan keeps `snapshot_token == 0` for every LIVE
    binding, which makes the invariant testable rather than aspirational.
    """
    check_binding(resolver, binding)
    if binding.snapshot_policy != SNAPSHOT_LIVE:
        return binding.copy()
    var token = resolver.resolve_snapshot(binding)
    return binding.with_snapshot_token(token)

# =============================================================================
# kci_reconciler/erased_resource.mojo — the RUNTIME-erased `Resource` facade of the
#   resource-graph deploy engine (so the graph holds a homogeneous
#   `Slab[ErasedResource]` of N distinct concrete conformer types).
# =============================================================================
#
# WHY A DEDICATED ERASURE. The general erasure family is
# `komira_async.runtime.shared_erasure`'s `ErasedHandle` / `make_erased[W]`.
# That family erases an `ErasableWork` whose ONLY arms are a no-arg `run(mut self)`
# and a no-arg `step(mut self) -> Int` — it carries NO per-call arguments and NO
# result type. `Resource` is a MULTI-VERB trait whose verbs take a per-call `Creds`
# and return value PODs (`ResourceStatus` / `ChangeAction` / `String`). ErasedHandle
# cannot carry that surface, so `ErasedResource` uses the SAME underlying MECHANISM
# `ErasedHandle` (and, in-tree, `ErasedAssumeRoleProvider` / `ErasedStorageApi`)
# use — an `OwnedPointer[UInt8]` type-erased home + FFI-POD thin fn-ptr vtable +
# single-consume drop trampoline — specialized to the `Resource` verb set. It is
# NOT a new erasure PRIMITIVE (it is the blessed manual-vtable shape) and NOT a
# variadic pack.
#
# THE PATTERN (mirrors `komira_gcp_bridge.erased_storage_api.ErasedStorageApi`
# EXACTLY). `ErasedResource` ITSELF conforms `Resource`, so a `Slab[ErasedResource]`
# holds N distinct concrete conformer types uniformly and the engine reconciles
# each BLIND. Construct via `ErasedResource.erase[R](resource^)` — the ONE site
# where the concrete `R` (and any transport it names, for a live conformer) is
# instantiated; the graph + engine monomorphize over `ErasedResource` ONLY.
#
# ── ENCAPSULATION (+ the FFI-POD fn-ptr carve-out) ──────────────────────────
# The PUBLIC surface is `erase[R](resource^)` plus the `Resource` verbs, which
# take/return only value PODs (`Creds`, `ResourceStatus`, `ChangeAction`,
# `String`, `List[String]`, `Int`) + owned `Self`. No pointer type appears in a
# public signature. The 22 fn-ptrs live in the PRIVATE struct `_ErasedVTable`
# (not re-exported), built only inside `erase[R]`; `ErasedResource`'s one
# constructor is keyword-only and underscore-named and takes the home and that
# private vtable, so no fn-ptr type (and with it no untracked-origin pointer
# type) reaches a public signature (tests/test_erased_resource_public_api.mojo
# holds this). The `_home: OwnedPointer[UInt8]` is a private field (CONCRETE
# origin, ASAP-tracked). The fn-ptrs are the FFI-POD carve-out — code pointers,
# no heap. The untracked origin (`MutUntrackedOrigin`) appears ONLY in the
# private fn-ptr comptime ALIASES, `_ErasedVTable`'s fields, the private helpers
# `_erased_home` / `_resource_at[R]` (the two reinterpret sites), the trampoline
# signatures and the `__deinit__` hand-off. Every cast carries a `# SAFETY:`
# comment. NO `unsafe_from_address`; NO wildcard origin.
#
# ── DESTROY/RECREATE SAFETY + the single-consume drop ────────────────────────
# `ErasedResource` is a graph NODE (built once at plan time, owned by the graph's
# Slab, dropped at graph teardown) — its only pointer field is the concrete-origin
# `OwnedPointer[UInt8]` home; no wildcard FIELD, no byte-slab cast at the storage
# boundary (the Slab element type is the CONCRETE `ErasedResource`, not a wildcard
# cast). `__del__` RELINQUISHES `_home`'s free (`unsafe_leak()`) and hands the bytes
# to the vtable's `drop_fn`, which rebuilds ONE `OwnedPointer[R]` for a SINGLE tracked
# destroy+free — so an `R` with a nested heap-owning field is never double-freed
# (the ErasedStorageApi / ErasedAssumeRoleProvider precedent; the two-step
# destroy-then-separate-free double-free hazard under Mojo 1.0.0b2). Do NOT
# "simplify" the drop to two steps. Mojo 1.0.0b2 (def-only).
# =============================================================================

from std.memory import OwnedPointer, UnsafePointer, alloc

from kci_reconciler.outputs import InputRef, Outputs, ResolvedInputs
from kci_reconciler.ownership import OwnerStamp
from kci_reconciler.resource import (
    Resource,
    ResourceStatus,
    ChangeAction,
    Creds,
)


# =============================================================================
# §1 — the FFI-POD thin fn-ptr TYPE aliases (the manual vtable). Each takes the
#      type-erased home byte ptr (MutUntrackedOrigin — the type-erasure handle)
#      + the value-POD verb args, and returns the value-POD result (`raises` — a
#      backend fault surfaces). The drop arm cannot raise.
# =============================================================================
# SAFETY: every alias below is private (underscore-named, not re-exported) and is
# used only by the private `_ErasedVTable`'s fields and the
# `_erased_*_for[R]` trampolines. The pointer each one takes is `_home`'s bytes,
# formed at a cast site in this file from a live `OwnedPointer[UInt8]` that owns
# a moved-in `R`, and each fn-ptr is bound by `erase[R]` for that same `R`, so
# the trampoline's reinterpret back to `R` is type-correct. The pointer is
# borrowed for the call only: no trampoline stores it, and only `_DropFn`
# consumes the home (once, from `__del__`).

# The read-only identity verbs (logical_id / retention take `self`; depends_on
# takes `self`). The home byte ptr is the type-erasure handle.
comptime _LogicalIdFn = def (
    UnsafePointer[UInt8, MutUntrackedOrigin],  # the erased R home
) raises thin -> String

comptime _DependsOnFn = def (
    UnsafePointer[UInt8, MutUntrackedOrigin],
) raises thin -> List[String]

comptime _RetentionFn = def (
    UnsafePointer[UInt8, MutUntrackedOrigin],
) raises thin -> Int

# WHY a RETAIN_UNDELETABLE node cannot be deleted, in the conformer's own words.
# Empty for every other node. Read by `destroy_graph` at the SKIP, so the reason
# reaches the report without the delete ever being issued.
comptime _UndeletableReasonFn = def (
    UnsafePointer[UInt8, MutUntrackedOrigin],
) raises thin -> String

# The live-read + pure-plan verbs.
comptime _ReadStatusFn = def (
    UnsafePointer[UInt8, MutUntrackedOrigin],
    Creds,  # the per-call opaque credential
) raises thin -> ResourceStatus

comptime _PlanFn = def (
    UnsafePointer[UInt8, MutUntrackedOrigin],
    ResourceStatus,  # the live status
) raises thin -> ChangeAction

comptime _ConvergeModeFn = def (
    UnsafePointer[UInt8, MutUntrackedOrigin],
    ResourceStatus,
) raises thin -> Int

# The mutating verbs.
comptime _CreateFn = def (
    UnsafePointer[UInt8, MutUntrackedOrigin],
    Creds,
) raises thin -> String

comptime _UpdateFn = def (
    UnsafePointer[UInt8, MutUntrackedOrigin],
    Creds,
) raises thin -> None

comptime _DeleteFn = def (
    UnsafePointer[UInt8, MutUntrackedOrigin],
    String,  # the physical id
    Creds,
) raises thin -> None

comptime _PruneFn = def (
    UnsafePointer[UInt8, MutUntrackedOrigin],
    Creds,
) raises thin -> None

# The ATTRIBUTION verb. A per-verb declaration, no error text — see
# `Resource.fault_domain`.
comptime _FaultDomainFn = def (
    UnsafePointer[UInt8, MutUntrackedOrigin],
    String,  # the Resource verb that raised
) raises thin -> Int

# The apply-time value-flow verbs (kci_reconciler/outputs.mojo). Each has a trait
# default, which is exactly why each needs its entry: without one the facade
# answers with the DEFAULT for every node of a real graph.
comptime _InputRefsFn = def (
    UnsafePointer[UInt8, MutUntrackedOrigin],
) raises thin -> List[InputRef]

comptime _BindInputsFn = def (
    UnsafePointer[UInt8, MutUntrackedOrigin],
    ResolvedInputs,
) raises thin -> None

comptime _OutputsFn = def (
    UnsafePointer[UInt8, MutUntrackedOrigin],
    String,  # the physical id
    Creds,
) raises thin -> Outputs

comptime _OwnerFn = def (
    UnsafePointer[UInt8, MutUntrackedOrigin],
) raises thin -> String

# The teardown read (`Resource.read_presence`). Defaulted to `read_status`, so
# a facade that did not forward it would read every node through the digest.
comptime _ReadPresenceFn = def (
    UnsafePointer[UInt8, MutUntrackedOrigin],
    Creds,
) raises thin -> ResourceStatus

# The ownership verbs (`Resource.stamps_ownership` / `create_owned` /
# `adopt_owned`) and the closed-world verb (`Resource.wanted`). Each has a
# trait default, so each needs its entry for the same reason as the value-flow
# verbs.
comptime _StampsOwnershipFn = def (
    UnsafePointer[UInt8, MutUntrackedOrigin],
) raises thin -> Bool
comptime _CreateOwnedFn = def (
    UnsafePointer[UInt8, MutUntrackedOrigin],
    OwnerStamp,
    Creds,
) raises thin -> String
comptime _AdoptOwnedFn = def (
    UnsafePointer[UInt8, MutUntrackedOrigin],
    OwnerStamp,
    String,  # the physical id of the existing object
    Creds,
) raises thin -> None
comptime _WantedFn = def (
    UnsafePointer[UInt8, MutUntrackedOrigin],
) raises thin -> Bool
comptime _DropFn = def (
    UnsafePointer[UInt8, MutUntrackedOrigin],  # the erased R home (consumed)
) thin -> None


# =============================================================================
# §2 — ErasedResource — the non-generic runtime-erased `Resource` facade.
# =============================================================================
# =============================================================================
# §2a — _ErasedVTable — the PRIVATE vtable: one fn-ptr per `Resource` verb plus
#       the drop arm. Built only inside `erase[R]`; not re-exported by the
#       package. Its field TYPES carry the untracked-origin pointer, so holding
#       them here keeps every pointer type out of `ErasedResource`'s public
#       signatures.
# =============================================================================
@fieldwise_init
struct _ErasedVTable(Movable):
    """The bound trampolines for ONE concrete `R`. Private: only `erase[R]`
    builds one, and only `ErasedResource` reads it."""

    # SAFETY: FFI-POD thin fn-ptr fields (code pointers, no heap), typed by the
    # private §1 aliases; §1 states why each call through them is sound. Every
    # field is bound by `erase[R]` for the same `R` as the home it is called with.
    var logical_id_fn: _LogicalIdFn
    var depends_on_fn: _DependsOnFn
    var retention_fn: _RetentionFn
    var undeletable_reason_fn: _UndeletableReasonFn
    var read_status_fn: _ReadStatusFn
    var plan_fn: _PlanFn
    var converge_mode_fn: _ConvergeModeFn
    var create_fn: _CreateFn
    var update_fn: _UpdateFn
    var delete_fn: _DeleteFn
    var prune_fn: _PruneFn
    var fault_domain_fn: _FaultDomainFn
    var input_refs_fn: _InputRefsFn
    var bind_inputs_fn: _BindInputsFn
    var outputs_fn: _OutputsFn
    var owner_fn: _OwnerFn
    var read_presence_fn: _ReadPresenceFn
    var stamps_ownership_fn: _StampsOwnershipFn
    var create_owned_fn: _CreateOwnedFn
    var adopt_owned_fn: _AdoptOwnedFn
    var wanted_fn: _WantedFn
    var drop_fn: _DropFn


struct ErasedResource(Resource, Movable, Deinitable):
    """A RUNTIME-erased `Resource`: owns ONE concrete `R: Resource` behind a
    type-erased heap home + a manual fn-ptr vtable, exposing the full neutral
    `Resource` surface. Construct via `ErasedResource.erase[R](resource^)`. The
    concrete `R` (and, for a live conformer, its transport) instantiates ONLY in
    the bound trampolines — the graph + engine monomorphize over `ErasedResource`.

    ITSELF conforms `Resource`, so a `Slab[ErasedResource]` holds N distinct
    concrete conformer types uniformly (the graph's node storage), and the engine
    topo-drives each node BLIND through this facade."""

    # `_home` owns the raw bytes of the concrete R (an `alloc[R](1) +
    # init_pointee_move(resource) + bitcast[UInt8]()` home). CONCRETE origin,
    # ASAP-tracked. The single private pointer field — no wildcard origin.
    var _home: OwnedPointer[UInt8]

    # The bound trampolines for this facade's `R`. A private struct, so no
    # fn-ptr type (and with it no untracked-origin pointer type) appears in
    # this struct's public surface.
    var _vtable: _ErasedVTable

    def __init__(
        out self, *, var _home: OwnedPointer[UInt8], var _vtable: _ErasedVTable
    ):
        """PRIVATE. Only `erase[R]` calls this. Keyword-only and underscore-named
        (this module's spelling of private): `_home` is type-erased bytes and
        `_vtable` is the private vtable bound for the same `R`. Construct an
        `ErasedResource` with `ErasedResource.erase[R](resource^)`."""
        self._home = _home^
        self._vtable = _vtable^

    # =========================================================================
    # erase[R] — heap-box a concrete Resource into the runtime facade.
    # =========================================================================
    @staticmethod
    def erase[R: Resource](var resource: R) -> ErasedResource:
        """Erase a concrete `R: Resource` into an `ErasedResource`. Heap-boxes
        `resource` into a `_home` and binds the TOP-LEVEL parametric trampolines
        (NOT nested closures — the same shape as `ErasedStorageApi` / `ErasedAssume
        RoleProvider`; nested closures over a comptime param do not lower as
        stable fn-ptrs). This is the ONE site where `R` is instantiated for the
        graph + engine.

        SAFETY: `alloc[R](1) + init_pointee_move(resource)` moves `resource` onto a
        fresh heap slot; `OwnedPointer(unsafe_from_raw_pointer=...)` takes single
        ownership of the byte-cast slot (concrete origin, ASAP-tracked). The
        trampolines are bound for the SAME `R`, so the in-body reinterpret of the
        home ptr is type-correct by construction. The untracked origin is confined
        to `_erased_home`, `_resource_at[R]` and the trampolines — never a public
        signature or field."""
        # SAFETY: a fresh one-element allocation for `R`; nothing else refers to
        # it, and the next statement initialises it before any read.
        var home_typed = alloc[R](1)
        # SAFETY: `home_typed` is uninitialised memory we own; this moves
        # `resource` into it, so the slot holds exactly one live `R`.
        UnsafePointer(to=home_typed[]).unsafe_write(resource^)
        # SAFETY: the `OwnedPointer[UInt8]` takes sole ownership of the slot
        # (concrete origin, ASAP-tracked); `home_typed` is not used again. The
        # bytes are viewed as `R` again only through `_resource_at[R]`, from a
        # vtable bound below for this same `R`.
        var home = OwnedPointer[UInt8](
            unsafe_from_raw_pointer=home_typed.bitcast[UInt8]()
        )
        var logical_id_t: _LogicalIdFn = _erased_logical_id_for[R]
        var depends_on_t: _DependsOnFn = _erased_depends_on_for[R]
        var retention_t: _RetentionFn = _erased_retention_for[R]
        var undeletable_reason_t: _UndeletableReasonFn = (
            _erased_undeletable_reason_for[R]
        )
        var read_status_t: _ReadStatusFn = _erased_read_status_for[R]
        var plan_t: _PlanFn = _erased_plan_for[R]
        var converge_mode_t: _ConvergeModeFn = _erased_converge_mode_for[R]
        var create_t: _CreateFn = _erased_create_for[R]
        var update_t: _UpdateFn = _erased_update_for[R]
        var delete_t: _DeleteFn = _erased_delete_for[R]
        var prune_t: _PruneFn = _erased_prune_for[R]
        var fault_domain_t: _FaultDomainFn = _erased_fault_domain_for[R]
        var input_refs_t: _InputRefsFn = _erased_input_refs_for[R]
        var bind_inputs_t: _BindInputsFn = _erased_bind_inputs_for[R]
        var outputs_t: _OutputsFn = _erased_outputs_for[R]
        var owner_t: _OwnerFn = _erased_owner_for[R]
        var read_presence_t: _ReadPresenceFn = _erased_read_presence_for[R]
        var stamps_ownership_t: _StampsOwnershipFn = (
            _erased_stamps_ownership_for[R]
        )
        var create_owned_t: _CreateOwnedFn = _erased_create_owned_for[R]
        var adopt_owned_t: _AdoptOwnedFn = _erased_adopt_owned_for[R]
        var wanted_t: _WantedFn = _erased_wanted_for[R]
        var drop_t: _DropFn = _erased_drop_for[R]
        return ErasedResource(
            _home=home^,
            _vtable=_ErasedVTable(
                logical_id_fn=logical_id_t,
                depends_on_fn=depends_on_t,
                retention_fn=retention_t,
                undeletable_reason_fn=undeletable_reason_t,
                read_status_fn=read_status_t,
                plan_fn=plan_t,
                converge_mode_fn=converge_mode_t,
                create_fn=create_t,
                update_fn=update_t,
                delete_fn=delete_t,
                prune_fn=prune_t,
                fault_domain_fn=fault_domain_t,
                input_refs_fn=input_refs_t,
                bind_inputs_fn=bind_inputs_t,
                outputs_fn=outputs_t,
                owner_fn=owner_t,
                read_presence_fn=read_presence_t,
                stamps_ownership_fn=stamps_ownership_t,
                create_owned_fn=create_owned_t,
                adopt_owned_fn=adopt_owned_t,
                wanted_fn=wanted_t,
                drop_fn=drop_t,
            ),
        )

    # =========================================================================
    # _erased_home — the ONE cast site that forms the type-erasure handle.
    # =========================================================================
    @always_inline
    def _erased_home(mut self) -> UnsafePointer[UInt8, MutUntrackedOrigin]:
        """PRIVATE. The home's bytes as the untracked-origin handle the §1
        trampolines take. Every forwarding verb below calls this and passes the
        result straight to its vtable entry."""
        # SAFETY: `_home` owns the moved-in `R` for this facade's whole lifetime,
        # and the caller holds `mut self` across the vtable call, so the bytes
        # outlive every use of the handle. The vtable entry was bound by
        # `erase[R]` for the same `R`. No caller stores the handle.
        return self._home.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin]()

    # =========================================================================
    # The neutral value-typed Resource surface (what the graph + engine call).
    # Each forms a MutUntrackedOrigin byte ptr to the home (the type-erasure
    # handle) and invokes the bound trampoline, which reinterprets it back to the
    # SAME R and drives the concrete verb IN-PLACE (not moved/freed). The
    # untracked origin is confined to `_erased_home` — never a public field.
    # =========================================================================
    def logical_id(mut self) -> String:
        """The graph-stable key. `mut self` — forming the mutable type-erasure
        handle to the home requires mutable access (the ErasedStorageApi shape,
        where every verb takes `mut self`). SAFETY: R is used in-place (read-only);
        the untracked origin is confined to `_erased_home`.

        `Resource.logical_id` is non-raising, but the erased trampoline is `raises`
        (def carries implicit raises), so a (contract-forbidden) raise surfaces an
        empty id rather than propagate. A well-formed conformer never raises."""
        try:
            var p = self._erased_home()
            return self._vtable.logical_id_fn(p)
        except e:
            return String("")

    def depends_on(mut self) -> List[String]:
        """The IN-edges. `mut self` (see `logical_id`). SAFETY: R read in-place."""
        try:
            var p = self._erased_home()
            return self._vtable.depends_on_fn(p)
        except e:
            return List[String]()

    def retention(mut self) -> Int:
        """The RETAIN_* policy. `mut self` (see `logical_id`). SAFETY: R read
        in-place."""
        try:
            var p = self._erased_home()
            return self._vtable.retention_fn(p)
        except e:
            return 0  # RETAIN_DELETE default (never reached for a valid conformer)

    def undeletable_reason(mut self) -> String:
        """WHY the erased R is RETAIN_UNDELETABLE — FORWARDED to the concrete R
        through `undeletable_reason_fn`.

        ⛔ THE VTABLE ENTRY IS LOAD-BEARING FOR EXACTLY `prune`'s AND
        `fault_domain`'s REASON. The graph holds `ErasedResource`, so every
        conformer reaches the engine through this facade; without the forward,
        this would resolve `Resource.undeletable_reason`'s trait DEFAULT and every
        conformer's reason in the tree would be silently replaced by the empty
        string — the teardown would still skip the right nodes and would report
        every one of them as "the conformer stated no reason". SAFETY: R read
        in-place; the untracked origin is confined to `_erased_home`.

        Non-raising for the same reason `logical_id` is: a contract-forbidden
        raise surfaces an empty reason rather than failing a teardown over prose.
        """
        try:
            var p = self._erased_home()
            return self._vtable.undeletable_reason_fn(p)
        except e:
            return String("")

    def read_status(mut self, creds: Creds) raises -> ResourceStatus:
        """Read the live status AS `creds`. SAFETY: `_home` owns R's heap home for
        this facade's lifetime; we form a MutUntrackedOrigin byte ptr (the
        type-erasure handle) and invoke `read_status_fn`, which reinterprets it to
        the SAME R bound at erase[R] time and drives it in-place. The untracked
        origin is confined to `_erased_home`."""
        var p = self._erased_home()
        return self._vtable.read_status_fn(p, creds)

    def plan(mut self, live: ResourceStatus) raises -> ChangeAction:
        """The pure diff. SAFETY: see `read_status`."""
        var p = self._erased_home()
        return self._vtable.plan_fn(p, live)

    def create(mut self, creds: Creds) raises -> String:
        """Create the resource AS `creds`. SAFETY: see `read_status`."""
        var p = self._erased_home()
        return self._vtable.create_fn(p, creds)

    def update(mut self, creds: Creds) raises:
        """Converge in place AS `creds`. SAFETY: see `read_status`."""
        var p = self._erased_home()
        self._vtable.update_fn(p, creds)

    def delete(mut self, physical_id: String, creds: Creds) raises:
        """Delete `physical_id` AS `creds` (idempotent). SAFETY: see `read_status`."""
        var p = self._erased_home()
        self._vtable.delete_fn(p, physical_id, creds)

    def converge_mode(mut self, live: ResourceStatus) raises -> Int:
        """The converge mode (IN_PLACE or raise for REPLACE). `mut self` (see
        `logical_id`). SAFETY: R is used in-place (read-only over the live status);
        the untracked origin is confined to `_erased_home`."""
        var p = self._erased_home()
        return self._vtable.converge_mode_fn(p, live)

    def prune(mut self, creds: Creds) raises:
        """Prune the erased R's older resource versions AS `creds` (the BEST-EFFORT
        retention verb; a non-versioned R no-ops via the trait default). This
        FORWARDS to the concrete R's `prune` through `prune_fn` — the trait default
        no-op would otherwise shadow the conformer's override at this facade, so the
        vtable entry is load-bearing. SAFETY: see `read_status` (R driven in-place;
        the untracked origin is confined to `_erased_home`)."""
        var p = self._erased_home()
        self._vtable.prune_fn(p, creds)

    def fault_domain(mut self, verb: String) raises -> Int:
        """WHOSE FAULT a failure of `verb` on the erased R is — FORWARDED to the
        concrete R through `fault_domain_fn`.

        ⛔ THE VTABLE ENTRY IS LOAD-BEARING, FOR THE SAME REASON `prune`'s IS, AND
        THE COST OF OMITTING IT IS WORSE. The graph holds `ErasedResource`, so
        EVERY conformer reaches the engine through this facade; without the
        forward, `ErasedResource` would resolve `Resource.fault_domain`'s trait
        DEFAULT and every conformer override in the tree would be silently
        discarded — an attribution scheme that compiles, passes, and
        classifies nothing.

        ⚠ It would fail SAFE (the default is `FAULT_UNSET`, i.e. OURS, so the
        errors would land in our queue rather than vanish) and that is precisely
        why it would go unnoticed: the symptom of the bug is the same as the
        symptom of not having started yet. SAFETY: see `read_status` (R driven
        in-place; the untracked origin is confined to `_erased_home`)."""
        var p = self._erased_home()
        return self._vtable.fault_domain_fn(p, verb)

    # ---- apply-time value flow: FORWARDED, never the trait default --------
    # Same reason as `prune` and `fault_domain`: the graph only holds erased
    # nodes, so a verb this facade does not forward is answered by the trait
    # default for every node. `test_resource_outputs` pins all four through an
    # erased probe. SAFETY: see `read_status` (R driven in-place; the untracked
    # origin is confined to `_erased_home`).

    def input_refs(mut self) -> List[InputRef]:
        """FORWARDED to the concrete R. `Resource.input_refs` does not raise;
        a (contract-forbidden) raise from the trampoline surfaces as NO refs,
        exactly as `depends_on` surfaces one."""
        try:
            var p = self._erased_home()
            return self._vtable.input_refs_fn(p)
        except e:
            return List[InputRef]()

    def bind_inputs(mut self, resolved: ResolvedInputs) raises:
        """FORWARDED to the concrete R."""
        var p = self._erased_home()
        self._vtable.bind_inputs_fn(p, resolved)

    def outputs(mut self, physical_id: String, creds: Creds) raises -> Outputs:
        """FORWARDED to the concrete R."""
        var p = self._erased_home()
        return self._vtable.outputs_fn(p, physical_id, creds)

    def owner(mut self) -> String:
        """FORWARDED to the concrete R; a (contract-forbidden) raise surfaces
        as no owner."""
        try:
            var p = self._erased_home()
            return self._vtable.owner_fn(p)
        except e:
            return String("")

    def read_presence(mut self, creds: Creds) raises -> ResourceStatus:
        """FORWARDED to the concrete R (the teardown read). Without the
        forward, the trait default would answer through `read_status` for
        every node, and a consumer left unbound at teardown would raise
        `UNBOUND` out of `destroy_graph`. SAFETY: see `read_status`."""
        var p = self._erased_home()
        return self._vtable.read_presence_fn(p, creds)

    def stamps_ownership(mut self) -> Bool:
        """FORWARDED to the concrete R. Without the forward every node would
        answer the trait default (False) and an owned apply would refuse every
        graph. Non-raising like `logical_id`: a contract-forbidden raise reads
        as False, which refuses (the safe direction). SAFETY: see
        `read_status`."""
        try:
            var p = self._erased_home()
            return self._vtable.stamps_ownership_fn(p)
        except e:
            return False

    def create_owned(mut self, stamp: OwnerStamp, creds: Creds) raises -> String:
        """FORWARDED to the concrete R (the create that carries the stamp).
        SAFETY: see `read_status`."""
        var p = self._erased_home()
        return self._vtable.create_owned_fn(p, stamp, creds)

    def adopt_owned(
        mut self, stamp: OwnerStamp, physical_id: String, creds: Creds
    ) raises:
        """FORWARDED to the concrete R (the explicit `adopt` takeover).
        SAFETY: see `read_status`."""
        var p = self._erased_home()
        self._vtable.adopt_owned_fn(p, stamp, physical_id, creds)

    def wanted(mut self) -> Bool:
        """FORWARDED to the concrete R. Without the forward every role the
        file turned off would read as wanted and never be removed.
        Non-raising: a contract-forbidden raise reads as True (wanted), so a
        broken conformer never causes a delete. SAFETY: see `read_status`."""
        try:
            var p = self._erased_home()
            return self._vtable.wanted_fn(p)
        except e:
            return True

    def __deinit__(deinit self):
        """Destroy the erased R AND free its home in ONE shot via `drop_fn`. We
        RELINQUISH `_home`'s own free first (`unsafe_leak()`) so the single owner of
        the bytes for teardown is the `OwnedPointer[R]` the drop trampoline
        reconstructs — which runs `R.__del__` (freeing its inner heap fields) +
        frees the allocation atomically (the ErasedStorageApi precedent — avoids
        the two-step double-free of an R with nested heap-owning fields under Mojo
        1.0.0b2).

        SAFETY: `_home` owns R's heap home; `unsafe_leak()` relinquishes its free so
        it does NOT also free the buffer; the bytes go to the vtable's `drop_fn`,
        which reconstructs one `OwnedPointer[R]` over the SAME allocation and runs
        the destroy+free in one shot. Runs exactly once per facade."""
        # SAFETY: `unsafe_leak()` relinquishes `_home`'s free, so the only owner
        # of the bytes from here on is the `OwnedPointer[R]` that `drop_fn`
        # rebuilds over them; that destroys `R` and frees the allocation once.
        # This runs once per facade, and the handle is not used after the call.
        var raw = self._home^.unsafe_take_allocation().unsafe_leak().unsafe_origin_cast[
            MutUntrackedOrigin
        ]()
        self._vtable.drop_fn(raw)


# =============================================================================
# §3 — the TOP-LEVEL parametric trampolines (bound ONCE per concrete R at
#      `erase[R]`). Each reinterprets the erased home byte ptr back to `R` and
#      drives the concrete verb IN-PLACE. NOT nested closures — top-level so they
#      lower as stable thin fn-ptrs (the ErasedStorageApi shape).
# =============================================================================
@always_inline
def _resource_at[
    R: Resource
](home: UnsafePointer[UInt8, MutUntrackedOrigin]) -> UnsafePointer[
    R, MutUntrackedOrigin
]:
    """PRIVATE. The erased home's bytes viewed as the concrete `R` again. Every
    trampoline below (and the drop arm) reinterprets through this one site."""
    # SAFETY: `home` is the byte view of an `alloc[R](1)` slot that `erase[R]`
    # move-initialised with an `R`, and every caller was bound by `erase[R]` for
    # that same `R`, so the reinterpret is type-correct and correctly aligned.
    return home.bitcast[R]()


def _erased_logical_id_for[
    R: Resource
](home: UnsafePointer[UInt8, MutUntrackedOrigin]) raises -> String:
    """`logical_id` trampoline for concrete `R`. SAFETY: `home` is the byte-cast of
    a live `OwnedPointer[R]` home (same R bound here at erase[R]); reinterpret to
    `R*` and call `logical_id` in-place (R is NOT moved/freed — the facade owns
    it)."""
    var rp = _resource_at[R](home)
    return rp[].logical_id()


def _erased_depends_on_for[
    R: Resource
](home: UnsafePointer[UInt8, MutUntrackedOrigin]) raises -> List[String]:
    """`depends_on` trampoline for concrete `R`. SAFETY: see `_erased_logical_id_for`."""
    var rp = _resource_at[R](home)
    return rp[].depends_on()


def _erased_retention_for[
    R: Resource
](home: UnsafePointer[UInt8, MutUntrackedOrigin]) raises -> Int:
    """`retention` trampoline for concrete `R`. SAFETY: see `_erased_logical_id_for`."""
    var rp = _resource_at[R](home)
    return rp[].retention()


def _erased_undeletable_reason_for[
    R: Resource
](home: UnsafePointer[UInt8, MutUntrackedOrigin]) raises -> String:
    """`undeletable_reason` trampoline for concrete `R` (a non-undeletable R
    resolves the trait default and returns empty). SAFETY: see
    `_erased_logical_id_for`."""
    var rp = _resource_at[R](home)
    return rp[].undeletable_reason()


def _erased_read_status_for[
    R: Resource
](
    home: UnsafePointer[UInt8, MutUntrackedOrigin],
    creds: Creds,
) raises -> ResourceStatus:
    """`read_status` trampoline for concrete `R`. SAFETY: see `_erased_logical_id_for`
    — R is driven in-place; the value-POD `creds` passes by value through the thin
    fn-ptr."""
    var rp = _resource_at[R](home)
    return rp[].read_status(creds)


def _erased_plan_for[
    R: Resource
](
    home: UnsafePointer[UInt8, MutUntrackedOrigin],
    live: ResourceStatus,
) raises -> ChangeAction:
    """`plan` trampoline for concrete `R`. SAFETY: see `_erased_read_status_for`."""
    var rp = _resource_at[R](home)
    return rp[].plan(live)


def _erased_converge_mode_for[
    R: Resource
](
    home: UnsafePointer[UInt8, MutUntrackedOrigin],
    live: ResourceStatus,
) raises -> Int:
    """`converge_mode` trampoline for concrete `R`. SAFETY: see
    `_erased_read_status_for`."""
    var rp = _resource_at[R](home)
    return rp[].converge_mode(live)


def _erased_create_for[
    R: Resource
](
    home: UnsafePointer[UInt8, MutUntrackedOrigin],
    creds: Creds,
) raises -> String:
    """`create` trampoline for concrete `R`. SAFETY: see `_erased_read_status_for`."""
    var rp = _resource_at[R](home)
    return rp[].create(creds)


def _erased_update_for[
    R: Resource
](
    home: UnsafePointer[UInt8, MutUntrackedOrigin],
    creds: Creds,
) raises:
    """`update` trampoline for concrete `R`. SAFETY: see `_erased_read_status_for`."""
    var rp = _resource_at[R](home)
    rp[].update(creds)


def _erased_delete_for[
    R: Resource
](
    home: UnsafePointer[UInt8, MutUntrackedOrigin],
    physical_id: String,
    creds: Creds,
) raises:
    """`delete` trampoline for concrete `R`. SAFETY: see `_erased_read_status_for`."""
    var rp = _resource_at[R](home)
    rp[].delete(physical_id, creds)


def _erased_prune_for[
    R: Resource
](
    home: UnsafePointer[UInt8, MutUntrackedOrigin],
    creds: Creds,
) raises:
    """`prune` trampoline for concrete `R`. SAFETY: see `_erased_read_status_for` —
    R is driven in-place (the retention prune); a non-versioned R resolves the trait
    default no-op."""
    var rp = _resource_at[R](home)
    rp[].prune(creds)


def _erased_fault_domain_for[
    R: Resource
](
    home: UnsafePointer[UInt8, MutUntrackedOrigin],
    verb: String,
) raises -> Int:
    """`fault_domain` trampoline for concrete `R`. SAFETY: see
    `_erased_read_status_for` — R is driven in-place (a read-only declaration); an
    unconsidered R resolves the trait default `FAULT_UNSET`, which reads as OURS."""
    var rp = _resource_at[R](home)
    return rp[].fault_domain(verb)


def _erased_input_refs_for[
    R: Resource
](home: UnsafePointer[UInt8, MutUntrackedOrigin]) raises -> List[InputRef]:
    """`input_refs` trampoline for concrete `R`. SAFETY: see
    `_erased_read_status_for` (R read in-place)."""
    var rp = _resource_at[R](home)
    return rp[].input_refs()


def _erased_bind_inputs_for[
    R: Resource
](
    home: UnsafePointer[UInt8, MutUntrackedOrigin],
    resolved: ResolvedInputs,
) raises:
    """`bind_inputs` trampoline for concrete `R`. SAFETY: see
    `_erased_read_status_for` (R mutated in-place, not moved or freed)."""
    var rp = _resource_at[R](home)
    rp[].bind_inputs(resolved)


def _erased_outputs_for[
    R: Resource
](
    home: UnsafePointer[UInt8, MutUntrackedOrigin],
    physical_id: String,
    creds: Creds,
) raises -> Outputs:
    """`outputs` trampoline for concrete `R`. SAFETY: see
    `_erased_read_status_for` (R read in-place)."""
    var rp = _resource_at[R](home)
    return rp[].outputs(physical_id, creds)


def _erased_owner_for[
    R: Resource
](home: UnsafePointer[UInt8, MutUntrackedOrigin]) raises -> String:
    """`owner` trampoline for concrete `R`. SAFETY: see
    `_erased_read_status_for` (R read in-place)."""
    var rp = _resource_at[R](home)
    return rp[].owner()


def _erased_read_presence_for[
    R: Resource
](
    home: UnsafePointer[UInt8, MutUntrackedOrigin],
    creds: Creds,
) raises -> ResourceStatus:
    """`read_presence` trampoline for concrete `R`. SAFETY: see
    `_erased_read_status_for` (R driven in-place)."""
    var rp = _resource_at[R](home)
    return rp[].read_presence(creds)


def _erased_stamps_ownership_for[
    R: Resource
](home: UnsafePointer[UInt8, MutUntrackedOrigin]) raises -> Bool:
    """`stamps_ownership` trampoline for concrete `R`. SAFETY: see
    `_erased_read_status_for` (R read in-place)."""
    var rp = _resource_at[R](home)
    return rp[].stamps_ownership()


def _erased_create_owned_for[
    R: Resource
](
    home: UnsafePointer[UInt8, MutUntrackedOrigin],
    stamp: OwnerStamp,
    creds: Creds,
) raises -> String:
    """`create_owned` trampoline for concrete `R`. SAFETY: see
    `_erased_read_status_for` (R driven in-place)."""
    var rp = _resource_at[R](home)
    return rp[].create_owned(stamp, creds)


def _erased_adopt_owned_for[
    R: Resource
](
    home: UnsafePointer[UInt8, MutUntrackedOrigin],
    stamp: OwnerStamp,
    physical_id: String,
    creds: Creds,
) raises:
    """`adopt_owned` trampoline for concrete `R`. SAFETY: see
    `_erased_read_status_for` (R driven in-place)."""
    var rp = _resource_at[R](home)
    rp[].adopt_owned(stamp, physical_id, creds)


def _erased_wanted_for[
    R: Resource
](home: UnsafePointer[UInt8, MutUntrackedOrigin]) raises -> Bool:
    """`wanted` trampoline for concrete `R`. SAFETY: see
    `_erased_read_status_for` (R read in-place)."""
    var rp = _resource_at[R](home)
    return rp[].wanted()


def _erased_drop_for[
    R: Resource
](home: UnsafePointer[UInt8, MutUntrackedOrigin]):
    """The drop trampoline for concrete `R`: reconstruct ONE `OwnedPointer[R]` over
    the home bytes and let it run `R.__del__` + free the allocation in a single
    tracked consume. SAFETY: `home` is the byte-cast of the R-home allocation whose
    free was relinquished by the facade's `__del__` (`unsafe_leak()`); we reconstruct
    the single owner over the SAME bytes (cast back to `R`, concrete origin) so the
    destroy+free happens exactly once — no double-free of R's inner heap fields."""
    # SAFETY: `home` is the start of the `alloc[R](1)` slot `erase[R]` filled,
    # and the facade's `__deinit__` relinquished its own free before this call,
    # so this `OwnedPointer[R]` is the single owner: it destroys `R` and frees
    # the slot exactly once.
    var owned = OwnedPointer[R](unsafe_from_raw_pointer=_resource_at[R](home))
    var r = owned^.into_inner()
    _ = r^

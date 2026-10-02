# =============================================================================
# ScanMorselResolver: the execution-time scan-kind registry (tier 2).
# =============================================================================
#
# THE TWO TIERS. `komira_core/source/scan_resolver.mojo` is tier 1: identity
# and freshness (`epoch`, `is_bound`, `resolve_snapshot`), the only questions
# core can spell. Tier 2 (here) adds what a KIND owns and core must never learn:
#
#   descriptor()          the optimizer's view of the kind (gate, orientation,
#                         snapshot policy, required params). Pure data.
#   build_binding(params) the kind's PLAN-side identity token: schema, identity
#                         fold and pushdown gate, all decided by the kind.
#   open_scan(request)    the payload, for ONE execution, at the snapshot the
#                         caller resolved with `resolve_for_execution`.
#
# This library depends on `komira_core` only, so a package that implements a
# scan kind (a message log, a search index, a log store) can conform to the
# trait without depending on the engine that executes it.
#
# THE TRADE-OFF, STATED PLAINLY. `open_scan` DRAINS the scan into resident
# batches (`ScanOpened.batches`) at execution start, after the LIVE snapshot has
# been resolved. It does not stream morsels into the executor. That lets an
# execution-time pass re-root the leaf as an ordinary bound IN_MEMORY scan that
# every executor route already serves. Pull-streaming would change the RETURN
# of `open_scan`, not the rest of this surface.
#
# ERASURE. An engine context holds resolvers for kinds owned by packages it
# must not depend on, so it holds them ERASED: `ErasedScanMorselResolver.erase[R]`
# heap-boxes one concrete conformer behind a manual thin-fn-ptr vtable. It is
# non-generic, so it can cross a shared-library facade, and it conforms
# `ScanMorselResolver` itself, so anything written against the trait (including
# core's `resolve_for_execution[RES: ScanResolver]`) accepts it directly.
#
# RECEIVERS ARE `read self`, EVERY ONE, AND THAT IS INHERITED, NOT CHOSEN. Tier
# 1 declares `resolve_snapshot(self, ...)`, and the execution-time pass borrows
# the resolver set. A kind whose store needs `mut` (a consumer, a reader cache)
# holds it behind an `ArcPointer` and mutates through the Arc, the same shape
# as `ScanRegistry` in `komira_core/source/scan_registry.mojo`, whose bind verbs
# are `read self` for the same reason.
# =============================================================================

from std.memory import ArcPointer, OwnedPointer, UnsafePointer, alloc

from komira_core.arrow.record_batch import RecordBatch
from komira_core.collections.slab import Slab
from komira_core.plan.expr import Expr
from komira_core.source.scan_binding import ScanBinding
from komira_core.source.scan_kind_registry import ScanKindDescriptor
from komira_core.source.scan_params import ScanParams
from komira_core.source.scan_resolver import ScanResolver


comptime SCAN_KIND_NOT_EXECUTABLE: StaticString = "SCAN_KIND_NOT_EXECUTABLE"
"""NAMED ERROR — a plan names a scan kind that no registered resolver serves.

The plan side of a kind needs no code (a `ScanBinding` is data, and a decoded
plan can carry any kind). The execution side does. A binding leaf whose kind
has no resolver here cannot be read, and the only honest answer is to say so by
name, listing what IS registered — never an empty relation, which would read as
"the topic is empty".
"""

comptime SCAN_KIND_ALREADY_REGISTERED: StaticString = (
    "SCAN_KIND_ALREADY_REGISTERED"
)
"""NAMED ERROR — a second resolver for a `kind_id` that already has one.

Unlike `ScanKindRegistry.register` (plan-time DATA, where re-registering the
same descriptor is idempotent), a resolver OWNS a store. Two resolvers for one
kind would make "which store served this scan" a question of registration
order, so the second registration is refused rather than silently winning or
silently losing. A same-name re-registration and a 32-bit FNV collision are both
refused; the message names both kind names so the two are distinguishable.
"""

comptime SCAN_RESOLVER_FOREIGN_KIND: StaticString = (
    "SCAN_RESOLVER_FOREIGN_KIND"
)
"""NAMED ERROR — a resolver was handed (or produced) a binding for a kind that
is not its own.

The erased facade enforces this once for every conformer, so no kind has to
remember to: a resolver that resolved or opened a foreign binding would read
ITS store with ANOTHER kind's params — wrong rows, not an error.
"""

comptime SCAN_BINDING_MISSING_PARAMS: StaticString = (
    "SCAN_BINDING_MISSING_PARAMS"
)
"""NAMED ERROR — `build_binding` was called without a param the kind's
descriptor declares REQUIRED. Raised before the kind is called, naming every
missing key, so a params typo is a plan-build error and not a silent miss at
execution (`ScanKindDescriptor.required_params`)."""

comptime SCAN_REQUEST_NO_LIMIT: Int64 = -1
"""`ScanRequest.limit` when no row limit applies. The plan carries no pushed
row limit on a scan leaf (a `ScanBinding` has no hint slot for one), so an
execution-time pass sends this."""


# =============================================================================
# §1 — the request and the opened payload
# =============================================================================


struct ScanRequest(Movable, Deinitable):
    """One execution's request to a kind.

    `binding` is the PER-EXECUTION binding: epoch-checked, and with a LIVE token
    already re-read (`resolve_for_execution`). A kind reads exactly the snapshot
    this binding names; it must not re-resolve on its own, or the snapshot the
    caller reports (`ResolvedScanSnapshot`) and the rows it returns could
    disagree. ONE STATED EXCEPTION: a kind whose token cannot name its
    snapshot (the broker's multi-partition token is a SUM of high-watermarks)
    reads it ONCE in `open_scan` and reports exactly what it read in
    `ScanOpened.resolved`, which is then the authority, not the token.

    `projection` and `predicate` are HINTS, and both are safe to ignore:
      * `projection` — the columns the plan needs, in the binding schema's
        order; None means every column the binding declares. A kind MAY
        return only these, or a SUPERSET, in ANY column order; it must return
        every one of them, with the type its binding declared. The engine
        re-projects the re-rooted leaf to the relation the plan declared (the
        binding's own columns, in its order, when the plan leaf has no
        projection), so neither extra columns nor their order ever reach a
        parent.
      * `predicate` — the conjuncts the kind's own pushdown gate accepted. A
        kind MAY use them to skip rows; the engine KEEPS the scan's WHOLE
        filter, as a filter node above the re-rooted in-memory scan, and
        re-applies it, so a kind that prunes coarsely (a whole segment outside
        a time window) stays correct. The gate is a
        capability to prune, not a promise of exactness — the same contract the
        parquet zonemap gate has.
    `limit` is `SCAN_REQUEST_NO_LIMIT` or a row count the kind MAY stop at.
    """

    var binding: ScanBinding
    var projection: Optional[List[String]]
    var predicate: Optional[Expr]
    var limit: Int64

    def __init__(
        out self,
        var binding: ScanBinding,
        var projection: Optional[List[String]] = None,
        var predicate: Optional[Expr] = None,
        limit: Int64 = SCAN_REQUEST_NO_LIMIT,
    ):
        self.binding = binding^
        self.projection = projection^
        self.predicate = predicate^
        self.limit = limit

    def copy(self) -> Self:
        var proj: Optional[List[String]] = None
        if self.projection:
            proj = Optional(self.projection.value().copy())
        var pred: Optional[Expr] = None
        if self.predicate:
            pred = Optional(self.predicate.value().copy())
        return Self(
            binding=self.binding.copy(),
            projection=proj^,
            predicate=pred^,
            limit=self.limit,
        )

    def has_limit(self) -> Bool:
        return self.limit >= Int64(0)


struct ScanOpened(Movable, Deinitable):
    """What `open_scan` returns: the drained payload plus the resolved side
    channel.

    `batches` is an `ArcPointer` so a kind that already holds its payload
    resident (a cache, a registry) hands a REFCOUNT BUMP, never a batch copy.
    Zero batches is a legal answer (an empty topic, a query with no hits).
    ⚠ EVERY BATCH CARRIES ONE SCHEMA — the same column names and types, in the
    same order. The re-rooted in-memory leaf reads every batch under batch 0's
    schema, so a kind stitching batches from different sources (live and
    compacted chunks, old and new segments) normalizes them before returning.
    An execution-time pass should refuse a batch that drifts rather than
    execute it. "Type" is the FULL field type, not the `ArrowType` tag: a
    DECIMAL128(18,4) batch after an (18,2) one, a timestamp that gained or lost
    its zone, a dictionary with another index type or a list with another item
    type are all drift.

    `resolved` is the SIDE CHANNEL: what the kind resolved for
    this execution — for a topic `{high_watermark, last_stable_offset,
    log_start_offset, aborted}`, for an index its generation. Keys are the
    kind's; core and the engine never read them, they only carry them to the
    caller (`ResolvedScanSnapshot.resolved`), so a frontend never makes a
    second, racy stats call.
    """

    var batches: ArcPointer[Slab[RecordBatch]]
    var resolved: ScanParams

    def __init__(
        out self,
        var batches: ArcPointer[Slab[RecordBatch]],
        var resolved: ScanParams,
    ):
        self.batches = batches^
        self.resolved = resolved^

    def num_batches(self) -> Int:
        return len(self.batches[])

    def num_rows(self) -> Int:
        var n = 0
        for i in range(len(self.batches[])):
            n += self.batches[][i].num_rows()
        return n


# =============================================================================
# §2 — the trait
# =============================================================================


trait ScanMorselResolver(ScanResolver):
    """Tier 2: a scan kind the engine can EXECUTE.

    `Movable, Deinitable` arrive through `ScanResolver`; they are what
    `ErasedScanMorselResolver.erase[R]` needs to heap-box a conformer and drop
    it exactly once.

    A tier-2 kind's bindings are UNBOUND (no registry handle): its payload is
    produced per execution by `open_scan`, not held in a registry slot. So
    `check_binding` never consults `epoch`/`is_bound` for them, and a conformer
    that holds no slots answers `SCAN_EPOCH_NONE` / `False`.
    """

    def descriptor(self) -> ScanKindDescriptor:
        """The optimizer's view of this kind. Its `kind_id` is the id this
        resolver serves; the erased facade reads it ONCE, at erase time."""
        ...

    def build_binding(self, params: ScanParams) raises -> ScanBinding:
        """The plan-side identity token for a scan of this kind over `params`:
        schema, identity fold and pushdown gate, all owned by the kind. The
        returned binding is UNBOUND and, for a LIVE kind, carries token 0 — the
        token is resolved per execution, never baked into a plan."""
        ...

    def open_scan(self, req: ScanRequest) raises -> ScanOpened:
        """Drain the scan `req.binding` names, at the snapshot it names. See
        `ScanRequest` for what `projection` / `predicate` / `limit` may and may
        not be used for."""
        ...


# =============================================================================
# §3 — the thin fn-ptr vtable (FFI-POD aliases)
#
# Each takes the type-erased home byte ptr (the type-erasure handle; its
# untracked origin is confined to these aliases, the cast sites and the
# trampoline bodies, never a struct field) plus value-typed arguments.
# =============================================================================

comptime _EpochFn = def (UnsafePointer[UInt8, MutUntrackedOrigin]) thin -> UInt64
comptime _IsBoundFn = def (
    UnsafePointer[UInt8, MutUntrackedOrigin], UInt32, Int
) thin -> Bool
comptime _ResolveSnapshotFn = def (
    UnsafePointer[UInt8, MutUntrackedOrigin], ScanBinding
) raises thin -> UInt64
comptime _BuildBindingFn = def (
    UnsafePointer[UInt8, MutUntrackedOrigin], ScanParams
) raises thin -> ScanBinding
comptime _OpenScanFn = def (
    UnsafePointer[UInt8, MutUntrackedOrigin], ScanRequest
) raises thin -> ScanOpened
comptime _DropScanResolverFn = def (
    UnsafePointer[UInt8, MutUntrackedOrigin]
) thin -> None


# =============================================================================
# §4 — ErasedScanMorselResolver — the non-generic runtime facade
# =============================================================================


struct ErasedScanMorselResolver(ScanMorselResolver, Movable, Deinitable):
    """A RUNTIME-erased `ScanMorselResolver`: owns ONE concrete
    `R: ScanMorselResolver` behind a type-erased heap home and a manual fn-ptr
    vtable. Construct with `ErasedScanMorselResolver.erase[R](resolver^)`.

    Conforms `ScanMorselResolver` itself, and adds the one check every
    conformer would otherwise have to remember: a binding for another kind is
    refused (`SCAN_RESOLVER_FOREIGN_KIND`) on the way in and on the way out.
    """

    # `_home` owns the raw bytes of the concrete R (`alloc[R](1)` + a move into
    # it + `bitcast[UInt8]()`). CONCRETE origin, ASAP-tracked. The single
    # pointer field — no wildcard origin in any field.
    var _home: OwnedPointer[UInt8]
    # Read from R ONCE at erase time: the id this facade serves never changes,
    # and caching it is what lets the foreign-kind checks run without a call.
    var _descriptor: ScanKindDescriptor
    # FFI-POD thin fn-ptr fields (code pointers, no heap — the carve-out).
    var _epoch_fn: _EpochFn
    var _is_bound_fn: _IsBoundFn
    var _resolve_snapshot_fn: _ResolveSnapshotFn
    var _build_binding_fn: _BuildBindingFn
    var _open_scan_fn: _OpenScanFn
    var _drop_fn: _DropScanResolverFn

    def __init__(
        out self,
        var home: OwnedPointer[UInt8],
        var descriptor: ScanKindDescriptor,
        epoch_fn: _EpochFn,
        is_bound_fn: _IsBoundFn,
        resolve_snapshot_fn: _ResolveSnapshotFn,
        build_binding_fn: _BuildBindingFn,
        open_scan_fn: _OpenScanFn,
        drop_fn: _DropScanResolverFn,
    ):
        self._home = home^
        self._descriptor = descriptor^
        self._epoch_fn = epoch_fn
        self._is_bound_fn = is_bound_fn
        self._resolve_snapshot_fn = resolve_snapshot_fn
        self._build_binding_fn = build_binding_fn
        self._open_scan_fn = open_scan_fn
        self._drop_fn = drop_fn

    @staticmethod
    def erase[
        R: ScanMorselResolver
    ](var resolver: R) -> ErasedScanMorselResolver:
        """Erase a concrete `R`. Heap-boxes `resolver` and binds the TOP-LEVEL
        parametric trampolines (not nested closures — nested closures over a
        comptime param do not lower as stable fn-ptrs). This is the ONE site
        where `R` is instantiated for a consumer.

        SAFETY: `alloc[R](1)` + an in-place move puts `resolver` on a fresh heap
        slot; `OwnedPointer(unsafe_from_raw_pointer=...)` takes single ownership
        of the byte-cast slot (concrete origin, ASAP-tracked). Every trampoline
        is bound for the SAME `R`, so the in-body reinterpret of the home ptr is
        type-correct by construction.
        """
        var descriptor = resolver.descriptor()
        var home_typed = alloc[R](1)
        # SAFETY: fresh allocation we own; move-construct `resolver` into it.
        UnsafePointer(to=home_typed[]).unsafe_write(resolver^)
        var home = OwnedPointer[UInt8](
            unsafe_from_raw_pointer=home_typed.bitcast[UInt8]()
        )
        var epoch_t: _EpochFn = _erased_scan_epoch_for[R]
        var is_bound_t: _IsBoundFn = _erased_scan_is_bound_for[R]
        var resolve_t: _ResolveSnapshotFn = _erased_scan_resolve_snapshot_for[R]
        var build_t: _BuildBindingFn = _erased_scan_build_binding_for[R]
        var open_t: _OpenScanFn = _erased_scan_open_for[R]
        var drop_t: _DropScanResolverFn = _erased_scan_drop_for[R]
        return ErasedScanMorselResolver(
            home^,
            descriptor^,
            epoch_t,
            is_bound_t,
            resolve_t,
            build_t,
            open_t,
            drop_t,
        )

    # ---- identity of the erased kind -----------------------------------------

    def kind_id(self) -> UInt32:
        return self._descriptor.kind_id

    def kind_name(self) -> String:
        return String(self._descriptor.kind_name)

    def _refuse_foreign(self, binding: ScanBinding, verb: String) raises:
        if binding.kind_id != self._descriptor.kind_id:
            raise Error(
                String(SCAN_RESOLVER_FOREIGN_KIND)
                + String(": the resolver for '")
                + self._descriptor.kind_name
                + String("' (id ")
                + String(self._descriptor.kind_id)
                + String(") refuses to ")
                + verb
                + String(" a binding of kind '")
                + binding.kind_name
                + String("' (id ")
                + String(binding.kind_id)
                + String(")")
            )

    # ---- ScanResolver (tier 1) -------------------------------------------------

    def epoch(self) -> UInt64:
        """SAFETY: `_home` owns R's heap home for this facade's lifetime. The
        byte ptr formed here is reinterpreted by the trampoline as the SAME R
        bound at `erase[R]` and used in place (not moved, not freed). The
        mutable cast is required by the vtable's single pointer type; every
        trampoline calls only a `read self` method of R, so nothing writes
        through it. The wildcard origin is confined to this cast-site body."""
        var p = self._home.unsafe_ptr().unsafe_mut_cast[True]().unsafe_origin_cast[
            MutUntrackedOrigin
        ]()
        return self._epoch_fn(p)

    def is_bound(self, kind_id: UInt32, handle: Int) -> Bool:
        """A foreign kind is never bound here. SAFETY: as `epoch`."""
        if kind_id != self._descriptor.kind_id:
            return False
        var p = self._home.unsafe_ptr().unsafe_mut_cast[True]().unsafe_origin_cast[
            MutUntrackedOrigin
        ]()
        return self._is_bound_fn(p, kind_id, handle)

    def resolve_snapshot(self, binding: ScanBinding) raises -> UInt64:
        """Re-read the CURRENT snapshot token for `binding`. Refuses a foreign
        kind. SAFETY: as `epoch`."""
        self._refuse_foreign(binding, String("resolve"))
        var p = self._home.unsafe_ptr().unsafe_mut_cast[True]().unsafe_origin_cast[
            MutUntrackedOrigin
        ]()
        return self._resolve_snapshot_fn(p, binding)

    # ---- ScanMorselResolver (tier 2) -------------------------------------------

    def descriptor(self) -> ScanKindDescriptor:
        return self._descriptor.copy()

    def build_binding(self, params: ScanParams) raises -> ScanBinding:
        """The kind's binding for `params`. Refuses, BEFORE calling the kind, a
        params map missing a key the descriptor requires; refuses, AFTER, a
        binding the kind built for another kind. SAFETY: as `epoch`."""
        var missing = self._descriptor.missing_params(params)
        if len(missing) > 0:
            var names = String("")
            for i in range(len(missing)):
                if i > 0:
                    names += String(", ")
                names += missing[i]
            raise Error(
                String(SCAN_BINDING_MISSING_PARAMS)
                + String(": scan kind '")
                + self._descriptor.kind_name
                + String("' requires params [")
                + names
                + String("], which are absent from {")
                + params.render()
                + String("}")
            )
        var p = self._home.unsafe_ptr().unsafe_mut_cast[True]().unsafe_origin_cast[
            MutUntrackedOrigin
        ]()
        var b = self._build_binding_fn(p, params)
        self._refuse_foreign(b, String("return"))
        return b^

    def open_scan(self, req: ScanRequest) raises -> ScanOpened:
        """Drain the scan `req.binding` names. Refuses a foreign kind.
        SAFETY: as `epoch`."""
        self._refuse_foreign(req.binding, String("open"))
        var p = self._home.unsafe_ptr().unsafe_mut_cast[True]().unsafe_origin_cast[
            MutUntrackedOrigin
        ]()
        return self._open_scan_fn(p, req)

    def __deinit__(deinit self):
        """Destroy the erased R AND free its home in ONE shot via `_drop_fn`.
        `_home`'s own free is relinquished first (`unsafe_leak()`) so the single
        owner of the bytes at teardown is the `OwnedPointer[R]` the drop
        trampoline reconstructs.

        SAFETY: `unsafe_leak()` relinquishes the home's free so it does NOT also
        free the buffer; `_drop_fn` reconstructs one `OwnedPointer[R]` over the
        SAME allocation and runs destroy + free exactly once."""
        var raw = self._home^.unsafe_take_allocation().unsafe_leak().unsafe_origin_cast[
            MutUntrackedOrigin
        ]()
        self._drop_fn(raw)


# =============================================================================
# §5 — the TOP-LEVEL parametric trampolines, bound ONCE per concrete R at
#      `erase[R]`. Top-level so they lower as stable thin fn-ptrs.
#
# SAFETY (all five non-drop trampolines): `home` is the byte-cast of the live
# `OwnedPointer[R]` home the facade owns (the same R bound here at `erase[R]`);
# it is reinterpreted to `R*` and a `read self` method is called in place — R is
# neither moved nor freed. Arguments are borrowed value types; results are owned
# values.
# =============================================================================


def _erased_scan_epoch_for[
    R: ScanMorselResolver
](home: UnsafePointer[UInt8, MutUntrackedOrigin]) -> UInt64:
    var rp = home.bitcast[R]()
    return rp[].epoch()


def _erased_scan_is_bound_for[
    R: ScanMorselResolver
](home: UnsafePointer[UInt8, MutUntrackedOrigin], kind_id: UInt32, handle: Int) -> Bool:
    var rp = home.bitcast[R]()
    return rp[].is_bound(kind_id, handle)


def _erased_scan_resolve_snapshot_for[
    R: ScanMorselResolver
](
    home: UnsafePointer[UInt8, MutUntrackedOrigin], binding: ScanBinding
) raises -> UInt64:
    var rp = home.bitcast[R]()
    return rp[].resolve_snapshot(binding)


def _erased_scan_build_binding_for[
    R: ScanMorselResolver
](
    home: UnsafePointer[UInt8, MutUntrackedOrigin], params: ScanParams
) raises -> ScanBinding:
    var rp = home.bitcast[R]()
    return rp[].build_binding(params)


def _erased_scan_open_for[
    R: ScanMorselResolver
](
    home: UnsafePointer[UInt8, MutUntrackedOrigin], req: ScanRequest
) raises -> ScanOpened:
    var rp = home.bitcast[R]()
    return rp[].open_scan(req)


def _erased_scan_drop_for[
    R: ScanMorselResolver
](home: UnsafePointer[UInt8, MutUntrackedOrigin]):
    """Reconstruct ONE `OwnedPointer[R]` over the home bytes and let it run R's
    destructor + free the allocation in a single tracked consume.

    SAFETY: `home` is the byte-cast of the R-home allocation whose free the
    facade's `__deinit__` relinquished (`unsafe_leak()`); reconstructing the
    single owner over the SAME bytes makes destroy + free happen exactly once.
    """
    var owned = OwnedPointer[R](unsafe_from_raw_pointer=home.bitcast[R]())
    var r = owned^.into_inner()
    _ = r^


# =============================================================================
# §6 — ScanMorselResolvers — the per-context resolver set, keyed by kind_id
# =============================================================================


struct ScanMorselResolvers(Movable, Deinitable):
    """The resolvers one engine context can execute, keyed by `kind_id`.

    Two parallel containers rather than a Dict, for `ScanKindRegistry`'s reason:
    one entry per KIND (single digits), looked up once per scan leaf per
    execution, never per morsel. `Slab` and not `List` because an erased
    resolver owns a heap home and is Movable-only.
    """

    var _ids: List[UInt32]
    var _resolvers: Slab[ErasedScanMorselResolver]

    def __init__(out self):
        self._ids = List[UInt32]()
        self._resolvers = Slab[ErasedScanMorselResolver]()

    def num_kinds(self) -> Int:
        return len(self._ids)

    def _index_of(self, kind_id: UInt32) -> Int:
        for i in range(len(self._ids)):
            if self._ids[i] == kind_id:
                return i
        return -1

    def contains(self, kind_id: UInt32) -> Bool:
        return self._index_of(kind_id) >= 0

    def register(mut self, var resolver: ErasedScanMorselResolver) raises:
        """Add a resolver. Refuses a `kind_id` that already has one
        (`SCAN_KIND_ALREADY_REGISTERED`), naming both kind names."""
        var id = resolver.kind_id()
        var at = self._index_of(id)
        if at >= 0:
            raise Error(
                String(SCAN_KIND_ALREADY_REGISTERED)
                + String(": scan kind id ")
                + String(id)
                + String(" is already served by '")
                + self._resolvers[at].kind_name()
                + String("'; refusing a second resolver for '")
                + resolver.kind_name()
                + String("'. One kind, one store.")
            )
        self._ids.append(id)
        self._resolvers.append(resolver^)

    def get(
        ref self, kind_id: UInt32
    ) raises -> ref [origin_of(self._resolvers[0])] ErasedScanMorselResolver:
        """The resolver for `kind_id`, BORROWED. Raises
        `SCAN_KIND_NOT_EXECUTABLE`, naming every registered kind, for a kind
        nothing here serves."""
        var at = self._index_of(kind_id)
        if at < 0:
            raise Error(
                String(SCAN_KIND_NOT_EXECUTABLE)
                + String(": no resolver for scan kind id ")
                + String(kind_id)
                + String("; registered: ")
                + self.render_kinds()
            )
        return self._resolvers[at]

    def kind_names(self) -> List[String]:
        """Registered kind names, in registration order."""
        var out = List[String]()
        for i in range(len(self._resolvers)):
            out.append(self._resolvers[i].kind_name())
        return out^

    def render_kinds(self) -> String:
        """`[a (id 1), b (id 2)]`, or `[] (none registered)`. What a
        `SCAN_KIND_NOT_EXECUTABLE` message lists."""
        if len(self._resolvers) == 0:
            return String("[] (none registered)")
        var out = String("[")
        for i in range(len(self._resolvers)):
            if i > 0:
                out += String(", ")
            out += self._resolvers[i].kind_name()
            out += String(" (id ")
            out += String(self._ids[i])
            out += String(")")
        out += String("]")
        return out^

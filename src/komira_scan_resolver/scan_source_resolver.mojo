# =============================================================================
# ScanSourceResolver: the execution-time scan-kind contract (tier 2).
# =============================================================================
#
# THE TWO TIERS. `komira_core/source/scan_resolver.mojo` is tier 1: identity
# and freshness (`epoch`, `is_bound`, `resolve_snapshot`), the only questions
# core can spell. Tier 2 (here) adds what a KIND owns and core must never learn:
#
#   descriptor()           the optimizer's view of the kind (gate, orientation,
#                          snapshot policy, required params). Pure data.
#   build_binding(params)  the kind's PLAN-side identity token: schema, identity
#                          fold and pushdown gate, all decided by the kind.
#   plan_splits(request)   the splits ONE execution reads, each with a start and
#                          (for a bounded read) an exact stop.
#   discover_splits(...)   splits added since the plan, for a read that follows
#                          a growing set of them.
#   open_split(req, split) a reader for one split (`Self.Reader`).
#
# This library depends on `komira_core` only, so a package that implements a
# scan kind (a message log, a search index, a log store) can conform to the
# trait without depending on the engine that executes it.
#
# ONE SURFACE FOR BOUNDED AND UNBOUNDED READS. A scan is a set of splits, each
# read from a start position to an optional stop position (`scan_split.mojo`).
# A snapshot read is a read whose every split has a stop; a read that follows a
# source forever is one whose splits have none. Nothing here changes shape when
# an engine starts following splits: it plans, opens and polls the same
# readers, and the bounded read stays `drain_scan` (`drain_scan.mojo`), which
# drains every split to its stop into resident batches at execution start. That
# drain is what lets an execution-time pass re-root the leaf as an ordinary
# bound IN_MEMORY scan that every executor route already serves.
#
# ERASURE. An engine context holds resolvers for kinds owned by packages it
# must not depend on, so it holds them ERASED: `ErasedScanSourceResolver.erase[R]`
# heap-boxes one concrete conformer behind a manual thin-fn-ptr vtable, and its
# `open_split` erases the conformer's reader the same way (`ErasedSplitReader`).
# Both are non-generic, so they can cross a shared-library facade, and both
# carry `SCAN_RESOLVER_ABI_VERSION` as their first field. The facade conforms
# `ScanSourceResolver` itself, so anything written against the trait (including
# core's `resolve_for_execution[RES: ScanResolver]` and `drain_scan`) accepts it.
#
# RECEIVERS ARE `read self` ON THE RESOLVER, AND THAT IS INHERITED, NOT CHOSEN.
# Tier 1 declares `resolve_snapshot(self, ...)`, and the execution-time pass
# borrows the resolver set. The mutable cursor of a read belongs to the READER
# (`SplitReader.poll(mut self, ...)`), which the caller owns. A kind whose
# shared store needs `mut` (a reader cache) holds it behind an `ArcPointer`,
# the same shape as `ScanRegistry` in `komira_core/source/scan_registry.mojo`.
# =============================================================================

from std.memory import ArcPointer, OwnedPointer, UnsafePointer, alloc

from komira_core.arrow.record_batch import RecordBatch
from komira_core.collections.slab import Slab
from komira_core.plan.expr import Expr
from komira_core.source.scan_binding import ScanBinding
from komira_core.source.scan_kind_registry import ScanKindDescriptor
from komira_core.source.scan_params import ScanParams
from komira_core.source.scan_resolver import ScanResolver
from komira_scan_resolver.scan_split import (
    ErasedSplitReader,
    ScanSplit,
    ScanSplitPlan,
    SplitDelta,
    SplitReader,
    SCAN_RESOLVER_ABI_VERSION,
    SCAN_RESOLVER_FOREIGN_KIND,
    _require_abi,
)


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

comptime SCAN_BINDING_MISSING_PARAMS: StaticString = (
    "SCAN_BINDING_MISSING_PARAMS"
)
"""NAMED ERROR — `build_binding` was called without a param the kind's
descriptor declares REQUIRED. Raised before the kind is called, naming every
missing key, so a params typo is a plan-build error and not a silent miss at
execution (`ScanKindDescriptor.required_params`)."""

comptime SCAN_READ_MODE_NOT_SUPPORTED: StaticString = (
    "SCAN_READ_MODE_NOT_SUPPORTED"
)
"""NAMED ERROR — a read the kind cannot serve: following a growing set of
splits (`discover_splits`) on a kind whose splits are fixed per snapshot (a
search index generation). A bounded kind answers `discover_splits` with
`refuse_discover_splits`, which raises this."""

comptime SCAN_REQUEST_NO_LIMIT: Int64 = -1
"""`ScanRequest.limit` when no row limit applies. The plan carries no pushed
row limit on a scan leaf (a `ScanBinding` has no hint slot for one), so an
execution-time pass sends this."""


# =============================================================================
# §1 — the request and the drained payload
# =============================================================================


struct ScanRequest(Movable, Deinitable):
    """One execution's request to a kind.

    `binding` is the PER-EXECUTION binding: epoch-checked, and with a LIVE token
    already re-read (`resolve_for_execution`). The kind plans the splits this
    execution reads from it (`plan_splits`); what that plan resolved is the
    authority on what was read (`ScanSplitPlan`), and the token is freshness
    and identity only.

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
    `limit` is `SCAN_REQUEST_NO_LIMIT` or a row count the read MAY stop at.
    It is applied across splits by `drain_scan`, never per split.
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
    """What `drain_scan` returns: the drained payload plus the resolved side
    channel.

    `batches` is an `ArcPointer` so a holder that already keeps its payload
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


trait ScanSourceResolver(ScanResolver):
    """Tier 2: a scan kind the engine can EXECUTE.

    `Movable, Deinitable` arrive through `ScanResolver`; they are what
    `ErasedScanSourceResolver.erase[R]` needs to heap-box a conformer and drop
    it exactly once.

    A tier-2 kind's bindings are UNBOUND (no registry handle): its payload is
    produced per execution by its readers, not held in a registry slot. So
    `check_binding` never consults `epoch`/`is_bound` for them, and a conformer
    that holds no slots answers `SCAN_EPOCH_NONE` / `False`.
    """

    # The reader `open_split` returns. One per split, owned by the caller.
    comptime Reader: SplitReader

    def descriptor(self) -> ScanKindDescriptor:
        """The optimizer's view of this kind. Its `kind_id` is the id this
        resolver serves; the erased facade reads it ONCE, at erase time."""
        ...

    def position_version(self) -> UInt8:
        """The version of this kind's `SplitPosition` encoding. Every position
        the kind writes carries it, and the erased facades refuse a position
        carrying another (`SCAN_SPLIT_POSITION_VERSION`). Read ONCE, at erase
        time."""
        ...

    def build_binding(self, params: ScanParams) raises -> ScanBinding:
        """The plan-side identity token for a scan of this kind over `params`:
        schema, identity fold and pushdown gate, all owned by the kind. The
        returned binding is UNBOUND and, for a LIVE kind, carries token 0 — the
        token is resolved per execution, never baked into a plan."""
        ...

    def plan_splits(self, req: ScanRequest) raises -> ScanSplitPlan:
        """The splits ONE execution of `req` reads. This is the execution's one
        read of the kind's store: every stop in the plan is exact, and
        `resolved` reports what they were derived from (`ScanSplitPlan`)."""
        ...

    def discover_splits(
        self, req: ScanRequest, known: List[String]
    ) raises -> SplitDelta:
        """Splits of `req`'s scan whose keys are not in `known`. A kind whose
        splits are fixed per snapshot answers `refuse_discover_splits`."""
        ...

    def open_split(self, req: ScanRequest, split: ScanSplit) raises -> Self.Reader:
        """A reader for `split`, from `split.start` to `split.stop`. See
        `ScanRequest` for what `projection` / `predicate` may and may not be
        used for; `limit` is not the reader's."""
        ...


def refuse_discover_splits(kind_name: String) raises -> SplitDelta:
    """What a kind whose splits are fixed per snapshot answers to
    `discover_splits`: `SCAN_READ_MODE_NOT_SUPPORTED`, naming the kind."""
    raise Error(
        String(SCAN_READ_MODE_NOT_SUPPORTED)
        + String(": scan kind '")
        + kind_name
        + String("' is read at a snapshot; it has no splits to discover")
    )


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
comptime _PlanSplitsFn = def (
    UnsafePointer[UInt8, MutUntrackedOrigin], ScanRequest
) raises thin -> ScanSplitPlan
comptime _DiscoverSplitsFn = def (
    UnsafePointer[UInt8, MutUntrackedOrigin], ScanRequest, List[String]
) raises thin -> SplitDelta
comptime _OpenSplitFn = def (
    UnsafePointer[UInt8, MutUntrackedOrigin],
    ScanRequest,
    ScanSplit,
    UInt32,
    UInt8,
    String,
) raises thin -> ErasedSplitReader
comptime _DropScanResolverFn = def (
    UnsafePointer[UInt8, MutUntrackedOrigin]
) thin -> None


# =============================================================================
# §4 — ErasedScanSourceResolver — the non-generic runtime facade
# =============================================================================


struct ErasedScanSourceResolver(ScanSourceResolver, Movable, Deinitable):
    """A RUNTIME-erased `ScanSourceResolver`: owns ONE concrete
    `R: ScanSourceResolver` behind a type-erased heap home and a manual fn-ptr
    vtable. Construct with `ErasedScanSourceResolver.erase[R](resolver^)`.

    Conforms `ScanSourceResolver` itself (its `Reader` is `ErasedSplitReader`),
    and adds the checks every conformer would otherwise have to remember: a
    binding for another kind is refused (`SCAN_RESOLVER_FOREIGN_KIND`) on the
    way in and on the way out, and so is a split position encoded by another
    kind or at another version (`SCAN_SPLIT_POSITION_VERSION`).
    """

    comptime Reader = ErasedSplitReader

    # FIRST FIELD, deliberately: the layout version, readable before any other
    # field is trusted (see `SCAN_RESOLVER_ABI_VERSION`).
    var _abi: UInt32
    # `_home` owns the raw bytes of the concrete R (`alloc[R](1)` + a move into
    # it + `bitcast[UInt8]()`). CONCRETE origin, ASAP-tracked. The single
    # pointer field — no wildcard origin in any field.
    #
    # SAFETY (every method below that casts `_home`): `_home` owns R's heap
    # home for this facade's lifetime. The byte ptr formed by the cast is
    # reinterpreted by a trampoline as the SAME R bound at `erase[R]` and used
    # in place (not moved, not freed). The mutable cast is required by the
    # vtable's single pointer type; every trampoline calls only a `read self`
    # method of R, so nothing writes through it. The untracked origin lives
    # only in the cast-site local and the trampoline, never in a field.
    var _home: OwnedPointer[UInt8]
    # Read from R ONCE at erase time: the id this facade serves and its position
    # encoding never change, and caching them is what lets the foreign-kind and
    # position checks run without a call.
    var _descriptor: ScanKindDescriptor
    var _position_version: UInt8
    # FFI-POD thin fn-ptr fields (code pointers, no heap — the carve-out).
    var _epoch_fn: _EpochFn
    var _is_bound_fn: _IsBoundFn
    var _resolve_snapshot_fn: _ResolveSnapshotFn
    var _build_binding_fn: _BuildBindingFn
    var _plan_splits_fn: _PlanSplitsFn
    var _discover_splits_fn: _DiscoverSplitsFn
    var _open_split_fn: _OpenSplitFn
    var _drop_fn: _DropScanResolverFn

    def __init__(
        out self,
        var home: OwnedPointer[UInt8],
        var descriptor: ScanKindDescriptor,
        position_version: UInt8,
        epoch_fn: _EpochFn,
        is_bound_fn: _IsBoundFn,
        resolve_snapshot_fn: _ResolveSnapshotFn,
        build_binding_fn: _BuildBindingFn,
        plan_splits_fn: _PlanSplitsFn,
        discover_splits_fn: _DiscoverSplitsFn,
        open_split_fn: _OpenSplitFn,
        drop_fn: _DropScanResolverFn,
    ):
        self._abi = SCAN_RESOLVER_ABI_VERSION
        self._home = home^
        self._descriptor = descriptor^
        self._position_version = position_version
        self._epoch_fn = epoch_fn
        self._is_bound_fn = is_bound_fn
        self._resolve_snapshot_fn = resolve_snapshot_fn
        self._build_binding_fn = build_binding_fn
        self._plan_splits_fn = plan_splits_fn
        self._discover_splits_fn = discover_splits_fn
        self._open_split_fn = open_split_fn
        self._drop_fn = drop_fn

    @staticmethod
    def erase[
        R: ScanSourceResolver
    ](var resolver: R) -> ErasedScanSourceResolver:
        """Erase a concrete `R`. Heap-boxes `resolver` and binds the TOP-LEVEL
        parametric trampolines (not nested closures — nested closures over a
        comptime param do not lower as stable fn-ptrs). This is the ONE site
        where `R` (and `R.Reader`) is instantiated for a consumer.

        SAFETY: `alloc[R](1)` + an in-place move puts `resolver` on a fresh heap
        slot; `OwnedPointer(unsafe_from_raw_pointer=...)` takes single ownership
        of the byte-cast slot (concrete origin, ASAP-tracked). Every trampoline
        is bound for the SAME `R`, so the in-body reinterpret of the home ptr is
        type-correct by construction.
        """
        var descriptor = resolver.descriptor()
        var position_version = resolver.position_version()
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
        var plan_t: _PlanSplitsFn = _erased_scan_plan_splits_for[R]
        var discover_t: _DiscoverSplitsFn = _erased_scan_discover_splits_for[R]
        var open_t: _OpenSplitFn = _erased_scan_open_split_for[R]
        var drop_t: _DropScanResolverFn = _erased_scan_drop_for[R]
        return ErasedScanSourceResolver(
            home^,
            descriptor^,
            position_version,
            epoch_t,
            is_bound_t,
            resolve_t,
            build_t,
            plan_t,
            discover_t,
            open_t,
            drop_t,
        )

    # ---- identity of the erased kind -----------------------------------------

    def kind_id(self) -> UInt32:
        return self._descriptor.kind_id

    def kind_name(self) -> String:
        return String(self._descriptor.kind_name)

    def abi_version(self) -> UInt32:
        return self._abi

    def require_abi(self, expected: UInt32) raises:
        """Refuse this facade unless it was built at `expected`, the
        `SCAN_RESOLVER_ABI_VERSION` the receiving host was compiled with. A
        host that takes a facade from another compilation calls this before
        any other method."""
        _require_abi(self._abi, expected, String("scan source resolver"))

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

    def _refuse_foreign_split(self, split: ScanSplit) raises:
        split.start.require_kind(
            self._descriptor.kind_id,
            self._position_version,
            self._descriptor.kind_name,
            String("start of '") + split.split_key + String("'"),
        )
        if split.stop:
            split.stop.value().require_kind(
                self._descriptor.kind_id,
                self._position_version,
                self._descriptor.kind_name,
                String("stop of '") + split.split_key + String("'"),
            )

    # ---- ScanResolver (tier 1) -------------------------------------------------

    def epoch(self) -> UInt64:
        # SAFETY: as the `_home` field note (a read-only in-place use of R).
        var p = self._home.unsafe_ptr().unsafe_mut_cast[True]().unsafe_origin_cast[
            MutUntrackedOrigin
        ]()
        return self._epoch_fn(p)

    def is_bound(self, kind_id: UInt32, handle: Int) -> Bool:
        """A foreign kind is never bound here."""
        if kind_id != self._descriptor.kind_id:
            return False
        # SAFETY: as the `_home` field note (a read-only in-place use of R).
        var p = self._home.unsafe_ptr().unsafe_mut_cast[True]().unsafe_origin_cast[
            MutUntrackedOrigin
        ]()
        return self._is_bound_fn(p, kind_id, handle)

    def resolve_snapshot(self, binding: ScanBinding) raises -> UInt64:
        """Re-read the CURRENT snapshot token for `binding`. Refuses a foreign
        kind."""
        self._refuse_foreign(binding, String("resolve"))
        # SAFETY: as the `_home` field note (a read-only in-place use of R).
        var p = self._home.unsafe_ptr().unsafe_mut_cast[True]().unsafe_origin_cast[
            MutUntrackedOrigin
        ]()
        return self._resolve_snapshot_fn(p, binding)

    # ---- ScanSourceResolver (tier 2) -------------------------------------------

    def descriptor(self) -> ScanKindDescriptor:
        return self._descriptor.copy()

    def position_version(self) -> UInt8:
        return self._position_version

    def build_binding(self, params: ScanParams) raises -> ScanBinding:
        """The kind's binding for `params`. Refuses, BEFORE calling the kind, a
        params map missing a key the descriptor requires; refuses, AFTER, a
        binding the kind built for another kind."""
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
        # SAFETY: as the `_home` field note (a read-only in-place use of R).
        var p = self._home.unsafe_ptr().unsafe_mut_cast[True]().unsafe_origin_cast[
            MutUntrackedOrigin
        ]()
        var b = self._build_binding_fn(p, params)
        self._refuse_foreign(b, String("return"))
        return b^

    def plan_splits(self, req: ScanRequest) raises -> ScanSplitPlan:
        """The kind's split plan. Refuses a foreign binding on the way in and a
        foreign or mis-versioned position on the way out."""
        self._refuse_foreign(req.binding, String("plan"))
        # SAFETY: as the `_home` field note (a read-only in-place use of R).
        var p = self._home.unsafe_ptr().unsafe_mut_cast[True]().unsafe_origin_cast[
            MutUntrackedOrigin
        ]()
        var plan = self._plan_splits_fn(p, req)
        for i in range(len(plan.splits)):
            self._refuse_foreign_split(plan.splits[i])
        return plan^

    def discover_splits(
        self, req: ScanRequest, known: List[String]
    ) raises -> SplitDelta:
        """As `plan_splits`, for splits discovered since."""
        self._refuse_foreign(req.binding, String("discover splits of"))
        # SAFETY: as the `_home` field note (a read-only in-place use of R).
        var p = self._home.unsafe_ptr().unsafe_mut_cast[True]().unsafe_origin_cast[
            MutUntrackedOrigin
        ]()
        var delta = self._discover_splits_fn(p, req, known)
        for i in range(len(delta.added)):
            self._refuse_foreign_split(delta.added[i])
        return delta^

    def open_split(self, req: ScanRequest, split: ScanSplit) raises -> ErasedSplitReader:
        """A reader for `split`, erased. Refuses a foreign binding and a split
        whose start or stop is foreign or mis-versioned before the kind runs."""
        self._refuse_foreign(req.binding, String("open"))
        self._refuse_foreign_split(split)
        # SAFETY: as the `_home` field note (a read-only in-place use of R).
        var p = self._home.unsafe_ptr().unsafe_mut_cast[True]().unsafe_origin_cast[
            MutUntrackedOrigin
        ]()
        return self._open_split_fn(
            p,
            req,
            split,
            self._descriptor.kind_id,
            self._position_version,
            String(self._descriptor.kind_name),
        )

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
# SAFETY (all non-drop trampolines): `home` is the byte-cast of the live
# `OwnedPointer[R]` home the facade owns (the same R bound here at `erase[R]`);
# it is reinterpreted to `R*` and a `read self` method is called in place — R is
# neither moved nor freed. Arguments are borrowed value types; results are owned
# values.
# =============================================================================


def _erased_scan_epoch_for[
    R: ScanSourceResolver
](home: UnsafePointer[UInt8, MutUntrackedOrigin]) -> UInt64:
    var rp = home.bitcast[R]()
    return rp[].epoch()


def _erased_scan_is_bound_for[
    R: ScanSourceResolver
](home: UnsafePointer[UInt8, MutUntrackedOrigin], kind_id: UInt32, handle: Int) -> Bool:
    var rp = home.bitcast[R]()
    return rp[].is_bound(kind_id, handle)


def _erased_scan_resolve_snapshot_for[
    R: ScanSourceResolver
](
    home: UnsafePointer[UInt8, MutUntrackedOrigin], binding: ScanBinding
) raises -> UInt64:
    var rp = home.bitcast[R]()
    return rp[].resolve_snapshot(binding)


def _erased_scan_build_binding_for[
    R: ScanSourceResolver
](
    home: UnsafePointer[UInt8, MutUntrackedOrigin], params: ScanParams
) raises -> ScanBinding:
    var rp = home.bitcast[R]()
    return rp[].build_binding(params)


def _erased_scan_plan_splits_for[
    R: ScanSourceResolver
](
    home: UnsafePointer[UInt8, MutUntrackedOrigin], req: ScanRequest
) raises -> ScanSplitPlan:
    var rp = home.bitcast[R]()
    return rp[].plan_splits(req)


def _erased_scan_discover_splits_for[
    R: ScanSourceResolver
](
    home: UnsafePointer[UInt8, MutUntrackedOrigin],
    req: ScanRequest,
    known: List[String],
) raises -> SplitDelta:
    var rp = home.bitcast[R]()
    return rp[].discover_splits(req, known)


def _erased_scan_open_split_for[
    R: ScanSourceResolver
](
    home: UnsafePointer[UInt8, MutUntrackedOrigin],
    req: ScanRequest,
    split: ScanSplit,
    kind_id: UInt32,
    position_version: UInt8,
    kind_name: String,
) raises -> ErasedSplitReader:
    """Open R's reader and erase it here, where `R.Reader` is still known."""
    var rp = home.bitcast[R]()
    var reader = rp[].open_split(req, split)
    return ErasedSplitReader.erase[R.Reader](
        reader^, kind_id, position_version, String(kind_name), String(split.split_key)
    )


def _erased_scan_drop_for[
    R: ScanSourceResolver
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
# §6 — ScanSourceResolvers — the per-context resolver set, keyed by kind_id
# =============================================================================


struct ScanSourceResolvers(Movable, Deinitable):
    """The resolvers one engine context can execute, keyed by `kind_id`.

    Two parallel containers rather than a Dict, for `ScanKindRegistry`'s reason:
    one entry per KIND (single digits), looked up once per scan leaf per
    execution, never per morsel. `Slab` and not `List` because an erased
    resolver owns a heap home and is Movable-only.
    """

    var _ids: List[UInt32]
    var _resolvers: Slab[ErasedScanSourceResolver]

    def __init__(out self):
        self._ids = List[UInt32]()
        self._resolvers = Slab[ErasedScanSourceResolver]()

    def num_kinds(self) -> Int:
        return len(self._ids)

    def _index_of(self, kind_id: UInt32) -> Int:
        for i in range(len(self._ids)):
            if self._ids[i] == kind_id:
                return i
        return -1

    def contains(self, kind_id: UInt32) -> Bool:
        return self._index_of(kind_id) >= 0

    def register(mut self, var resolver: ErasedScanSourceResolver) raises:
        """Add a resolver. Refuses a facade built at another ABI
        (`SCAN_RESOLVER_ABI_MISMATCH`) and a `kind_id` that already has one
        (`SCAN_KIND_ALREADY_REGISTERED`), naming both kind names."""
        resolver.require_abi(SCAN_RESOLVER_ABI_VERSION)
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
    ) raises -> ref [origin_of(self._resolvers[0])] ErasedScanSourceResolver:
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

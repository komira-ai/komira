# =============================================================================
# InMemorySource — concrete SourceLike for in-process RecordBatch data.
# =============================================================================
#
# Identity = `_mix64(monotonic_id)`.
#
#   - `monotonic_id` is a strictly-increasing, guaranteed-unique per-ctor ID
#     from a process-global atomic counter (`komira_next_inmem_source_id()`
#     in the C posix shim): distinct ArcPointers ⇒ distinct ctor calls ⇒
#     distinct IDs. No wall-clock dependence — two ctors in the same nanosecond
#     (a fast machine in a tight loop) are still distinct.
#   - `_mix64` is a SplitMix64 finalizer — a *bijection* on 64 bits — so a
#     unique input maps to a unique output; the finalization just gives the
#     identity good distribution for downstream hash-folding. The Arc heap
#     address is deliberately NOT folded in: XOR-combining a varying address
#     with the monotonic ID re-introduces a collision channel (two (addr, id)
#     pairs can XOR to the same value when addr varies) and adds no value,
#     since the monotonic ID already guarantees uniqueness.
#
# Why a C-side counter. A timestamp (`time.perf_counter_ns()`) is NOT
# guaranteed-unique: two ctor calls in a tight loop can land in the same
# nanosecond AND reuse the same just-freed heap slot (tcmalloc reuse) ⇒
# identical fingerprints for two genuinely-distinct sources, which
# cross-contaminates the plan-compile cache. Mojo has no module-level mutable
# globals, so the process-global monotonic counter is implemented C-side
# (`uint64_t komira_next_inmem_source_id()` via `__atomic_fetch_add` relaxed,
# statically linked into every binary and test). NO module-level Mojo state;
# identity is computed once in __init__ and stored as a field (stable across
# `value^` moves and `value.copy()` clones).
#
# Why not the Arc's heap address. An `ArcPointer` pins its allocation only
# WHILE a holder is alive; the moment the last holder drops, tcmalloc reuses
# the slot, so a refcount-1 source's Arc address gets handed to the next
# `from_record_batch` call → identical fingerprint for a genuinely-distinct
# source (construct→drop→construct in a loop reproduces it). There is also a
# correctness edge: a dropped source A's compiled plan stays cached; a new
# source B reusing A's freed Arc slot would collide and get A's plan → wrong
# results. The `__atomic_fetch_add` counter has no such edge and
# `external_call` is ~tens-of-ns.
#
# Surface:
#   - `from_record_batch(rb, name=None)`     — single-batch convenience.
#   - `from_record_batches(batches, name=None)` — primary (multi-batch).
#   - `.copy()` is refcount-bump on `ArcPointer[Slab[RecordBatch]]` (NO buffer
#     byte-copy); `_identity` preserved via internal `_with_preserved_identity`.
#   - Eager Schema validation across batches at construction.
#   - `to_dataframe()` is NOT declared (cyclic dep with DataFrame).
# =============================================================================

from std.ffi import external_call
from std.memory import ArcPointer

from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema
from komira_collections.slab import Slab
from komira_plan_expr.expr import Expr
from komira_scan_source.column_stats import ColumnStats, compute_column_stats
from komira_scan_source.scan_binding import ScanBinding
from komira_scan_source.source_like import SourceLike


# =============================================================================
# Process-global monotonic ID — InMemorySource identity differentiator.
# =============================================================================


@always_inline
def _next_inmem_source_id() -> UInt64:
    """Strictly-increasing, guaranteed-unique per-call ID from a process-global
    atomic counter (`komira_next_inmem_source_id()` in the C posix shim, a
    `static uint64_t` advanced by `__atomic_fetch_add` relaxed). Returns nonzero
    values (1, 2, 3, ...).

    A timestamp differentiator is not guaranteed-unique (two ctor calls in the
    same nanosecond on a fast machine collide — see module header). Mojo has
    no module-level mutable globals, so a C-side atomic is the canonical
    replacement."""
    # SAFETY: `komira_next_inmem_source_id` is a fixed-arity, scalar-returning
    # C function (no pointers cross the FFI boundary); the `static uint64_t`
    # counter and its `__atomic_fetch_add` are internal to the C shim.
    # No allocation, no Mojo origin interaction.
    return external_call["komira_next_inmem_source_id", UInt64]()


@always_inline
def _mix64(x: UInt64) -> UInt64:
    """SplitMix64-style finalizer (local copy of `column_stats_hll.mojo:_mix64` —
    source/ keeps its own hash helpers; see the FNV-1a comment below). One
    multiply + xor-shift rounds; a *bijection* on 64 bits, so a unique input
    maps to a unique output — which is exactly what we need: the monotonic
    ctor ID is unique, so `_mix64(id)` is unique too, just better-distributed
    for downstream hash-folding (it ends up in plan structural_hash)."""
    var z = x + UInt64(0x9E3779B97F4A7C15)
    z = (z ^ (z >> 30)) * UInt64(0xBF58476D1CE4E5B9)
    z = (z ^ (z >> 27)) * UInt64(0x94D049BB133111EB)
    return z ^ (z >> 31)


# =============================================================================
# STRUCTURAL-ID MEMO — O(1) repeat calls for an O(bytes) fold.
# =============================================================================
#
# `InMemorySource.structural_id()` folds `RecordBatch.content_hash` over the
# RAW BYTES of every backing buffer of every batch (see the method docstring).
# It is a PURE function of `self.data` — an `ArcPointer[Slab[RecordBatch]]`
# that is written exactly once (in `__init__`) and never mutated afterwards
# (the only `self.data` reads in this file are `len()`, indexing and
# `.copy()`; nothing mutates a source's batches).
#
# But the call site is `plan_display._write_plan_node`
# (`inmem_id=<structural_id()>`), which `LogicalPlan.structural_hash()`
# reaches by RENDERING THE WHOLE PLAN TO TEXT. Without a memo every plan hash
# costs a full re-scan of every in-memory batch's bytes, and a plan that is
# hashed N times pays N times. `optimizer_agg_cse.collect_agg_subtree_hashes`
# alone calls `structural_hash()` once per GROUPED AGGREGATE node, so a
# nested-aggregate plan re-hashes the SAME inlined in-memory leaf once per
# level — and scan dedup INLINES a materialized shared scan as a
# `SOURCE_IN_MEMORY` leaf, so "the bytes" can be a whole cached fact table.
#
# The memo makes the second and later calls O(1). It is refcount-SHARED
# through `.copy()` (a copy shares the same `data` Arc, hence the same content,
# hence the same id), which is what makes the memo hit across the plan-tree
# clones the optimizer makes.
#
# CONCURRENCY: driver-thread only. Plan rendering / plan hashing happens on the
# optimizer (driver) thread; pool workers never hash a plan. The memo is a
# two-word cell with no atomics, exactly like the existing lazy
# `column_stats` cache next to it (which is `mut self`-gated). Do not call
# `structural_id()` from a worker thread on a shared copy.
# =============================================================================


struct _StructuralIdMemo(Movable, Deinitable):
    """One-shot memo cell for `InMemorySource.structural_id()`.

    Held behind an `ArcPointer` so it is SHARED by every `.copy()` of the
    owning source — which is sound precisely because `.copy()` also shares the
    `data` Arc, so all copies have byte-identical content and therefore the
    same structural id.
    """

    var computed: Bool
    """False until the first `structural_id()` call fills `value`."""

    var value: UInt64
    """The folded content hash. Meaningless while `computed` is False."""

    def __init__(out self):
        self.computed = False
        self.value = UInt64(0)


# =============================================================================
# InMemorySource
# =============================================================================


struct InMemorySource(SourceLike, Movable, Copyable, Deinitable):
    """Concrete SourceLike for in-process RecordBatch data.

    Identity = `_mix64(monotonic_id)` where `monotonic_id` is a process-global,
    strictly-increasing, guaranteed-unique per-ctor ID — see module header for
    the allocator-reuse rationale.

    Construction:
        `InMemorySource.from_record_batch(rb, name=None)` — single
        batch convenience.
        `InMemorySource.from_record_batches(batches: Slab[RecordBatch],
        name=None)` — multi-batch primary ctor. Container is
        `Slab[RecordBatch]` (Movable-only RB precludes `List[RB]`).
        Schema is derived from `batches[0].schema`.

    `.copy()` is refcount-bump on the ArcPointer; NO byte-copy of batch
    payloads. `_identity` is preserved across `.copy()` and across `value^`
    moves (it is a stored field).

    `column_stats: Optional[ArcPointer[List[ColumnStats]]]`:
    lazily-computed per-column statistics (min/max/null_count/distinct_count/
    sum/avg_size + HLL + bloom; see `column_stats.mojo`). Starts `None`;
    `get_column_stats(compute=True)` computes + caches on first call. The Arc
    is refcount-shared so two cache entries / two copies over the same source
    share the sketch. **Stats are NOT part of the source identity** —
    `fingerprint()` is unchanged whether or not stats have been computed (two
    sources over the same batches fingerprint identically regardless).
    """

    var data: ArcPointer[Slab[RecordBatch]]
    var schema_cached: Schema
    var name: Optional[String]
    var _identity: UInt64
    var column_stats: Optional[ArcPointer[List[ColumnStats]]]

    var binding: Optional[ScanBinding]
    """THE CARRIER. `None` until an `EngineContext` binds this source's
    payload into its `ScanRegistry`; then the `(handle, epoch)`-stamped
    `inmem_scan_binding(self)`.

    ⚠ THE PAYLOAD IS REACHABLE BOTH WAYS. `SourceVariant._in_memory` still
    holds `ArcPointer[Slab[RecordBatch]]`, and a payload-read site may read it
    there. This field makes a handle EXIST on an in-memory node so the epoch
    check (wired at every terminal route) has something to check, and so a
    read site can resolve the payload through the registry by handle. The
    two are the same `ArcPointer` (`bind` takes a refcount bump of `data`, not
    a copy of the batches).

    NOT PART OF IDENTITY. `fingerprint()` and `structural_id()` do not read it,
    deliberately: two sources over identical content must hash identically
    whether or not either has been bound, exactly as `column_stats` and
    `_sid_memo` are excluded for the same reason. `plan_display` does not read
    it either — `is_binding_backed()` is false for this tag, so the rendered
    text (and therefore `structural_hash()` and the plan-compile cache key) is
    byte-identical to the unbound form.

    FORWARDED BY `.copy()`, because a plan clone must keep naming the same
    registry slot; a clone that lost its handle would silently fall back to the
    union arm and the gate would report one fewer leaf.
    """

    var _sid_memo: ArcPointer[_StructuralIdMemo]
    """One-shot memo for `structural_id()` — always used; the reference fold
    is reached by `structural_id(memo=False)`. Shared by `.copy()` because a
    copy shares `data`, so its content — and therefore its structural id — is
    byte-identical. NOT part of the source's identity: two sources over the
    same content still hash equal whether or not either has been memoized."""

    @staticmethod
    def from_record_batches(
        var batches: Slab[RecordBatch],
        var name: Optional[String] = None,
    ) raises -> InMemorySource:
        """Primary ctor: own a non-empty Slab of batches; the structural
        schema is derived from `batches[0].schema`.

        Container: `Slab[RecordBatch]` (NOT `List[RecordBatch]`). `List[T]`
        requires `T: Copyable`; `RecordBatch` is Movable-only so
        `List[RecordBatch]` does not compile. `Slab[T: Deinitable](Movable,
        Sized)` is the container for Movable-only batches.

        Schema derivation: the structural Schema is the first batch's
        `.schema`. Every batch carries its own schema (the arrow
        `RecordBatch` invariant), so the caller does not pass one. Each
        batch's column count is validated against
        `batches[0].schema.num_columns()`.

        Empty-relation note: passing an empty Slab raises (there is no
        batch to derive a schema from). To express "an empty in-memory
        relation with a known schema", build a 0-row RecordBatch
        carrying the desired Schema and pass it as a single-element
        Slab, or use `_from_record_batches_unchecked` (internal — keeps
        the explicit schema param for empty-batch + registry-handle
        plan construction).

        Args:
            batches: Owned Slab of one-or-more RecordBatch values.
            name: Optional debug label; NOT folded into fingerprint.

        Raises:
            - empty `batches` Slab (no schema to derive).
            - per-batch column-count mismatch vs `batches[0]`.
        """
        if len(batches) == 0:
            raise Error(
                "InMemorySource.from_record_batches: zero batches — the"
                " schema-derivation factory requires at least one batch."
                " For an empty in-memory relation with a known schema,"
                " pass a single 0-row RecordBatch carrying that schema."
            )
        var schema = batches[0].schema.copy()
        var ncols = schema.num_columns()
        for i in range(len(batches)):
            if batches[i].schema.num_columns() != ncols:
                raise Error(
                    "InMemorySource.from_record_batches: batch "
                    + String(i)
                    + " has "
                    + String(batches[i].schema.num_columns())
                    + " columns, expected "
                    + String(ncols)
                )
        var data = ArcPointer[Slab[RecordBatch]](batches^)
        # Identity = a SplitMix64 finalization of a process-global monotonic
        # ctor ID. The ID is strictly-increasing and guaranteed-unique, so the
        # finalized value is unique too (SplitMix64's finalizer is a bijection
        # on 64 bits) — distinct ArcPointers ⇒ distinct ctor calls ⇒ distinct
        # IDs ⇒ distinct fingerprints, with NO wall-clock dependence and NO
        # heap-address reuse hazard (see the module header).
        # `_identity` is a stored field, so it is stable across `.copy()`
        # (refcount-bump) and across `value^` moves.
        var ident = _mix64(_next_inmem_source_id())
        return InMemorySource(
            _data=data^,
            _schema=schema^,
            _name=name^,
            _identity=ident,
        )

    @staticmethod
    def from_record_batch(
        var batch: RecordBatch,
        var name: Optional[String] = None,
    ) raises -> InMemorySource:
        """Single-batch convenience factory. The structural schema is
        derived from `batch.schema`. Wraps the batch in a
        `Slab[RecordBatch]` and delegates to `from_record_batches`.

        Every RecordBatch carries its own schema, so the caller does not
        pass one.
        """
        var sl = Slab[RecordBatch].create(1)
        sl.append(batch^)
        return InMemorySource.from_record_batches(sl^, name^)

    @staticmethod
    def _from_record_batches_unchecked(
        var batches: Slab[RecordBatch],
        var schema: Schema,
        var name: Optional[String] = None,
    ) -> InMemorySource:
        """Non-raising internal factory used by ScanData / LogicalPlan.scan.

        Skips the per-batch column-count validation that `from_record_batches`
        does — callers are responsible for ensuring schema/batch shape
        agreement at their layer. The only behavioral difference: a
        shape-mismatch is not surfaced as a typed error here.

        Used to bridge the non-raising `LogicalPlan.scan(...)` (whose many
        call sites cannot adopt `raises` without a cascade) to the
        SourceVariant payload.
        """
        var data = ArcPointer[Slab[RecordBatch]](batches^)
        var ident = _mix64(_next_inmem_source_id())
        return InMemorySource(
            _data=data^,
            _schema=schema^,
            _name=name^,
            _identity=ident,
        )

    @staticmethod
    def from_shared_batches(
        var data: ArcPointer[Slab[RecordBatch]],
        var schema: Schema,
        var name: Optional[String] = None,
    ) raises -> InMemorySource:
        """Wrap a payload SOMEBODY ELSE ALREADY HOLDS — a refcount bump, never
        a batch copy.

        The one factory that takes the `ArcPointer` rather than the `Slab`. Its
        caller is the execution-time scan resolve pass
        (`komira_morsel` scan-binding resolve pass): a tier-2 kind's
        `open_scan` hands back an `ArcPointer[Slab[RecordBatch]]` that the kind
        may still hold (a cache, a registry), and `RecordBatch` is Movable-only,
        so the batches can be neither moved out of the Arc nor cheaply copied.

        The schema is EXPLICIT (as `_from_record_batches_unchecked`), so zero
        batches is a well-defined empty relation; every batch present must
        match its column count. The identity is a FRESH per-construction token,
        exactly as `from_record_batches` mints it — the same bytes wrapped twice
        are two sources, which is the cache-discrimination contract
        `fingerprint()` documents.

        Raises:
            - a batch whose column count differs from `schema`'s.
        """
        var ncols = schema.num_columns()
        for i in range(len(data[])):
            if data[][i].schema.num_columns() != ncols:
                raise Error(
                    "InMemorySource.from_shared_batches: batch "
                    + String(i)
                    + " has "
                    + String(data[][i].schema.num_columns())
                    + " columns, expected "
                    + String(ncols)
                )
        var ident = _mix64(_next_inmem_source_id())
        return InMemorySource(
            _data=data^,
            _schema=schema^,
            _name=name^,
            _identity=ident,
        )

    def __init__(
        out self,
        *,
        var _data: ArcPointer[Slab[RecordBatch]],
        var _schema: Schema,
        var _name: Optional[String],
        _identity: UInt64,
        var _column_stats: Optional[ArcPointer[List[ColumnStats]]] = None,
        var _sid_memo: Optional[ArcPointer[_StructuralIdMemo]] = None,
        var _binding: Optional[ScanBinding] = None,
    ):
        """Internal kwarg-only ctor. Used by `from_record_batches` and by
        `_with_preserved_identity`. NOT for public callers — public users
        go through the static factories which compute identity correctly.

        `_column_stats` defaults to `None` (lazy — computed on first
        `get_column_stats(compute=True)` call); `copy()` forwards the cached
        Arc so clones share the sketch.

        `_sid_memo` defaults to `None` ⇒ a FRESH (uncomputed) memo cell. Only
        `.copy()` passes one in, so a clone shares the original's memo (sound:
        a clone shares `data`, so it has identical content). A genuinely new
        source over new bytes always starts with a fresh cell.

        `_binding` defaults to `None` — a source is UNBOUND until an
        `EngineContext` binds its payload. Only `.copy()` and
        `EngineContext._bind_inmem_payload` pass one in; a
        `from_record_batch(es)` site with no context in frame stays `None`.
        """
        self.data = _data^
        self.schema_cached = _schema^
        self.name = _name^
        self._identity = _identity
        self.column_stats = _column_stats^
        self.binding = _binding^
        if _sid_memo:
            self._sid_memo = _sid_memo.take()
        else:
            self._sid_memo = ArcPointer[_StructuralIdMemo](
                _StructuralIdMemo()
            )

    @staticmethod
    def _with_preserved_identity(
        var data: ArcPointer[Slab[RecordBatch]],
        var schema: Schema,
        var name: Optional[String],
        identity: UInt64,
        var column_stats: Optional[ArcPointer[List[ColumnStats]]] = None,
        var sid_memo: Optional[ArcPointer[_StructuralIdMemo]] = None,
        var binding: Optional[ScanBinding] = None,
    ) -> InMemorySource:
        """Internal: build an InMemorySource that inherits the supplied
        identity. Used by `.copy()` so clones preserve the original's
        fingerprint (the cache-discrimination contract requires this), and —
        when `sid_memo` is supplied — the original's `structural_id()` memo."""
        return InMemorySource(
            _data=data^,
            _schema=schema^,
            _name=name^,
            _identity=identity,
            _column_stats=column_stats^,
            _sid_memo=sid_memo^,
            _binding=binding^,
        )

    def copy(self) -> Self:
        """Explicit clone: refcount-bump the ArcPointer (NO buffer byte-
        copy), deep-clone the Schema (~1μs Schema.copy), preserve the
        Optional[String] name and the `_identity` field unchanged, and
        forward the cached `column_stats` Arc (refcount-bump — clones share
        the lazily-computed sketch). Cache-discrimination contract:
        fingerprint is stable across explicit clones (see the SourceLike
        `fingerprint` docstring in `source_like.mojo`).

        The `structural_id()` memo Arc is forwarded for the same reason the
        `column_stats` Arc is: the clone shares `data`, so its content — and
        therefore its structural id — is byte-identical to the original's.

        ⚠ THE `binding` IS FORWARDED TOO, and it is the one field here whose
        omission would be SILENT. A clone shares `data`, so it names the same
        registry slot; a clone that dropped its handle would still execute (the
        payload sites read the union arm), so nothing would fail — the epoch
        gate would simply report one fewer leaf.
        """
        var name_copy: Optional[String] = None
        if self.name:
            name_copy = Optional(String(self.name.value()))
        var stats_copy = self.column_stats.copy()  # Optional-of-Arc refcount bump
        var sid_copy = Optional[ArcPointer[_StructuralIdMemo]](
            self._sid_memo.copy()
        )
        return InMemorySource._with_preserved_identity(
            self.data.copy(),
            self.schema_cached.copy(),
            name_copy^,
            self._identity,
            stats_copy^,
            sid_copy^,
            self.binding.copy(),
        )

    def attach_binding(mut self, var binding: ScanBinding):
        """Stamp this source with the `(handle, epoch)` its payload was bound
        under.

        A NAMED METHOD rather than a bare field assignment so that "a source
        acquired a handle" is greppable — the set of binding sites is
        "who calls this", and the answer has to be readable without knowing the
        field exists. The only caller is
        `EngineContext._bind_inmem_payload`.

        The caller is responsible for having actually bound `self.data` (not a
        copy of the batches) into the registry whose epoch this binding carries.
        `_bind_inmem_payload` is the single place that pairing is made, which is
        why it is one helper and not four inline blocks.
        """
        self.binding = Optional[ScanBinding](binding^)

    # --- lazy ColumnStats accessor ---

    def get_column_stats(
        mut self, compute: Bool = True
    ) raises -> Optional[ArcPointer[List[ColumnStats]]]:
        """Return the per-column statistics for this source.

        - `compute == True` (default): if stats are not yet cached, compute
          them now (one pass over all batches — see `compute_column_stats`),
          cache the result in `self.column_stats`, and return the Arc. On the
          second and later calls this is an O(1) refcount-bump of the cached
          Arc — the SAME `List[ColumnStats]` instance is shared (no recompute).
        - `compute == False`: return the current state (`None` if stats have
          never been computed) WITHOUT touching the batch data. This is the
          cheap path — it just reads the field.

        The Arc is refcount-shared, so callers (e.g. the resolved-plan cache,
        the cardinality estimator) can hold it for the duration of an
        optimization pass cheaply. Returning `None` from the `compute=True`
        path is not possible (stats are always computable for in-memory data).
        """
        if self.column_stats:
            return self.column_stats.copy()
        if not compute:
            var none_v: Optional[ArcPointer[List[ColumnStats]]] = None
            return none_v
        var stats = compute_column_stats(self.data[], self.schema_cached)
        var arc = ArcPointer[List[ColumnStats]](stats^)
        self.column_stats = Optional(arc.copy())
        return Optional(arc^)

    # --- SourceLike trait conformance ---

    def schema(self) -> Schema:
        """Structural schema (eager copy of cached state — no I/O)."""
        return self.schema_cached.copy()

    def estimate_rows(self) -> Int:
        """Row-count estimate: sum across all batches (-1 only if the
        in-memory list ever becomes lazy; today it's always eager so
        the count is exact)."""
        var total = 0
        for i in range(len(self.data[])):
            total += self.data[][i]._num_rows
        return total

    def fingerprint(self) -> UInt64:
        """Stable identity = `_mix64(monotonic_id)`, where `monotonic_id` is a
        process-global, strictly-increasing, guaranteed-unique per-ctor ID
        (`_next_inmem_source_id()`) and `_mix64` is a SplitMix64 finalizer
        (a bijection — preserves the input's uniqueness).

        Stored field (not recomputed) ⇒ stable across `value^` moves and
        `value.copy()` clones — the cache-discrimination contract requires
        this. Distinct ArcPointers ⇒ distinct ctor calls ⇒ distinct IDs ⇒
        distinct fingerprints (closes the allocator-reuse-plus-same-nanosecond
        hole). See module header.

        NOTE: `fingerprint()` is per-ctor UNIQUE by design (the allocator-reuse
        identity contract). It is therefore NOT what enters the plan
        `structural_hash` — a structural hash MUST be equal for
        structurally-identical plans, and a per-ctor unique id defeats that by
        construction (it would break subquery dedup + the plan-compile cache).
        The plan `structural_hash` uses `structural_id()` (content-derived)
        instead. `fingerprint()` stays the IDENTITY differentiator (debugging /
        allocator-reuse safety).
        """
        return self._identity

    def structural_id(self, memo: Bool = True) -> UInt64:
        """CONTENT-derived structural identity — the value `plan_display` emits
        for an in-memory scan so the plan `structural_hash` is EQUAL for two
        structurally-identical in-mem sources and DISTINCT for two sources over
        different content.

        Folds the structural schema text (field names + types + nullability)
        and every batch's `RecordBatch.content_hash` (raw buffer bytes +
        per-column metadata). Does NOT fold the per-ctor `_identity` (that is
        the allocator-reuse IDENTITY, not the structural one) and does NOT fold
        the optional debug `name`.

        Why content-derived is the correct structural-hash key (and SAFE
        against the allocator-reuse hazard the per-ctor id was added to guard):
          * Two SEPARATELY-constructed sources over identical content hash
            equal ⇒ subquery dedup + the plan-compile factory cache fire — the
            cache reuse is CORRECT because the compiled plan IS structurally
            identical.
          * Two sources over DIFFERENT content (different field names or
            different data bytes) hash differently ⇒ CSE never merges them
            into a self-join (a correctness property preserved by CONTENT,
            not by a per-ctor id).
          * The allocator-reuse hazard (a dropped source A's cached compiled
            plan handed to a fresh source B reusing A's freed bytes) cannot
            misfire: a structural-hash COLLISION now implies B has byte-
            identical CONTENT to A, so reusing A's compiled plan is correct.
            A NON-content differentiator (a timestamp) could collide for
            DIFFERENT content; a content hash has no such edge.

        Stable across `.copy()` (the Arc is refcount-shared — same batch
        bytes) and across `value^` moves.

        COST / MEMO: the fold is O(total batch bytes) and this method is
        called once per plan RENDER (`plan_display` emits
        `inmem_id=<structural_id()>`), which `LogicalPlan.structural_hash()`
        performs by writing the whole plan to a String. A plan hashed N times
        would therefore rescan every in-memory batch N times even though
        `data` never changes after construction. The memo makes calls 2..N
        O(1) by caching the fold in `_sid_memo` (shared through `.copy()`);
        the returned value is byte-identical to `_structural_id_compute()`
        either way.

        The memo only helps when the SAME source is re-hashed (nested
        aggregates over one inlined leaf); folds over DISTINCT sources are
        each a miss. Row-count equality is NOT a valid proxy for source
        identity — two equal-sized batches can be distinct source instances.

        Args:
            memo: `True` — the default, and the only value any production
                caller passes — reads and fills the `_sid_memo` cell. `False`
                recomputes from the bytes on every call and never reads or
                writes the cell. It exists so a byte-equivalence oracle can
                reach the REFERENCE fold THROUGH the production entry point.
                It is NOT a runtime switch.

        Returns:
            The content-derived structural id — identical for both values of
            `memo`; only whether the fold is recomputed differs.
        """
        # memo=False FIRST — decided before touching the memo cell (the only
        # side-effecting op in this method), so the reference arm provably
        # never writes it.
        if not memo:
            return self._structural_id_compute()
        if self._sid_memo[].computed:
            return self._sid_memo[].value
        var h = self._structural_id_compute()
        # Interior mutability through the Arc (driver-thread only — see the
        # `_StructuralIdMemo` header). `value` is written BEFORE `computed` so
        # a reader can never observe `computed == True` with a stale value.
        self._sid_memo[].value = h
        self._sid_memo[].computed = True
        return h

    def _structural_id_compute(self) -> UInt64:
        """The unmemoized fold — the REFERENCE implementation of
        `structural_id()`.

        Split out of `structural_id()` (the memo wrapper) so a
        byte-equivalence oracle has something to compare the memoized value
        against. Pure: reads only `self.data`, which is written once in
        `__init__` and never mutated.
        """
        comptime prime = UInt64(0x00000100000001B3)
        var h = UInt64(0xCBF29CE484222325)  # FNV offset basis
        # Salt with the source-kind so an in-mem identity never aliases a
        # raw numeric id from another source family.
        h = (h ^ UInt64(0x1A_1A_1A_1A)) * prime
        h = (h ^ UInt64(len(self.data[]))) * prime  # batch count
        for i in range(len(self.data[])):
            h = self.data[][i].content_hash(h)
        return h

    def _sid_memo_is_computed(self) -> Bool:
        """Test hook: True iff the `structural_id()` memo cell has been
        filled. Lets a test assert (a) that the memo fires on the DEFAULT
        call `structural_id()`, (b) that it stays cold under
        `structural_id(memo=False)`, and (c) that `.copy()` SHARES the filled
        cell."""
        return self._sid_memo[].computed

    def supports_filter_pushdown(self, predicate: Expr) -> Bool:
        """Return `True` for all predicates — an in-memory scan applies ANY
        predicate as a deferred `OP_FILTER` on its morsel op chain.

        In_memory is the ONLY `GATE_ACCEPT_ALL` kind across the nine arms
        (seven arms REJECT_ALL, parquet GATE_SHAPED).

        What `True` means, precisely, for a fixture
        `from_record_batch(v = i-4, i in 0..9)` run through
        `ctx.materialize_plan`:

          predicate       | in the exec envelope? | PUSHED   | left as FILTER
          ----------------+-----------------------+----------+---------------
          `v >= 0`        | yes                   | 6 rows   | 6 rows
          `(v + 1) > 0`   | no (LHS arithmetic)   | RAISES   | RAISES
          `0 < v`         | no (literal on LEFT)  | RAISES   | RAISES

        1. THE PUSHED PREDICATE IS APPLIED, AND THIS SCAN IS THE SOLE APPLIER —
           `push_predicates_down` DELETES the `PLAN_FILTER` node, so the
           rendered plan is a bare `Scan(..., filter=...)`. Not re-applied
           above: if the scan drops it, nothing catches it.

        2. "If this returns True the engine WILL apply `predicate`" does not
           hold for a predicate outside
           `inmem_leaf._inmem_filter_predicate_supported` — but every in-mem
           consumer declines or raises rather than dropping it, so the cost is
           CAPABILITY, not correctness.

        3. ⚠ NARROWING THIS TO THE SERVED ENVELOPE RECOVERS NOTHING. The
           UN-pushed shape — `FILTER(p, SCAN(in_mem))`, exactly what returning
           `False` leaves — RAISES with the SAME error on the same predicates.
           The refusal is the in-mem EXECUTION envelope, not the pushdown. A
           `False` here would trade a raise for an identical raise and rewrite
           the plan shape of every in-mem query.

        SO `True` STAYS, and it means something checkable:

            folding a predicate into `Scan.filter` is OUTCOME-PRESERVING — the
            pushed and un-pushed plans agree, on rows OR on refusal.

        That is the property the fold actually needs.
        `_inmem_filter_predicate_supported` is the real discriminator and is
        enforced at EXECUTION, fail-closed.

        Returning `True` keeps the plan `Filter`-free over an in-mem scan:
        `push_predicates_down` folds every Filter conjunct INTO `Scan.filter`,
        which several downstream optimizer rules (build-side selection,
        scan-dedup) and the morsel executor's join-segment fusion paths are
        built around. There is also no perf cost to this: the deferred
        `OP_FILTER` the in-mem scan re-emits is exactly the same O(n)
        row-wise filter a separate `Filter` node would run, so there's no
        decode work saved either way — but folding it in avoids gratuitously
        changing the plan shape the rest of the pipeline expects.

        Possible refinement: when this source has computed `ColumnStats`
        (min/max/distinct/HLL/bloom), return `False` for predicates whose
        stats CANNOT short-circuit anything (keep them as a `Filter` node
        above — relocating them into the scan is then pure churn) and `True`
        only for predicates the stats prove vacuous (e.g. `col == literal`
        where `literal` is outside `[min, max]`, or a bloom-negative
        `IN`-list), so the optimizer can fold those into a pruned-to-nothing
        scan. That requires an optimizer-side consumer that special-cases the
        "stats prove empty" outcome, and the engine-side change that makes a
        `Filter` node directly over an in-memory scan compose correctly
        under a join (the pipeline assumes such a filter was folded into the
        scan).
        """
        return True

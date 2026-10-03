# =============================================================================
# planner_scale_counter — the STRUCTURAL falsifiers for the two PLANNER passes
# whose cost scales with RESIDENT DATA VOLUME rather than with plan size
# =============================================================================
#
# WHY THIS EXISTS. `EngineContext._apply_scan_dedup` runs two passes on the
# driver, before the first fork of a rep, whose cost is O(resident bytes):
#
#   PASS 16  `_inline_registry_scans` -> `_inline_one_registry_scan` ->
#            `copy_batch(registry.lookup(name))`, a DEEP COPY of every
#            dedup-registered batch INTO the plan, once per query.
#   PASS 17  `_apply_dup_agg_materialize` -> `collect_agg_subtree_hashes` ->
#            `LogicalPlan.structural_hash()` -> `InMemorySource.structural_id`
#            -> `Column.content_hash`, which folds every resident BYTE to
#            derive the agg-CSE plan-node id.
#
# BOTH FIXES ARE INVISIBLE TO A VALUE ASSERTION. Pass 16 replaces a deep copy
# with an Arc share: byte-for-byte the same cells on every consumer, so no
# output comparison can tell the two apart. Pass 17 adds a REACHABILITY GATE
# (`< 2 grouped-aggregate nodes` cannot produce a `counts[h] >= 2`, so the pass
# is provably outcome-identical when it fires): a gate that silently stops
# firing changes nothing observable either. A correctness-only test cannot see
# either lever stop applying, so each is guarded by an OBSERVATION OF THE
# MECHANISM — the same shape as `join_index_window_counter` (`copy_bytes = 0`)
# and for the same reason.
#
# A ROW COUNT IS NOT A FALSIFIER. `InMemoryRegistry.total_rows()` is a
# property of the RESIDENT DATA and does not move under either fix -- the
# registry still holds its rows after the inline shares, and pass 17's gate
# does not empty it. The counters here measure the quantity each lever
# actually removes.
#
# WHAT IS OBSERVED
#
#   PASS 16, per `_inline_one_registry_scan` call:
#     * `inline_scans`   — registry-handle scans inlined. The denominator; a
#                          cell that never inlines reads 0 here and neither
#                          byte counter means anything for it.
#     * `inline_copy_bytes`  — buffer bytes DEEP-COPIED into the plan. The
#                          sharing path copies only columns the share
#                          eligibility predicate rejects, so for ordinary
#                          columns this reads 0. It is the slot a reverted share is required
#                          to declare itself in.
#     * `inline_share_bytes` — buffer bytes Arc-SHARED into the plan. A COPYING
#                          implementation reads 0 here no matter how many scans
#                          it inlined, so this is the independent positive
#                          witness: the two counters cannot both be faked by a
#                          lever that stopped applying.
#
#   PASS 17, per `_apply_dup_agg_materialize` call:
#     * `agg_cse_calls`        — passes run. The denominator.
#     * `agg_cse_grouped_nodes`— GROUPED aggregate nodes the gate counted. The
#                          gate's own input, printed so "the count is 1 on this
#                          cell" is a measurement and not an inference from SQL
#                          shape (the optimizer can SYNTHESIZE aggregates —
#                          `eager_agg`'s cross-side pre-agg is exactly such a
#                          thing — so the post-optimize count is the only count
#                          that decides).
#     * `agg_cse_gate_skips`   — passes the gate short-circuited.
#     * `agg_cse_hash_calls`   — EXACT `structural_hash()` calls the collect
#                          walk made. Zero exactly when the gate fired, OR when
#                          the cheap-key pre-grouping proved no two candidates
#                          can be equal.
#     * `agg_cse_cheap_calls`  — `structural_hash_modulo_inmem_id()` calls (the
#                          CHEAP key: the same plan-text render with the one
#                          O(resident-bytes) field placeholdered). This is the
#                          DENOMINATOR for `hash_calls`: a cheap-key scheme that
#                          silently stopped applying reads 0 here, so
#                          "`hash_calls == 0`" alone cannot be mistaken for
#                          success when the truth is "the pass never ran".
#     * `agg_cse_folds`        — exact hashes that reached `count >= 2`, i.e.
#                          aggregate subtrees actually materialized-and-shared.
#                          A cell with `folds > 0` is doing REAL work and its
#                          `hash_bytes` is irreducible; a cell with `folds == 0`
#                          hashed for nothing. Without this, "this query still
#                          hashes" is indistinguishable from "the lever missed
#                          this query".
#
#     * `agg_cse_hash_bytes`   — content-hash bytes folded INSIDE pass 17,
#                          recorded as a DELTA of `content_hash_bytes` across
#                          the pass. ⚠ THIS, NOT THE PROCESS-WIDE COUNTER, IS
#                          THE PASS'S OWN QUANTITY. `InMemorySource
#                          .structural_id` MEMOIZES, so
#                          whichever consumer reaches a source first pays for
#                          it and every later one reads free. A pass that stops
#                          folding therefore does not necessarily reduce the
#                          PROCESS-WIDE total — the fold can SHIFT to the next
#                          consumer (the engine context's Layer-1 factory
#                          cache hashes the RAW plan and
#                          will absorb any in-memory leaf the caller supplied
#                          directly). The two counters answer two different
#                          questions and both are needed: this one says "did
#                          the pass stop folding", the process-wide one says
#                          "did the work leave the process".
#
#   PROCESS-WIDE, at the one place bytes are actually folded:
#     * `content_hash_bytes`   — bytes folded by `Column._fold_buffer_bytes`.
#                          Read as a DELTA across a region: the delta across
#                          pass 17 is that pass's true `hash_bytes`, exact by
#                          construction and incapable of drifting away from
#                          `content_hash`'s real cost, because it is counted
#                          inside the fold itself rather than re-derived from a
#                          parallel walk. It is a side effect on a separate
#                          atomic and CANNOT change a hash value — the
#                          content-derived identity contract is untouched.
#
# COST. One relaxed `fetch_add` per inlined scan (not per column, not per row),
# per agg-CSE pass, and per BUFFER folded by a content hash. A buffer fold is
# an O(bytes) loop over megabytes; an atomic increment in front of it is not
# measurable. The `structural_id` memo means the
# fold itself runs at most once per distinct source per query anyway.
#
# Same `_Global` + `Atomic` idiom as `join_index_window_counter.mojo` -- no
# environment read, no `unsafe_from_address` laundering, no wildcard-origin
# field.
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.ffi import _Global
from std.memory import OwnedPointer, UnsafePointer, alloc


def _init_ps_counter() -> OwnedPointer[AtomicI64]:
    """`_Global` init_fn: allocate one counter cell per process (init 0)."""
    var raw = alloc[AtomicI64](1)
    raw.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


comptime _PS_INLINE_SCANS = _Global[
    "komira_core_planner_scale_inline_scans", _init_ps_counter
]
comptime _PS_INLINE_COPY_BYTES = _Global[
    "komira_core_planner_scale_inline_copy_bytes", _init_ps_counter
]
comptime _PS_INLINE_SHARE_BYTES = _Global[
    "komira_core_planner_scale_inline_share_bytes", _init_ps_counter
]
comptime _PS_AGG_CSE_CALLS = _Global[
    "komira_core_planner_scale_agg_cse_calls", _init_ps_counter
]
comptime _PS_AGG_CSE_GROUPED_NODES = _Global[
    "komira_core_planner_scale_agg_cse_grouped_nodes", _init_ps_counter
]
comptime _PS_AGG_CSE_GATE_SKIPS = _Global[
    "komira_core_planner_scale_agg_cse_gate_skips", _init_ps_counter
]
comptime _PS_AGG_CSE_HASH_CALLS = _Global[
    "komira_core_planner_scale_agg_cse_hash_calls", _init_ps_counter
]
comptime _PS_AGG_CSE_CHEAP_CALLS = _Global[
    "komira_core_planner_scale_agg_cse_cheap_calls", _init_ps_counter
]
comptime _PS_AGG_CSE_FOLDS = _Global[
    "komira_core_planner_scale_agg_cse_folds", _init_ps_counter
]
comptime _PS_AGG_CSE_HASH_BYTES = _Global[
    "komira_core_planner_scale_agg_cse_hash_bytes", _init_ps_counter
]
comptime _PS_CONTENT_HASH_BYTES = _Global[
    "komira_core_planner_scale_content_hash_bytes", _init_ps_counter
]


# -----------------------------------------------------------------------------
# Recorders
# -----------------------------------------------------------------------------


@always_inline
def planner_scale_note_inline(copy_bytes: Int, share_bytes: Int) raises:
    """Record ONE `_inline_one_registry_scan` resolution.

    Args:
        copy_bytes: Buffer bytes this resolution DEEP-COPIED into the plan.
        share_bytes: Buffer bytes it Arc-SHARED into the plan.

    A resolution contributes to exactly one of the two on a per-COLUMN basis
    (the share is column-gated), so `copy + share` is the batch's whole buffer
    footprint and the split says which mechanism moved it."""
    # SAFETY: FFI carve-out — `get_or_create_ptr` targets KGEN-runtime static
    # storage (process-lifetime); the wildcard is the stdlib `_Global` API's own
    # return type, confined to this helper.
    var gs = _PS_INLINE_SCANS.get_or_create_ptr()
    _ = gs[][].fetch_add(Int64(1))
    if copy_bytes != 0:
        # SAFETY: FFI carve-out (see above).
        var gc = _PS_INLINE_COPY_BYTES.get_or_create_ptr()
        _ = gc[][].fetch_add(Int64(copy_bytes))
    if share_bytes != 0:
        # SAFETY: FFI carve-out (see above).
        var gh = _PS_INLINE_SHARE_BYTES.get_or_create_ptr()
        _ = gh[][].fetch_add(Int64(share_bytes))


@always_inline
def planner_scale_note_agg_cse(grouped_nodes: Int, gate_skipped: Bool) raises:
    """Record ONE `_apply_dup_agg_materialize` pass and the gate's decision.

    Args:
        grouped_nodes: GROUPED aggregate nodes found in the post-optimize plan.
        gate_skipped: True iff the reachability gate short-circuited the pass.
    """
    # SAFETY: FFI carve-out (see `planner_scale_note_inline`).
    var gc = _PS_AGG_CSE_CALLS.get_or_create_ptr()
    _ = gc[][].fetch_add(Int64(1))
    if grouped_nodes != 0:
        # SAFETY: FFI carve-out (see above).
        var gn = _PS_AGG_CSE_GROUPED_NODES.get_or_create_ptr()
        _ = gn[][].fetch_add(Int64(grouped_nodes))
    if gate_skipped:
        # SAFETY: FFI carve-out (see above).
        var gk = _PS_AGG_CSE_GATE_SKIPS.get_or_create_ptr()
        _ = gk[][].fetch_add(Int64(1))


@always_inline
def planner_scale_note_agg_cse_hash() raises:
    """Record ONE `structural_hash()` call made by the agg-CSE collect walk.
    Reads 0 for a pass the gate short-circuited — that is the whole point."""
    # SAFETY: FFI carve-out (see `planner_scale_note_inline`).
    var gh = _PS_AGG_CSE_HASH_CALLS.get_or_create_ptr()
    _ = gh[][].fetch_add(Int64(1))


@always_inline
def planner_scale_note_agg_cse_cheap() raises:
    """Record ONE `structural_hash_modulo_inmem_id()` call — the CHEAP key the
    agg-CSE pass groups candidates by before deciding which pairs are worth an
    exact content hash. Folds ZERO resident bytes by construction."""
    # SAFETY: FFI carve-out (see `planner_scale_note_inline`).
    var gh = _PS_AGG_CSE_CHEAP_CALLS.get_or_create_ptr()
    _ = gh[][].fetch_add(Int64(1))


@always_inline
def planner_scale_note_agg_cse_fold() raises:
    """Record ONE aggregate subtree the pass actually folded (an exact hash with
    `count >= 2`). Separates "this cell hashed and it was NECESSARY" from "this
    cell hashed for nothing"."""
    # SAFETY: FFI carve-out (see `planner_scale_note_inline`).
    var gf = _PS_AGG_CSE_FOLDS.get_or_create_ptr()
    _ = gf[][].fetch_add(Int64(1))


@always_inline
def planner_scale_note_agg_cse_hash_bytes(n: Int) raises:
    """Record `n` content-hash bytes folded INSIDE the agg-CSE pass, as a delta
    of `content_hash_bytes` across it. The pass's OWN quantity — see this
    module's header for why the process-wide counter cannot answer the same
    question (the `structural_id` memo lets a fold SHIFT to another consumer
    rather than disappear)."""
    if n == 0:
        return
    # SAFETY: FFI carve-out (see `planner_scale_note_inline`).
    var gb = _PS_AGG_CSE_HASH_BYTES.get_or_create_ptr()
    _ = gb[][].fetch_add(Int64(n))


@always_inline
def planner_scale_note_content_hash_bytes(n: Int) raises:
    """Record `n` bytes folded by a content hash. Called from
    `Column._fold_buffer_bytes` — the ONE place the O(bytes) fold happens — so
    the count cannot drift from the cost it stands for."""
    # SAFETY: FFI carve-out (see `planner_scale_note_inline`).
    var gb = _PS_CONTENT_HASH_BYTES.get_or_create_ptr()
    _ = gb[][].fetch_add(Int64(n))


# -----------------------------------------------------------------------------
# Readers
# -----------------------------------------------------------------------------


def planner_scale_inline_scans() raises -> Int:
    """Registry-handle scans inlined into a plan since the last reset."""
    # SAFETY: FFI carve-out (see `planner_scale_note_inline`).
    var g = _PS_INLINE_SCANS.get_or_create_ptr()
    return Int(g[][].load())


def planner_scale_inline_copy_bytes() raises -> Int:
    """Buffer bytes DEEP-COPIED by the registry inline. The share path
    copies only share-ineligible columns, so over offset-0, full-length
    batches this reads 0."""
    # SAFETY: FFI carve-out (see `planner_scale_note_inline`).
    var g = _PS_INLINE_COPY_BYTES.get_or_create_ptr()
    return Int(g[][].load())


def planner_scale_inline_share_bytes() raises -> Int:
    """Buffer bytes Arc-SHARED by the registry inline. Zero for a copying
    implementation, whatever its scan count."""
    # SAFETY: FFI carve-out (see `planner_scale_note_inline`).
    var g = _PS_INLINE_SHARE_BYTES.get_or_create_ptr()
    return Int(g[][].load())


def planner_scale_agg_cse_calls() raises -> Int:
    """`_apply_dup_agg_materialize` invocations since the last reset."""
    # SAFETY: FFI carve-out (see `planner_scale_note_inline`).
    var g = _PS_AGG_CSE_CALLS.get_or_create_ptr()
    return Int(g[][].load())


def planner_scale_agg_cse_grouped_nodes() raises -> Int:
    """GROUPED aggregate nodes counted by the gate, summed over passes."""
    # SAFETY: FFI carve-out (see `planner_scale_note_inline`).
    var g = _PS_AGG_CSE_GROUPED_NODES.get_or_create_ptr()
    return Int(g[][].load())


def planner_scale_agg_cse_gate_skips() raises -> Int:
    """Passes the `< 2 grouped aggregates` reachability gate short-circuited."""
    # SAFETY: FFI carve-out (see `planner_scale_note_inline`).
    var g = _PS_AGG_CSE_GATE_SKIPS.get_or_create_ptr()
    return Int(g[][].load())


def planner_scale_agg_cse_hash_calls() raises -> Int:
    """`structural_hash()` calls made by the agg-CSE collect walk."""
    # SAFETY: FFI carve-out (see `planner_scale_note_inline`).
    var g = _PS_AGG_CSE_HASH_CALLS.get_or_create_ptr()
    return Int(g[][].load())


def planner_scale_agg_cse_cheap_calls() raises -> Int:
    """CHEAP-key (`structural_hash_modulo_inmem_id`) calls. The denominator that
    keeps `hash_calls == 0` from being satisfiable by a pass that never ran."""
    # SAFETY: FFI carve-out (see `planner_scale_note_inline`).
    var g = _PS_AGG_CSE_CHEAP_CALLS.get_or_create_ptr()
    return Int(g[][].load())


def planner_scale_agg_cse_folds() raises -> Int:
    """Aggregate subtrees the pass materialized-and-shared."""
    # SAFETY: FFI carve-out (see `planner_scale_note_inline`).
    var g = _PS_AGG_CSE_FOLDS.get_or_create_ptr()
    return Int(g[][].load())


def planner_scale_agg_cse_hash_bytes() raises -> Int:
    """Content-hash bytes folded INSIDE the agg-CSE pass. The falsifier for the
    reachability gate + the cheap-key pre-grouping."""
    # SAFETY: FFI carve-out (see `planner_scale_note_inline`).
    var g = _PS_AGG_CSE_HASH_BYTES.get_or_create_ptr()
    return Int(g[][].load())


def planner_scale_content_hash_bytes() raises -> Int:
    """Bytes folded by `Column.content_hash` process-wide. Read as a DELTA
    across a region to attribute the fold to that region."""
    # SAFETY: FFI carve-out (see `planner_scale_note_inline`).
    var g = _PS_CONTENT_HASH_BYTES.get_or_create_ptr()
    return Int(g[][].load())


def reset_planner_scale_counters() raises:
    """Reset every counter to 0 (test setup / per-cell delta harness)."""
    # SAFETY: FFI carve-out (see `planner_scale_note_inline`).
    _PS_INLINE_SCANS.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _PS_INLINE_COPY_BYTES.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _PS_INLINE_SHARE_BYTES.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _PS_AGG_CSE_CALLS.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _PS_AGG_CSE_GROUPED_NODES.get_or_create_ptr()[][].store(
        Scalar[DType.int64](0)
    )
    _PS_AGG_CSE_GATE_SKIPS.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _PS_AGG_CSE_HASH_CALLS.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _PS_AGG_CSE_CHEAP_CALLS.get_or_create_ptr()[][].store(
        Scalar[DType.int64](0)
    )
    _PS_AGG_CSE_FOLDS.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _PS_AGG_CSE_HASH_BYTES.get_or_create_ptr()[][].store(
        Scalar[DType.int64](0)
    )
    _PS_CONTENT_HASH_BYTES.get_or_create_ptr()[][].store(
        Scalar[DType.int64](0)
    )

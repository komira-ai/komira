# =============================================================================
# growable_hash_set_i64.mojo — GrowableHashSetI64 single-Int64-key SET primitive
# =============================================================================
#
# ERR-COUNT-DISTINCT-GROWABLE-SUBSTRATE — set
# primitive over Int64 keys, growable (no cap), gap6-safe.
#
# Replaces the legacy 16-cap `HashSetI64` (InlineArray-backed open-addressing
# mirror of the pre-DENSE-HASH-AGG `HashAggTableI64`) for the two v0.4 GA
# consumers:
#
#   1. `CountDistinctI64ToF64.StateTy` — per-group distinct-set state for the
#      COUNT(DISTINCT) hash-agg conformer in `runtime_breaker_state.mojo`.
#      ClickBench cb04/cb05/cb10/cb13 = `count(DISTINCT user_id)` over 100M
#      rows with millions of distinct user_ids — the 16-cap was unworkable
#      and surfaced as a sharper `RuntimeCardinalityOverflow` raise at
#      finalize. Growable substrate removes the cap (subject to RAM).
#
#   2. `distinct_set_single_i64` field — single-key BREAKER_DISTINCT path.
#      Mirror swap; the legacy 16-cap surfaced `DISTINCT_OVERFLOW_RAISE_MSG`
#      at insert-time which the SDK try-fallback used to route to legacy
#      `_compile_distinct`. With the growable substrate the fallback is
#      no longer needed for the single-key shape.
#
# # Storage rationale
#
# The growable variant is a THIN WRAPPER over `_DenseAggDirectory` (the
# salt-packed open-addressing dense directory introduced by DENSE-HASH-AGG
# Phase 1 for `HashAggTableF64/I64/I32/F32`). Set semantics need the same
# probe/insert/grow logic that `_DenseAggDirectory` already implements;
# the set ignores the dense `group_id` return (it cares only about
# "newly inserted vs already present") and uses `n_groups` AS the
# cardinality.
#
# Rationale for "wrap, don't fork": `_DenseAggDirectory` has been
# perf-validated under Q1 (4-group case, 0 `bl` in the inner loop),
# under H2O h1 (~100 groups), and under the larger TPC-H queries
# (variable cardinality). The set primitive piggybacks on every probe /
# salt-stride / grow-and-rehash invariant for free.
#
# # POD-storage discipline (gap6)
#
# `_DenseAggDirectory` storage = `List[UInt64]` directory + `List[Int64]`
# keys + `List[UInt64]` cached_hash. All `List[POD]`, gap6-clean by
# construction (see `dense_hash_agg_table.mojo` §"Encapsulation
# invariants"). The set wrapper adds no fields beyond the inner
# directory. Storage of `GrowableHashSetI64` as a per-group state inside
# `HashAggTableF64[CountDistinctI64ToF64].slabs: List[StateTy]` is a
# `List[List[...]]` — heap-owning, but the outer List preserves origin
# tracking (not byte-erased), so the gap6 hazard does not fire here.
# Verified pattern: `HashSetI64I64` (composite-arity-2 DISTINCT) already
# uses `List[Int64]` fields and lives at `runtime_breaker_state.mojo:556`
# without incident.
#
# # Encapsulation invariants
#
#   - NO `UnsafePointer` in any public method signature.
#   - NO wildcard origins.
#   - All inner `_DenseAggDirectory` fields are `List[POD]`; no heap-owning
#     inner field, no `Movable` struct with `List[U]` payload that gap6
#     could fire on.
#   - No partial-move via `UnsafePointer(to=field).take_pointee()` —
#     the directory is accessed through whole-struct refs / by-value
#     copies; whole-struct Movable+Copyable auto-synthesized.
#
# Cross-references:
#   - dense_hash_agg_table.mojo §"§2 — _DenseAggDirectory" — the wrapped
#     directory.
#   - runtime_breaker_state.mojo §"§0c — HashSet primitives for DISTINCT"
#     — the legacy fixed-16 HashSetI64 this replaces.
#   - err_count_distinct_growable_plus_tls_sha256_record.md — diary.
# =============================================================================


from komira_op_agg_state.dense_hash_agg_table import (
    DENSE_INITIAL_CAPACITY,
    _DenseAggDirectory,
)


# =============================================================================
# §1 — GrowableHashSetI64 — growable single-Int64-key SET
# =============================================================================
#
# Thin wrapper over `_DenseAggDirectory`. Public API:
#
#   - `insert(key) -> Bool` — True if newly inserted (cardinality grew),
#     False if already present.
#   - `contains(key) -> Bool` — membership check (no mutation).
#   - `size() -> Int` — distinct cardinality.
#   - `key_at(slot) -> Int64` — dense ordered key access for finalize-time
#     drain (slot in 0..size()).
#
# The set ignores the dense `group_id` from `lookup_or_insert` (it's
# the inserted-or-found ordinal; cardinality grows iff a new
# group_id was assigned, which is detected by comparing the returned
# group_id to the pre-call `size()`).
# =============================================================================


@fieldwise_init
struct GrowableHashSetI64(Copyable, Movable):
    """Growable single-Int64-key hash SET.

    Mirror of `HashSetI64` (16-cap, InlineArray-backed) but storage-
    unbounded — uses `_DenseAggDirectory` (the same salt-packed
    open-addressing directory that powers `HashAggTableF64/I64/I32/F32`)
    for grow-on-load probe + rehash semantics.

    Set semantics layered over directory semantics:
      - `lookup_or_insert(key) -> group_id`: directory returns dense
        group_id in `0..n_groups` (stable for table lifetime). The set
        compares the returned group_id against the directory's
        pre-call `n_groups` to determine "newly inserted" vs "already
        present".
      - `size()` == directory's `n_groups` == set cardinality.

    Per-row hot path: `insert(key) -> Bool`. The directory does the
    salt-stride probe, the salt-gate before key fetch, and the
    grow-and-rehash at ~0.67 load. The set adds a single
    `pre_call_n_groups` comparison.

    Storage growth: implicit via the directory's geometric doubling at
    capacity * 2 / 3 load. Initial capacity is `DENSE_INITIAL_CAPACITY`
    (2048 slots = 16 KB directory + dense key column / cached_hash
    growing as 8 + 8 bytes per inserted key).

    Memory ceiling: unbounded-in-RAM; will OOM above some cardinality
    (no spill in Phase 1, mirror of `HashAggTableF64` per its RFC
    §7.6). For ClickBench cb04/cb05/cb10/cb13 (100M rows, up to
    millions of distinct user_ids) the upper bound is ~16 MB per
    table (1M groups × 16 bytes for key + cached_hash), well within
    the per-pipeline memory envelope.
    """

    var dir: _DenseAggDirectory

    @staticmethod
    def new(
        initial_capacity: Int = DENSE_INITIAL_CAPACITY,
    ) -> GrowableHashSetI64:
        """Construct empty growable set with at-least `initial_capacity`
        directory slots (rounded up to power-of-2 by the directory)."""
        return GrowableHashSetI64(dir=_DenseAggDirectory.new(initial_capacity))

    @staticmethod
    def with_expected(n_expected: Int) -> GrowableHashSetI64:
        """LEVER CDP — construct a set already sized for `n_expected` distinct
        keys, so the grow-and-rehash ladder never runs.

        `n_expected` is an UPPER bound (callers pass the input VALUE count; the
        distinct count can only be smaller). See
        `_DenseAggDirectory.new_presized` for the cost model, the clamp, and the
        proof that `size()` / `key_at()` are capacity-invariant.

        `with_expected(n)` for any `n <= 0` is byte-for-byte the default
        `GrowableHashSetI64()` — that identity is what lets a caller gate the
        lever with a single `hint = n if on else 0` and keep the OFF arm on the
        exact pre-lever code path."""
        return GrowableHashSetI64(dir=_DenseAggDirectory.new_presized(n_expected))

    def __init__(out self):
        """Default-construct (DENSE_INITIAL_CAPACITY=2048 directory slots)."""
        self.dir = _DenseAggDirectory.new(DENSE_INITIAL_CAPACITY)

    @always_inline
    def insert(mut self, key: Int64) -> Bool:
        """Insert `key` into the set. Returns True if newly inserted
        (cardinality grew); False if already present (no-op).

        Hot path: O(1) amortized — directory salt-stride probe + optional
        grow-and-rehash on capacity * 2 / 3 load. Per-row cost dominated
        by one Knuth multiplicative mix + one cache-line load from the
        directory.
        """
        var pre = self.dir.n_groups
        var _gid = self.dir.lookup_or_insert(key)
        return self.dir.n_groups > pre

    @always_inline
    def contains(self, key: Int64) -> Bool:
        """Membership check (no mutation). Returns True if `key` is
        already in the set.

        Implementation: invoke `lookup_or_insert` on a temporary copy of
        the directory and check whether n_groups grew. Avoided in the
        hot path (`insert` is the canonical write path); provided for
        symmetry with the legacy `HashSetI64.contains` API.
        """
        # Linear-probe via a `__copy__`-d directory; cheap because
        # _DenseAggDirectory is Copyable+Movable and the cost is bounded
        # by the directory's current capacity (typically 2048 slots).
        var probe_dir = self.dir.copy()
        var pre = probe_dir.n_groups
        var _gid = probe_dir.lookup_or_insert(key)
        return probe_dir.n_groups == pre

    @always_inline
    def size(self) -> Int:
        """Distinct cardinality (== directory's `n_groups`)."""
        return self.dir.n_groups

    @always_inline
    def key_at(self, slot: Int) -> Int64:
        """Read the inserted key at dense slot index (0..size()).

        Order: insertion order (directory's dense `keys` list is
        append-on-insert). Equivalent to `HashSetI64I64`'s
        insertion-ordered drain.
        """
        return self.dir.key_at(slot)

    @always_inline
    def capacity_of(self) -> Int:
        """Directory slot count (power-of-2). DIAGNOSTIC — the set's resident
        directory is `capacity_of() * 8` bytes, and the number of grow-and-
        rehash doublings this set performed is `log2(capacity_of() / 2048)`.
        """
        return self.dir.capacity_of()

    def audit_displacement(self) -> Int:
        """DIAGNOSTIC — see `_DenseAggDirectory.audit_displacement`. Sum of the
        extra probe steps over all live keys; `1 + that / size()` is the mean
        directory slot loads per steady-state `insert`."""
        return self.dir.audit_displacement()

    def into_keys(var self) -> List[Int64]:
        """CONSUME the set and hand back its dense key column, MOVED.

        The directory's `keys` list IS the deduped key set in insertion
        order — exactly what a `key_at(0..size())` drain loop would
        produce, element for element. Handing the list out by MOVE makes
        that drain O(1) instead of O(size()): the caller gets the same
        values with zero copies and zero allocation.

        CONSUMING BY DESIGN (`var self`). A `mut self` drain would have to
        leave the directory internally consistent — either re-sentinel-
        filling `directory` or reallocating it — which reintroduces the
        per-set memory traffic this method exists to remove. Taking `self`
        by value lets the type system, not a comment, guarantee the
        half-emptied set is unreachable: the callee owns it and drops the
        (now keyless) directory on return.

        Used by the grouped COUNT(DISTINCT) finalize to turn each promoted
        per-(worker, group, value-partition) set into an already-deduped
        value run for `radix_distinct_count_grouped`.
        """
        var out = List[Int64]()
        swap(self.dir.keys, out)
        return out^

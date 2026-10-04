# =============================================================================
# Tests for InMemorySource, the concrete SourceLike impl over in-memory batches.
#
#   Identity = _mix64(monotonic_id).  `monotonic_id` is a process-global,
#   strictly-increasing, guaranteed-unique per-ctor ID from a C-side atomic
#   counter (`komira_next_inmem_source_id()` in `_posix_shim.c`); `_mix64` is
#   a SplitMix64 finalizer (a bijection — preserves uniqueness).
#
#   - from_record_batch(rb, schema, name=None) + from_record_batches(...).
#   - schema() returns a deep copy.
#   - estimate_rows() sums per-batch _num_rows.
#   - fingerprint():
#       * stable across `value^` move    (LOAD-BEARING).
#       * stable across `value.copy()`   (cache-discrimination contract).
#       * differs between two same-payload constructions.
#       * differs across destroy-then-construct cycles      (allocator reuse
#         must not collide identities — load-bearing).
#       * differs across 10_000 destroy-then-construct cycles (the stronger
#         bulk version of the same contract).
#   - copy() is refcount-bump (no buffer byte-copy).
#   - Schema validation across batches at construction.
#
# Why a counter: a `perf_counter_ns()` differentiator is NOT guaranteed-unique
# (two ctors in the same nanosecond on a fast machine + tcmalloc heap-slot
# reuse collide). Mojo has no module-level mutable globals, hence the C-FFI
# atomic.
# =============================================================================

from std.memory import ArcPointer, UnsafePointer
from std.testing import (
    TestSuite,
    assert_equal,
    assert_true,
    assert_false,
    assert_not_equal,
    assert_raises,
)

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, RecordBatch, Schema, SchemaBuilder
from komira_arrow.primitive_array import PrimitiveArray
from komira_collections.slab import Slab
from komira_scan_source.in_memory_source import InMemorySource


# =============================================================================
# Helpers
# =============================================================================


def _make_1col_int64_schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("c0", ArrowType.INT64, nullable=False))
    return sb.build()


def _make_2col_int64_schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("c0", ArrowType.INT64, nullable=False))
    sb.add_field(Field("c1", ArrowType.INT64, nullable=False))
    return sb.build()


def _build_int64_array(num_rows: Int, seed: Int) -> PrimitiveArray[DType.int64]:
    var vals = List[Int64]()
    for i in range(num_rows):
        vals.append(Int64(seed + i))
    return PrimitiveArray[DType.int64].from_list(vals)


def _build_1col_batch(num_rows: Int, seed: Int) raises -> RecordBatch:
    return RecordBatch.from_columns_1(
        _make_1col_int64_schema(),
        _build_int64_array(num_rows, seed),
    )


def _build_2col_batch(num_rows: Int, seed: Int) raises -> RecordBatch:
    return RecordBatch.from_columns_2(
        _make_2col_int64_schema(),
        _build_int64_array(num_rows, seed),
        _build_int64_array(num_rows, seed + 1000),
    )


# =============================================================================
# Construction
# =============================================================================


def test_in_memory_source_from_record_batch_single() raises:
    """Single-batch convenience factory: schema derived from batch, name
    None default. The structural Schema comes from `batch.schema`."""
    var src = InMemorySource.from_record_batch(
        _build_1col_batch(10, 0),
    )
    assert_equal(src.schema_cached.num_columns(), 1)
    assert_true(src.name is None)
    assert_equal(len(src.data[]), 1)


def test_in_memory_source_from_record_batches_multi() raises:
    """Multi-batch primary ctor with explicit name; schema derived from
    batches[0].schema."""
    var batches = Slab[RecordBatch]()
    batches.append(_build_2col_batch(5, 0))
    batches.append(_build_2col_batch(7, 100))
    batches.append(_build_2col_batch(3, 200))
    var src = InMemorySource.from_record_batches(
        batches^,
        Optional(String("my_table")),
    )
    assert_equal(src.schema_cached.num_columns(), 2)
    assert_true(src.name is not None)
    assert_equal(src.name.value(), String("my_table"))
    assert_equal(len(src.data[]), 3)


def test_in_memory_source_empty_batches_raises() raises:
    """The schema-derivation factory rejects an empty Slab — there is no
    batch to derive the schema from. An "empty relation with a known
    schema" is a 0-row RecordBatch carrying the desired Schema (or
    `from_shared_batches`, which takes an explicit schema)."""
    var batches = Slab[RecordBatch]()
    with assert_raises(contains="zero batches"):
        var _src = InMemorySource.from_record_batches(
            batches^,
        )


def test_in_memory_source_schema_mismatch_raises() raises:
    """Per-batch column-count mismatch vs `batches[0].schema` must raise
    at construction (the schema is derived from `batches[0]`; subsequent
    batches must match its column count)."""
    var batches = Slab[RecordBatch]()
    batches.append(_build_2col_batch(5, 0))  # batches[0]: 2 cols
    batches.append(_build_1col_batch(3, 0))  # batches[1]: 1 col -> mismatch
    with assert_raises(contains="expected 2"):
        var _src = InMemorySource.from_record_batches(
            batches^,
        )


# =============================================================================
# SourceLike trait conformance
# =============================================================================


def test_in_memory_source_schema_returns_copy() raises:
    """schema() returns an independent Schema clone."""
    var src = InMemorySource.from_record_batch(
        _build_1col_batch(3, 0),
    )
    var s1 = src.schema()
    assert_equal(s1.num_columns(), 1)
    # Cached state intact:
    assert_equal(src.schema_cached.num_columns(), 1)
    # Second call returns a fresh independent copy:
    var s2 = src.schema()
    assert_equal(s2.num_columns(), 1)


def test_in_memory_source_estimate_rows_sums_batches() raises:
    """estimate_rows() = sum of per-batch _num_rows."""
    var batches = Slab[RecordBatch]()
    batches.append(_build_1col_batch(11, 0))
    batches.append(_build_1col_batch(13, 100))
    batches.append(_build_1col_batch(17, 200))
    var src = InMemorySource.from_record_batches(
        batches^,
    )
    assert_equal(src.estimate_rows(), 41)


# =============================================================================
# Fingerprint — stability + discrimination
# =============================================================================


def test_in_memory_source_fingerprint_stable_across_move() raises:
    """LOAD-BEARING: identity is preserved
    across `value^` move because it's a stored field, not recomputed.

    This is the cache-discrimination contract: a DataFrame that has been
    moved into a different scope (e.g. into a ctx.materialize call) must
    still hash to the same plan-cache slot.
    """
    var src = InMemorySource.from_record_batch(
        _build_1col_batch(8, 0),
    )
    var fp_pre = src.fingerprint()
    var src2 = src^
    var fp_post = src2.fingerprint()
    assert_equal(fp_pre, fp_post)


def test_in_memory_source_fingerprint_stable_across_copy() raises:
    """src.copy().fingerprint() == src.fingerprint() — the explicit-clone
    arm of the cache-discrimination contract. Refcount-bump on Arc; the
    `_identity` field is forwarded via _with_preserved_identity."""
    var src = InMemorySource.from_record_batch(
        _build_1col_batch(8, 0),
        Optional(String("a_name")),
    )
    var fp_pre = src.fingerprint()
    var src2 = src.copy()
    var fp_post = src2.fingerprint()
    assert_equal(fp_pre, fp_post)


def test_in_memory_source_fingerprint_distinct_same_payload() raises:
    """Two simultaneously-live InMemorySources built from identical-payload
    batches must hash to DIFFERENT identities — each ctor draws a fresh,
    guaranteed-unique monotonic ID, so even byte-for-byte identical payloads
    (and even a reused heap address) produce distinct fingerprints."""
    var a = InMemorySource.from_record_batch(
        _build_1col_batch(4, 7),
    )
    var b = InMemorySource.from_record_batch(
        _build_1col_batch(4, 7),
    )
    assert_not_equal(a.fingerprint(), b.fingerprint())


def test_in_memory_source_fingerprint_allocator_reuse_distinct() raises:
    """Allocator-reuse test (LOAD-BEARING):
    construct A, drop A, construct B (tcmalloc may reuse A's heap slot).
    A's identity must NOT equal B's identity. Each ctor draws a fresh,
    guaranteed-unique monotonic ID from the process-global atomic counter,
    so full address reuse — and even same-nanosecond construction on a fast
    machine — cannot collide them. (A `perf_counter_ns()` differentiator
    collides under exactly this pattern.)

    Rapid-fire 8-cycle construction simulates worst-case allocator reuse;
    all 8 identities must be pairwise distinct. (See the 10_000-cycle bulk
    test below for a stronger version of the same contract.)
    """
    var ids = List[UInt64]()
    for i in range(8):
        var s = InMemorySource.from_record_batch(
            _build_1col_batch(4, i),
        )
        ids.append(s.fingerprint())
        # `s` drops at end of this loop iteration — heap slot may be reused.
    # Pairwise-distinctness check:
    var n = len(ids)
    for i in range(n):
        for j in range(i + 1, n):
            assert_not_equal(
                ids[i],
                ids[j],
                "allocator-reuse collision: ids["
                + String(i) + "] == ids[" + String(j)
                + "] — the monotonic ID failed to differentiate.",
            )


def test_in_memory_source_fingerprint_distinct_bulk_10k() raises:
    """Stronger version of the allocator-reuse contract: construct 10_000
    InMemorySources from distinct single-row batches (each going out of scope
    before the next, so tcmalloc reuses the same heap slot repeatedly) and
    assert all 10_000 fingerprints are distinct. A `perf_counter_ns()`
    differentiator collides here on a fast machine; with the process-global
    monotonic counter (finalized through `_mix64`, a bijection) every
    fingerprint is unique by construction. This also guards against
    XOR-folding the Arc heap address into the hash, which collides within a
    few dozen iterations (XOR of a varying address with the monotonic ID is
    not collision-free).
    """
    var seen = Dict[UInt64, Bool]()
    var n_iters = 10_000
    for i in range(n_iters):
        var s = InMemorySource.from_record_batch(
            _build_1col_batch(1, i),
        )
        var fp = s.fingerprint()
        assert_false(
            fp in seen,
            "duplicate InMemorySource fingerprint at iteration " + String(i),
        )
        seen[fp] = True
        # `s` drops at end of this iteration — heap slot may be reused.
    assert_equal(len(seen), n_iters)


def test_in_memory_source_fingerprint_ignores_name() raises:
    """The optional `name` field is debug-only and MUST NOT contribute to
    fingerprint. Two InMemorySources with the SAME underlying ArcPointer
    payload (one shared via copy) and DIFFERENT names should fingerprint
    identically — but in practice copy() preserves identity AND name doesn't
    enter the hash, so we verify name-ignorance via copy-then-name-mutate
    isn't possible. Instead we assert that the same source's fingerprint
    is unaffected by its name slot's content.

    (Cross-construction name comparison cannot be done because two ctors
    always produce different identities by design — see the
    same-payload test above.)
    """
    var unnamed = InMemorySource.from_record_batch(
        _build_1col_batch(3, 0),
    )
    var fp = unnamed.fingerprint()
    var clone_renamed = unnamed.copy()
    # Replace name on the clone; fingerprint must remain unchanged.
    clone_renamed.name = Optional(String("after_copy_rename"))
    assert_equal(fp, clone_renamed.fingerprint())


# =============================================================================
# copy() — independence + identity preservation
# =============================================================================


def test_in_memory_source_copy_preserves_fields() raises:
    """copy() preserves schema column count + name + identity. Data is
    Arc-shared, so payload equality is by-reference (same Arc). A single
    2-col batch is the simplest payload to copy."""
    var batches = Slab[RecordBatch]()
    batches.append(_build_2col_batch(1, 0))
    var src = InMemorySource.from_record_batches(
        batches^,
        Optional(String("t1")),
    )
    var src2 = src.copy()
    assert_equal(src.schema_cached.num_columns(), src2.schema_cached.num_columns())
    assert_true(src2.name is not None)
    assert_equal(src.name.value(), src2.name.value())
    assert_equal(src._identity, src2._identity)
    # Re-cloning preserves identity through the chain:
    var src3 = src2.copy()
    assert_equal(src._identity, src3._identity)


def test_in_memory_source_copy_name_none_preserved() raises:
    """copy() preserves None on the optional name field."""
    var src = InMemorySource.from_record_batch(
        _build_1col_batch(2, 0),
    )
    var src2 = src.copy()
    assert_true(src2.name is None)


# =============================================================================
# Suite
# =============================================================================


# =============================================================================
# from_shared_batches — wrap an Arc somebody else already holds
# =============================================================================


def test_in_memory_source_from_shared_batches_shares_the_arc() raises:
    """The Arc is SHARED, not copied: the source's `data` and the caller's
    handle are the same allocation, and the identity is still a fresh
    per-construction token."""
    var sl = Slab[RecordBatch].create(2)
    sl.append(_build_1col_batch(4, 0))
    sl.append(_build_1col_batch(3, 100))
    var held = ArcPointer[Slab[RecordBatch]](sl^)
    var a = InMemorySource.from_shared_batches(
        held.copy(), _make_1col_int64_schema()
    )
    var b = InMemorySource.from_shared_batches(
        held.copy(), _make_1col_int64_schema()
    )
    assert_equal(a.estimate_rows(), 7)
    assert_true(
        Int(UnsafePointer(to=a.data[])) == Int(UnsafePointer(to=held[])),
        "the source wraps the caller's allocation, no batch copy",
    )
    assert_not_equal(
        a.fingerprint(),
        b.fingerprint(),
        "the same bytes wrapped twice are two sources",
    )


def test_in_memory_source_from_shared_batches_zero_batches_is_empty() raises:
    """The schema is explicit, so zero batches is a legal empty relation."""
    var held = ArcPointer[Slab[RecordBatch]](Slab[RecordBatch].create(0))
    var src = InMemorySource.from_shared_batches(
        held^, _make_2col_int64_schema(), Optional[String](String("empty"))
    )
    assert_equal(src.schema_cached.num_columns(), 2)
    assert_equal(src.estimate_rows(), 0)


def test_in_memory_source_from_shared_batches_column_mismatch_raises() raises:
    var sl = Slab[RecordBatch].create(1)
    sl.append(_build_1col_batch(2, 0))
    var held = ArcPointer[Slab[RecordBatch]](sl^)
    with assert_raises(contains="from_shared_batches"):
        _ = InMemorySource.from_shared_batches(
            held^, _make_2col_int64_schema()
        )


def main() raises:
    var suite = TestSuite()
    # Construction
    suite.test[test_in_memory_source_from_record_batch_single]()
    suite.test[test_in_memory_source_from_record_batches_multi]()
    suite.test[test_in_memory_source_empty_batches_raises]()
    suite.test[test_in_memory_source_schema_mismatch_raises]()
    # Trait conformance
    suite.test[test_in_memory_source_schema_returns_copy]()
    suite.test[test_in_memory_source_estimate_rows_sums_batches]()
    # Fingerprint
    suite.test[test_in_memory_source_fingerprint_stable_across_move]()
    suite.test[test_in_memory_source_fingerprint_stable_across_copy]()
    suite.test[test_in_memory_source_fingerprint_distinct_same_payload]()
    suite.test[test_in_memory_source_fingerprint_allocator_reuse_distinct]()
    suite.test[test_in_memory_source_fingerprint_distinct_bulk_10k]()
    suite.test[test_in_memory_source_fingerprint_ignores_name]()
    # copy()
    suite.test[test_in_memory_source_copy_preserves_fields]()
    suite.test[test_in_memory_source_copy_name_none_preserved]()
    # from_shared_batches()
    suite.test[test_in_memory_source_from_shared_batches_shares_the_arc]()
    suite.test[test_in_memory_source_from_shared_batches_zero_batches_is_empty]()
    suite.test[test_in_memory_source_from_shared_batches_column_mismatch_raises]()
    suite^.run()

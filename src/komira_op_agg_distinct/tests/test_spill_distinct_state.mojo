# =============================================================================
# test_spill_distinct_state.mojo — DistinctState SpillableOp round-trip.
# =============================================================================
#
# Proves the landed spill codecs + storage (THSPLC column codec +
# FileSystemSpillStorage[LocalFs]) against a REAL column breaker's state:
# the variadic `DistinctState[*Keys]` now conforms `SpillableOp`.
#
# Round-trip shape:
#   (1) Build a DistinctState with N input rows (composite I64 + I64 keys,
#       feeding via the public `feed_row` BreakerState surface over a BatchView).
#       The input deliberately contains DUPLICATE key tuples so the dedup set is
#       exercised; the resident image is the DEDUPED set in insertion order.
#   (2) Capture the un-spilled REFERENCE distinct drain.
#   (3) `spill_to_storage` the set -> its key columns + dedup directory empty
#       (memory_usage_bytes drops, num_live_chunks == 1).
#   (4) `restore_from_storage` into the SAME set -> re-feeds the deduped image
#       through the dedup path, rebuilding the dedup directory + n_used.
#   (5) Assert the restored set's distinct drain is LOGICALLY IDENTICAL to the
#       reference: same multiset of distinct key tuples, same insertion order.
#
# Also exercises:
#   * can_spill() True before spill, after restore.
#   * spill-then-restore-then-spill-again (multi-pass chunk lifecycle).
#   * empty set round-trip (0-row spill image).
#   * single-key shape (the canonical single-key DISTINCT).
#
# Key coverage: the round-trips below use fixed-width INT64 keys, plus one
# composite (INT64, STRING) round-trip. `DistinctState` stores values only, no
# validity, and rejects NULL keys in `feed_row`; the spill image therefore
# never carries NULLs.
#
# Restore order: a restore re-feeds the spilled rows into whatever is
# resident, so rows fed after a spill come first and restored rows follow;
# the dedup is what the multi-batch tests pin, not a global order.
#
# Encapsulation: tests use ONLY the public surface — no UnsafePointer, no
# wildcard origin, no unsafe_from_address.
# =============================================================================

from std.collections import Set
from std.ffi import external_call
from std.memory import bitcast
from std.os import abort
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_arrow.schema import (
    ArrowType,
    Field,
    RecordBatch,
    RecordBatchBuilder,
    SchemaBuilder,
)
from komira_arrow.batch_view import BatchView

from komira_op_agg_distinct.distinct_key_column import (
    DISTINCT_FNV_OFFSET,
    DISTINCT_FNV_PRIME,
)
from komira_op_agg_distinct.distinct_key_column_string import (
    DistinctKeyColumn_String,
)
from komira_op_agg_distinct.distinct_state import (
    DistinctKeyColumn_Typed,
    DistinctState,
)
from komira_engine_runtime.spill.local_disk import LocalDiskSpillStorage
from komira_libc.posix import _read_env


# ---------------------------------------------------------------------------
# $TEST_TMPDIR (or $TMPDIR) names this execution's scratch directory.
#
# More than one execution of a welded test can run on one worker at a time, so
# each needs its own directory. The gate runner
# (`tools/build/mojo/gate_runner.sh`) gives each execution its own empty
# `TEST_TMPDIR` (equal to `TMPDIR`). When neither variable is set the test
# aborts instead of writing to a shared fixed path.
#
# `_read_env`, not `std.os.getenv`: Mojo's MLIR FFI legalization allows at most
# ONE `getenv` declaration per link unit and `komira_libc.posix` is the
# canonical one.
# ---------------------------------------------------------------------------
def _scratch_dir() -> String:
    """The directory THIS execution may write scratch files into."""
    var d = _read_env("TEST_TMPDIR")
    if d.byte_length() == 0:
        d = _read_env("TMPDIR")
    if d.byte_length() == 0:
        abort(
            "test_spill_distinct_state: set TEST_TMPDIR or TMPDIR to a"
            " scratch directory"
        )
    return d


# Single Int64-key set + composite (I64 @0, I64 @1) set.
comptime _K0_I64 = DistinctKeyColumn_Typed[DType.int64, 0]
comptime _K1_I64 = DistinctKeyColumn_Typed[DType.int64, 1]
comptime _DistinctI64 = DistinctState[_K0_I64]
comptime _DistinctI64I64 = DistinctState[_K0_I64, _K1_I64]


# -----------------------------------------------------------------------------
# Fixture helpers
# -----------------------------------------------------------------------------


def _temp_root(tag: String) raises -> String:
    """A unique dir under this execution's scratch dir for one test."""
    var pid = external_call["getpid", Int32]()
    return (
        (_scratch_dir() + String("/komira-spill-distinct-"))
        + String(Int(pid))
        + String("-")
        + tag
    )


def _make_2key_batch(
    k0: List[Int64], k1: List[Int64]
) raises -> RecordBatch:
    """Build a 2-column (k0: Int64 @0, k1: Int64 @1) RecordBatch."""
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k0"), ArrowType.INT64, False))
    sb.add_field(Field(String("k1"), ArrowType.INT64, False))
    var schema = sb.build()
    var l0: List[Scalar[DType.int64]] = []
    var l1: List[Scalar[DType.int64]] = []
    for i in range(len(k0)):
        l0.append(k0[i])
        l1.append(k1[i])
    var c0 = Column.from_primitive[DType.int64](
        PrimitiveArray[DType.int64].from_list(l0)
    )
    var c1 = Column.from_primitive[DType.int64](
        PrimitiveArray[DType.int64].from_list(l1)
    )
    return RecordBatch.from_typed_columns_2(schema^, c0^, c1^)


def _make_1key_batch(keys: List[Int64]) raises -> RecordBatch:
    """Build a 1-column (k0: Int64 @0) RecordBatch."""
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k0"), ArrowType.INT64, False))
    var schema = sb.build()
    var l0: List[Scalar[DType.int64]] = []
    for i in range(len(keys)):
        l0.append(keys[i])
    var c0 = Column.from_primitive[DType.int64](
        PrimitiveArray[DType.int64].from_list(l0)
    )
    return RecordBatch.from_typed_columns_1(schema^, c0^)


# The composite fixture rows. Deliberately include:
#   * duplicate (k0,k1) tuples — (1,1) x3, (1,2) x2 — that MUST collapse.
#   * a key0-shared-but-key1-differs pair (1,1) vs (1,2) that must NOT collapse.
#   * negatives + zero.
# Expected distinct set in insertion order:
#   (1,1), (1,2), (2,1), (-3,7), (0,0)
def _composite_k0() -> List[Int64]:
    return [1, 1, 1, 2, 1, -3, 0, -3, 1]


def _composite_k1() -> List[Int64]:
    return [1, 2, 1, 1, 2, 7, 0, 7, 1]


comptime _COMPOSITE_DISTINCT_N: Int = 5


def _feed_batch_2key(mut state: _DistinctI64I64, batch: RecordBatch) raises:
    """Feed every row of a 2-key batch through the public `feed_row` surface."""
    var n = batch.num_rows()
    var bv = BatchView(batch)
    for r in range(n):
        state.feed_row(bv, r)


def _feed_batch_1key(mut state: _DistinctI64, batch: RecordBatch) raises:
    """Feed every row of a 1-key batch through the public `feed_row` surface."""
    var n = batch.num_rows()
    var bv = BatchView(batch)
    for r in range(n):
        state.feed_row(bv, r)


# -----------------------------------------------------------------------------
# Drain-equivalence helpers: compare the distinct drain of two states.
# -----------------------------------------------------------------------------


def _assert_drain_equal_2key(
    mut a: _DistinctI64I64, mut b: _DistinctI64I64
) raises:
    """Assert states `a` and `b` produce LOGICALLY IDENTICAL distinct drains:
    same row count, and for each insertion position the same (k0, k1) tuple."""
    var oa_opt = a.drain_to_record_batch()
    var ob_opt = b.drain_to_record_batch()
    var oa = oa_opt.take()
    var ob = ob_opt.take()
    assert_equal(oa.num_rows(), ob.num_rows(), "distinct row-count mismatch")
    assert_equal(oa.num_columns(), 2, "expected 2 key columns")
    assert_equal(ob.num_columns(), 2, "expected 2 key columns")
    var a0 = oa.column_as_primitive_int64(0)
    var a1 = oa.column_as_primitive_int64(1)
    var b0 = ob.column_as_primitive_int64(0)
    var b1 = ob.column_as_primitive_int64(1)
    for r in range(oa.num_rows()):
        assert_equal(
            a0.load[1](r)[0],
            b0.load[1](r)[0],
            "k0 mismatch at insertion pos " + String(r),
        )
        assert_equal(
            a1.load[1](r)[0],
            b1.load[1](r)[0],
            "k1 mismatch at insertion pos " + String(r),
        )


def _assert_drain_equal_1key(mut a: _DistinctI64, mut b: _DistinctI64) raises:
    """Assert single-key states `a` and `b` produce logically identical drains."""
    var oa_opt = a.drain_to_record_batch()
    var ob_opt = b.drain_to_record_batch()
    var oa = oa_opt.take()
    var ob = ob_opt.take()
    assert_equal(oa.num_rows(), ob.num_rows(), "distinct row-count mismatch")
    var a0 = oa.column_as_primitive_int64(0)
    var b0 = ob.column_as_primitive_int64(0)
    for r in range(oa.num_rows()):
        assert_equal(
            a0.load[1](r)[0],
            b0.load[1](r)[0],
            "k0 mismatch at insertion pos " + String(r),
        )


# =============================================================================
# Test 1 — composite round-trip: spill empties the set; restore reproduces drain.
# =============================================================================


def test_distinct_state_spill_restore_roundtrip() raises:
    var root = _temp_root("roundtrip")
    var storage = LocalDiskSpillStorage.with_unlimited(root)

    # Reference set (never spilled).
    var ref_set = _DistinctI64I64(Tuple(_K0_I64.new(16), _K1_I64.new(16)))
    _feed_batch_2key(ref_set, _make_2key_batch(_composite_k0(), _composite_k1()))
    assert_equal(
        ref_set.size(), _COMPOSITE_DISTINCT_N, "fixture distinct count"
    )

    # Subject set (same shape) that we will spill + restore.
    var subj = _DistinctI64I64(Tuple(_K0_I64.new(16), _K1_I64.new(16)))
    _feed_batch_2key(subj, _make_2key_batch(_composite_k0(), _composite_k1()))

    # Pre-spill: resident, spillable, no chunks yet.
    assert_true(subj.can_spill(), "fresh set should be spillable")
    assert_true(
        subj.memory_usage_bytes() > Int64(0), "non-empty set has bytes"
    )
    assert_equal(storage.num_live_chunks(), 0, "no chunks before spill")

    # Spill: writes one THSPLC chunk + frees the in-memory buffers.
    var freed = subj.spill_to_storage(storage)
    assert_true(freed > Int64(0), "spill freed bytes")
    assert_equal(storage.num_live_chunks(), 1, "one live chunk after spill")
    assert_equal(subj.size(), 0, "set empty after spill")
    assert_equal(
        subj.memory_usage_bytes(), Int64(0), "no resident bytes after spill"
    )

    # Restore into the SAME subject: re-feeds the deduped image, rebuilding the
    # dedup directory + n_used.
    subj.restore_from_storage(storage)
    assert_true(subj.can_spill(), "restored set spillable again")
    assert_equal(subj.size(), _COMPOSITE_DISTINCT_N, "distinct count restored")
    assert_equal(
        storage.num_live_chunks(),
        0,
        "chunk released after successful restore",
    )

    # The restored set's distinct drain must match the un-spilled reference,
    # including the insertion order.
    _assert_drain_equal_2key(ref_set, subj)

    storage.cleanup()


# =============================================================================
# Test 2 — spill -> restore -> spill again (multi-pass chunk lifecycle).
# =============================================================================


def test_distinct_state_spill_restore_spill_again() raises:
    var root = _temp_root("twopass")
    var storage = LocalDiskSpillStorage.with_unlimited(root)

    var ref_set = _DistinctI64I64(Tuple(_K0_I64.new(16), _K1_I64.new(16)))
    _feed_batch_2key(ref_set, _make_2key_batch(_composite_k0(), _composite_k1()))

    var subj = _DistinctI64I64(Tuple(_K0_I64.new(16), _K1_I64.new(16)))
    _feed_batch_2key(subj, _make_2key_batch(_composite_k0(), _composite_k1()))

    # Pass 1.
    _ = subj.spill_to_storage(storage)
    assert_equal(storage.num_live_chunks(), 1, "pass-1 chunk live")
    subj.restore_from_storage(storage)
    assert_equal(storage.num_live_chunks(), 0, "pass-1 chunk released")
    _assert_drain_equal_2key(ref_set, subj)

    # Pass 2 — re-spill the restored set + restore once more.
    var freed2 = subj.spill_to_storage(storage)
    assert_true(freed2 > Int64(0), "pass-2 spill freed bytes")
    assert_equal(storage.num_live_chunks(), 1, "pass-2 chunk live")
    subj.restore_from_storage(storage)
    assert_equal(storage.num_live_chunks(), 0, "pass-2 chunk released")
    _assert_drain_equal_2key(ref_set, subj)

    storage.cleanup()


# =============================================================================
# Test 3 — single-key round-trip (the canonical single-key DISTINCT).
# =============================================================================


def test_distinct_state_spill_restore_single_key() raises:
    var root = _temp_root("single")
    var storage = LocalDiskSpillStorage.with_unlimited(root)

    var keys: List[Int64] = [10, 20, 10, 20, 30, 10, -5, 0, 30]
    # Expected distinct set in insertion order: 10, 20, 30, -5, 0.

    var ref_set = _DistinctI64(Tuple(_K0_I64.new(16)))
    _feed_batch_1key(ref_set, _make_1key_batch(keys))
    assert_equal(ref_set.size(), 5, "single-key distinct count")

    var subj = _DistinctI64(Tuple(_K0_I64.new(16)))
    _feed_batch_1key(subj, _make_1key_batch(keys))

    var freed = subj.spill_to_storage(storage)
    assert_true(freed > Int64(0), "single-key spill freed bytes")
    assert_equal(subj.size(), 0, "set empty after spill")

    subj.restore_from_storage(storage)
    assert_equal(subj.size(), 5, "single-key distinct count restored")
    _assert_drain_equal_1key(ref_set, subj)

    storage.cleanup()


# =============================================================================
# Test 4 — empty set round-trip (0-row spill image).
# =============================================================================


def test_distinct_state_spill_restore_empty() raises:
    var root = _temp_root("empty")
    var storage = LocalDiskSpillStorage.with_unlimited(root)

    var subj = _DistinctI64I64(Tuple(_K0_I64.new(16), _K1_I64.new(16)))
    assert_equal(subj.size(), 0, "empty to start")
    assert_equal(
        subj.memory_usage_bytes(), Int64(0), "empty set has no bytes"
    )

    var freed = subj.spill_to_storage(storage)
    assert_equal(freed, Int64(0), "empty spill frees 0 bytes")
    assert_equal(storage.num_live_chunks(), 1, "empty chunk still written")

    subj.restore_from_storage(storage)
    assert_equal(subj.size(), 0, "still empty after restore")
    assert_equal(storage.num_live_chunks(), 0, "empty chunk released")

    storage.cleanup()


# =============================================================================
# Test 5 — many distinct keys, duplicates across batches and across the spill.
# =============================================================================
#
# The restore re-feeds 30k+ rows into an empty state, which grows the dedup
# directory several times; keys fed after the spill are resident, so the
# restore must drop the spilled rows that repeat them.


def _stepped_mod(n: Int, mult: Int, modulus: Int) -> List[Int64]:
    var out = List[Int64](capacity=n)
    for i in range(n):
        out.append(Int64((i * mult) % modulus))
    return out^


def _drained_1key(mut st: _DistinctI64) raises -> List[Int64]:
    var out = List[Int64]()
    var drained = st.drain_to_record_batch()
    var rb = drained.take()
    var col = rb.column_as_primitive_int64(0)
    for r in range(rb.num_rows()):
        out.append(col.load[1](r)[0])
    return out^


def test_distinct_state_spill_restore_many_keys_with_duplicates() raises:
    var root = _temp_root("many")
    var storage = LocalDiskSpillStorage.with_unlimited(root)

    # Batches 1 and 2 overlap each other; batch 3 (fed after the spill)
    # repeats part of what was spilled and adds keys of its own.
    var b1 = _stepped_mod(40_000, 7, 50_021)
    var b2 = _stepped_mod(40_000, 11, 50_021)
    var b3 = _stepped_mod(30_000, 13, 70_001)

    var subj = _DistinctI64(Tuple(_K0_I64.new(16)))
    _feed_batch_1key(subj, _make_1key_batch(b1))
    _feed_batch_1key(subj, _make_1key_batch(b2))
    var resident_before = subj.size()
    assert_true(resident_before > 20_000, "enough keys to grow the directory")
    _ = subj.spill_to_storage(storage)
    assert_equal(subj.size(), 0, "empty after spill")
    _feed_batch_1key(subj, _make_1key_batch(b3))

    # Expected: b3's distinct keys first (resident), then the spilled keys
    # that b3 did not repeat, each once, in spilled order.
    var want = List[Int64]()
    var seen = Set[Int64]()
    for i in range(len(b3)):
        if b3[i] not in seen:
            seen.add(b3[i])
            want.append(b3[i])
    var spilled = List[Int64]()
    var spilled_seen = Set[Int64]()
    for i in range(len(b1)):
        if b1[i] not in spilled_seen:
            spilled_seen.add(b1[i])
            spilled.append(b1[i])
    for i in range(len(b2)):
        if b2[i] not in spilled_seen:
            spilled_seen.add(b2[i])
            spilled.append(b2[i])
    assert_equal(len(spilled), resident_before, "spilled image size")
    for i in range(len(spilled)):
        if spilled[i] not in seen:
            seen.add(spilled[i])
            want.append(spilled[i])

    subj.restore_from_storage(storage)
    assert_equal(subj.size(), len(want), "distinct count after restore")
    var got = _drained_1key(subj)
    assert_equal(len(got), len(want), "drained rows")
    for i in range(len(want)):
        if got[i] != want[i]:
            assert_equal(got[i], want[i], "row " + String(i))

    # The restored directory still dedups: feeding everything again adds none.
    _feed_batch_1key(subj, _make_1key_batch(b1))
    _feed_batch_1key(subj, _make_1key_batch(b3))
    assert_equal(subj.size(), len(want), "no new rows on re-feed")

    storage.cleanup()


# =============================================================================
# Test 6 — composite (INT64, STRING) key round-trip.
# =============================================================================

comptime _K1_STR = DistinctKeyColumn_String[1]
comptime _DistinctI64Str = DistinctState[_K0_I64, _K1_STR]


def _make_i64_str_batch(
    k: List[Int64], v: List[String]
) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), ArrowType.INT64, False))
    sb.add_field(Field(String("s"), ArrowType.STRING, False))
    var rb = RecordBatchBuilder()
    rb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(k)
        )
    )
    rb.add_column(Column.from_string(StringArray.from_strings(v)))
    return rb.build(sb.build())


def _feed_batch_i64_str(mut st: _DistinctI64Str, b: RecordBatch) raises:
    var bv = BatchView(b)
    for r in range(b.num_rows()):
        st.feed_row(bv, r)


def test_distinct_state_spill_restore_string_key() raises:
    var root = _temp_root("string")
    var storage = LocalDiskSpillStorage.with_unlimited(root)

    var k: List[Int64] = [1, 1, 1, 2, 1, 3, 3, 3]
    var v: List[String] = ["a", "b", "a", "a", "", "ÄÖÜ", "ÄÖ", "ÄÖÜ"]
    # Distinct pairs in insertion order:
    # (1,a) (1,b) (2,a) (1,"") (3,ÄÖÜ) (3,ÄÖ).
    var st = _DistinctI64Str()
    _feed_batch_i64_str(st, _make_i64_str_batch(k, v))
    assert_equal(st.size(), 6, "six distinct pairs")
    var freed = st.spill_to_storage(storage)
    assert_true(freed > Int64(0), "spill freed bytes")
    assert_equal(st.size(), 0, "empty after spill")

    # A pair seen again after the spill is resident; the restore must not
    # duplicate it.
    var k2: List[Int64] = [3, 9]
    var v2: List[String] = ["ÄÖ", "z"]
    _feed_batch_i64_str(st, _make_i64_str_batch(k2, v2))
    st.restore_from_storage(storage)
    assert_equal(st.size(), 7, "six spilled pairs plus (9, z)")

    var drained = st.drain_to_record_batch()
    var rb = drained.take()
    var kc = rb.column_at(0).as_primitive[DType.int64]()
    var sc = rb.column_at(1).as_string()
    var wk: List[Int64] = [3, 9, 1, 1, 2, 1, 3]
    var ws: List[String] = ["ÄÖ", "z", "a", "b", "a", "", "ÄÖÜ"]
    assert_equal(rb.num_rows(), 7, "drained rows")
    for i in range(7):
        assert_equal(kc.get(i), wk[i], "k of row " + String(i))
        assert_equal(sc.get(i), ws[i], "s of row " + String(i))

    storage.cleanup()


# =============================================================================
# Test 7 — keys with one combined hash survive a spill and restore.
# =============================================================================


def _bits(v: Int64) -> UInt64:
    return bitcast[DType.uint64, 1](SIMD[DType.int64, 1](v))[0]


def _colliding_second_key(a: Int64, b: Int64, a2: Int64) -> Int64:
    """The `b2` for which `(a2, b2)` has the same combined FNV-1a hash as
    `(a, b)` (the hash of `(x, y)` is `((OFFSET ^ x) * PRIME ^ y) * PRIME`)."""
    var inner = (DISTINCT_FNV_OFFSET ^ _bits(a)) * DISTINCT_FNV_PRIME
    var inner2 = (DISTINCT_FNV_OFFSET ^ _bits(a2)) * DISTINCT_FNV_PRIME
    var u = inner ^ _bits(b) ^ inner2
    return bitcast[DType.int64, 1](SIMD[DType.uint64, 1](u))[0]


def test_distinct_state_spill_restore_keys_with_identical_hashes() raises:
    var root = _temp_root("collide")
    var storage = LocalDiskSpillStorage.with_unlimited(root)

    var b1 = _colliding_second_key(1, 2, 3)
    var k0: List[Int64] = [1, 3, 1, 3]
    var k1: List[Int64] = [2, b1, 2, b1]
    var st = _DistinctI64I64(Tuple(_K0_I64.new(16), _K1_I64.new(16)))
    _feed_batch_2key(st, _make_2key_batch(k0, k1))
    assert_equal(st.size(), 2, "two distinct keys with one hash")
    _ = st.spill_to_storage(storage)
    st.restore_from_storage(storage)
    assert_equal(st.size(), 2, "both survive the round-trip")
    # Feeding them again adds nothing; a third colliding key adds one.
    _feed_batch_2key(st, _make_2key_batch(k0, k1))
    assert_equal(st.size(), 2, "re-fed keys deduped")
    var b2 = _colliding_second_key(1, 2, 9)
    var k0c: List[Int64] = [9]
    var k1c: List[Int64] = [b2]
    _feed_batch_2key(st, _make_2key_batch(k0c, k1c))
    assert_equal(st.size(), 3, "a third key with the same hash is new")

    storage.cleanup()


# =============================================================================
# Test 8 — a failed restore leaves the state restorable.
# =============================================================================


def test_distinct_state_failed_restore_can_be_retried() raises:
    var storage = LocalDiskSpillStorage.with_unlimited(
        _temp_root("retry_a")
    )
    var other = LocalDiskSpillStorage.with_unlimited(_temp_root("retry_b"))

    var subj = _DistinctI64(Tuple(_K0_I64.new(16)))
    var keys: List[Int64] = [4, 8, 4, 15]
    _feed_batch_1key(subj, _make_1key_batch(keys))
    _ = subj.spill_to_storage(storage)

    # `other` never wrote the chunk, so reading it raises.
    var raised = False
    try:
        subj.restore_from_storage(other)
    except:
        raised = True
    assert_true(raised, "restore from the wrong storage raises")
    assert_true(subj.can_spill(), "a failed restore leaves the state spillable")

    subj.restore_from_storage(storage)
    assert_equal(subj.size(), 3, "the retry restores every spilled row")
    assert_equal(storage.num_live_chunks(), 0, "chunk released")

    storage.cleanup()
    other.cleanup()


# =============================================================================
# Test 9 — spilled rows are never silently dropped.
# =============================================================================


def test_distinct_state_spilled_rows_block_drain_and_combine() raises:
    var storage = LocalDiskSpillStorage.with_unlimited(_temp_root("blocked"))

    var keys: List[Int64] = [4, 8, 15]
    var subj = _DistinctI64(Tuple(_K0_I64.new(16)))
    _feed_batch_1key(subj, _make_1key_batch(keys))
    _ = subj.spill_to_storage(storage)

    var drain_raised = False
    try:
        _ = subj.drain_to_record_batch()
    except:
        drain_raised = True
    assert_true(drain_raised, "drain with unrestored spilled rows raises")

    var host = _DistinctI64(Tuple(_K0_I64.new(16)))
    var combine_raised = False
    try:
        host.combine(subj^)
    except:
        combine_raised = True
    assert_true(combine_raised, "combining a spilled state raises")

    storage.cleanup()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

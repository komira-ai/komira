# =============================================================================
# test_spill_distinct_state.mojo — SPILL-U-4a2 DistinctState SpillableOp round-trip.
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
#   (3) `spill_to_storage` the set -> its key columns + hash filter empty
#       (memory_usage_bytes drops, num_live_chunks == 1).
#   (4) `restore_from_storage` into the SAME set -> re-feeds the deduped image
#       through the dedup path, rebuilding the hash filter + n_used.
#   (5) Assert the restored set's distinct drain is LOGICALLY IDENTICAL to the
#       reference: same multiset of distinct key tuples, same insertion order.
#
# Also exercises:
#   * can_spill() True before spill, after restore.
#   * spill-then-restore-then-spill-again (multi-pass chunk lifecycle).
#   * empty set round-trip (0-row spill image).
#   * single-key shape (the canonical v0.4 GA single-key DISTINCT).
#
# WHY DistinctState keys are all fixed-width numeric (NOT string/varlen + nulls):
#   DistinctState's state stores keys as native `Scalar[dt]` SoA columns
#   (int64/int32/float64/float32) — it has NO string-key or null-key storage at
#   the breaker-state level. So this round-trip exercises the THSPLC FIXED-WIDTH
#   primitive path. The varlen/null THSPLC paths are covered by the THSPLC
#   codec's own tests; the substance HERE is the real-operator
#   state<->RecordBatch gather/rebuild, plus the dedup-filter rebuild on restore.
#
# Encapsulation: tests use ONLY the public surface — no UnsafePointer, no
# wildcard origin, no unsafe_from_address.
# =============================================================================

from std.ffi import external_call
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    ArrowType,
    Field,
    RecordBatch,
    SchemaBuilder,
)
from komira_arrow.batch_view import BatchView

from komira_op_agg_distinct.distinct_state import (
    DistinctKeyColumn_Typed,
    DistinctState,
)
from komira_engine_runtime.spill.local_disk import LocalDiskSpillStorage
from komira_libc.posix import _read_env


# ---------------------------------------------------------------------------
# ⚠ $TEST_TMPDIR, NOT A HARD-CODED `/tmp` PATH.
#
# A gated test is executed by MORE THAN ONE build action at a time (its
# library's own gate and //tools/release_gates each declare a marker, and
# `test_gate.bzl`'s dedup is package-scoped), on one worker, with `no-sandbox`.
# A fixed `/tmp` path is shared by every one of those executions and no
# `TMPDIR`/`TEST_TMPDIR` the runner sets can redirect it. `TEST_TMPDIR` is
# unique per action under both `bazel test` and `test_gate_runner.sh`, which is
# what makes them disjoint.
#
# Written by `scripts/check_gated_test_scratch_paths.py --fix`; that script is
# the single definition and `pixi run lint` keeps the literal from coming back.
#
# ⚠ `_read_env`, NOT `std.os.getenv` — Mojo's MLIR FFI legalization allows at
# most ONE `getenv` declaration per link unit and `komira_libc.posix` is
# the canonical one.
# ---------------------------------------------------------------------------
def _scratch_dir() -> String:
    """The directory THIS execution may write scratch files into."""
    var d = _read_env("TEST_TMPDIR")
    if d.byte_length() == 0:
        d = _read_env("TMPDIR")
    if d.byte_length() == 0:
        return String("/tmp")
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
    """A unique temp dir under /tmp for this test invocation."""
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
    # hash filter + n_used.
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
# Test 3 — single-key round-trip (the canonical v0.4 GA single-key DISTINCT).
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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

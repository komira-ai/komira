# =============================================================================
# test_join_key_dtype_exact -- the batch-row key path reads, hashes, compares
# and stores each key at its own DType
# =============================================================================
#
# Drives `KeyBundleVar.build_insert_row` / `probe_batch_row_first` directly
# off a `BatchView` with non-INT64 keys and checks that:
#   (a) keys match exactly, fractional FLOAT64 keys included: a path that read
#       the key through `col_i64` and a numeric cast would hash 4.2, 4.7 and
#       4.0 alike and store garbage, so `test_f64_key_fractional_match_exact`
#       and `test_f64_key_distinct_buckets_not_collapsed` go red on it;
#   (b) the build-key emit channel (`key_bits_at_slot` + `key_from_bits`)
#       gives back the exact stored value;
#   (c) a narrow INT16 key is read as two bytes (an eight-byte read of a
#       two-byte column folds the neighbouring cells into the key, red in
#       `test_i16_narrow_key_match_exact`).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.batch_view import BatchView, batch_view_over
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, SchemaBuilder

from komira_op_join_stage.join_key_bundle import (
    KeyBundle1,
    KeyBundleVar,
    make_key_bundle_1,
)
from komira_op_join_stage.join_key_slot import KeySlot, key_from_bits
# ---------------------------------------------------------------------------
# Origin-inferring driver helpers — `bo` is inferred from the BatchView arg so
# the test doesn't have to spell the origin (which the bundle method needs as
# its leading comptime param).
# ---------------------------------------------------------------------------


def _insert1[
    K: DType, bo: Origin[mut=False]
](
    mut bundle: KeyBundleVar[KeySlot[K]],
    bv: BatchView[bo],
    row: Int,
    mut n_used: Int,
    mut saw_dup: Bool,
) raises:
    _ = bundle.build_insert_row[bo, 0, 0, 0, 0](
        bv, row, n_used, 63, saw_dup
    )


def _probe1[
    K: DType, bo: Origin[mut=False]
](bundle: KeyBundleVar[KeySlot[K]], bv: BatchView[bo], row: Int) raises -> Int:
    return bundle.probe_batch_row_first[bo, 0, 0, 0, 0](bv, row, 63)


# ---------------------------------------------------------------------------
# Single-column batch builders
# ---------------------------------------------------------------------------


def _f64_batch(vals: List[Float64]) raises -> RecordBatch:
    var prim = List[Scalar[DType.float64]]()
    for i in range(len(vals)):
        prim.append(Scalar[DType.float64](vals[i]))
    var arr = PrimitiveArray[DType.float64].from_list(prim)
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.FLOAT64, False))
    return RecordBatch.from_typed_columns_1(
        sb.build(), Column.from_primitive[DType.float64](arr^)
    )


def _i16_batch(vals: List[Int16]) raises -> RecordBatch:
    var prim = List[Scalar[DType.int16]]()
    for i in range(len(vals)):
        prim.append(Scalar[DType.int16](vals[i]))
    var arr = PrimitiveArray[DType.int16].from_list(prim)
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT16, False))
    return RecordBatch.from_typed_columns_1(
        sb.build(), Column.from_primitive[DType.int16](arr^)
    )


# ---------------------------------------------------------------------------
# F64 key — the marquee correctness case
# ---------------------------------------------------------------------------


def test_f64_key_fractional_match_exact() raises:
    """An F64 join key with FRACTIONAL values matches correctly. Through an
    `Int64(key)` channel 4.2, 4.7 and 4.0 all hash as 4 and the numeric cast
    corrupts the stored value; this test fails on such a path."""
    comptime F64 = DType.float64
    var bundle = make_key_bundle_1[F64](64)

    # Build side: insert distinct fractional F64 keys (all truncate to 4 under
    # Int64()), so an `Int64(key)` channel would alias them into one bucket and
    # mis-store.
    var build_vals: List[Float64] = [
        Float64(4.2),
        Float64(4.7),
        Float64(4.0),
        Float64(-7.5),
        Float64(100.25),
    ]
    var bbatch = _f64_batch(build_vals)
    var bv = batch_view_over(bbatch)

    var n_used = 0
    var saw_dup = False
    for r in range(len(build_vals)):
        _insert1[F64](bundle, bv, r, n_used, saw_dup)
    assert_equal(n_used, 5, "5 distinct fractional F64 keys inserted")
    assert_false(saw_dup, "no duplicate among distinct fractional keys")

    # Probe side: each distinct fractional key must HIT; an absent key misses.
    var probe_vals: List[Float64] = [
        Float64(4.2),
        Float64(4.7),
        Float64(4.0),
        Float64(-7.5),
        Float64(100.25),
        Float64(4.5),  # absent — must miss
    ]
    var pbatch = _f64_batch(probe_vals)
    var pv = batch_view_over(pbatch)

    for r in range(5):
        var slot = _probe1[F64](bundle, pv, r)
        assert_true(slot >= 0, "fractional F64 key hits its own insert")
        # EMIT channel: read the stored key's bits and reconstruct the exact
        # native F64 — must equal the probe value (no i64 corruption).
        var bits = bundle.key_bits_at_slot[0](slot)
        var stored = key_from_bits[F64](bits)
        assert_equal(stored, probe_vals[r], "stored F64 key is bit-exact")

    var miss = _probe1[F64](bundle, pv, 5)
    assert_true(miss < 0, "absent F64 key 4.5 misses (not aliased to 4.x)")


def test_f64_key_distinct_buckets_not_collapsed() raises:
    """4.2 and 4.7 are DISTINCT keys — probing 4.7 must NOT return 4.2's row.
    An `Int64(key)` hash collapses both to bucket 4; the key model hashes and
    compares the bits."""
    comptime F64 = DType.float64
    var bundle = make_key_bundle_1[F64](64)

    var bbatch = _f64_batch([Float64(4.2)])
    var bv = batch_view_over(bbatch)
    var n_used = 0
    var saw_dup = False
    _insert1[F64](bundle, bv, 0, n_used, saw_dup)

    # Probe 4.7 — must MISS (only 4.2 is in the table).
    var pbatch = _f64_batch([Float64(4.7)])
    var pv = batch_view_over(pbatch)
    var slot = _probe1[F64](bundle, pv, 0)
    assert_true(slot < 0, "4.7 misses — not aliased to 4.2's bucket-4 entry")


# ---------------------------------------------------------------------------
# Narrow I16 key — the over-read case
# ---------------------------------------------------------------------------


def test_i16_narrow_key_match_exact() raises:
    """A narrow I16 key matches correctly. A `col_i64` read takes 8 bytes
    of a 2-byte column (reading adjacent cells' bits into the key)."""
    comptime I16 = DType.int16
    var bundle = make_key_bundle_1[I16](64)

    var build_vals: List[Int16] = [Int16(5), Int16(-32000), Int16(32767)]
    var bbatch = _i16_batch(build_vals)
    var bv = batch_view_over(bbatch)
    var n_used = 0
    var saw_dup = False
    for r in range(len(build_vals)):
        _insert1[I16](bundle, bv, r, n_used, saw_dup)
    assert_equal(n_used, 3, "3 distinct I16 keys inserted")

    var pbatch = _i16_batch(build_vals)
    var pv = batch_view_over(pbatch)
    for r in range(3):
        var slot = _probe1[I16](bundle, pv, r)
        assert_true(slot >= 0, "I16 key hits")
        var stored = key_from_bits[I16](bundle.key_bits_at_slot[0](slot))
        assert_equal(stored, build_vals[r], "stored I16 key is exact")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

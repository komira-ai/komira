# =============================================================================
# test_join_untyped_float_key_model -- float join keys on
# `JoinBuildTable_Untyped` follow the query semantics' float model
# (docs/design/query_semantics.md, 3.9 and 2.6): every NaN equals every NaN,
# whatever its sign or payload, and `-0.0` equals `+0.0`. DuckDB matches such
# rows; a NULL key still matches nothing.
# =============================================================================
#
# Each case builds an INNER join whose build side carries one payload per row
# and checks, per probe row, the exact multiset of build payloads it matched.
#
# What each test catches:
#   * `test_f64_nan_matches_every_nan`: equality by IEEE `==` (NaN != NaN)
#     drops every NaN pair; hashing the raw bits splits NaNs whose sign or
#     payload differ into different buckets.
#   * `test_f64_signed_zeros_match`: hashing the raw bits puts `-0.0` and
#     `+0.0` in different buckets, so they never reach the compare.
#   * `test_f32_nan_and_zero_model`: the same two defects on the FLOAT32 arms.
#   * `test_f64_model_survives_directory_rehash`: the storage-vs-storage
#     equality (reached only when the directory doubles and the chains are
#     rebuilt) must follow the same model, or a NaN / zero chain is split and a
#     probe sees only one half. (The rehash re-places slots at their STORED
#     hashes, so the storage-side hash is not reached on this path.)
#   * `test_f64_null_key_matches_nothing`: the model does not make a NULL key
#     (whose value bits are zero) equal to a `+0.0` key.
#
# Mutants run while writing it, each red on this file: the batch-vs-storage
# `float_quotient_eq_*` replaced by `==` (red: the three NaN tests); every
# `canonical_bits_*` replaced by the raw `bitcast` (red: the four NaN and zero
# tests); the storage-vs-storage F64 equality replaced by `==` (red: the
# rehash test alone).
# =============================================================================

from std.memory import bitcast
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.batch_view import batch_view_over
from komira_arrow.column import Column
from komira_buffer.heap_region import HeapRegion
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, Schema
from komira_column_format.column_format_storage import (
    ColDescriptor,
    COL_FIXED,
    DT_F32,
    DT_F64,
    DT_I64,
    ROLE_KEY,
    ROLE_PAYLOAD,
)

from komira_op_join_build.join_build_untyped import (
    JoinBuildTable_Untyped,
    MatchPair,
)


def _nan_f64(bits: UInt64) -> Float64:
    return bitcast[DType.float64](bits)


def _nan_f32(bits: UInt32) -> Float32:
    return bitcast[DType.float32](bits)


# -----------------------------------------------------------------------------
# Fixtures: build (k f64, p i64), probe (k f64); `nulls` marks NULL keys.
# -----------------------------------------------------------------------------


def _f64_col(values: List[Float64], nulls: List[Bool]) raises -> Column[HeapRegion]:
    var a = PrimitiveArray[DType.float64].allocate_nullable(len(values))
    for i in range(len(values)):
        a.set(i, values[i])
        if len(nulls) > i and nulls[i]:
            a._set_null(i)
    return Column.from_primitive[DType.float64](a^)


def _f32_col(values: List[Float32]) raises -> Column[HeapRegion]:
    var a = PrimitiveArray[DType.float32].allocate_nullable(len(values))
    for i in range(len(values)):
        a.set(i, values[i])
    return Column.from_primitive[DType.float32](a^)


def _i64_col(n: Int, base: Int) raises -> Column[HeapRegion]:
    var a = PrimitiveArray[DType.int64].allocate_nullable(n)
    for i in range(n):
        a.set(i, Int64(base + i))
    return Column.from_primitive[DType.int64](a^)


def _table(key_tag: UInt8, cap: Int) raises -> JoinBuildTable_Untyped:
    var keys = List[ColDescriptor]()
    keys.append(ColDescriptor(-1, COL_FIXED, key_tag, ROLE_KEY, 0, 0, False))
    var pays = List[ColDescriptor]()
    pays.append(ColDescriptor(-1, COL_FIXED, DT_I64, ROLE_PAYLOAD, 1, 1, False))
    return JoinBuildTable_Untyped(keys^, pays^, cap)


def _build_f64(
    mut table: JoinBuildTable_Untyped,
    keys: List[Float64],
    nulls: List[Bool],
) raises:
    """Build rows `(keys[i], 100 + i)`."""
    var schema = Schema.from_fields_2(
        Field("k", DType.float64, True), Field("p", DType.int64, True)
    )
    var batch = RecordBatch.from_typed_columns_2(
        schema^, _f64_col(keys, nulls), _i64_col(len(keys), 100)
    )
    table.build_batch(batch_view_over(batch))


def _probe_f64(
    table: JoinBuildTable_Untyped, keys: List[Float64], nulls: List[Bool]
) raises -> List[MatchPair]:
    var schema = Schema.from_fields_2(
        Field("k", DType.float64, True), Field("pad", DType.int64, True)
    )
    var batch = RecordBatch.from_typed_columns_2(
        schema^, _f64_col(keys, nulls), _i64_col(len(keys), 0)
    )
    var pairs = List[MatchPair]()
    table.probe_batch(batch_view_over(batch), pairs)
    return pairs^


def _matched_payloads(
    table: JoinBuildTable_Untyped, pairs: List[MatchPair], probe_row: Int
) raises -> List[Int]:
    """The build payloads probe row `probe_row` matched, sorted ascending."""
    var out = List[Int]()
    for i in range(len(pairs)):
        if pairs[i].probe_row == probe_row:
            out.append(Int(table.storage.read_slot_i64(1, pairs[i].build_slot)))
    for i in range(1, len(out)):
        var v = out[i]
        var j = i - 1
        while j >= 0 and out[j] > v:
            out[j + 1] = out[j]
            j -= 1
        out[j + 1] = v
    return out^


def _assert_payloads(
    got: List[Int], var want: List[Int], what: String
) raises:
    assert_equal(len(got), len(want), what + ": match count")
    for i in range(len(want)):
        assert_equal(got[i], want[i], what + ": payload " + String(i))


# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------


def test_f64_nan_matches_every_nan() raises:
    # Build: three NaNs that differ in sign and payload, and 1.0.
    var t = _table(DT_F64, 16)
    var bk = List[Float64]()
    bk.append(_nan_f64(0x7FF8000000000000))  # payload 100: quiet NaN
    bk.append(_nan_f64(0xFFF8000000000000))  # payload 101: negative NaN
    bk.append(_nan_f64(0x7FF0000000000001))  # payload 102: signalling payload
    bk.append(Float64(1.0))                   # payload 103
    _build_f64(t, bk, List[Bool]())
    var pk = List[Float64]()
    pk.append(_nan_f64(0x7FF8000000000123))  # a fourth NaN pattern
    pk.append(Float64(1.0))
    var pairs = _probe_f64(t, pk, List[Bool]())
    _assert_payloads(
        _matched_payloads(t, pairs, 0), [100, 101, 102],
        "a NaN probe key matches every NaN build key",
    )
    _assert_payloads(
        _matched_payloads(t, pairs, 1), [103], "1.0 matches only 1.0"
    )


def test_f64_signed_zeros_match() raises:
    var t = _table(DT_F64, 16)
    var bk = List[Float64]()
    bk.append(Float64(0.0))       # payload 100
    bk.append(-Float64(0.0))      # payload 101
    bk.append(Float64(2.0))       # payload 102
    _build_f64(t, bk, List[Bool]())
    var pk = List[Float64]()
    pk.append(-Float64(0.0))
    pk.append(Float64(0.0))
    pk.append(Float64(2.0))
    var pairs = _probe_f64(t, pk, List[Bool]())
    _assert_payloads(_matched_payloads(t, pairs, 0), [100, 101], "-0.0 probe")
    _assert_payloads(_matched_payloads(t, pairs, 1), [100, 101], "+0.0 probe")
    _assert_payloads(_matched_payloads(t, pairs, 2), [102], "2.0 probe")
    # One key, so one chain: the second zero was a duplicate of the first.
    assert_true(t.has_duplicate_keys, "-0.0 and +0.0 are one key")


def test_f32_nan_and_zero_model() raises:
    var t = _table(DT_F32, 16)
    var bk = List[Float32]()
    bk.append(_nan_f32(0x7FC00000))   # payload 100
    bk.append(_nan_f32(0xFFC00001))   # payload 101
    bk.append(-Float32(0.0))          # payload 102
    bk.append(Float32(3.5))           # payload 103
    var bschema = Schema.from_fields_2(
        Field("k", DType.float32, True), Field("p", DType.int64, True)
    )
    var bbatch = RecordBatch.from_typed_columns_2(
        bschema^, _f32_col(bk), _i64_col(len(bk), 100)
    )
    t.build_batch(batch_view_over(bbatch))
    var pk = List[Float32]()
    pk.append(_nan_f32(0x7F800001))
    pk.append(Float32(0.0))
    pk.append(Float32(3.5))
    var pschema = Schema.from_fields_2(
        Field("k", DType.float32, True), Field("pad", DType.int64, True)
    )
    var pbatch = RecordBatch.from_typed_columns_2(
        pschema^, _f32_col(pk), _i64_col(len(pk), 0)
    )
    var pairs = List[MatchPair]()
    t.probe_batch(batch_view_over(pbatch), pairs)
    _assert_payloads(_matched_payloads(t, pairs, 0), [100, 101], "f32 NaN")
    _assert_payloads(_matched_payloads(t, pairs, 1), [102], "f32 +0.0")
    _assert_payloads(_matched_payloads(t, pairs, 2), [103], "f32 3.5")


def test_f64_model_survives_directory_rehash() raises:
    # A 4-slot table and 300 distinct finite keys force several directory
    # doublings; the NaN and zero rows are built FIRST, so their chains are
    # rebuilt by every rehash.
    var t = _table(DT_F64, 4)
    var bk = List[Float64]()
    bk.append(_nan_f64(0x7FF8000000000000))   # payload 100
    bk.append(-Float64(0.0))                   # payload 101
    bk.append(_nan_f64(0xFFF800000000BEEF))   # payload 102
    bk.append(Float64(0.0))                    # payload 103
    for i in range(300):
        bk.append(Float64(i + 1) * 0.25)       # payloads 104..403
    _build_f64(t, bk, List[Bool]())
    assert_true(t.directory_rehashes() > 0, "the fixture must grow")
    var pk = List[Float64]()
    pk.append(_nan_f64(0x7FF8000000000001))
    pk.append(Float64(0.0))
    pk.append(Float64(0.25))
    var pairs = _probe_f64(t, pk, List[Bool]())
    _assert_payloads(_matched_payloads(t, pairs, 0), [100, 102], "NaN after grow")
    _assert_payloads(_matched_payloads(t, pairs, 1), [101, 103], "zero after grow")
    _assert_payloads(_matched_payloads(t, pairs, 2), [104], "0.25 after grow")


def test_f64_null_key_matches_nothing() raises:
    var t = _table(DT_F64, 16)
    var bk = List[Float64]()
    bk.append(Float64(0.0))   # payload 100
    bk.append(Float64(0.0))   # payload 101, NULL key (value bits zero)
    var bn = List[Bool]()
    bn.append(False)
    bn.append(True)
    _build_f64(t, bk, bn)
    var pk = List[Float64]()
    pk.append(Float64(0.0))
    pk.append(Float64(0.0))   # NULL probe key
    var pn = List[Bool]()
    pn.append(False)
    pn.append(True)
    var pairs = _probe_f64(t, pk, pn)
    _assert_payloads(_matched_payloads(t, pairs, 0), [100], "0.0 vs NULL build")
    _assert_payloads(_matched_payloads(t, pairs, 1), [], "NULL probe")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

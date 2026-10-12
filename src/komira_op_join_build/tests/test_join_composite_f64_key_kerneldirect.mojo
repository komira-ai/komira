# =============================================================================
# test_join_composite_f64_key_kerneldirect -- oracle for the composite
# (I64, F64) INNER join on `JoinBuildTable_Untyped`, kernel-direct, with a
# HAND-COMPUTED oracle.
# =============================================================================
#
# The batches' SECOND key column is a genuine FLOAT64 column; matched payloads
# are compared to the hand oracle as an ORDER-INDEPENDENT MULTISET. The
# decisive property: the F64 key MUST distinguish (10, 1.5) from (10, 2.5). A
# correct equi-join never crosses the two. A composite key that silently read
# the F64 column through an I64 walker, or ignored it, gives the right row
# count with the wrong rows.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import ArrowType, Field, Schema
from komira_arrow.batch_view import BatchView, batch_view_over

from komira_op_join_build.join_build_untyped import (
    JoinBuildTable_Untyped,
    MatchPair,
)
from komira_column_format.column_format_storage import (
    ColDescriptor,
    COL_FIXED,
    DT_F64,
    DT_I64,
    ROLE_KEY,
    ROLE_PAYLOAD,
)


# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------


# Build batch: (k0 i64, k1 f64, p0 i64) — composite key (k0, k1), 1 i64 payload.
def _build_batch_i64_f64_p_i64(
    var k0: List[Int64], var k1: List[Float64], var p0: List[Int64]
) raises -> RecordBatch:
    var k0_typed = List[Scalar[DType.int64]]()
    var k1_typed = List[Scalar[DType.float64]]()
    var p0_typed = List[Scalar[DType.int64]]()
    for i in range(len(k0)):
        k0_typed.append(Scalar[DType.int64](k0[i]))
        k1_typed.append(Scalar[DType.float64](k1[i]))
        p0_typed.append(Scalar[DType.int64](p0[i]))
    var k0_arr = PrimitiveArray[DType.int64].from_list(k0_typed^)
    var k1_arr = PrimitiveArray[DType.float64].from_list(k1_typed^)
    var p0_arr = PrimitiveArray[DType.int64].from_list(p0_typed^)
    var schema = Schema.from_fields_3(
        Field("k0", DType.int64, True),
        Field("k1", DType.float64, True),
        Field("p0", DType.int64, True),
    )
    var k0_col = Column.from_primitive[DType.int64](k0_arr^)
    var k1_col = Column.from_primitive[DType.float64](k1_arr^)
    var p0_col = Column.from_primitive[DType.int64](p0_arr^)
    return RecordBatch.from_typed_columns_3(schema^, k0_col^, k1_col^, p0_col^)


# Probe batch: (k0 i64, k1 f64) — composite key (k0, k1).
def _probe_batch_i64_f64(
    var k0: List[Int64], var k1: List[Float64]
) raises -> RecordBatch:
    var k0_typed = List[Scalar[DType.int64]]()
    var k1_typed = List[Scalar[DType.float64]]()
    for i in range(len(k0)):
        k0_typed.append(Scalar[DType.int64](k0[i]))
        k1_typed.append(Scalar[DType.float64](k1[i]))
    var k0_arr = PrimitiveArray[DType.int64].from_list(k0_typed^)
    var k1_arr = PrimitiveArray[DType.float64].from_list(k1_typed^)
    var schema = Schema.from_fields_2(
        Field("k0", DType.int64, True),
        Field("k1", DType.float64, True),
    )
    var k0_col = Column.from_primitive[DType.int64](k0_arr^)
    var k1_col = Column.from_primitive[DType.float64](k1_arr^)
    return RecordBatch.from_typed_columns_2(schema^, k0_col^, k1_col^)


# Build the JoinBuildTable_Untyped layout: 2 keys (k0=I64, k1=F64) + 1 payload
# (p0=I64).
def _make_build_table() raises -> JoinBuildTable_Untyped:
    var key_descs = List[ColDescriptor]()
    # k0: I64 key, batch col 0, storage 0.
    key_descs.append(
        ColDescriptor(-1, COL_FIXED, DT_I64, ROLE_KEY, 0, 0, False)
    )
    # k1: F64 key, batch col 1, storage 1.
    key_descs.append(
        ColDescriptor(-1, COL_FIXED, DT_F64, ROLE_KEY, 1, 1, False)
    )
    var pay_descs = List[ColDescriptor]()
    # p0: I64 payload, build batch col 2, storage 2 (== n_keys + 0).
    pay_descs.append(
        ColDescriptor(-1, COL_FIXED, DT_I64, ROLE_PAYLOAD, 2, 2, False)
    )
    return JoinBuildTable_Untyped(key_descs^, pay_descs^, 16)


def _insort(mut xs: List[Int]):
    for i in range(1, len(xs)):
        var key = xs[i]
        var j = i - 1
        while j >= 0 and xs[j] > key:
            xs[j + 1] = xs[j]
            j -= 1
        xs[j + 1] = key


# =============================================================================
# THE TEST
# =============================================================================
#
# BUILD rows (composite key (k0, k1)):
#   (10, 1.5) -> p0=100      [key DUPLICATED below for M:N fanout]
#   (10, 1.5) -> p0=200
#   (10, 2.5) -> p0=300      [same k0, DIFFERENT f64 key — must NOT cross]
#   (30, 1.5) -> p0=400      [no probe match]
#
# PROBE rows (composite key (k0, k1)):
#   (10, 1.5)   -> matches build {100, 200}  = 2 output rows
#   (10, 2.5)   -> matches build {300}        = 1 output row
#   (20, 1.5)   -> no build match             = 0 rows
#   (10, 9.5)   -> no build match             = 0 rows
#
# Oracle INNER multiset of matched build payload p0: {100, 200, 300}.
# =============================================================================


def test_composite_f64_key_inner_multiset() raises:
    var table = _make_build_table()

    # ---- BUILD ----
    var b_k0 = List[Int64]()
    var b_k1 = List[Float64]()
    var b_p0 = List[Int64]()
    b_k0.append(Int64(10)); b_k1.append(Float64(1.5)); b_p0.append(Int64(100))
    b_k0.append(Int64(10)); b_k1.append(Float64(1.5)); b_p0.append(Int64(200))
    b_k0.append(Int64(10)); b_k1.append(Float64(2.5)); b_p0.append(Int64(300))
    b_k0.append(Int64(30)); b_k1.append(Float64(1.5)); b_p0.append(Int64(400))
    var build_batch = _build_batch_i64_f64_p_i64(b_k0^, b_k1^, b_p0^)
    var build_view = batch_view_over(build_batch)
    table.build_batch(build_view)

    # ---- PROBE ----
    var p_k0 = List[Int64]()
    var p_k1 = List[Float64]()
    p_k0.append(Int64(10)); p_k1.append(Float64(1.5))
    p_k0.append(Int64(10)); p_k1.append(Float64(2.5))
    p_k0.append(Int64(20)); p_k1.append(Float64(1.5))
    p_k0.append(Int64(10)); p_k1.append(Float64(9.5))
    var probe_batch = _probe_batch_i64_f64(p_k0^, p_k1^)
    var probe_view = batch_view_over(probe_batch)

    var pairs = List[MatchPair]()
    table.probe_batch(probe_view, pairs)

    # Oracle: matched build payload p0 multiset = {100, 200, 300}.
    var expected = List[Int]()
    expected.append(100)
    expected.append(200)
    expected.append(300)

    assert_equal(
        len(pairs), len(expected),
        "composite F64-key INNER: match count must equal the hand oracle (3"
        " INNER matches). A 4 or 5 here means the F64 key is being IGNORED"
        " (cross-matching (10,1.5) with (10,2.5)).",
    )

    # Read the matched build payload p0 (storage col 2) for each pair.
    var got = List[Int]()
    for i in range(len(pairs)):
        var slot = pairs[i].build_slot
        got.append(Int(table.storage.read_slot_i64(2, slot)))

    _insort(got)
    _insort(expected)
    for i in range(len(expected)):
        assert_equal(
            got[i], expected[i],
            "composite F64-key INNER: matched payload p0 multiset must match"
            " the hand oracle {100,200,300}. A divergence here means the F64"
            " key was mis-matched (wrong build row pulled).",
        )


# =============================================================================
# §2 — F64-key DISTINGUISH guard: probe (10, 2.5) MUST pull ONLY p0=300, and
# probe (10, 1.5) MUST pull ONLY {100, 200} — NEVER crossing. This isolates
# the F64-key correctness from the aggregate multiset above.
# =============================================================================


def test_composite_f64_key_no_cross_match() raises:
    var table = _make_build_table()

    var b_k0 = List[Int64]()
    var b_k1 = List[Float64]()
    var b_p0 = List[Int64]()
    b_k0.append(Int64(10)); b_k1.append(Float64(1.5)); b_p0.append(Int64(100))
    b_k0.append(Int64(10)); b_k1.append(Float64(2.5)); b_p0.append(Int64(300))
    var build_batch = _build_batch_i64_f64_p_i64(b_k0^, b_k1^, b_p0^)
    var build_view = batch_view_over(build_batch)
    table.build_batch(build_view)

    # ONE probe row: (10, 2.5). With a correct F64 key this matches ONLY the
    # build row carrying p0=300, never the (10, 1.5) row (p0=100).
    var p_k0 = List[Int64]()
    var p_k1 = List[Float64]()
    p_k0.append(Int64(10)); p_k1.append(Float64(2.5))
    var probe_batch = _probe_batch_i64_f64(p_k0^, p_k1^)
    var probe_view = batch_view_over(probe_batch)

    var pairs = List[MatchPair]()
    table.probe_batch(probe_view, pairs)

    assert_equal(
        len(pairs), 1,
        "F64-key distinguish: probe (10,2.5) must match EXACTLY 1 build row"
        " (the (10,2.5) row). A 2 here means the F64 key was ignored.",
    )
    assert_equal(
        Int(table.storage.read_slot_i64(2, pairs[0].build_slot)), 300,
        "F64-key distinguish: probe (10,2.5) must pull p0=300, NOT p0=100"
        " (the (10,1.5) row). A 100 here means a cross-match on the I64 key"
        " alone.",
    )


def main() raises:
    var suite = TestSuite()
    suite.test[test_composite_f64_key_inner_multiset]()
    suite.test[test_composite_f64_key_no_cross_match]()
    suite^.run()

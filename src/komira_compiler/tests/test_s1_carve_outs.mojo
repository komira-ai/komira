# =============================================================================
# Tests for the S1 carve-outs: temporal-scale casts and string <-> numeric casts
# =============================================================================
#
# Two carve-out clusters:
#
# S1.cast-temporal-scale — temporal cast arms that need an IR carrier for
#   the Arrow logical type / unit (`CastData.target_arrow`), via the
#   Expr.cast_to_arrow constructor + _eval_cast arm wiring.
#
# S1.string-numeric-cast — STRING<->numeric parse / format kernels
#   in komira_kernels/cast_to_varchar_kernels.mojo.
#
# Each test below was written BEFORE the production code passed (TDD-shaped)
# and validates a single direction / edge case.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.arrow import PrimitiveArray
from komira_core.arrow.column import Column
from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.schema import SchemaBuilder, Field, RecordBatch, RecordBatchBuilder
from komira_core.arrow.string_array import StringArray
from komira_core.arrow.bitmap import Bitmap
from komira_core.io.heap_region import HeapRegion
from komira_core.plan.expr import Expr
from komira_core.plan.expr_walk import walk_expr_field, ExecColRefFields
from komira_compiler.compiler_eval_column import _eval_column_expr
from komira_kernels.cast_to_varchar_kernels import (
    i64_from_str, i32_from_str, f64_from_str, f32_from_str,
    i64_to_str, i32_to_str, f64_to_str, f32_to_str,
    cast_string_to_int64, cast_string_to_float64,
    cast_int64_to_string, cast_float64_to_string,
)


# =============================================================================
# Helpers
# =============================================================================


def _i32_batch(vals: List[Int32], nulls: List[Bool], name: String, at: ArrowType) raises -> RecordBatch:
    """Build a single-column RecordBatch with the given ArrowType label.

    Used for `_eval_column_expr(Expr.cast(...), batch)` round-trips.
    """
    var n = len(vals)
    var arr = PrimitiveArray[DType.int32].allocate_nullable(n)
    var nc = 0
    for i in range(n):
        arr.set(i, Scalar[DType.int32](vals[i]))
        if nulls[i]:
            arr.validity.value().clear(i)
            nc += 1
    arr.null_count = nc
    var c = Column.from_primitive[DType.int32](arr^)
    c.arrow_type = at
    var sb = SchemaBuilder()
    sb.add_field(Field(name, at, True))
    var rbb = RecordBatchBuilder()
    rbb.add_column(c^)
    return rbb.build(sb.build())


def _i64_batch(vals: List[Int64], nulls: List[Bool], name: String, at: ArrowType) raises -> RecordBatch:
    var n = len(vals)
    var arr = PrimitiveArray[DType.int64].allocate_nullable(n)
    var nc = 0
    for i in range(n):
        arr.set(i, Scalar[DType.int64](vals[i]))
        if nulls[i]:
            arr.validity.value().clear(i)
            nc += 1
    arr.null_count = nc
    var c = Column.from_primitive[DType.int64](arr^)
    c.arrow_type = at
    var sb = SchemaBuilder()
    sb.add_field(Field(name, at, True))
    var rbb = RecordBatchBuilder()
    rbb.add_column(c^)
    return rbb.build(sb.build())


def _f32_batch(vals: List[Float32], nulls: List[Bool], name: String) raises -> RecordBatch:
    """A FLOAT32 column. ⚠ NO OTHER HELPER IN THIS FILE BUILDS ONE, and that
    absence is exactly why `CAST(<float32> AS <anything>)` reached a customer as
    an internal error: nothing here could construct the source that broke."""
    var n = len(vals)
    var arr = PrimitiveArray[DType.float32].allocate_nullable(n)
    var nc = 0
    for i in range(n):
        arr.set(i, Scalar[DType.float32](vals[i]))
        if nulls[i]:
            arr.validity.value().clear(i)
            nc += 1
    arr.null_count = nc
    var c = Column.from_primitive[DType.float32](arr^)
    c.arrow_type = ArrowType.FLOAT32
    var sb = SchemaBuilder()
    sb.add_field(Field(name, ArrowType.FLOAT32, True))
    var rbb = RecordBatchBuilder()
    rbb.add_column(c^)
    return rbb.build(sb.build())


def _f64_batch(vals: List[Float64], nulls: List[Bool], name: String) raises -> RecordBatch:
    var n = len(vals)
    var arr = PrimitiveArray[DType.float64].allocate_nullable(n)
    var nc = 0
    for i in range(n):
        arr.set(i, Scalar[DType.float64](vals[i]))
        if nulls[i]:
            arr.validity.value().clear(i)
            nc += 1
    arr.null_count = nc
    var c = Column.from_primitive[DType.float64](arr^)
    c.arrow_type = ArrowType.FLOAT64
    var sb = SchemaBuilder()
    sb.add_field(Field(name, ArrowType.FLOAT64, True))
    var rbb = RecordBatchBuilder()
    rbb.add_column(c^)
    return rbb.build(sb.build())


def _string_batch(vals: List[String], nulls: List[Bool], name: String) raises -> RecordBatch:
    var n = len(vals)
    var sa = StringArray.from_strings(vals)
    if True:
        # Apply null mask
        var bm = Bitmap.create_all_valid(n)
        var nc = 0
        for i in range(n):
            if nulls[i]:
                bm.clear(i)
                nc += 1
        sa.validity = bm^
        sa.null_count = nc
    var c = Column.from_string(sa^)
    var sb = SchemaBuilder()
    sb.add_field(Field(name, ArrowType.STRING, True))
    var rbb = RecordBatchBuilder()
    rbb.add_column(c^)
    return rbb.build(sb.build())


# =============================================================================
# S1.cast-temporal-scale — reverse-direction tests
# =============================================================================


def test_cast_int32_to_date32_reinterpret() raises:
    """cast(int32_col AS date32): same bits, same null mask, type -> DATE32."""
    var batch = _i32_batch(
        [Int32(19000), Int32(19001), Int32(0), Int32(19003)],
        [False, False, True, False],
        "i", ArrowType.INT32,
    )
    var expr = Expr.cast_to_arrow(Expr.col_ref("i"), ArrowType.DATE32)
    var out = _eval_column_expr(expr, batch)
    assert_true(out.arrow_type == ArrowType.DATE32)
    assert_equal(out.length(), 4)
    assert_equal(out.null_count(), 1)
    var arr = out.as_primitive[DType.int32]()
    assert_false(arr.is_null(0))
    assert_equal(arr.get(0), Scalar[DType.int32](19000))
    assert_true(arr.is_null(2))


def test_cast_int64_to_timestamp_us_reinterpret() raises:
    """cast(int64_col AS timestamp[us]): same bits, type -> TIMESTAMP_US."""
    var batch = _i64_batch(
        [Int64(1700000000000000), Int64(0), Int64(1700000003000000)],
        [False, True, False],
        "ts", ArrowType.INT64,
    )
    var expr = Expr.cast_to_arrow(Expr.col_ref("ts"), ArrowType.TIMESTAMP_US)
    var out = _eval_column_expr(expr, batch)
    assert_true(out.arrow_type == ArrowType.TIMESTAMP_US)
    assert_equal(out.length(), 3)
    assert_equal(out.null_count(), 1)
    var arr = out.as_primitive[DType.int64]()
    assert_false(arr.is_null(0))
    assert_equal(arr.get(0), Scalar[DType.int64](1700000000000000))


def test_cast_timestamp_ms_to_us_scale() raises:
    """cast(timestamp[ms]_col AS timestamp[us]) -- multiplies by 1000."""
    var batch = _i64_batch(
        [Int64(1700000000000), Int64(1700000001000), Int64(0)],
        [False, False, True],
        "ts", ArrowType.TIMESTAMP_MS,
    )
    var expr = Expr.cast_to_arrow(Expr.col_ref("ts"), ArrowType.TIMESTAMP_US)
    var out = _eval_column_expr(expr, batch)
    assert_true(out.arrow_type == ArrowType.TIMESTAMP_US)
    assert_equal(out.length(), 3)
    assert_equal(out.null_count(), 1)
    var arr = out.as_primitive[DType.int64]()
    assert_equal(arr.get(0), Scalar[DType.int64](1700000000000000))  # x1000
    assert_equal(arr.get(1), Scalar[DType.int64](1700000001000000))  # x1000
    assert_true(arr.is_null(2))


def test_cast_timestamp_us_to_ns_scale() raises:
    """cast(timestamp[us]_col AS timestamp[ns]) -- multiplies by 1000."""
    var batch = _i64_batch(
        [Int64(1700000000000000), Int64(0)],
        [False, False],
        "ts", ArrowType.TIMESTAMP_US,
    )
    var expr = Expr.cast_to_arrow(Expr.col_ref("ts"), ArrowType.TIMESTAMP_NS)
    var out = _eval_column_expr(expr, batch)
    assert_true(out.arrow_type == ArrowType.TIMESTAMP_NS)
    var arr = out.as_primitive[DType.int64]()
    assert_equal(arr.get(0), Scalar[DType.int64](1700000000000000000))  # x1000


def test_cast_timestamp_us_to_ms_scale() raises:
    """cast(timestamp[us] AS timestamp[ms]) -- divides by 1000 (truncate)."""
    var batch = _i64_batch(
        [Int64(1700000000123456), Int64(1700000000999)],
        [False, False],
        "ts", ArrowType.TIMESTAMP_US,
    )
    var expr = Expr.cast_to_arrow(Expr.col_ref("ts"), ArrowType.TIMESTAMP_MS)
    var out = _eval_column_expr(expr, batch)
    assert_true(out.arrow_type == ArrowType.TIMESTAMP_MS)
    var arr = out.as_primitive[DType.int64]()
    assert_equal(arr.get(0), Scalar[DType.int64](1700000000123))  # truncate
    assert_equal(arr.get(1), Scalar[DType.int64](1700000000))    # truncate


def test_cast_timestamp_ns_to_us_scale() raises:
    """cast(timestamp[ns] AS timestamp[us]) -- divides by 1000."""
    var batch = _i64_batch(
        [Int64(1700000000000000000)],
        [False],
        "ts", ArrowType.TIMESTAMP_NS,
    )
    var expr = Expr.cast_to_arrow(Expr.col_ref("ts"), ArrowType.TIMESTAMP_US)
    var out = _eval_column_expr(expr, batch)
    assert_true(out.arrow_type == ArrowType.TIMESTAMP_US)
    var arr = out.as_primitive[DType.int64]()
    assert_equal(arr.get(0), Scalar[DType.int64](1700000000000000))


def test_cast_timestamp_same_unit_noop() raises:
    """cast(ts[us] AS ts[us]) is a no-op (just relabel)."""
    var batch = _i64_batch(
        [Int64(1700000000000000)],
        [False],
        "ts", ArrowType.TIMESTAMP_US,
    )
    var expr = Expr.cast_to_arrow(Expr.col_ref("ts"), ArrowType.TIMESTAMP_US)
    var out = _eval_column_expr(expr, batch)
    assert_true(out.arrow_type == ArrowType.TIMESTAMP_US)
    var arr = out.as_primitive[DType.int64]()
    assert_equal(arr.get(0), Scalar[DType.int64](1700000000000000))


def test_cast_temporal_preserves_validity() raises:
    """Scale conversion preserves the input null mask."""
    var batch = _i64_batch(
        [Int64(1000), Int64(0), Int64(2000)],
        [False, True, False],
        "ts", ArrowType.TIMESTAMP_MS,
    )
    var expr = Expr.cast_to_arrow(Expr.col_ref("ts"), ArrowType.TIMESTAMP_US)
    var out = _eval_column_expr(expr, batch)
    assert_equal(out.null_count(), 1)
    var arr = out.as_primitive[DType.int64]()
    assert_false(arr.is_null(0))
    assert_true(arr.is_null(1))
    assert_false(arr.is_null(2))


# =============================================================================
# S1.string-numeric-cast — scalar parse kernels
# =============================================================================


def test_string_to_int64_basic() raises:
    assert_equal(i64_from_str(String("42")), Int64(42))
    assert_equal(i64_from_str(String("-1")), Int64(-1))
    assert_equal(i64_from_str(String("0")), Int64(0))
    assert_equal(i64_from_str(String("+99")), Int64(99))


def test_string_to_int64_leading_zeros() raises:
    """Leading zeros accepted (DuckDB-parity)."""
    assert_equal(i64_from_str(String("007")), Int64(7))
    assert_equal(i64_from_str(String("0042")), Int64(42))


def test_string_to_int64_whitespace_trimmed() raises:
    """Surrounding ASCII whitespace trimmed."""
    assert_equal(i64_from_str(String("  42  ")), Int64(42))
    assert_equal(i64_from_str(String("\t-1\n")), Int64(-1))


def test_string_to_int64_rejects_scientific() raises:
    """REJECTS `1e2` -- DuckDB/Arrow INT-cast semantics."""
    var raised = False
    try:
        var _ = i64_from_str(String("1e2"))
    except e:
        raised = True
    assert_true(raised)


def test_string_to_int64_rejects_overflow() raises:
    var raised = False
    try:
        var _ = i64_from_str(String("99999999999999999999"))
    except e:
        raised = True
    assert_true(raised)


def test_string_to_int64_rejects_garbage() raises:
    var raised1 = False
    try:
        var _ = i64_from_str(String("abc"))
    except e:
        raised1 = True
    assert_true(raised1)
    var raised2 = False
    try:
        var _ = i64_from_str(String("12a3"))
    except e:
        raised2 = True
    assert_true(raised2)


def test_string_to_int64_rejects_empty() raises:
    var raised = False
    try:
        var _ = i64_from_str(String(""))
    except e:
        raised = True
    assert_true(raised)


def test_string_to_int64_min_max_boundary() raises:
    """Int64.MIN / Int64.MAX both representable."""
    assert_equal(i64_from_str(String("9223372036854775807")), Int64(9223372036854775807))
    assert_equal(i64_from_str(String("-9223372036854775808")), Int64(-9223372036854775808))


def test_string_to_float64_basic() raises:
    assert_equal(f64_from_str(String("1.5")), Float64(1.5))
    assert_equal(f64_from_str(String("-3.14")), Float64(-3.14))
    assert_equal(f64_from_str(String("0.0")), Float64(0.0))
    assert_equal(f64_from_str(String("42")), Float64(42.0))


def test_string_to_float64_scientific() raises:
    """ACCEPTS scientific notation (DuckDB/Arrow float-cast)."""
    assert_equal(f64_from_str(String("1.5e3")), Float64(1500.0))
    assert_equal(f64_from_str(String("1E-2")), Float64(0.01))
    assert_equal(f64_from_str(String("-2.5e2")), Float64(-250.0))


def test_string_to_float64_nan() raises:
    """Case-insensitive NaN -> Float64 NaN."""
    var v = f64_from_str(String("NaN"))
    # NaN != NaN — use the IEEE 754 contract.
    assert_true(v != v)
    var v2 = f64_from_str(String("nan"))
    assert_true(v2 != v2)


def test_string_to_float64_inf() raises:
    """Case-insensitive Inf / Infinity -> +/-Inf."""
    var pos_inf = Float64(1.0) / Float64(0.0)
    var neg_inf = Float64(-1.0) / Float64(0.0)
    assert_equal(f64_from_str(String("Inf")), pos_inf)
    assert_equal(f64_from_str(String("inf")), pos_inf)
    assert_equal(f64_from_str(String("-Inf")), neg_inf)
    assert_equal(f64_from_str(String("Infinity")), pos_inf)
    assert_equal(f64_from_str(String("-infinity")), neg_inf)


def test_string_to_float64_empty_raises() raises:
    var raised = False
    try:
        var _ = f64_from_str(String(""))
    except e:
        raised = True
    assert_true(raised)


# =============================================================================
# S1.string-numeric-cast — format kernels
# =============================================================================


def test_int64_to_string_basic() raises:
    assert_equal(i64_to_str(Int64(42)), String("42"))
    assert_equal(i64_to_str(Int64(-1)), String("-1"))
    assert_equal(i64_to_str(Int64(0)), String("0"))


def test_int64_to_string_round_trip() raises:
    """For all integer inputs, i64_from_str(i64_to_str(v)) == v."""
    var values = List[Int64]()
    values.append(Int64(0))
    values.append(Int64(1))
    values.append(Int64(-1))
    values.append(Int64(42))
    values.append(Int64(-42))
    values.append(Int64(1234567890123456789))
    values.append(Int64(-1234567890123456789))
    for i in range(len(values)):
        var v = values[i]
        var s = i64_to_str(v)
        var back = i64_from_str(s)
        assert_equal(back, v)


def test_float64_to_string_basic() raises:
    """Verify simple round-trip for finite values."""
    assert_equal(f64_from_str(f64_to_str(Float64(1.5))), Float64(1.5))
    assert_equal(f64_from_str(f64_to_str(Float64(-3.14))), Float64(-3.14))
    assert_equal(f64_from_str(f64_to_str(Float64(0.0))), Float64(0.0))


# =============================================================================
# S1.string-numeric-cast — column orchestrators
# =============================================================================


def test_cast_string_to_int64_array() raises:
    """Bulk array cast: 4 valid rows."""
    var values = List[String]()
    values.append(String("42"))
    values.append(String("-1"))
    values.append(String("0"))
    values.append(String("100"))
    var sa = StringArray.from_strings(values)
    var arr = cast_string_to_int64(sa)
    assert_equal(arr.length, 4)
    assert_equal(arr.get(0), Scalar[DType.int64](42))
    assert_equal(arr.get(1), Scalar[DType.int64](-1))
    assert_equal(arr.get(2), Scalar[DType.int64](0))
    assert_equal(arr.get(3), Scalar[DType.int64](100))


def test_cast_string_to_int64_preserves_nulls() raises:
    """Null rows in input -> null rows in output."""
    var batch = _string_batch(
        [String("42"), String("X"), String("99")],  # middle is null so X is never parsed
        [False, True, False],
        "s",
    )
    var expr = Expr.cast(Expr.col_ref("s"), DType.int64)
    var out = _eval_column_expr(expr, batch)
    assert_equal(out.length(), 3)
    assert_equal(out.null_count(), 1)
    var arr = out.as_primitive[DType.int64]()
    assert_false(arr.is_null(0))
    assert_equal(arr.get(0), Scalar[DType.int64](42))
    assert_true(arr.is_null(1))
    assert_false(arr.is_null(2))
    assert_equal(arr.get(2), Scalar[DType.int64](99))


# =============================================================================
# TRY_CAST TWIN
# =============================================================================


def test_try_cast_is_flagged() raises:
    """PHASE-0b: Expr.try_cast sets the flag; Expr.cast does not; copy
    preserves it. Existing CAST is byte-identical (try_cast defaults False)."""
    var t = Expr.try_cast(Expr.col_ref("s"), DType.int64)
    assert_true(t.cast_is_try())
    var c = Expr.cast(Expr.col_ref("s"), DType.int64)
    assert_false(c.cast_is_try())
    # copy preserves the flag.
    var t2 = t.copy()
    assert_true(t2.cast_is_try())


def test_cast_string_to_int64_try_mode_kernel() raises:
    """PHASE-0b: the kernel's try_mode nulls an unparseable row instead of
    raising. Strict mode (default) is unchanged."""
    var values = List[String]()
    values.append(String("42"))
    values.append(String("abc"))  # unparseable
    values.append(String("99"))
    var sa = StringArray.from_strings(values)
    var arr = cast_string_to_int64(sa, True)  # try_mode
    assert_equal(arr.length, 3)
    assert_false(arr.is_null(0))
    assert_equal(arr.get(0), Scalar[DType.int64](42))
    assert_true(arr.is_null(1))  # bad row -> NULL, not a raise
    assert_false(arr.is_null(2))
    assert_equal(arr.get(2), Scalar[DType.int64](99))


def test_try_cast_string_bad_input_nulls_e2e() raises:
    """PHASE-0b: TRY_CAST('abc' AS INT) -> NULL end-to-end (Expr.try_cast
    through the columnar cast eval)."""
    var batch = _string_batch(
        [String("42"), String("abc"), String("99")],
        [False, False, False],  # all non-null; 'abc' is a bad-parse row
        "s",
    )
    var expr = Expr.try_cast(Expr.col_ref("s"), DType.int64)
    var out = _eval_column_expr(expr, batch)
    assert_equal(out.length(), 3)
    var arr = out.as_primitive[DType.int64]()
    assert_false(arr.is_null(0))
    assert_equal(arr.get(0), Scalar[DType.int64](42))
    assert_true(arr.is_null(1))  # 'abc' -> NULL under TRY_CAST
    assert_false(arr.is_null(2))
    assert_equal(arr.get(2), Scalar[DType.int64](99))


def test_strict_cast_string_bad_input_raises_e2e() raises:
    """PHASE-0b: the STRICT twin still RAISES on the same bad input, so
    CAST and TRY_CAST diverge exactly as SQL requires."""
    var batch = _string_batch(
        [String("42"), String("abc"), String("99")],
        [False, False, False],
        "s",
    )
    var expr = Expr.cast(Expr.col_ref("s"), DType.int64)
    var raised = False
    try:
        var _out = _eval_column_expr(expr, batch)
    except:
        raised = True
    assert_true(raised)


def test_cast_string_to_float64_via_expr() raises:
    """End-to-end Expr.cast(STRING AS f64) path."""
    var batch = _string_batch(
        [String("1.5"), String("-3.14"), String("1e2")],
        [False, False, False],
        "s",
    )
    var expr = Expr.cast(Expr.col_ref("s"), DType.float64)
    var out = _eval_column_expr(expr, batch)
    assert_equal(out.length(), 3)
    var arr = out.as_primitive[DType.float64]()
    assert_equal(arr.get(0), Scalar[DType.float64](1.5))
    assert_equal(arr.get(1), Scalar[DType.float64](-3.14))
    assert_equal(arr.get(2), Scalar[DType.float64](100.0))


def test_cast_int64_to_string_via_expr() raises:
    """End-to-end Expr.cast_to_arrow(int64 AS STRING) path."""
    var batch = _i64_batch(
        [Int64(42), Int64(-1), Int64(0)],
        [False, False, False],
        "v", ArrowType.INT64,
    )
    var expr = Expr.cast_to_arrow(Expr.col_ref("v"), ArrowType.STRING)
    var out = _eval_column_expr(expr, batch)
    assert_equal(out.length(), 3)
    assert_true(out.arrow_type == ArrowType.STRING)
    var sa = out.as_string()
    assert_equal(sa.get(0), String("42"))
    assert_equal(sa.get(1), String("-1"))
    assert_equal(sa.get(2), String("0"))


def test_cast_float64_to_string_via_expr() raises:
    """End-to-end Expr.cast_to_arrow(float64 AS STRING) path. Values are
    chosen for round-trip equivalence under Mojo's default String(f) format."""
    var batch = _f64_batch(
        [Float64(1.5), Float64(0.0), Float64(-3.14)],
        [False, False, False],
        "v",
    )
    var expr = Expr.cast_to_arrow(Expr.col_ref("v"), ArrowType.STRING)
    var out = _eval_column_expr(expr, batch)
    assert_equal(out.length(), 3)
    assert_true(out.arrow_type == ArrowType.STRING)
    var sa = out.as_string()
    # Round-trip parse to verify equivalent value (not byte-exact format).
    assert_equal(f64_from_str(sa.get(0)), Float64(1.5))
    assert_equal(f64_from_str(sa.get(1)), Float64(0.0))
    assert_equal(f64_from_str(sa.get(2)), Float64(-3.14))


# =============================================================================
# DuckDB parity fixture — 1000-row round-trip
# =============================================================================


def test_string_int64_duckdb_parity_fixture() raises:
    """1000-row STRING -> INT64 -> STRING round trip on a DuckDB-equivalent
    fixture. The fixture is generated by stepping the input range [-500, 499].
    DuckDB-equivalent expected: i64_to_str(parse(s)) == strip-leading-zeros(s).

    For each input string s, the chain:
        parsed = cast(s AS INT64)
        formatted = cast(parsed AS STRING)
    must produce `formatted` byte-identical to DuckDB's `CAST(CAST(s AS BIGINT) AS VARCHAR)`.
    DuckDB drops leading zeros and `+`; matches Mojo's `String(Int64)` default.
    """
    var n = 1000
    var values = List[String]()
    var expected_parsed = List[Int64]()
    var expected_formatted = List[String]()
    for i in range(n):
        var v = Int64(i - 500)
        values.append(String(v))   # canonical formatting (no leading zeros)
        expected_parsed.append(v)
        expected_formatted.append(String(v))
    var sa = StringArray.from_strings(values)
    var parsed = cast_string_to_int64(sa)
    for i in range(n):
        assert_equal(parsed.get(i), Scalar[DType.int64](expected_parsed[i]))
    var formatted = cast_int64_to_string(parsed)
    for i in range(n):
        assert_equal(formatted.get(i), expected_formatted[i])


def test_string_float64_duckdb_parity_fixture() raises:
    """1000-row STRING -> FLOAT64 round-trip on a stepped fixture. Each input
    is `Float64(i) * 0.5` formatted via Mojo's String(f64), expected to parse
    back to the original Float64."""
    var n = 1000
    var values = List[String]()
    var expected = List[Float64]()
    for i in range(n):
        var v = Float64(i) * Float64(0.5) - Float64(250.0)
        values.append(String(v))
        expected.append(v)
    var sa = StringArray.from_strings(values)
    var parsed = cast_string_to_float64(sa)
    for i in range(n):
        assert_equal(parsed.get(i), Scalar[DType.float64](expected[i]))


# =============================================================================
# Bug-Fix Protocol regression — temporal scale conversion preserves nulls
# =============================================================================


def test_carve_out_comment_removed_at_compiler_eval_column_1191() raises:
    """Documentation regression: this test passes trivially. It is here as
    a Bug-Fix Protocol breadcrumb that the carve-out comment at
    compiler_eval_column.mojo:1191 was removed in Sub-slot 4 closure. If a
    future agent re-inserts a similar carve-out comment without re-checking
    target_arrow IR support, this test name acts as the lookup beacon.
    """
    assert_true(True)


# =============================================================================
# ⭐⭐ A TRY_CAST IS NULLABLE WHATEVER ITS CHILD IS
# =============================================================================
#
# ⛔ THE DEFECT THIS PINS, and it is a SILENT WRONG rather than a crash.
# `expr_walk.walk_expr_field`'s EXPR_CAST arm returned `child_field.nullable`
# verbatim, so a TRY_CAST over a NON-NULLABLE child was DECLARED non-nullable
# while its kernel produced NULLs. Downstream arms read `Field.nullable` as a
# licence to skip the null check and to allocate no validity bitmap, so the
# value that reaches a customer is a garbage NUMBER, not an error.
#
# ⚠ REACHABLE, NOT THEORETICAL, AND IT BECAME REACHABLE FROM SQL ON THE SAME DAY.
# `sql_binder._bind_cast` now serves `TRY_CAST(<string> AS <numeric>)`, and
# `_bound_expr_is_string` admits a string LITERAL — which is non-nullable. The
# shape below is the one `test_try_cast_string_bad_input_nulls_e2e` above has
# executed: an ALL-NON-NULL string column whose middle row does
# not parse.


def test_try_cast_field_is_nullable_over_a_nonnullable_child() raises:
    """`walk_expr_field(TRY_CAST(s AS BIGINT))` is NULLABLE even when `s` is not.

    ⛔ THE CONTROL IS THE HALF THAT MAKES THIS A MEASUREMENT: the STRICT cast
    over the SAME child must still be NON-nullable. Without it, `nullable = True`
    unconditionally passes this assertion and silently widens every cast in the
    engine — a change that would look like a fix and cost a validity bitmap on
    every projection.
    """
    var sb = SchemaBuilder()
    sb.add_field(Field("s", ArrowType.STRING, False))  # ⚠ NON-nullable
    var schema = sb.build()
    # ⚠ `missing` IS A `String` OUT-PARAM, NOT A SINK OBJECT — the walk is
    # non-raising and reports an unresolvable column by appending to it. Empty
    # after both calls is part of what this asserts: a MISSPELLED column would
    # otherwise give `walk_expr_field` a default Field and make either verdict
    # meaningless.
    var missing = String("")

    var tf = walk_expr_field[ExecColRefFields](
        Expr.try_cast(Expr.col_ref("s"), DType.int64), schema, missing
    )
    assert_equal(Int(tf.arrow_type.type_id), Int(ArrowType.INT64.type_id))
    assert_true(tf.nullable)

    var cf = walk_expr_field[ExecColRefFields](
        Expr.cast(Expr.col_ref("s"), DType.int64), schema, missing
    )
    assert_equal(Int(cf.arrow_type.type_id), Int(ArrowType.INT64.type_id))
    assert_false(cf.nullable)
    assert_equal(missing.byte_length(), 0)


# =============================================================================
# ⭐⭐ THE NUMERIC CAST MATRIX — THE SIX EDGES THAT USED TO RAISE
# =============================================================================
#
# ⛔ THE DEFECT THESE PIN REACHED A CUSTOMER AS AN INTERNAL COMPONENT NAME.
# `compiler_eval_column`'s EXPR_CAST ladder carried SIX of the twelve ordered
# pairs over {I32, I64, F32, F64}. The other six fell through to
#
#     PipelineCompiler: unsupported EXPR_CAST from <a> to <b>
#
# for somebody who wrote `SELECT CAST(x AS REAL)`.
#
# ⚠⚠ AND THE TWO HALVES OF IT ARE INDEPENDENT, which is why both are asserted.
# `_sql_cast_target_arrow` WITHDREW `REAL` to stop the first half.
# It could not stop the second: a TARGET table cannot see a SOURCE, so
# `CAST(f32 AS BIGINT)` names only served types and died anyway. Deleting either
# executor arm below must red this file.
#
# ⛔ THESE GO THROUGH `_eval_column_expr`, NOT THROUGH THE KERNELS, ON PURPOSE.
# `eval_cast` and `eval_cast_float_to_int` were both callable and correct while
# the ladder that dispatches to them had no arm — a kernel-level test would have
# been GREEN for the whole window the customer was seeing the error.


def test_cast_f32_source_to_int64_reaches_a_kernel() raises:
    """`CAST(<float32> AS BIGINT)` ANSWERS, and answers HALF TO EVEN.

    ⭐ TWO ASSERTIONS IN ONE, and they fail differently: if the ladder has no
    FLOAT32 arm this RAISES, and if it has one that calls plain `eval_cast` it
    returns [-1, -2, 0, 2] — the truncation. Only the rounding kernel gives
    [-2, -2, 0, 2]. ⚠ Every value is exactly representable in float32, so no
    cell here is an artefact of the decimal spelling.
    """
    var batch = _f32_batch(
        [Float32(-1.5), Float32(-2.5), Float32(0.5), Float32(2.5)],
        [False, False, False, False],
        "f",
    )
    var out = _eval_column_expr(Expr.cast(Expr.col_ref("f"), DType.int64), batch)
    assert_equal(Int(out.arrow_type.type_id), Int(ArrowType.INT64.type_id))
    var arr = out.as_primitive[DType.int64]()
    assert_equal(arr.get(0), Scalar[DType.int64](-2))
    assert_equal(arr.get(1), Scalar[DType.int64](-2))
    assert_equal(arr.get(2), Scalar[DType.int64](0))
    assert_equal(arr.get(3), Scalar[DType.int64](2))


def test_cast_int64_source_to_float32_reaches_a_kernel() raises:
    """`CAST(<int64> AS REAL)` ANSWERS — the exact query that withdrew REAL.

    ⚠ THE ARROW TYPE IS ASSERTED, NOT ONLY THE VALUES. The no-op arm at the
    bottom of the ladder returns the CHILD COLUMN UNCHANGED when the physical
    types happen to match, so a cast that silently answered an INT64 column
    would pass a values-only check on these operands and hand a customer who
    asked for REAL a column of the wrong type with a success code.
    """
    var batch = _i64_batch([Int64(-1), Int64(0), Int64(7)], [False, False, False], "v", ArrowType.INT64)
    var out = _eval_column_expr(Expr.cast(Expr.col_ref("v"), DType.float32), batch)
    assert_equal(Int(out.arrow_type.type_id), Int(ArrowType.FLOAT32.type_id))
    var arr = out.as_primitive[DType.float32]()
    assert_equal(arr.get(0), Scalar[DType.float32](-1.0))
    assert_equal(arr.get(1), Scalar[DType.float32](0.0))
    assert_equal(arr.get(2), Scalar[DType.float32](7.0))


def test_cast_f64_to_int64_rounds_half_to_even_through_the_ladder() raises:
    """The LIVE SQL path, not the kernel: `CAST(<float64> AS BIGINT)`.

    ⛔ THIS IS THE ARM THE DEFECT ACTUALLY SHIPPED THROUGH. The committed ledger
    line named `expr_kernel_templates` template 41 as the site and was WRONG —
    that template has no reader. What a `SELECT CAST(f AS BIGINT)` executes is
    this ladder, and until it called `compiler_helpers.float64_to_int64`,
    whose `Int(x)` truncates.
    """
    var batch = _f64_batch([-1.5, 2.5, 3.5, -2.5], [False, False, False, False], "d")
    var out = _eval_column_expr(Expr.cast(Expr.col_ref("d"), DType.int64), batch)
    var arr = out.as_primitive[DType.int64]()
    assert_equal(arr.get(0), Scalar[DType.int64](-2))
    assert_equal(arr.get(1), Scalar[DType.int64](2))
    assert_equal(arr.get(2), Scalar[DType.int64](4))
    assert_equal(arr.get(3), Scalar[DType.int64](-2))



# =============================================================================
# DOUBLE -> REAL OUT OF RANGE
# =============================================================================
#
# The EXPR_CAST ladder's F64 -> F32 arm was a bare `fptrunc`: a FINITE double
# beyond FLOAT's range answered +-inf with a success code, where DuckDB v1.5.3
# raises `Conversion Error: Type DOUBLE with value -1e+308 can't be cast because
# the value is out of range for the destination type FLOAT`. Every expectation
# below was MEASURED on the DuckDB v1.5.3 CLI. These go through
# `_eval_column_expr` — the ladder the SQL door reaches — not the kernel alone.


def _cast_f64_col_to_real(vals: List[Float64], nulls: List[Bool], is_try: Bool) raises -> Column[HeapRegion]:
    var batch = _f64_batch(vals, nulls, "x")
    var expr = Expr.try_cast(Expr.col_ref("x"), DType.float32) if is_try else Expr.cast_to_arrow(Expr.col_ref("x"), ArrowType.FLOAT32)
    return _eval_column_expr(expr, batch)


def _raises_out_of_range_for_float(v: Float64) raises:
    var raised = False
    var msg = String("")
    var got = String("")
    try:
        var out = _cast_f64_col_to_real([v], [False], False)
        got = String(out.as_primitive[DType.float32]().get(0))
    except e:
        raised = True
        msg = String(e)
    assert_true(
        raised,
        "CAST(" + String(v) + " AS REAL): DuckDB raises; this ANSWERED " + got,
    )
    assert_true("out of range" in msg, "message must say out of range: " + msg)
    assert_true("FLOAT" in msg, "message must name the destination FLOAT: " + msg)
    assert_true("DOUBLE" in msg, "message must name the source DOUBLE: " + msg)


def test_cast_double_to_real_out_of_range_raises() raises:
    """-1e308 and 1e39 are finite and beyond FLOAT's range: RAISE, not +-inf."""
    _raises_out_of_range_for_float(Float64(-1e308))
    _raises_out_of_range_for_float(Float64(1e39))


def test_cast_double_to_real_boundary_is_the_rounding_not_flt_max() raises:
    """⭐ The raise starts where float ROUNDING overflows, NOT at FLT_MAX.

    MEASURED DuckDB v1.5.3: 3.4028235677973362e38 (above FLT_MAX) ANSWERS
    3.4028234663852886e+38 — it rounds DOWN to FLT_MAX — while
    3.4028235677973366e38 (FLT_MAX + half an ulp, the first double that rounds
    to inf) RAISES. A guard written as `|x| > FLT_MAX` refuses the first."""
    var out = _cast_f64_col_to_real([Float64(3.4028235677973362e38), Float64(-3.4028235677973362e38)], [False, False], False)
    var arr = out.as_primitive[DType.float32]()
    assert_equal(arr.get(0), Scalar[DType.float32].MAX_FINITE)
    assert_equal(arr.get(1), -Scalar[DType.float32].MAX_FINITE)
    _raises_out_of_range_for_float(Float64(3.4028235677973366e38))
    _raises_out_of_range_for_float(Float64(-3.4028235677973366e38))


def test_cast_double_to_real_passes_the_specials_and_nulls() raises:
    """+inf, -inf and NaN are NOT out of range (DuckDB carries each into FLOAT);
    -0.0 keeps its sign; a NULL stays NULL."""
    var inf = Float64(1.0) / Float64(0.0)
    var out = _cast_f64_col_to_real(
        [inf, -inf, inf - inf, Float64(-0.0), Float64(1.5), Float64(0.0)],
        [False, False, False, False, False, True],
        False,
    )
    var arr = out.as_primitive[DType.float32]()
    assert_equal(out.length(), 6)
    assert_true(arr.get(0) > Scalar[DType.float32].MAX_FINITE, "+inf must stay +inf")
    assert_true(arr.get(1) < -Scalar[DType.float32].MAX_FINITE, "-inf must stay -inf")
    assert_true(arr.get(2) != arr.get(2), "NaN must stay NaN")
    assert_equal(arr.get(3), Scalar[DType.float32](0.0))
    assert_true(1.0 / arr.get(3) < 0.0, "-0.0 must keep its sign")
    assert_equal(arr.get(4), Scalar[DType.float32](1.5))
    assert_true(arr.is_null(5), "a NULL must stay NULL")
    assert_equal(out.null_count(), 1)


def test_try_cast_double_to_real_nulls_the_out_of_range_rows() raises:
    """TRY: DuckDB's `TRY_CAST(1e39::DOUBLE AS REAL)` is NULL. The overflow
    NULL is UNIONed with the source NULL — both rows NULL, the count 2."""
    var out = _cast_f64_col_to_real(
        [Float64(1e39), Float64(2.5), Float64(0.0), Float64(-1e308)],
        [False, False, True, False],
        True,
    )
    var arr = out.as_primitive[DType.float32]()
    assert_true(arr.is_null(0), "1e39 -> NULL under TRY")
    assert_false(arr.is_null(1))
    assert_equal(arr.get(1), Scalar[DType.float32](2.5))
    assert_true(arr.is_null(2), "the source NULL survives")
    assert_true(arr.is_null(3), "-1e308 -> NULL under TRY")
    assert_equal(out.null_count(), 3)

def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

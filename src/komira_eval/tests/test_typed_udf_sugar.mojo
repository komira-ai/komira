# =============================================================================
# test_typed_udf_sugar.mojo — FIVE typed UDFs a real customer would write
# =============================================================================
#
# Each one is written the way a customer would actually write it: a plain Mojo
# function, then one comptime line naming its columns. A hand-written
# conformer needs 2 structs and ~16 lines for the same thing.
# =============================================================================

from std.testing import assert_equal, assert_true, TestSuite
from komira_eval.map_fn import MapFn
from komira_eval.typed_udf_sugar import Map1, Map2, Row1, Row2, SumOf2
from komira_eval.schema_descriptor import DT_F64, DT_I64, DT_BOOL


# =============================================================================
# UDF 1 — scalar arithmetic (the "a * 10" case the design doc promises in 1-3 lines)
# =============================================================================
def scale_by_ten(a: Int64) -> Int64:
    return a * 10

comptime ScaleByTen = Map1[f=scale_by_ten, out_name="a10", in0="a"]


# =============================================================================
# UDF 2 — over TWO columns (the canonical worked example)
# =============================================================================
def margin(price: Float64, cost: Float64) -> Float64:
    return (price - cost) / price

comptime Margin = Map2[f=margin, out_name="margin", in0="price", in1="cost"]


# =============================================================================
# UDF 3 — CHANGING TYPE (Float64 -> bool column).
#
# ⚠ ERGONOMIC DEFECT, MEASURED: the customer's NATURAL spelling `-> Bool` does
# NOT bind. `Bool` and `Scalar[DType.bool]` (= `SIMD[DType.bool, 1]`) are
# distinct types in Mojo 1.0.0, so `def is_expensive(price: Float64) -> Bool`
# fails with "cannot be converted from 'def is_expensive(price: Float64) thin
# -> Bool' to 'def($1|0) thin -> Scalar[$1|1]'". The workaround below leaks an
# engine type (`Scalar[DType.bool]`) into customer code, which is exactly the
# kind of ceremony this file exists to delete. Fixable with a `-> Bool`
# overload of the adapter; not fixable by the customer.
# =============================================================================
def is_expensive(price: Float64) -> Scalar[DType.bool]:
    return price > 100.0

comptime IsExpensive = Map1[f=is_expensive, out_name="is_expensive", in0="price"]


# =============================================================================
# UDF 4 — changing type the other way (Float64 -> Int64), two columns.
# =============================================================================
def total_cents(price: Float64, qty: Float64) -> Int64:
    return Int64(price * qty * 100.0)

comptime TotalCents = Map2[f=total_cents, out_name="total_cents", in0="price", in1="qty"]


# =============================================================================
# UDF 5 — ONE `def`, TWO different column pairs. This is why the column names
# are named at the CALL SITE and not derived from the parameter names: the same
# function is a different UDF over different columns.
# =============================================================================
comptime MarginRetail = Map2[f=margin, out_name="retail_margin", in0="retail_price", in1="retail_cost"]


# =============================================================================
# Tests
# =============================================================================

def test_scalar_arithmetic() raises:
    var f = ScaleByTen()
    assert_equal(f.run_row(Row1[Int64](Int64(7))), Int64(70))
    assert_equal(f.run_row(Row1[Int64](Int64(-3))), Int64(-30))


def test_two_column_margin() raises:
    var f = Margin()
    assert_equal(f.run_row(Row2[Float64, Float64](100.0, 60.0)), Float64(0.4))
    assert_equal(f.run_row(Row2[Float64, Float64](200.0, 50.0)), Float64(0.75))


def test_type_changing_to_bool() raises:
    var f = IsExpensive()
    assert_equal(f.run_row(Row1[Float64](150.0)), True)
    assert_equal(f.run_row(Row1[Float64](50.0)), False)


def test_type_changing_float_to_int() raises:
    var f = TotalCents()
    assert_equal(f.run_row(Row2[Float64, Float64](2.50, 4.0)), Int64(1000))


def test_schema_is_derived_from_the_function() raises:
    """The customer declared NO types and NO schema. Both are derived: the
    column NAMES from the call site, the DTYPES from the function signature."""
    comptime IN_N = len(Margin.InputSchema.cols)
    comptime IN0 = String(Margin.InputSchema.cols[0].name)
    comptime IN1 = String(Margin.InputSchema.cols[1].name)
    comptime IN0_D = Margin.InputSchema.cols[0].dtype
    comptime OUT_N = String(Margin.OutputSchema.cols[0].name)
    comptime OUT_D = Margin.OutputSchema.cols[0].dtype
    assert_equal(IN_N, 2)
    assert_equal(IN0, "price")
    assert_equal(IN1, "cost")
    assert_equal(IN0_D, DT_F64)
    assert_equal(OUT_N, "margin")
    assert_equal(OUT_D, DT_F64)
    # derived from `is_expensive`'s Bool return -- the customer wrote no dtype
    comptime BOOL_D = IsExpensive.OutputSchema.cols[0].dtype
    assert_equal(BOOL_D, DT_BOOL)
    # derived from `total_cents`'s Int64 return
    comptime INT_D = TotalCents.OutputSchema.cols[0].dtype
    assert_equal(INT_D, DT_I64)


def test_udf_id_is_derived_and_distinct() raises:
    """The customer picks no global integer. Distinct UDFs get distinct ids,
    and the SAME function over DIFFERENT columns is a DIFFERENT UDF."""
    comptime A = Margin.UDF_ID
    comptime B = MarginRetail.UDF_ID
    comptime C = TotalCents.UDF_ID
    assert_true(A != B, "same fn, different columns -> must differ")
    assert_true(A != C, "different UDFs -> must differ")
    assert_true(A >= UInt32(10000), "must not land in the hand-assigned [7000,9999] range")
    assert_true(B >= UInt32(10000))


def test_one_function_serves_two_column_pairs() raises:
    """`margin` is declared once and used as two distinct UDFs."""
    var a = Margin()
    var b = MarginRetail()
    assert_equal(a.run_row(Row2[Float64, Float64](100.0, 60.0)), Float64(0.4))
    assert_equal(b.run_row(Row2[Float64, Float64](100.0, 60.0)), Float64(0.4))
    comptime BN = String(MarginRetail.InputSchema.cols[0].name)
    assert_equal(BN, "retail_price")


def test_conforms_to_the_real_MapFn_trait() raises:
    """Generic over `MapFn` -- proves these are usable anywhere the engine
    takes a typed UDF, not a parallel surface."""
    _assert_is_mapfn[ScaleByTen]()
    _assert_is_mapfn[Margin]()
    _assert_is_mapfn[IsExpensive]()
    _assert_is_mapfn[TotalCents]()


def _assert_is_mapfn[M: MapFn]() raises:
    comptime N = len(M.OutputSchema.cols)
    assert_equal(N, 1, "a MapFn produces exactly one output column")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()


# =============================================================================
# UDF 5 — an AGGREGATE. Same plain `def` as UDF 2; only the reduction is named.
# The customer writes NO state struct, NO init/update/merge/finalize.
# =============================================================================
comptime SumMargin = SumOf2[f=margin, out_name="sum_margin", in0="price", in1="cost"]


def test_aggregate_over_a_plain_function() raises:
    var a = SumMargin()
    var s = a.init()
    a.update(s, Row2[Float64, Float64](100.0, 60.0))   # 0.40
    a.update(s, Row2[Float64, Float64](200.0, 50.0))   # 0.75
    assert_equal(a.finalize(s), Float64(1.15))


def test_aggregate_merge_is_parallel_correct() raises:
    """Two workers fold disjoint morsels; merge must equal the serial fold.
    This is the contract that cannot be derived from `update` -- which is why
    a custom `AggFn` still has five methods."""
    var a = SumMargin()
    var w0 = a.init()
    var w1 = a.init()
    a.update(w0, Row2[Float64, Float64](100.0, 60.0))
    a.update(w1, Row2[Float64, Float64](200.0, 50.0))
    assert_equal(a.finalize(a.merge(w0, w1)), Float64(1.15))


def test_aggregate_schema_is_derived() raises:
    comptime ON = String(SumMargin.OutputSchema.cols[0].name)
    comptime OD = SumMargin.OutputSchema.cols[0].dtype
    comptime IN0 = String(SumMargin.InputSchema.cols[0].name)
    assert_equal(ON, "sum_margin")
    assert_equal(OD, DT_F64)
    assert_equal(IN0, "price")


# =============================================================================
# UDF 6 — a UDF whose INPUT is a bool column (e.g. chained after `is_expensive`).
#
# ⚠ THIS IS THE OTHER HALF OF THE BOOL HAZARD. Both sides derive their tag via
# `_dtag_of_dtype`. Deriving the INPUT tag from the Mojo TYPE via `_dtag_for`
# would answer DT_UNKNOWN (-1) for `Scalar[DType.bool]` — `SIMD[DType.bool, 1]`
# is not the type `Bool` — so the plan node would advertise an UNKNOWN-typed
# INPUT column and no error would fire. Float64/Int64 hide it on this side too.
# =============================================================================
def not_flag(b: Scalar[DType.bool]) -> Scalar[DType.bool]:
    return not b

comptime NotFlag = Map1[f=not_flag, out_name="not_flag", in0="flag"]


def test_bool_input_column_dtype_is_derived() raises:
    """The INPUT tag must be derived as exactly as the OUTPUT tag."""
    comptime IN_D = NotFlag.InputSchema.cols[0].dtype
    comptime OUT_D = NotFlag.OutputSchema.cols[0].dtype
    assert_equal(IN_D, DT_BOOL)
    assert_equal(OUT_D, DT_BOOL)
    var f = NotFlag()
    assert_equal(f.run_row(Row1[Scalar[DType.bool]](True)), False)


# =============================================================================
# The derived `UDF_ID` does NOT identify the FUNCTION — only its columns.
#
# This pins a KNOWN LIMITATION rather than a feature. `udf_id_*` hashes the
# column names, and two DIFFERENT functions over the SAME columns therefore
# collide. It cannot be fixed by a better hash: `twice` and `thrice` have the
# SAME Mojo type (`def(Int64) thin -> Int64`), so comptime has nothing to
# distinguish them with — `reflect[type_of(f)]` returns the same `Reflected[...]` for both.
#
# It is safe ONLY because the typed path builds no `UdfData` node, so nothing
# reads `UDF_ID` there. Anything that DOES read it to answer "which UDF is
# this" must not be fed these adapters. If this test ever goes red because the
# ids now differ, the limitation was lifted — delete the test and say how.
# =============================================================================
def twice(a: Int64) -> Int64:
    return a * 2

def thrice(a: Int64) -> Int64:
    return a * 3

comptime Twice = Map1[f=twice, out_name="y", in0="a"]
comptime Thrice = Map1[f=thrice, out_name="y", in0="a"]


def test_udf_id_does_NOT_identify_the_function() raises:
    comptime A = Twice.UDF_ID
    comptime B = Thrice.UDF_ID
    assert_equal(A, B, "known limitation: the id hashes columns, not the fn")

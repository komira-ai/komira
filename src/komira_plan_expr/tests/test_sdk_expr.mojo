# =============================================================================
# Tests for SDK Expr type system, ColExpr operator overloading, AggExpr
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

# `min` / `max` do not resolve when imported through a wildcard re-export
# (Mojo treats them as shadowed by the builtin `min(x,y)` / `max(x,y)` during
# overload resolution at the call site), so they are imported directly from
# the canonical agg_expr / col_expr / expr modules.
from komira_arrow.dtype_sentinel import DTYPE_NONE
from komira_plan_expr.expr import (
    Expr,
    ScalarValue,
    WhenCaseData,
    EXPR_COL_REF,
    EXPR_COL_IDX,
    EXPR_LITERAL,
    EXPR_BINARY_OP,
    EXPR_UNARY_OP,
    EXPR_CAST,
    EXPR_ALIAS,
    EXPR_WHEN,
    BIN_ADD,
    BIN_SUB,
    BIN_MUL,
    BIN_DIV,
    BIN_MOD,
    BIN_EQ,
    BIN_NE,
    BIN_LT,
    BIN_LE,
    BIN_GT,
    BIN_GE,
    BIN_AND,
    BIN_OR,
    UN_NOT,
    UN_NEGATE,
    UN_IS_NULL,
    UN_IS_NOT_NULL,
)
# `binop_name` / `unop_name` live in `komira_plan_expr.expr_helpers`.
from komira_plan_expr.expr_helpers import binop_name, unop_name
from komira_plan_expr.col_expr import ColExpr, col, lit

# Mojo 1.0.0 removed `DType.invalid`. `ScalarValue`'s NULL discriminant is
# `dtype == DTYPE_NONE` (`ScalarValue.is_null`), so the assertions
# below read the same constant the type writes.
from komira_arrow.dtype_sentinel import DTYPE_NONE
from komira_plan_expr.agg_expr import (
    AggExpr,
    AGG_SUM,
    AGG_COUNT,
    AGG_MIN,
    AGG_MAX,
    AGG_MEAN,
    AGG_COUNT_DISTINCT,
    AGG_FIRST,
    AGG_LAST,
    sum,
    count,
    min,
    max,
    mean,
    count_distinct,
    first,
    last,
)


# =============================================================================
# 1. ColRef creation
# =============================================================================

def test_col_creates_col_ref() raises:
    """col('age') creates a ColRef Expr."""
    var c = col("age")
    var e = c.copy_expr()
    assert_true(e.is_col_ref(), "expected ColRef")
    assert_equal(e.col_ref_name(), "age")


# =============================================================================
# 2. Literal creation (Int)
# =============================================================================

def test_lit_int_creates_literal() raises:
    """lit(42) creates a Literal Expr with int value."""
    var c = lit(42)
    var e = c.copy_expr()
    assert_true(e.is_literal(), "expected Literal")
    var sv = e.literal_value()
    assert_true(sv.is_int(), "expected int scalar")
    assert_equal(Int(sv.int_val), 42)


# =============================================================================
# 3. col("age") > 25 creates BinaryOp(GT, ColRef, Literal)
# =============================================================================

def test_col_gt_int() raises:
    """col('age') > 25 creates BinaryOp(GT, ColRef, Literal(25))."""
    var e = col("age") > 25
    assert_true(e.is_binary(), "expected BinaryOp")
    assert_equal(Int(e.binary_op()), Int(BIN_GT))
    assert_true(e.binary_left_ref().is_col_ref(), "left should be ColRef")
    assert_equal(e.binary_left_ref().col_ref_name(), "age")
    assert_true(e.binary_right_ref().is_literal(), "right should be Literal")
    var rv = e.binary_right_ref().literal_value()
    assert_equal(Int(rv.int_val), 25)


# =============================================================================
# 4. col("age") > 3.14 uses Float64 overload
# =============================================================================

def test_col_gt_float() raises:
    """col('age') > 3.14 uses Float64 overload."""
    var e = col("age") > 3.14
    assert_true(e.is_binary(), "expected BinaryOp")
    assert_equal(Int(e.binary_op()), Int(BIN_GT))
    var rv = e.binary_right_ref().literal_value()
    assert_true(rv.is_float(), "expected float scalar")


# =============================================================================
# 5. col("age") > col("score") uses ColExpr overload
# =============================================================================

def test_col_gt_col() raises:
    """col('age') > col('score') compares two columns."""
    var e = col("age") > col("score")
    assert_true(e.is_binary(), "expected BinaryOp")
    assert_equal(Int(e.binary_op()), Int(BIN_GT))
    assert_true(e.binary_left_ref().is_col_ref(), "left should be ColRef")
    assert_true(e.binary_right_ref().is_col_ref(), "right should be ColRef")
    assert_equal(e.binary_right_ref().col_ref_name(), "score")


# =============================================================================
# 6. col("a") + col("b") returns ColExpr (chainable)
# =============================================================================

def test_col_add_col_returns_col_expr() raises:
    """col('a') + col('b') returns a ColExpr wrapping BinaryOp(ADD)."""
    var result = col("a") + col("b")
    # result is a ColExpr -- verify it wraps a BinaryOp
    var e = result.copy_expr()
    assert_true(e.is_binary(), "expected BinaryOp")
    assert_equal(Int(e.binary_op()), Int(BIN_ADD))


# =============================================================================
# 7. col("a") * 2 + 1 chains correctly (nested tree)
# =============================================================================

def test_arithmetic_chaining() raises:
    """Chaining col('a') * 2 + 1 produces nested BinaryOp tree: ADD(MUL(ColRef, 2), 1)."""
    var result = col("a") * 2 + 1
    var e = result.copy_expr()
    # Top level: ADD
    assert_true(e.is_binary(), "top should be BinaryOp")
    assert_equal(Int(e.binary_op()), Int(BIN_ADD))
    # Left child: MUL(ColRef("a"), Literal(2)) -- use copy accessors
    var left = e.binary_left()
    assert_true(left.is_binary(), "left should be BinaryOp(MUL)")
    assert_equal(Int(left.binary_op()), Int(BIN_MUL))
    assert_true(left.binary_left_ref().is_col_ref(), "left.left should be ColRef")
    assert_equal(left.binary_left_ref().col_ref_name(), "a")
    # Right child of top: Literal(1) -- use copy accessor
    var right = e.binary_right()
    assert_true(right.is_literal(), "right should be Literal(1)")
    assert_equal(Int(right.literal_value().int_val), 1)


# =============================================================================
# 8. col("x") > 5 & col("y") < 10 combines with AND
# =============================================================================

def test_and_combination() raises:
    """Two comparisons combined with & produce BinaryOp(AND)."""
    var left_expr = col("x") > 5
    var right_expr = col("y") < 10
    # Wrap left in ColExpr to use __and__
    var left_col = ColExpr(left_expr^)
    var combined = left_col & right_expr
    assert_true(combined.is_binary(), "expected BinaryOp")
    assert_equal(Int(combined.binary_op()), Int(BIN_AND))
    assert_true(combined.binary_left_ref().is_binary(), "left should be BinaryOp(GT)")
    assert_true(combined.binary_right_ref().is_binary(), "right should be BinaryOp(LT)")


# =============================================================================
# 9. is_col_ref(), is_literal(), is_binary() type checks
# =============================================================================

def test_expr_type_checks() raises:
    """Type check methods return correct values for different Expr variants."""
    var cr = Expr.col_ref("x")
    assert_true(cr.is_col_ref())
    assert_false(cr.is_literal())
    assert_false(cr.is_binary())

    var lit_e = Expr.literal(ScalarValue.from_int(42))
    assert_true(lit_e.is_literal())
    assert_false(lit_e.is_col_ref())
    assert_false(lit_e.is_binary())

    var bin_e = Expr.binary(BIN_ADD, Expr.col_ref("a"), Expr.col_ref("b"))
    assert_true(bin_e.is_binary())
    assert_false(bin_e.is_col_ref())
    assert_false(bin_e.is_literal())


# =============================================================================
# 10. col_ref_name() returns correct name
# =============================================================================

def test_col_ref_name_accessor() raises:
    """col_ref_name() returns the name string."""
    var e = Expr.col_ref("my_column")
    assert_equal(e.col_ref_name(), "my_column")


# =============================================================================
# 11. literal_value() returns correct ScalarValue
# =============================================================================

def test_literal_value_accessor() raises:
    """literal_value() returns the scalar value."""
    var e = Expr.literal(ScalarValue.from_int(99))
    var sv = e.literal_value()
    assert_true(sv.is_int())
    assert_equal(Int(sv.int_val), 99)


# =============================================================================
# 12. binary_left()/binary_right() traverse children
# =============================================================================

def test_binary_child_traversal() raises:
    """binary_left()/binary_right() return copies of children."""
    var e = Expr.binary(BIN_SUB, Expr.col_ref("x"), Expr.literal(ScalarValue.from_int(10)))
    var left = e.binary_left()
    var right = e.binary_right()
    assert_true(left.is_col_ref())
    assert_equal(left.col_ref_name(), "x")
    assert_true(right.is_literal())
    assert_equal(Int(right.literal_value().int_val), 10)


# =============================================================================
# 13. sum(col("x")).alias("total") creates AggExpr
# =============================================================================

def test_sum_with_alias() raises:
    """sum(col('x')).alias('total') creates a named AggExpr."""
    var agg = sum(col("x")).alias("total")
    assert_equal(Int(agg.func), Int(AGG_SUM))
    assert_true(agg.child.__bool__(), "SUM should have a child")
    assert_true(agg.alias_name.__bool__(), "should have alias")
    assert_equal(agg.alias_name.value(), "total")


# =============================================================================
# 14. count() creates AggExpr with no child
# =============================================================================

def test_count_star() raises:
    """count() creates COUNT(*) with no child expression."""
    var agg = count()
    assert_equal(Int(agg.func), Int(AGG_COUNT))
    assert_false(agg.child.__bool__(), "COUNT(*) should have no child")


# =============================================================================
# 15. WhenData construction
# =============================================================================

def test_when_construction() raises:
    """Expr.when() creates a WHEN expression with cases and default."""
    var cases = List[WhenCaseData]()
    cases.append(WhenCaseData(
        Expr.binary(BIN_GT, Expr.col_ref("age"), Expr.literal(ScalarValue.from_int(18))),
        Expr.literal(ScalarValue.from_string("adult")),
    ))
    var default = Expr.literal(ScalarValue.from_string("minor"))
    var e = Expr.when(cases^, default^)
    assert_true(e.is_when(), "expected WHEN")
    assert_equal(Int(e.tag), Int(EXPR_WHEN))


# =============================================================================
# 16. ScalarValue from_int roundtrip
# =============================================================================

def test_scalar_from_int() raises:
    """ScalarValue.from_int() stores and retrieves int value."""
    var sv = ScalarValue.from_int(42)
    assert_true(sv.is_int())
    assert_equal(Int(sv.int_val), 42)
    assert_equal(sv.dtype, DType.int64)


# =============================================================================
# 17. ScalarValue from_float roundtrip
# =============================================================================

def test_scalar_from_float() raises:
    """ScalarValue.from_float() stores and retrieves float value."""
    var sv = ScalarValue.from_float(3.14)
    assert_true(sv.is_float())
    assert_equal(sv.dtype, DType.float64)


# =============================================================================
# 18. ScalarValue from_string roundtrip
# =============================================================================

def test_scalar_from_string() raises:
    """ScalarValue.from_string() stores and retrieves string value."""
    var sv = ScalarValue.from_string("hello")
    assert_true(sv.is_string())
    assert_equal(sv.string_val, "hello")


# =============================================================================
# 18b. EMPTY-STRING is a VALUE, not NULL
# =============================================================================

def test_scalar_empty_string_is_not_null() raises:
    """`from_string("")` is a real, non-null empty string — NOT a NULL.

    An encoding of `from_string("")` as `(DTYPE_NONE, "")` would make
    `is_null()` report True and `is_string()` report False — conflating `''`
    with NULL. SQL (`'' <> NULL`) requires them distinct; the
    SCALAR_KIND_STRING encoding keeps them apart.
    """
    var empty = ScalarValue.from_string("")
    # The empty string is a string value, not a null.
    assert_true(empty.is_string())
    assert_false(empty.is_null())
    assert_equal(empty.string_val, "")

    # A real NULL is still a NULL and is not a string.
    var nul = ScalarValue.null(DType.int64)
    assert_true(nul.is_null())
    assert_false(nul.is_string())

    # The default (untyped) null is still a NULL.
    var default_nul = ScalarValue()
    assert_true(default_nul.is_null())
    assert_false(default_nul.is_string())


def test_scalar_empty_string_equality() raises:
    """`'' == ''`, `'' != NULL`, `'' != 'x'`, and non-empty
    strings stay byte-identical."""
    var e1 = ScalarValue.from_string("")
    var e2 = ScalarValue.from_string("")
    var x = ScalarValue.from_string("x")
    var nul = ScalarValue.null(DType.int64)
    var default_nul = ScalarValue()

    # Two empty strings are structurally equal.
    assert_true(e1 == e2)
    # An empty string is not a null (either typed or untyped).
    assert_true(e1 != nul)
    assert_true(e1 != default_nul)
    # An empty string is not a non-empty string.
    assert_true(e1 != x)

    # Non-empty behavior byte-identical: two equal non-empty strings match,
    # differing ones do not.
    var h1 = ScalarValue.from_string("hello")
    var h2 = ScalarValue.from_string("hello")
    assert_true(h1 == h2)
    assert_true(h1 != x)
    assert_true(h1.is_string())
    assert_equal(h1.string_val, "hello")


def test_scalar_empty_string_expr_roundtrip() raises:
    """an empty-string literal round-trips through the Expr IR as a
    non-null string (plan-side round-trip)."""
    var lit_e = Expr.literal(ScalarValue.from_string(""))
    assert_equal(lit_e.tag, EXPR_LITERAL)
    var back = lit_e.literal_value()
    assert_true(back.is_string())
    assert_false(back.is_null())
    assert_equal(back.string_val, "")


# =============================================================================
# 18c. MISSING LITERALS — narrow / unsigned integers
# =============================================================================

def test_scalar_narrow_signed_ints() raises:
    """int8 / int16 literals round-trip and equate."""
    var i8 = ScalarValue.from_int8(Int8(-5))
    assert_true(i8.is_signed_int_narrow())
    assert_true(i8.is_any_integer())
    assert_false(i8.is_int())  # is_int() is int64/int32 only
    assert_equal(i8.dtype, DType.int8)
    assert_equal(Int(i8.int_val), -5)
    assert_true(i8 == ScalarValue.from_int8(Int8(-5)))
    assert_true(i8 != ScalarValue.from_int8(Int8(-6)))

    var i16 = ScalarValue.from_int16(Int16(1000))
    assert_true(i16.is_signed_int_narrow())
    assert_equal(i16.dtype, DType.int16)
    assert_equal(Int(i16.int_val), 1000)
    # Different width => not equal even at the same numeric value.
    assert_true(i16 != ScalarValue.from_int8(Int8(100)))
    # int8 with the same value but different dtype is not equal to int16.
    assert_true(ScalarValue.from_int8(Int8(100)) != ScalarValue.from_int16(Int16(100)))


def test_scalar_unsigned_ints() raises:
    """uint8/16/32/64 literals round-trip, equate, and classify."""
    var u8 = ScalarValue.from_uint8(UInt8(200))
    assert_true(u8.is_uint())
    assert_true(u8.is_any_integer())
    assert_true(u8.fits_int64_family())
    assert_equal(Int(u8.int_val), 200)
    assert_true(u8 == ScalarValue.from_uint8(UInt8(200)))
    assert_true(u8 != ScalarValue.from_uint8(UInt8(201)))

    var u32 = ScalarValue.from_uint32(UInt32(4000000000))
    assert_true(u32.is_uint())
    assert_true(u32.fits_int64_family())
    assert_equal(Int(u32.int_val), 4000000000)

    # uint64 with the top bit set: value preserved via bit pattern, NOT
    # folded into the Int64 family (would flip sign).
    var big: UInt64 = UInt64(0x8000000000000001)
    var u64 = ScalarValue.from_uint64(big)
    assert_true(u64.is_uint())
    assert_false(u64.fits_int64_family())  # excluded — top bit set
    assert_equal(u64.uint64_value(), big)
    assert_true(u64 == ScalarValue.from_uint64(big))
    assert_true(u64 != ScalarValue.from_uint64(UInt64(1)))


# =============================================================================
# 18d. MISSING LITERALS — interval / time / duration
# =============================================================================

def test_scalar_interval() raises:
    """INTERVAL (month-day-nano) literal round-trips and equates,
    keeping the three components independent."""
    var iv = ScalarValue.interval_month_day_nano(Int32(14), Int32(3), Int64(500))
    assert_true(iv.is_interval())
    assert_false(iv.is_int())
    assert_equal(Int(iv.iv_months), 14)
    assert_equal(Int(iv.iv_days), 3)
    assert_equal(Int(iv.iv_nanos), 500)
    assert_true(iv == ScalarValue.interval_month_day_nano(Int32(14), Int32(3), Int64(500)))
    # Any component differing => not equal.
    assert_true(iv != ScalarValue.interval_month_day_nano(Int32(14), Int32(3), Int64(501)))
    assert_true(iv != ScalarValue.interval_month_day_nano(Int32(15), Int32(3), Int64(500)))


def test_scalar_time_of_day() raises:
    """TIME literal round-trips; value + unit both discriminate."""
    var t = ScalarValue.time_of_day(Int64(43200000000))  # noon, micros
    assert_true(t.is_time())
    assert_equal(Int(t.int_val), 43200000000)
    assert_true(t == ScalarValue.time_of_day(Int64(43200000000)))
    assert_true(t != ScalarValue.time_of_day(Int64(0)))
    # Same numeric value, different unit => not equal (3 = nano).
    assert_true(t != ScalarValue.time_of_day(Int64(43200000000), 3))


def test_scalar_duration() raises:
    """DURATION literal round-trips; distinct kind from TIME/INTERVAL."""
    var d = ScalarValue.duration(Int64(90000000))
    assert_true(d.is_duration())
    assert_false(d.is_time())
    assert_false(d.is_interval())
    assert_equal(Int(d.int_val), 90000000)
    assert_true(d == ScalarValue.duration(Int64(90000000)))
    assert_true(d != ScalarValue.duration(Int64(1)))
    # A TIME and a DURATION with the same value/unit are DIFFERENT kinds.
    assert_true(ScalarValue.duration(Int64(5)) != ScalarValue.time_of_day(Int64(5)))


# =============================================================================
# 18e. MISSING LITERALS — decimal256 / binary
# =============================================================================

def test_scalar_decimal256() raises:
    """DECIMAL256 literal round-trips all four limbs + (p,s)."""
    var dec = ScalarValue.decimal256(
        Int64(1), Int64(2), Int64(3), Int64(4), 40, 6
    )
    assert_true(dec.is_decimal256())
    assert_false(dec.is_decimal128())
    assert_equal(Int(dec.dec128_low), 1)
    assert_equal(Int(dec.dec128_high), 2)
    assert_equal(Int(dec.dec256_high_lo), 3)
    assert_equal(Int(dec.dec256_high_hi), 4)
    assert_equal(dec.dec128_precision, 40)
    assert_equal(dec.dec128_scale, 6)
    assert_true(dec == ScalarValue.decimal256(Int64(1), Int64(2), Int64(3), Int64(4), 40, 6))
    # Any limb differing => not equal.
    assert_true(dec != ScalarValue.decimal256(Int64(1), Int64(2), Int64(3), Int64(5), 40, 6))
    # Different scale => not equal.
    assert_true(dec != ScalarValue.decimal256(Int64(1), Int64(2), Int64(3), Int64(4), 40, 7))


def test_scalar_binary() raises:
    """BINARY literal round-trips its bytes and is DISTINCT from a
    Utf8 string with the same bytes."""
    var b = ScalarValue.from_binary(String("abc"))
    assert_true(b.is_binary())
    assert_false(b.is_string())  # binary is not a Utf8 string
    assert_false(b.is_null())
    assert_equal(b.string_val, "abc")
    assert_true(b == ScalarValue.from_binary(String("abc")))
    assert_true(b != ScalarValue.from_binary(String("abd")))
    # Binary "abc" and string "abc" are different kinds => not equal.
    assert_true(b != ScalarValue.from_string("abc"))
    # Empty binary is a real value, not a null.
    var eb = ScalarValue.from_binary(String(""))
    assert_true(eb.is_binary())
    assert_false(eb.is_null())


# =============================================================================
# 19. ScalarValue from_bool roundtrip
# =============================================================================

def test_scalar_from_bool() raises:
    """ScalarValue.from_bool() stores and retrieves bool value."""
    var sv = ScalarValue.from_bool(True)
    assert_true(sv.is_bool())
    assert_true(sv.bool_val)
    var sv2 = ScalarValue.from_bool(False)
    assert_false(sv2.bool_val)


# =============================================================================
# 20. Writable: print(col("age") > 25) shows human-readable representation
# =============================================================================

def test_expr_writable() raises:
    """Verify Expr write_to produces human-readable output via print()."""
    var e = col("age") > 25
    # Verify it prints without error (Writable conformance)
    print("  Writable output: ", e)


# =============================================================================
# 21. ColExpr __lt__ with Int
# =============================================================================

def test_col_lt_int() raises:
    """col('score') < 100 creates BinaryOp(LT)."""
    var e = col("score") < 100
    assert_true(e.is_binary())
    assert_equal(Int(e.binary_op()), Int(BIN_LT))
    assert_equal(e.binary_left_ref().col_ref_name(), "score")


# =============================================================================
# 22. ColExpr __eq__ with String
# =============================================================================

def test_col_eq_string() raises:
    """col('name') == 'alice' creates BinaryOp(EQ) with string literal."""
    var e = col("name") == "alice"
    assert_true(e.is_binary())
    assert_equal(Int(e.binary_op()), Int(BIN_EQ))
    var rv = e.binary_right_ref().literal_value()
    assert_true(rv.is_string())
    assert_equal(rv.string_val, "alice")


# =============================================================================
# 23. ColExpr __ne__ with Int
# =============================================================================

def test_col_ne_int() raises:
    """col('status') != 0 creates BinaryOp(NE)."""
    var e = col("status") != 0
    assert_true(e.is_binary())
    assert_equal(Int(e.binary_op()), Int(BIN_NE))


# =============================================================================
# 24. ColExpr __ge__ and __le__
# =============================================================================

def test_col_ge_le() raises:
    """col('x') >= 10 and col('x') <= 20 create correct BinaryOps."""
    var ge = col("x") >= 10
    assert_true(ge.is_binary())
    assert_equal(Int(ge.binary_op()), Int(BIN_GE))

    var le = col("x") <= 20
    assert_true(le.is_binary())
    assert_equal(Int(le.binary_op()), Int(BIN_LE))


# =============================================================================
# 25. Unary: is_null() and is_not_null()
# =============================================================================

def test_is_null_is_not_null() raises:
    """col('x').is_null() and is_not_null() create UnaryOp expressions."""
    var null_e = col("x").is_null()
    assert_true(null_e.is_unary())
    assert_equal(Int(null_e.unary_op()), Int(UN_IS_NULL))
    assert_true(null_e.unary_child_ref().is_col_ref())

    var not_null_e = col("x").is_not_null()
    assert_true(not_null_e.is_unary())
    assert_equal(Int(not_null_e.unary_op()), Int(UN_IS_NOT_NULL))


# =============================================================================
# 26. Cast expression
# =============================================================================

def test_cast_expr() raises:
    """col('x').cast(DType.float64) creates a Cast expression."""
    var result = col("x").cast(DType.float64)
    var e = result.copy_expr()
    assert_true(e.is_cast())
    assert_equal(e.cast_target(), DType.float64)
    assert_true(e.cast_child_ref().is_col_ref())
    assert_equal(e.cast_child_ref().col_ref_name(), "x")


# =============================================================================
# 27. Alias expression
# =============================================================================

def test_alias_expr() raises:
    """col('x').alias('output') creates an Alias expression."""
    var e = col("x").alias("output")
    assert_true(e.is_alias())
    assert_equal(e.alias_name(), "output")
    assert_true(e.alias_child_ref().is_col_ref())
    assert_equal(e.alias_child_ref().col_ref_name(), "x")


# =============================================================================
# 28. Subtraction operator
# =============================================================================

def test_sub_operator() raises:
    """col('a') - col('b') creates BinaryOp(SUB)."""
    var result = col("a") - col("b")
    var e = result.copy_expr()
    assert_true(e.is_binary())
    assert_equal(Int(e.binary_op()), Int(BIN_SUB))


# =============================================================================
# 29. Division operator
# =============================================================================

def test_div_operator() raises:
    """col('a') / 2.0 creates BinaryOp(DIV)."""
    var result = col("a") / 2.0
    var e = result.copy_expr()
    assert_true(e.is_binary())
    assert_equal(Int(e.binary_op()), Int(BIN_DIV))


# =============================================================================
# 30. OR combinator
# =============================================================================

def test_or_combination() raises:
    """Two comparisons combined with | produce BinaryOp(OR)."""
    var left_expr = col("x") > 5
    var right_expr = col("y") < 10
    var left_col = ColExpr(left_expr^)
    var combined = left_col | right_expr
    assert_true(combined.is_binary())
    assert_equal(Int(combined.binary_op()), Int(BIN_OR))


# =============================================================================
# 31. AggExpr: min, max, mean
# =============================================================================

def test_agg_min_max_mean() raises:
    """min(), max(), mean() create correct AggExpr types."""
    var mn = min(col("x"))
    assert_equal(Int(mn.func), Int(AGG_MIN))
    assert_true(mn.child.__bool__())

    var mx = max(col("x"))
    assert_equal(Int(mx.func), Int(AGG_MAX))

    var avg = mean(col("x"))
    assert_equal(Int(avg.func), Int(AGG_MEAN))


# =============================================================================
# 32. AggExpr writable
# =============================================================================

def test_agg_writable() raises:
    """Verify AggExpr write_to produces human-readable output via print()."""
    var agg = sum(col("amount")).alias("total")
    # Verify it prints without error (Writable conformance)
    print("  AggExpr writable: ", agg)


# =============================================================================
# 33. ColIdx (post-compilation) expression
# =============================================================================

def test_col_idx() raises:
    """Expr.col_idx() creates a column index reference."""
    var e = Expr.col_idx(3)
    assert_true(e.is_col_idx())
    assert_equal(e.col_idx_index(), 3)


# =============================================================================
# 34. Deep copy of expression tree
# =============================================================================

def test_expr_deep_copy() raises:
    """Expr.copy() creates an independent deep copy."""
    var original = Expr.binary(BIN_ADD, Expr.col_ref("a"), Expr.literal(ScalarValue.from_int(5)))
    var copied = original.copy()
    # Both should be structurally equivalent
    assert_true(copied.is_binary())
    assert_equal(Int(copied.binary_op()), Int(BIN_ADD))
    assert_equal(copied.binary_left_ref().col_ref_name(), "a")
    assert_equal(Int(copied.binary_right_ref().literal_value().int_val), 5)


# =============================================================================
# 35. binop_name / unop_name helpers
# =============================================================================

def test_op_name_helpers() raises:
    """binop_name() and unop_name() return correct strings."""
    assert_equal(binop_name(BIN_ADD), "ADD")
    assert_equal(binop_name(BIN_GT), "GT")
    assert_equal(binop_name(BIN_AND), "AND")
    assert_equal(unop_name(UN_NOT), "NOT")
    assert_equal(unop_name(UN_IS_NULL), "IS_NULL")


# =============================================================================
# 36. Lit with different types
# =============================================================================

def test_lit_variants() raises:
    """lit() works with Int, Float64, String, Bool."""
    var li = lit(42)
    assert_true(li.copy_expr().is_literal())

    var lf = lit(3.14)
    assert_true(lf.copy_expr().is_literal())

    var ls = lit("hello")
    var lse = ls.copy_expr()
    assert_true(lse.is_literal())
    assert_true(lse.literal_value().is_string())

    var lb = lit(True)
    var lbe = lb.copy_expr()
    assert_true(lbe.is_literal())
    assert_true(lbe.literal_value().is_bool())


# =============================================================================
# 37. count_distinct creates correct AggExpr
# =============================================================================

def test_count_distinct() raises:
    """count_distinct(col('x')) creates a COUNT_DISTINCT AggExpr."""
    var agg = count_distinct(col("x"))
    assert_equal(Int(agg.func), Int(AGG_COUNT_DISTINCT))
    assert_true(agg.child.__bool__())


# =============================================================================
# 38. ScalarValue from_int64 roundtrip
# =============================================================================

def test_scalar_from_int64() raises:
    """ScalarValue.from_int64() stores and retrieves Int64 value."""
    var sv = ScalarValue.from_int64(Int64(-99))
    assert_true(sv.is_int())
    assert_equal(sv.dtype, DType.int64)
    assert_equal(Int(sv.int_val), -99)


# =============================================================================
# 39. ScalarValue from_int32 roundtrip
# =============================================================================

def test_scalar_from_int32() raises:
    """ScalarValue.from_int32() stores and retrieves Int32 value."""
    var sv = ScalarValue.from_int32(Int32(7))
    assert_true(sv.is_int())
    assert_equal(sv.dtype, DType.int32)
    assert_equal(Int(sv.int_val), 7)


# =============================================================================
# 40. ScalarValue from_float32 roundtrip
# =============================================================================

def test_scalar_from_float32() raises:
    """ScalarValue.from_float32() stores and retrieves Float32 value."""
    var sv = ScalarValue.from_float32(Float32(1.5))
    assert_true(sv.is_float())
    assert_equal(sv.dtype, DType.float32)


# =============================================================================
# 41. ScalarValue null roundtrip
# =============================================================================

def test_scalar_null() raises:
    """`ScalarValue.null(dt)` is a NULL for EVERY dtype — `is_null()` True, and
    NOT is_int / is_float / is_string / is_bool. A `null(int64)` that set
    `dtype=int64` would be mis-read as int 0 (`is_int()` True, `is_null()`
    False), a wrong answer; this test pins the contract.
    """
    # Default constructor: dtype=DTYPE_NONE, empty string -> is_null() == True
    var sv_default = ScalarValue()
    assert_true(sv_default.is_null())
    assert_false(sv_default.is_string())
    assert_equal(sv_default.null_type(), DTYPE_NONE)

    # Every typed null must report is_null() == True (and no other kind).
    var dtypes: List[DType] = [
        DType.int64, DType.int32, DType.int16, DType.int8,
        DType.uint64, DType.uint32, DType.uint16, DType.uint8,
        DType.float64, DType.float32, DType.bool, DTYPE_NONE,
    ]
    for i in range(len(dtypes)):
        var dt = dtypes[i]
        var sv = ScalarValue.null(dt)
        assert_true(sv.is_null(),
                    "null(dt).is_null() must be True for every dtype")
        assert_false(sv.is_int(), "a typed null is NOT is_int()")
        assert_false(sv.is_float(), "a typed null is NOT is_float()")
        assert_false(sv.is_string(), "a typed null is NOT is_string()")
        assert_false(sv.is_bool(), "a typed null is NOT is_bool()")
        # The null discriminant field is always DTYPE_NONE; the declared
        # logical type is preserved separately for schema inference.
        assert_equal(sv.dtype, DTYPE_NONE)
        assert_equal(sv.null_type(), dt)
        assert_equal(Int(sv.int_val), 0)

    # Structural equality: differently-typed nulls stay distinct, and a
    # typed null is NOT equal to the zero literal of that type.
    assert_true(ScalarValue.null(DType.int64) == ScalarValue.null(DType.int64))
    assert_true(ScalarValue.null(DType.int64) != ScalarValue.null(DType.int32))
    assert_true(ScalarValue.null(DType.int64) != ScalarValue.from_int64(0))


# =============================================================================
# 42. ScalarValue copy
# =============================================================================

def test_scalar_copy() raises:
    """ScalarValue.copy() creates an independent copy."""
    var original = ScalarValue.from_string("test")
    var copied = original.copy()
    assert_true(copied.is_string())
    assert_equal(copied.string_val, "test")


# =============================================================================
# 43. ScalarValue negative int
# =============================================================================

def test_scalar_negative_int() raises:
    """ScalarValue.from_int() works with negative values."""
    var sv = ScalarValue.from_int(-42)
    assert_true(sv.is_int())
    assert_equal(Int(sv.int_val), -42)


# =============================================================================
# 44. ScalarValue zero values
# =============================================================================

def test_scalar_zero_values() raises:
    """ScalarValue handles zero correctly for int and float."""
    var sv_int = ScalarValue.from_int(0)
    assert_true(sv_int.is_int())
    assert_equal(Int(sv_int.int_val), 0)

    var sv_float = ScalarValue.from_float(0.0)
    assert_true(sv_float.is_float())


# =============================================================================
# 45. ScalarValue Writable (all variants)
# =============================================================================

def test_scalar_writable() raises:
    """ScalarValue write_to works for all variants."""
    print("  int: ", ScalarValue.from_int(42))
    print("  float: ", ScalarValue.from_float(3.14))
    print("  string: ", ScalarValue.from_string("hello"))
    print("  bool_t: ", ScalarValue.from_bool(True))
    print("  bool_f: ", ScalarValue.from_bool(False))
    print("  null: ", ScalarValue())


# =============================================================================
# 46. Empty string column name
# =============================================================================

def test_col_empty_name() raises:
    """col('') with empty string column name still creates a valid ColRef."""
    var c = col("")
    var e = c.copy_expr()
    assert_true(e.is_col_ref())
    assert_equal(e.col_ref_name(), "")


# =============================================================================
# 47. ColExpr __gt__ with String
# =============================================================================

def test_col_gt_string() raises:
    """col('name') > 'alice' creates BinaryOp(GT) with string literal."""
    var e = col("name") > "alice"
    assert_true(e.is_binary())
    assert_equal(Int(e.binary_op()), Int(BIN_GT))
    var rv = e.binary_right_ref().literal_value()
    assert_true(rv.is_string())
    assert_equal(rv.string_val, "alice")


# =============================================================================
# 48. ColExpr __lt__ with Float64
# =============================================================================

def test_col_lt_float() raises:
    """col('x') < 3.14 creates BinaryOp(LT) with float literal."""
    var e = col("x") < 3.14
    assert_true(e.is_binary())
    assert_equal(Int(e.binary_op()), Int(BIN_LT))
    var rv = e.binary_right_ref().literal_value()
    assert_true(rv.is_float())


# =============================================================================
# 49. ColExpr __lt__ with String
# =============================================================================

def test_col_lt_string() raises:
    """col('name') < 'z' creates BinaryOp(LT) with string literal."""
    var e = col("name") < "z"
    assert_true(e.is_binary())
    assert_equal(Int(e.binary_op()), Int(BIN_LT))
    var rv = e.binary_right_ref().literal_value()
    assert_true(rv.is_string())


# =============================================================================
# 50. ColExpr __lt__ with ColExpr
# =============================================================================

def test_col_lt_col() raises:
    """col('a') < col('b') creates BinaryOp(LT) comparing two columns."""
    var e = col("a") < col("b")
    assert_true(e.is_binary())
    assert_equal(Int(e.binary_op()), Int(BIN_LT))
    assert_true(e.binary_left_ref().is_col_ref())
    assert_true(e.binary_right_ref().is_col_ref())


# =============================================================================
# 51. ColExpr __eq__ with Float64
# =============================================================================

def test_col_eq_float() raises:
    """col('x') == 3.14 creates BinaryOp(EQ) with float literal."""
    var e = col("x") == 3.14
    assert_true(e.is_binary())
    assert_equal(Int(e.binary_op()), Int(BIN_EQ))
    var rv = e.binary_right_ref().literal_value()
    assert_true(rv.is_float())


# =============================================================================
# 52. ColExpr __eq__ with ColExpr
# =============================================================================

def test_col_eq_col() raises:
    """col('a') == col('b') creates BinaryOp(EQ) comparing two columns."""
    var e = col("a") == col("b")
    assert_true(e.is_binary())
    assert_equal(Int(e.binary_op()), Int(BIN_EQ))
    assert_true(e.binary_right_ref().is_col_ref())


# =============================================================================
# 53. ColExpr __ne__ with Float64
# =============================================================================

def test_col_ne_float() raises:
    """col('x') != 3.14 creates BinaryOp(NE) with float literal."""
    var e = col("x") != 3.14
    assert_true(e.is_binary())
    assert_equal(Int(e.binary_op()), Int(BIN_NE))
    var rv = e.binary_right_ref().literal_value()
    assert_true(rv.is_float())


# =============================================================================
# 54. ColExpr __ne__ with String
# =============================================================================

def test_col_ne_string() raises:
    """col('name') != 'bob' creates BinaryOp(NE) with string literal."""
    var e = col("name") != "bob"
    assert_true(e.is_binary())
    assert_equal(Int(e.binary_op()), Int(BIN_NE))
    var rv = e.binary_right_ref().literal_value()
    assert_true(rv.is_string())


# =============================================================================
# 55. ColExpr __ne__ with ColExpr
# =============================================================================

def test_col_ne_col() raises:
    """col('a') != col('b') creates BinaryOp(NE) comparing two columns."""
    var e = col("a") != col("b")
    assert_true(e.is_binary())
    assert_equal(Int(e.binary_op()), Int(BIN_NE))
    assert_true(e.binary_right_ref().is_col_ref())


# =============================================================================
# 56. ColExpr __ge__ with Float64, String, ColExpr
# =============================================================================

def test_col_ge_variants() raises:
    """col('x') >= works with Float64, String, and ColExpr."""
    var ge_f = col("x") >= 3.14
    assert_true(ge_f.is_binary())
    assert_equal(Int(ge_f.binary_op()), Int(BIN_GE))
    assert_true(ge_f.binary_right_ref().literal_value().is_float())

    var ge_s = col("x") >= "abc"
    assert_true(ge_s.is_binary())
    assert_equal(Int(ge_s.binary_op()), Int(BIN_GE))
    assert_true(ge_s.binary_right_ref().literal_value().is_string())

    var ge_c = col("x") >= col("y")
    assert_true(ge_c.is_binary())
    assert_equal(Int(ge_c.binary_op()), Int(BIN_GE))
    assert_true(ge_c.binary_right_ref().is_col_ref())


# =============================================================================
# 57. ColExpr __le__ with Float64, String, ColExpr
# =============================================================================

def test_col_le_variants() raises:
    """col('x') <= works with Float64, String, and ColExpr."""
    var le_f = col("x") <= 2.5
    assert_true(le_f.is_binary())
    assert_equal(Int(le_f.binary_op()), Int(BIN_LE))
    assert_true(le_f.binary_right_ref().literal_value().is_float())

    var le_s = col("x") <= "zzz"
    assert_true(le_s.is_binary())
    assert_equal(Int(le_s.binary_op()), Int(BIN_LE))
    assert_true(le_s.binary_right_ref().literal_value().is_string())

    var le_c = col("x") <= col("y")
    assert_true(le_c.is_binary())
    assert_equal(Int(le_c.binary_op()), Int(BIN_LE))
    assert_true(le_c.binary_right_ref().is_col_ref())


# =============================================================================
# 58. ColExpr __add__ with Float64
# =============================================================================

def test_col_add_float() raises:
    """col('x') + 1.5 creates BinaryOp(ADD) with float literal."""
    var result = col("x") + 1.5
    var e = result.copy_expr()
    assert_true(e.is_binary())
    assert_equal(Int(e.binary_op()), Int(BIN_ADD))
    assert_true(e.binary_right_ref().literal_value().is_float())


# =============================================================================
# 59. ColExpr __sub__ with Int and Float64
# =============================================================================

def test_col_sub_int_and_float() raises:
    """col('x') - 5 and col('x') - 2.5 create BinaryOp(SUB)."""
    var sub_i = col("x") - 5
    var e_i = sub_i.copy_expr()
    assert_true(e_i.is_binary())
    assert_equal(Int(e_i.binary_op()), Int(BIN_SUB))
    assert_equal(Int(e_i.binary_right_ref().literal_value().int_val), 5)

    var sub_f = col("x") - 2.5
    var e_f = sub_f.copy_expr()
    assert_true(e_f.is_binary())
    assert_equal(Int(e_f.binary_op()), Int(BIN_SUB))
    assert_true(e_f.binary_right_ref().literal_value().is_float())


# =============================================================================
# 60. ColExpr __mul__ with Float64
# =============================================================================

def test_col_mul_float() raises:
    """col('x') * 2.5 creates BinaryOp(MUL) with float literal."""
    var result = col("x") * 2.5
    var e = result.copy_expr()
    assert_true(e.is_binary())
    assert_equal(Int(e.binary_op()), Int(BIN_MUL))
    assert_true(e.binary_right_ref().literal_value().is_float())


# =============================================================================
# 61. ColExpr __truediv__ with Int and ColExpr
# =============================================================================

def test_col_div_int_and_col() raises:
    """col('x') / 2 and col('x') / col('y') create BinaryOp(DIV)."""
    var div_i = col("x") / 2
    var e_i = div_i.copy_expr()
    assert_true(e_i.is_binary())
    assert_equal(Int(e_i.binary_op()), Int(BIN_DIV))
    assert_equal(Int(e_i.binary_right_ref().literal_value().int_val), 2)

    var div_c = col("x") / col("y")
    var e_c = div_c.copy_expr()
    assert_true(e_c.is_binary())
    assert_equal(Int(e_c.binary_op()), Int(BIN_DIV))
    assert_true(e_c.binary_right_ref().is_col_ref())


# 61b. `/` is TRUE division, `//` DuckDB's truncating integer division.
# `col("x") / 2` over integers answers 3.5, as DuckDB, polars and pandas do —
# not the 3 of a bare `BIN_DIV`. The shape is the plan the Python front ends
# emit too: the LEFT operand CAST to FLOAT64.

def _is_cast_f64_of(e: Expr, name: String) -> Bool:
    return (
        e.is_cast()
        and e.cast_target() == DType.float64
        and e.cast_child_ref().is_col_ref()
        and e.cast_child_ref().col_ref_name() == name
    )


def test_truediv_casts_an_unproven_left_operand_to_f64() raises:
    var e_i = (col("x") / 2).copy_expr()
    assert_equal(Int(e_i.binary_op()), Int(BIN_DIV))
    assert_true(_is_cast_f64_of(e_i.binary_left_ref(), "x"), "col / 2")
    var e_c = (col("x") / col("y")).copy_expr()
    assert_true(_is_cast_f64_of(e_c.binary_left_ref(), "x"), "col / col")
    var e_l = (lit(120) / col("v")).copy_expr()
    assert_true(e_l.binary_left_ref().is_cast(), "lit(120) / col")
    assert_true(e_l.binary_left_ref().cast_child_ref().is_literal())


def test_truediv_leaves_a_provably_floating_division_alone() raises:
    """A float operand already makes `/` true division, so NO cast is added and
    every float plan (TPC-H q14 / q17's ratios) keeps its exact shape."""
    var e_rf = (col("a") / 2.0).copy_expr()
    assert_true(e_rf.binary_left_ref().is_col_ref(), "col / 2.0")
    var e_lf = ((col("a") * 100.0) / col("b")).copy_expr()
    assert_true(e_lf.binary_left_ref().is_binary(), "(a * 100.0) / b")
    var lc = ColExpr(Expr.cast(Expr.col_ref("a"), DType.float64))
    var e_lc = (lc / 2).copy_expr()
    assert_true(e_lc.binary_left_ref().cast_child_ref().is_col_ref(), "no double cast")


def test_truediv_over_an_integer_division_still_casts() raises:
    """`(k // 2) / 3` is TRUE division of an INTEGER quotient: DuckDB v1.5.3
    answers `(7 // 2) / 3 = 1.0`, `(10 // 2) / 3 = 1.666...`. The left operand
    is a `BIN_DIV` that PROVES nothing floating (`//` over integers), so it
    must be CAST. A rule that took "any division" as proof of a float would
    skip the cast and answer integer division (`5 / 3 = 1`)."""
    var e = ((col("k") // 2) / 3).copy_expr()
    assert_equal(Int(e.binary_op()), Int(BIN_DIV))
    ref l = e.binary_left_ref()
    assert_true(l.is_cast(), "(k // 2) / 3: the integer quotient is cast")
    assert_true(l.cast_target() == DType.float64)
    assert_true(l.cast_child_ref().is_binary(), "the cast wraps `k // 2`")


def test_floordiv_is_the_bare_truncating_bin_div() raises:
    """`//` is DuckDB's integer division — the engine's `BIN_DIV` unchanged
    (`-7 // 2 == -3`; NOT polars' floor), no cast."""
    var e_i = (col("x") // 2).copy_expr()
    assert_equal(Int(e_i.binary_op()), Int(BIN_DIV))
    assert_true(e_i.binary_left_ref().is_col_ref())
    var e_c = (col("k") // col("v")).copy_expr()
    assert_true(e_c.binary_left_ref().is_col_ref())
    var e_f = (col("x") // 2.0).copy_expr()
    assert_true(e_f.binary_left_ref().is_col_ref())


# =============================================================================
# 62. ColExpr take_expr — SKIPPED: Mojo compiler partial-destruction bug
# prevents calling take_expr() in current version. The method is correct
# but the compiler cannot handle field-of-field partial moves yet.
# =============================================================================


# =============================================================================
# 63. ColExpr Writable
# =============================================================================

def test_col_expr_writable() raises:
    """ColExpr write_to delegates to inner Expr."""
    var c = col("x")
    print("  ColExpr writable: ", c)


# =============================================================================
# 64. AggExpr first and last
# =============================================================================

def test_agg_first_last() raises:
    """first() and last() create correct AggExpr types."""
    var f = first(col("x"))
    assert_equal(Int(f.func), Int(AGG_FIRST))
    assert_true(f.child.__bool__())

    var l = last(col("x"))
    assert_equal(Int(l.func), Int(AGG_LAST))
    assert_true(l.child.__bool__())


# =============================================================================
# 65. AggExpr count(col(...))
# =============================================================================

def test_count_column() raises:
    """count(col('x')) creates COUNT with a child expression."""
    var agg = count(col("x"))
    assert_equal(Int(agg.func), Int(AGG_COUNT))
    assert_true(agg.child.__bool__(), "COUNT(col) should have a child")


# =============================================================================
# 66. AggExpr alias on count_star
# =============================================================================

def test_count_star_alias() raises:
    """count().alias('n') creates a named COUNT(*) AggExpr."""
    var agg = count().alias("n")
    assert_equal(Int(agg.func), Int(AGG_COUNT))
    assert_false(agg.child.__bool__(), "COUNT(*) should have no child")
    assert_true(agg.alias_name.__bool__(), "should have alias")
    assert_equal(agg.alias_name.value(), "n")


# =============================================================================
# 67. AggExpr Writable for count(*)
# =============================================================================

def test_agg_count_star_writable() raises:
    """count() Writable shows COUNT(*)."""
    var agg = count()
    print("  count(*) writable: ", agg)


# =============================================================================
# 68. binop_name comprehensive
# =============================================================================

def test_binop_name_all() raises:
    """binop_name() returns correct strings for all BinOp constants."""
    assert_equal(binop_name(BIN_ADD), "ADD")
    assert_equal(binop_name(BIN_SUB), "SUB")
    assert_equal(binop_name(BIN_MUL), "MUL")
    assert_equal(binop_name(BIN_DIV), "DIV")
    assert_equal(binop_name(BIN_MOD), "MOD")
    assert_equal(binop_name(BIN_EQ), "EQ")
    assert_equal(binop_name(BIN_NE), "NE")
    assert_equal(binop_name(BIN_LT), "LT")
    assert_equal(binop_name(BIN_LE), "LE")
    assert_equal(binop_name(BIN_GT), "GT")
    assert_equal(binop_name(BIN_GE), "GE")
    assert_equal(binop_name(BIN_AND), "AND")
    assert_equal(binop_name(BIN_OR), "OR")
    assert_equal(binop_name(UInt8(255)), "UNKNOWN")


# =============================================================================
# 69. unop_name comprehensive
# =============================================================================

def test_unop_name_all() raises:
    """unop_name() returns correct strings for all UnOp constants."""
    assert_equal(unop_name(UN_NOT), "NOT")
    assert_equal(unop_name(UN_NEGATE), "NEGATE")
    assert_equal(unop_name(UN_IS_NULL), "IS_NULL")
    assert_equal(unop_name(UN_IS_NOT_NULL), "IS_NOT_NULL")
    assert_equal(unop_name(UInt8(255)), "UNKNOWN")


# =============================================================================
# 70. Expr unary_child copy accessor
# =============================================================================

def test_unary_child_copy() raises:
    """unary_child() returns an independent copy of the child."""
    var e = Expr.unary(UN_NEGATE, Expr.col_ref("x"))
    var child = e.unary_child()
    assert_true(child.is_col_ref())
    assert_equal(child.col_ref_name(), "x")


# =============================================================================
# 71. Expr cast_child copy accessor
# =============================================================================

def test_cast_child_copy() raises:
    """cast_child() returns an independent copy of the child."""
    var e = Expr.cast(Expr.col_ref("x"), DType.float64)
    var child = e.cast_child()
    assert_true(child.is_col_ref())
    assert_equal(child.col_ref_name(), "x")


# =============================================================================
# 72. Expr alias_child copy accessor
# =============================================================================

def test_alias_child_copy() raises:
    """alias_child() returns an independent copy of the child."""
    var e = Expr.alias(Expr.col_ref("x"), "output")
    var child = e.alias_child()
    assert_true(child.is_col_ref())
    assert_equal(child.col_ref_name(), "x")


# =============================================================================
# 73. Deep copy of unary expression
# =============================================================================

def test_deep_copy_unary() raises:
    """Expr.copy() works for unary expressions."""
    var original = Expr.unary(UN_NOT, Expr.col_ref("flag"))
    var copied = original.copy()
    assert_true(copied.is_unary())
    assert_equal(Int(copied.unary_op()), Int(UN_NOT))
    assert_equal(copied.unary_child_ref().col_ref_name(), "flag")


# =============================================================================
# 74. Deep copy of cast expression
# =============================================================================

def test_deep_copy_cast() raises:
    """Expr.copy() works for cast expressions."""
    var original = Expr.cast(Expr.col_ref("x"), DType.float32)
    var copied = original.copy()
    assert_true(copied.is_cast())
    assert_equal(copied.cast_target(), DType.float32)
    assert_equal(copied.cast_child_ref().col_ref_name(), "x")


# =============================================================================
# 75. Deep copy of alias expression
# =============================================================================

def test_deep_copy_alias() raises:
    """Expr.copy() works for alias expressions."""
    var original = Expr.alias(Expr.col_ref("x"), "out")
    var copied = original.copy()
    assert_true(copied.is_alias())
    assert_equal(copied.alias_name(), "out")
    assert_equal(copied.alias_child_ref().col_ref_name(), "x")


# =============================================================================
# 76. Deep copy of col_idx expression
# =============================================================================

def test_deep_copy_col_idx() raises:
    """Expr.copy() works for col_idx expressions."""
    var original = Expr.col_idx(7)
    var copied = original.copy()
    assert_true(copied.is_col_idx())
    assert_equal(copied.col_idx_index(), 7)


# =============================================================================
# 77. Deep copy of when expression
# =============================================================================

def test_deep_copy_when() raises:
    """Expr.copy() works for WHEN expressions."""
    var cases = List[WhenCaseData]()
    cases.append(WhenCaseData(
        Expr.binary(BIN_GT, Expr.col_ref("x"), Expr.literal(ScalarValue.from_int(0))),
        Expr.literal(ScalarValue.from_string("positive")),
    ))
    var default = Expr.literal(ScalarValue.from_string("non-positive"))
    var original = Expr.when(cases^, default^)
    var copied = original.copy()
    assert_true(copied.is_when())


# =============================================================================
# 78. Expr Writable for unary, cast, alias, literal
# =============================================================================

def test_expr_writable_variants() raises:
    """Expr write_to works for unary, cast, alias, literal, col_idx."""
    print("  unary: ", Expr.unary(UN_NOT, Expr.col_ref("flag")))
    print("  cast: ", Expr.cast(Expr.col_ref("x"), DType.float64))
    print("  alias: ", Expr.alias(Expr.col_ref("x"), "output"))
    print("  literal: ", Expr.literal(ScalarValue.from_int(42)))
    print("  col_idx: ", Expr.col_idx(5))


# =============================================================================
# 79. ColExpr __add__ with Int
# =============================================================================

def test_col_add_int() raises:
    """col('x') + 10 creates BinaryOp(ADD) with int literal."""
    var result = col("x") + 10
    var e = result.copy_expr()
    assert_true(e.is_binary())
    assert_equal(Int(e.binary_op()), Int(BIN_ADD))
    assert_equal(Int(e.binary_right_ref().literal_value().int_val), 10)


# =============================================================================
# 80. ColExpr __mul__ with Int
# =============================================================================

def test_col_mul_int() raises:
    """col('x') * 3 creates BinaryOp(MUL) with int literal."""
    var result = col("x") * 3
    var e = result.copy_expr()
    assert_true(e.is_binary())
    assert_equal(Int(e.binary_op()), Int(BIN_MUL))
    assert_equal(Int(e.binary_right_ref().literal_value().int_val), 3)


# =============================================================================
# 81. Negative literal via lit()
# =============================================================================

def test_lit_negative_int() raises:
    """lit(-1) creates a negative integer literal."""
    var c = lit(-1)
    var e = c.copy_expr()
    assert_true(e.is_literal())
    var sv = e.literal_value()
    assert_true(sv.is_int())
    assert_equal(Int(sv.int_val), -1)


# =============================================================================
# 82. ScalarValue __copyinit__
# =============================================================================

def test_scalar_copyinit() raises:
    """ScalarValue copy init creates independent copy."""
    var original = ScalarValue.from_string("test")
    var copied = ScalarValue(copy=original)
    assert_true(copied.is_string())
    assert_equal(copied.string_val, "test")


# =============================================================================
# 83. Expr type checks are mutually exclusive
# =============================================================================

def test_type_checks_mutually_exclusive() raises:
    """Each Expr variant returns True for exactly one type check."""
    var col_e = Expr.col_ref("x")
    assert_true(col_e.is_col_ref())
    assert_false(col_e.is_col_idx())
    assert_false(col_e.is_literal())
    assert_false(col_e.is_binary())
    assert_false(col_e.is_unary())
    assert_false(col_e.is_cast())
    assert_false(col_e.is_alias())
    assert_false(col_e.is_when())

    var idx_e = Expr.col_idx(0)
    assert_true(idx_e.is_col_idx())
    assert_false(idx_e.is_col_ref())
    assert_false(idx_e.is_literal())

    var unary_e = Expr.unary(UN_NOT, Expr.col_ref("x"))
    assert_true(unary_e.is_unary())
    assert_false(unary_e.is_binary())
    assert_false(unary_e.is_col_ref())

    var cast_e = Expr.cast(Expr.col_ref("x"), DType.float64)
    assert_true(cast_e.is_cast())
    assert_false(cast_e.is_alias())

    var alias_e = Expr.alias(Expr.col_ref("x"), "out")
    assert_true(alias_e.is_alias())
    assert_false(alias_e.is_cast())


# =============================================================================
# Main — discover and run all tests
# =============================================================================

def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

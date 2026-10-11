# =============================================================================
# test_lower_untyped_expr_leaves.mojo: the translator's leaf, unary, LIKE,
# IN-list, math, CASE and cast arms, node by node
# =============================================================================
#
# SUBJECT: `lower_untyped_expr.translate_expr` (both overloads) and
# `count_and_conjuncts`, and the arms of `lower_untyped_expr_ops` other than
# the binary operators (those are in test_lower_untyped_expr_binary).
#
# The oracle is the pool itself: each case translates one expression against
# a fixed pair of column maps and asserts the kind, the operands and the
# side-pool entries of the nodes it appended. Each raise is asserted by the
# part of its message that names the shape.
#
# Each test names in its docstring the mutant of the module that turns it red.
# =============================================================================

from std.collections import Dict
from std.testing import TestSuite, assert_true, assert_equal, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_eval.expression_executor import DecimalSpec
from komira_kernels.runtime_expr import (
    RuntimeExpr,
    EXPR_AND,
    EXPR_ASIN_F64,
    EXPR_ATAN2_F64,
    EXPR_CASE_F64,
    EXPR_CASE_I64,
    EXPR_COL,
    EXPR_COL_BINARY,
    EXPR_COL_BOOL,
    EXPR_COL_DECIMAL128,
    EXPR_COL_STRING,
    EXPR_COS_F64,
    EXPR_GT_I64,
    EXPR_I64_TO_F64,
    EXPR_IN_LIST,
    EXPR_IS_NOT_NULL_STRING,
    EXPR_IS_NULL_STRING,
    EXPR_LIKE_STRING,
    EXPR_LIT_BOOL,
    EXPR_LIT_DECIMAL128,
    EXPR_LIT_F64,
    EXPR_LIT_I64,
    EXPR_LIT_STRING,
    EXPR_MATH_UNARY_F64,
    EXPR_NOT_BOOL,
    EXPR_POW_F64,
    EXPR_RADIANS_F64,
    EXPR_SIN_F64,
    EXPR_SQRT_F64,
)
from komira_plan_expr.expr import (
    Expr,
    WhenCaseData,
    BIN_AND,
    BIN_GT,
    MATH_GAMMA,
    MATH_LN,
    MATH2_ATAN2,
    MATH2_POW,
    STR_CONTAINS,
    STR_ENDS_WITH,
    STR_LIKE,
    STR_STARTS_WITH,
    UN_IS_NOT_NULL,
    UN_IS_NULL,
    UN_NEGATE,
    UN_NOT,
)
from komira_plan_expr.scalar_value import ScalarValue

from komira_dispatch_project.lower_untyped_expr import (
    count_and_conjuncts,
    translate_expr,
    RUNTIME_DTYPE_BINARY,
    RUNTIME_DTYPE_BOOL_COL,
    RUNTIME_DTYPE_DECIMAL128,
    RUNTIME_DTYPE_DICTIONARY,
    RUNTIME_DTYPE_F64,
    RUNTIME_DTYPE_I32,
    RUNTIME_DTYPE_I64,
    RUNTIME_DTYPE_STRING,
)


# =============================================================================
# Fixture: the column maps and a lowering harness
# =============================================================================


def _idx() -> Dict[String, Int]:
    """Column name -> walker position. `nodt` has a position and no family."""
    var m = Dict[String, Int]()
    m["i"] = 0
    m["f"] = 1
    m["b"] = 2
    m["s"] = 3
    m["d"] = 4
    m["bin"] = 5
    m["dict"] = 6
    m["i32"] = 7
    m["nodt"] = 8
    return m^


def _dt() -> Dict[String, Int]:
    var m = Dict[String, Int]()
    m["i"] = RUNTIME_DTYPE_I64
    m["f"] = RUNTIME_DTYPE_F64
    m["b"] = RUNTIME_DTYPE_BOOL_COL
    m["s"] = RUNTIME_DTYPE_STRING
    m["d"] = RUNTIME_DTYPE_DECIMAL128
    m["bin"] = RUNTIME_DTYPE_BINARY
    m["dict"] = RUNTIME_DTYPE_DICTIONARY
    m["i32"] = RUNTIME_DTYPE_I32
    return m^


struct _Lowered(Movable):
    """A translated expression: the pool, its root slot and the side pools."""

    var pool: List[RuntimeExpr]
    var root: Int
    var strings: List[String]
    var decimals: List[DecimalSpec]
    var in_lists: List[List[ScalarValue]]
    var whens: List[List[Int]]

    def __init__(out self):
        self.pool = List[RuntimeExpr]()
        self.root = -1
        self.strings = List[String]()
        self.decimals = List[DecimalSpec]()
        self.in_lists = List[List[ScalarValue]]()
        self.whens = List[List[Int]]()

    def kind(self) -> Int:
        return self.pool[self.root].kind

    def node(self, slot: Int) -> RuntimeExpr:
        return self.pool[slot]


def _lower(imm e: Expr) raises -> _Lowered:
    var out = _Lowered()
    out.root = translate_expr(
        e, out.pool, _idx(), _dt(), out.strings, out.decimals,
        out.in_lists, out.whens,
    )
    return out^


def _raise_text(imm e: Expr) -> String:
    """The translator's error text for `e`, or "" when it lowers."""
    try:
        _ = _lower(e)
        return String("")
    except err:
        return String(err)


def _assert_refused(imm e: Expr, want: String) raises:
    var got = _raise_text(e)
    assert_true(
        got.startswith("UnsupportedByLowerUntypedExpr:") and got.find(want) >= 0,
        String("want a refusal naming `") + want + "`, got `" + got + "`",
    )


def _c(name: StaticString) -> Expr:
    return Expr.col_ref(String(name))


def _li(v: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int(v))


def _lf(v: Float64) -> Expr:
    return Expr.literal(ScalarValue.from_float(v))


# =============================================================================
# Column references
# =============================================================================


def test_each_column_family_lowers_to_its_leaf_kind() raises:
    """Every family of `_translate_col_ref`'s ladder: BOOL_COL, STRING,
    DECIMAL128, BINARY, DICTIONARY (read as a string), I64, F64 and I32 (the
    EXPR_COL default), and a name with no family (EXPR_COL). The position is
    the map's. Mutant: the DICTIONARY arm emitting `make_col(idx)` turns the
    `dict` case red."""
    var names = List[String]()
    var kinds = List[Int]()
    names.append("b")
    kinds.append(EXPR_COL_BOOL)
    names.append("s")
    kinds.append(EXPR_COL_STRING)
    names.append("d")
    kinds.append(EXPR_COL_DECIMAL128)
    names.append("bin")
    kinds.append(EXPR_COL_BINARY)
    names.append("dict")
    kinds.append(EXPR_COL_STRING)
    names.append("i")
    kinds.append(EXPR_COL)
    names.append("f")
    kinds.append(EXPR_COL)
    names.append("i32")
    kinds.append(EXPR_COL)
    names.append("nodt")
    kinds.append(EXPR_COL)
    var idx = _idx()
    for k in range(len(names)):
        var lo = _lower(Expr.col_ref(names[k]))
        assert_equal(len(lo.pool), 1, names[k] + ": one node")
        assert_equal(lo.root, 0, names[k] + ": the root is the leaf")
        assert_equal(lo.kind(), kinds[k], names[k] + ": the leaf kind")
        assert_equal(lo.node(0).col_idx, idx[names[k]], names[k] + ": position")


def test_a_column_missing_from_the_position_map_is_refused() raises:
    """Mutant: the membership check removed (the Dict lookup then raises a
    KeyError without the translator's prefix)."""
    _assert_refused(_c("absent"), "EXPR_COL_REF name 'absent'")


def test_an_alias_lowers_to_its_child() raises:
    """An alias (and an alias of an alias) appends exactly its child's
    node. Mutant: the alias arm removed, so the tag falls to the final
    refusal."""
    var lo = _lower(Expr.alias(Expr.alias(_c("f"), String("x")), String("y")))
    assert_equal(len(lo.pool), 1)
    assert_equal(lo.kind(), EXPR_COL)
    assert_equal(lo.node(0).col_idx, 1)


# =============================================================================
# Literals
# =============================================================================


def test_each_literal_kind_lowers_to_its_node() raises:
    """DATE32 and TIMESTAMP as EXPR_LIT_I64 (days, microseconds), an integer of
    each int64-family width as EXPR_LIT_I64, float64 and float32 as
    EXPR_LIT_F64, bool as EXPR_LIT_BOOL. Mutant: the TIMESTAMP arm removed
    (the timestamp then falls to the kind refusal)."""
    var lo = _lower(Expr.literal(ScalarValue.date32(Int32(9204))))
    assert_equal(lo.kind(), EXPR_LIT_I64)
    assert_equal(Int(lo.node(0).i64), 9204)
    lo = _lower(Expr.literal(ScalarValue.timestamp_micros(Int64(-1_500_000))))
    assert_equal(lo.kind(), EXPR_LIT_I64)
    assert_equal(Int(lo.node(0).i64), -1_500_000)
    lo = _lower(Expr.literal(ScalarValue.from_int32(Int32(-7))))
    assert_equal(lo.kind(), EXPR_LIT_I64)
    assert_equal(Int(lo.node(0).i64), -7)
    lo = _lower(Expr.literal(ScalarValue.from_uint32(UInt32(4000000000))))
    assert_equal(lo.kind(), EXPR_LIT_I64)
    assert_equal(Int(lo.node(0).i64), 4000000000)
    lo = _lower(_lf(2.5))
    assert_equal(lo.kind(), EXPR_LIT_F64)
    assert_equal(lo.node(0).f64, 2.5)
    lo = _lower(Expr.literal(ScalarValue.from_float32(Float32(0.25))))
    assert_equal(lo.kind(), EXPR_LIT_F64)
    assert_equal(lo.node(0).f64, 0.25)
    lo = _lower(Expr.literal(ScalarValue.from_bool(True)))
    assert_equal(lo.kind(), EXPR_LIT_BOOL)
    assert_true(lo.node(0).b)


def test_string_and_decimal_literals_are_interned_in_their_side_pools() raises:
    """A string (the empty string too) is appended to `string_pool` and the
    node carries its index; a DECIMAL128 appends (value, precision, scale) to
    `decimal_pool`. Mutant: the string arm interning `String("")` instead of
    the value turns the "abc" check red."""
    var lo = _lower(Expr.literal(ScalarValue.from_string(String("abc"))))
    assert_equal(lo.kind(), EXPR_LIT_STRING)
    assert_equal(len(lo.strings), 1)
    assert_equal(lo.strings[0], String("abc"))
    assert_equal(lo.node(0).col_idx, 0)
    lo = _lower(Expr.literal(ScalarValue.from_string(String(""))))
    assert_equal(lo.kind(), EXPR_LIT_STRING, "the empty string is a string")
    assert_equal(len(lo.strings), 1)
    lo = _lower(Expr.literal(ScalarValue.decimal128(Int64(0), Int64(1250), 10, 2)))
    assert_equal(lo.kind(), EXPR_LIT_DECIMAL128)
    assert_equal(len(lo.decimals), 1)
    assert_equal(lo.node(0).col_idx, 0)
    assert_equal(lo.decimals[0].precision, 10)
    assert_equal(lo.decimals[0].scale, 2)


def test_a_null_an_unsigned_64_bit_and_an_extended_literal_are_refused() raises:
    """A NULL and a uint64 (not in the int64 family) fall to the DType
    refusal; an interval has a kind of its own and falls to the kind
    refusal. Mutant: the bool arm widened to `or True` turns the NULL case
    into an EXPR_LIT_BOOL."""
    _assert_refused(Expr.literal(ScalarValue.null(DType.int64)), "(null / other)")
    _assert_refused(
        Expr.literal(ScalarValue.from_uint64(UInt64(1))), "(null / other)"
    )
    _assert_refused(
        Expr.literal(
            ScalarValue.interval_month_day_nano(Int32(1), Int32(0), Int64(0))
        ),
        "unknown extended-kind variant",
    )


# =============================================================================
# Unary operators
# =============================================================================


def test_not_and_the_string_null_tests_lower() raises:
    """NOT appends EXPR_NOT_BOOL over its operand; IS NULL and IS NOT NULL
    over a STRING column append their string null tests. Mutant: the two
    null-test kinds swapped turns the IS NULL check red."""
    var lo = _lower(Expr.unary(UN_NOT, _c("b")))
    assert_equal(lo.kind(), EXPR_NOT_BOOL)
    assert_equal(lo.node(lo.root).left, 0)
    lo = _lower(Expr.unary(UN_IS_NULL, _c("s")))
    assert_equal(lo.kind(), EXPR_IS_NULL_STRING)
    lo = _lower(Expr.unary(UN_IS_NOT_NULL, _c("s")))
    assert_equal(lo.kind(), EXPR_IS_NOT_NULL_STRING)


def test_a_null_test_over_a_non_string_and_negation_are_refused() raises:
    """A null test is refused over an I64 operand, and over a DICTIONARY one
    (its family is not STRING, although its leaf reads as a string), and
    negation is refused. Mutant: the family check of the null tests removed
    (an I64 operand then lowers to a string null test)."""
    _assert_refused(Expr.unary(UN_IS_NULL, _c("i")), "on non-String child")
    _assert_refused(
        Expr.unary(UN_IS_NULL, _c("dict")), "(child_family=24)"
    )
    _assert_refused(Expr.unary(UN_NEGATE, _c("i")), "UN_NEGATE / other")


# =============================================================================
# The LIKE family
# =============================================================================


def test_each_string_op_becomes_a_like_pattern() raises:
    """CONTAINS, STARTS_WITH and ENDS_WITH wrap the pattern in `%`; LIKE keeps
    it. The pattern is interned as an EXPR_LIT_STRING that the
    EXPR_LIKE_STRING node names on its right. Mutant: the STARTS_WITH and
    ENDS_WITH wraps swapped."""
    var ops = List[UInt8]()
    var want = List[String]()
    ops.append(STR_CONTAINS)
    want.append("%ab%")
    ops.append(STR_STARTS_WITH)
    want.append("ab%")
    ops.append(STR_ENDS_WITH)
    want.append("%ab")
    ops.append(STR_LIKE)
    want.append("ab")
    for k in range(len(ops)):
        var lo = _lower(Expr.string_op(ops[k], _c("s"), String("ab")))
        assert_equal(lo.kind(), EXPR_LIKE_STRING)
        assert_equal(lo.node(lo.root).left, 0, "the column is the left operand")
        var lit = lo.node(lo.node(lo.root).right)
        assert_equal(lit.kind, EXPR_LIT_STRING)
        assert_equal(lo.strings[lit.col_idx], want[k])


def test_a_like_over_a_non_string_and_an_unknown_string_op_are_refused() raises:
    """Mutant: the EXPR_COL_STRING check of the operand removed."""
    _assert_refused(
        Expr.string_op(STR_LIKE, _c("i"), String("1%")),
        "child must resolve to EXPR_COL_STRING",
    )
    _assert_refused(
        Expr.string_op(UInt8(9), _c("s"), String("x")), "EXPR_STRING_OP op 9"
    )


# =============================================================================
# IN lists
# =============================================================================


def test_an_in_list_is_one_node_and_a_copy_of_its_values() raises:
    """Mutant: the value copy loop dropped (the side-pool entry then has no
    values)."""
    var vals = List[ScalarValue]()
    vals.append(ScalarValue.from_int(1))
    vals.append(ScalarValue.from_int(5))
    vals.append(ScalarValue.from_int(9))
    var lo = _lower(Expr.in_list_node(_c("i"), vals^))
    assert_equal(lo.kind(), EXPR_IN_LIST)
    assert_equal(lo.node(lo.root).left, 0, "the operand's slot")
    assert_equal(lo.node(lo.root).col_idx, 0, "the side-pool entry")
    assert_equal(len(lo.in_lists), 1)
    assert_equal(len(lo.in_lists[0]), 3)
    assert_equal(Int(lo.in_lists[0][2].int_val), 9)


# =============================================================================
# Math
# =============================================================================


def test_each_math_op_lowers_to_its_node() raises:
    """SIN, COS, SQRT, ASIN and RADIANS have kinds of their own; LN and GAMMA
    (the top of the op space) ride EXPR_MATH_UNARY_F64 with the op code in
    `col_idx`; ATAN2 and POW are binary. Mutant: `mop <= MATH_GAMMA` made
    `mop < MATH_GAMMA` (GAMMA is then refused)."""
    assert_equal(_lower(Expr.sin(_c("f"))).kind(), EXPR_SIN_F64)
    assert_equal(_lower(Expr.cos(_c("f"))).kind(), EXPR_COS_F64)
    assert_equal(_lower(Expr.sqrt(_c("f"))).kind(), EXPR_SQRT_F64)
    assert_equal(_lower(Expr.asin(_c("f"))).kind(), EXPR_ASIN_F64)
    assert_equal(_lower(Expr.radians(_c("i"))).kind(), EXPR_RADIANS_F64)
    var lo = _lower(Expr.math_fn(MATH_LN, _c("f")))
    assert_equal(lo.kind(), EXPR_MATH_UNARY_F64)
    assert_equal(lo.node(lo.root).col_idx, Int(MATH_LN))
    lo = _lower(Expr.math_fn(MATH_GAMMA, _c("f")))
    assert_equal(lo.kind(), EXPR_MATH_UNARY_F64)
    assert_equal(lo.node(lo.root).col_idx, Int(MATH_GAMMA))
    lo = _lower(Expr.math_fn2(MATH2_ATAN2, _c("f"), _c("i")))
    assert_equal(lo.kind(), EXPR_ATAN2_F64)
    assert_equal(lo.node(lo.root).left, 0)
    assert_equal(lo.node(lo.root).right, 1)
    assert_equal(_lower(Expr.math_fn2(MATH2_POW, _c("f"), _lf(2.0))).kind(), EXPR_POW_F64)


def test_a_math_op_beyond_the_op_space_is_refused() raises:
    """An op code above MATH_GAMMA, and an unknown binary math op. Mutant: the
    range check removed (code 99 then lowers to EXPR_MATH_UNARY_F64)."""
    _assert_refused(
        Expr.math_fn(UInt8(99), _c("f")), "unary math op 99 is above MATH_GAMMA"
    )
    _assert_refused(
        Expr.math_fn2(UInt8(7), _c("f"), _c("f")), "unknown binary math op 7"
    )


# =============================================================================
# CASE
# =============================================================================


def _case(var then0: Expr, var else_: Expr) -> Expr:
    var cases = List[WhenCaseData]()
    cases.append(WhenCaseData(Expr.binary(BIN_GT, _c("i"), _li(0)), then0^))
    return Expr.when(cases^, else_^)


def test_an_integer_case_flattens_its_slots_into_the_when_pool() raises:
    """An all-I64 CASE is EXPR_CASE_I64; its `when_pool` entry is
    `[cond, then, else]` and the node carries the entry's index. Mutant: the
    ELSE slot not appended (the entry then has two slots)."""
    var lo = _lower(_case(_c("i"), _li(0)))
    assert_equal(lo.kind(), EXPR_CASE_I64)
    assert_equal(len(lo.whens), 1)
    assert_equal(lo.node(lo.root).col_idx, 0)
    ref slots = lo.whens[0]
    assert_equal(len(slots), 3, "[cond, then, else]")
    assert_equal(lo.node(slots[0]).kind, EXPR_GT_I64)
    assert_equal(lo.node(slots[1]).kind, EXPR_COL)
    assert_equal(lo.node(slots[2]).kind, EXPR_LIT_I64)


def test_a_float_branch_makes_the_case_float_and_widens_the_integer_ones() raises:
    """A F64 THEN makes the CASE EXPR_CASE_F64, and the I64 ELSE is wrapped in
    EXPR_I64_TO_F64; a F64 ELSE does the same to an I64 THEN. Mutant: the
    `case_is_float` test in `_translate_when_branch` removed (the I64 branch
    then stays unwrapped)."""
    var lo = _lower(_case(_c("f"), _li(0)))
    assert_equal(lo.kind(), EXPR_CASE_F64)
    ref s1 = lo.whens[0]
    assert_equal(lo.node(s1[1]).kind, EXPR_COL, "the F64 THEN is not wrapped")
    assert_equal(lo.node(s1[2]).kind, EXPR_I64_TO_F64, "the I64 ELSE is wrapped")
    var lo2 = _lower(_case(_c("i"), _lf(0.5)))
    assert_equal(lo2.kind(), EXPR_CASE_F64, "a F64 ELSE makes the CASE F64")
    ref s2 = lo2.whens[0]
    assert_equal(lo2.node(s2[1]).kind, EXPR_I64_TO_F64)
    assert_equal(lo2.node(s2[2]).kind, EXPR_LIT_F64)


def test_a_case_with_no_when_is_refused() raises:
    """Mutant: the zero-case check removed (the CASE then lowers to a pool
    entry holding the ELSE only)."""
    _assert_refused(
        Expr.when(List[WhenCaseData](), _li(0)), "EXPR_WHEN with zero cases"
    )


def test_the_overload_without_a_when_pool_refuses_a_case() raises:
    """The seven-argument overload owns a `when_pool` the executor never
    sees, so it refuses a tree that filled it, and lowers a CASE-free tree.
    Mutant: its `len(when_pool) > 0` check removed."""
    var pool = List[RuntimeExpr]()
    var strings = List[String]()
    var decimals = List[DecimalSpec]()
    var in_lists = List[List[ScalarValue]]()
    var root = translate_expr(
        Expr.binary(BIN_GT, _c("i"), _li(3)), pool, _idx(), _dt(), strings,
        decimals, in_lists,
    )
    assert_equal(pool[root].kind, EXPR_GT_I64, "a CASE-free tree lowers")
    var msg = String("")
    try:
        _ = translate_expr(
            _case(_c("i"), _li(0)), pool, _idx(), _dt(), strings, decimals,
            in_lists,
        )
    except err:
        msg = String(err)
    assert_true(
        msg.find("reached the 7-arg translate_expr overload") >= 0,
        "a CASE through the 7-argument overload is refused: " + msg,
    )


# =============================================================================
# CAST
# =============================================================================


def test_a_float64_cast_widens_an_integer_and_passes_a_float_through() raises:
    """CAST(i AS DOUBLE) appends EXPR_I64_TO_F64 over the column; CAST(f AS
    DOUBLE) appends only the column. Mutant: the F64 operand also wrapped
    (the pool then holds two nodes)."""
    var lo = _lower(Expr.cast(_c("i"), DType.float64))
    assert_equal(lo.kind(), EXPR_I64_TO_F64)
    assert_equal(lo.node(lo.root).left, 0)
    var lo2 = _lower(Expr.cast(_c("f"), DType.float64))
    assert_equal(len(lo2.pool), 1, "a no-op cast appends nothing of its own")
    assert_equal(lo2.kind(), EXPR_COL)


def test_every_other_cast_and_tag_is_refused() raises:
    """A narrowing cast, a FLOAT64 cast over a STRING column, a column by
    index and a regexp all reach the final refusal. Mutant: the cast arm's
    FLOAT64 target check removed (the narrowing cast of a F64 column then
    lowers to the column itself)."""
    _assert_refused(Expr.cast(_c("f"), DType.int64), "Expr tag 5 not in")
    _assert_refused(Expr.cast(_c("s"), DType.float64), "Expr tag 5 not in")
    _assert_refused(
        Expr.cast_from_parts(_c("i"), DType.float64, ArrowType.FLOAT32, 0, 0, False),
        "Expr tag 5 not in",
    )
    _assert_refused(Expr.col_idx(0), "Expr tag 1 not in")
    _assert_refused(Expr.regexp_like(_c("s"), String("a")), "Expr tag 15 not in")


# =============================================================================
# count_and_conjuncts
# =============================================================================


def test_count_and_conjuncts_counts_the_leaves_of_an_and_chain() raises:
    """`(a AND b) AND (c AND d)` counts 4; a non-AND root counts 1. Mutant:
    the right side not counted (3 then)."""
    var p = Expr.binary(
        BIN_AND,
        Expr.binary(BIN_AND, Expr.binary(BIN_GT, _c("i"), _li(0)), _c("b")),
        Expr.binary(BIN_AND, _c("b"), Expr.binary(BIN_GT, _c("i"), _li(9))),
    )
    var lo = _lower(p)
    assert_equal(lo.kind(), EXPR_AND)
    assert_equal(count_and_conjuncts(lo.pool, lo.root), 4)
    var one = _lower(Expr.binary(BIN_GT, _c("i"), _li(0)))
    assert_equal(count_and_conjuncts(one.pool, one.root), 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

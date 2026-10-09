# =============================================================================
# test_plan_wire_values_gate_arms.mojo — `plan_wire_check_values` arms no
# other test reaches, and the admit gate's three remaining refusals.
# =============================================================================
#
# The value gate is public and runs on any `LogicalPlan`, not only a decoded
# one: `plan_from_bytes` calls it after decoding, and in-process callers
# (the conformance corpus, the dataframe doors) call it directly. So the plans
# below are built in-process and handed to it.
#
# THE ORACLE. The gate mirrors the engine's comparison and IN-list kernels,
# which live outside this repository; each mirror's docstring in
# `plan_wire_values.mojo` names the kernel lines it copies and, for the IN-list
# rule, the rows a wrong answer returns. Every verdict asserted here is one the
# module states in those docstrings, and every refusal is of a pair whose
# executed answer the docstring gives as wrong rows (an INT64 column probed
# with a FLOAT literal, a FLOAT64 column probed with an INT8 literal, a
# dictionary-of-strings probed with integers). The one verdict the module
# itself calls an over-refusal (a temporal column against an INT8 IN-list
# member at n >= 2) is not asserted.
#
# Each test pairs an admitted shape with a refused neighbour wherever the arm
# makes a choice, so a mirror arm that flipped either way is red.
#
# `_lookup_arrow_type`'s miss (`return ArrowType.NULL`) is reached by a
# LEFT/RIGHT-sided column reference OUTSIDE a join residual whose name the
# input lacks. The leaf arm resolves sided names only in a sided scope, so the
# gate admits that reference unresolved. One such shape is correct SQL: a
# correlated subquery whose inner plan names an OUTER column; it is asserted
# admitted below. The same miss on a plain filter (no subquery) is open in
# komira#991 item 2 and its verdict is not pinned here.
#
# NOT COVERED, ON PURPOSE: the `_child_pos` fall-through for a binary operator
# outside every declared range, which only an in-process `Expr.binary` with an
# undeclared operator reaches (komira#991 item 4).
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.agg_expr import AggExpr
from komira_plan_expr.expr import (
    Expr, EXPR_BETWEEN, BIN_ADD, BIN_EQ, BIN_GT, BIN_LT,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    JOIN_INNER,
    CORR_KIND_EXISTS,
    SOURCE_PARQUET,
)

from komira_plan_wire import (
    plan_to_bytes,
    plan_from_bytes,
    plan_wire_check_values,
    plan_wire_admit,
    plan_wire_apparent_depth,
    plan_wire_envelope_prescan,
    PlanWireVersionSet,
    PLAN_WIRE_INCOMPARABLE_LITERAL,
    PLAN_WIRE_UNCHECKED_VALUE_SITE,
    PLAN_WIRE_AGG_ARG_DROPPED,
    PLAN_WIRE_MALFORMED,
)


# =============================================================================
# Fixtures
# =============================================================================


def _schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, True))
    sb.add_field(Field("f", ArrowType.FLOAT64, True))
    sb.add_field(Field("s", ArrowType.STRING, True))
    sb.add_field(Field("d", ArrowType.DATE32, True))
    sb.add_field(Field("flag", ArrowType.BOOL, True))
    sb.add_field(Field("bin", ArrowType.BINARY, True))
    var dic = Field("dic", ArrowType.DICTIONARY, True)
    dic._dict_index_type = ArrowType.INT32
    sb.add_field(dic^)
    return sb.build()


def _scan() raises -> LogicalPlan:
    return LogicalPlan.scan(String("/d/t.parquet"), SOURCE_PARQUET, _schema())


def _col(name: String) -> Expr:
    return Expr.col_ref(name)


def _i(v: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int64(Int64(v)))


def _b(v: Bool) -> Expr:
    return Expr.literal(ScalarValue.from_bool(v))


def _str(v: String) -> Expr:
    return Expr.literal(ScalarValue.from_string(v))


def _where(var pred: Expr) raises -> LogicalPlan:
    return LogicalPlan.filter(pred^, _scan())


def _gate_error(p: LogicalPlan) raises -> String:
    try:
        plan_wire_check_values(p)
    except e:
        return String(e)
    return String("")


def _admits(what: String, p: LogicalPlan) raises:
    var text = _gate_error(p)
    assert_equal(text, String(""), what + ": refused a shape the gate admits")


def _refuses(what: String, p: LogicalPlan, token: String, detail: String) raises:
    var text = _gate_error(p)
    assert_true(text != "", what + ": admitted a shape the gate refuses")
    assert_true(
        text.startswith(token),
        what + ": refused, but not by " + token + ". Got: " + text,
    )
    assert_true(detail in text, what + ": does not say `" + detail + "`: " + text)


# =============================================================================
# Comparison domains (`_check_comparison_operands`, `_refuse_if_incomparable`)
# =============================================================================


def test_a_bool_column_compares_only_with_a_bool_literal() raises:
    _admits(String("flag = TRUE"), _where(Expr.binary(BIN_EQ, _col("flag"), _b(True))))
    _refuses(
        String("flag = 1"), _where(Expr.binary(BIN_EQ, _col("flag"), _i(1))),
        PLAN_WIRE_INCOMPARABLE_LITERAL, String("compares a column of type"),
    )


def test_a_string_column_compares_only_with_a_string_literal() raises:
    _admits(String("s = 'x'"), _where(Expr.binary(BIN_EQ, _col("s"), _str("x"))))
    _refuses(
        String("s = 1"), _where(Expr.binary(BIN_EQ, _col("s"), _i(1))),
        PLAN_WIRE_INCOMPARABLE_LITERAL, String("compares a column of type"),
    )


def test_a_column_with_no_comparison_domain_is_left_to_the_engine() raises:
    """BINARY has no domain in the table, so the gate declines to judge (the
    engine's own dispatch is the refusal for a pair it lacks)."""
    _admits(String("bin = 'x'"), _where(Expr.binary(BIN_EQ, _col("bin"), _str("x"))))


def test_an_aliased_column_is_graded_through_its_alias() raises:
    _refuses(
        String("(k AS x) > TRUE"),
        _where(Expr.binary(BIN_GT, Expr.alias(_col("k"), String("x")), _b(True))),
        PLAN_WIRE_INCOMPARABLE_LITERAL, String("against the literal"),
    )


def test_an_aliased_literal_is_graded_through_its_alias() raises:
    _refuses(
        String("k > (TRUE AS t)"),
        _where(Expr.binary(BIN_GT, _col("k"), Expr.alias(_b(True), String("t")))),
        PLAN_WIRE_INCOMPARABLE_LITERAL, String("against the literal"),
    )


def test_a_literal_on_the_left_of_a_comparison_is_graded_too() raises:
    _refuses(
        String("TRUE < k"), _where(Expr.binary(BIN_LT, _b(True), _col("k"))),
        PLAN_WIRE_INCOMPARABLE_LITERAL, String("against the literal"),
    )
    _admits(String("1 < k"), _where(Expr.binary(BIN_LT, _i(1), _col("k"))))


def test_a_temporal_column_reads_an_int_literal_but_not_a_float() raises:
    """`_temporal_column_reads_int_literal`: a DATE32 column is int32 days, and
    the executor's temporal arm reads an INT64 literal's `int_val`."""
    _admits(String("d > 20456"), _where(Expr.binary(BIN_GT, _col("d"), _i(20456))))
    _refuses(
        String("d > 2.5"),
        _where(
            Expr.binary(
                BIN_GT, _col("d"), Expr.literal(ScalarValue.from_float(2.5))
            )
        ),
        PLAN_WIRE_INCOMPARABLE_LITERAL, String("compares a column of type"),
    )


def _join_with_residual(var residual: Expr) raises -> LogicalPlan:
    """Left `(lk INT64, rk STRING)`, right `(rk INT64)`: `rk` names a column of
    a different type on each side, so a sided reference resolved against the
    wrong input changes the verdict."""
    var ls = SchemaBuilder()
    ls.add_field(Field("lk", ArrowType.INT64, True))
    ls.add_field(Field("rk", ArrowType.STRING, True))
    var rs = SchemaBuilder()
    rs.add_field(Field("rk", ArrowType.INT64, True))
    var lo: List[String] = [String("lk")]
    var ro: List[String] = [String("rk")]
    return LogicalPlan.join(
        LogicalPlan.scan(String("/d/l.parquet"), SOURCE_PARQUET, ls.build()),
        LogicalPlan.scan(String("/d/r.parquet"), SOURCE_PARQUET, rs.build()),
        lo^, ro^, JOIN_INNER,
        residual=Optional(OwnedPointer(residual^)),
    )


def test_a_sided_reference_in_a_join_residual_reads_its_own_side() raises:
    _refuses(
        String("right.rk = 'x'"),
        _join_with_residual(
            Expr.binary(BIN_EQ, Expr.right(String("rk")), _str("x"))
        ),
        PLAN_WIRE_INCOMPARABLE_LITERAL, String("compares a column of type"),
    )
    _admits(
        String("left.rk = 'x'"),
        _join_with_residual(
            Expr.binary(BIN_EQ, Expr.left(String("rk")), _str("x"))
        ),
    )


def test_a_correlated_outer_reference_the_inner_scan_lacks_is_admitted() raises:
    """`EXISTS (SELECT * FROM i WHERE LEFT.k > 1)`: `LEFT.k` is the CORRELATED
    OUTER reference, and the inner scan has no `k`. The gate descends into the
    inner plan, where the sided name is not resolved and the comparison
    lookup misses (`_lookup_arrow_type` returns NULL), so the comparison is
    not graded and the plan is admitted. It also crosses the wire: the decoded
    plan (which `plan_from_bytes` gates again) renders the same. Red: a lookup
    miss that refuses, or a gate that resolves the outer name against the
    inner scan."""
    var isb = SchemaBuilder()
    isb.add_field(Field("x", ArrowType.INT64, True))
    var inner = LogicalPlan.filter(
        Expr.binary(BIN_GT, Expr.left(String("k")), _i(1)),
        LogicalPlan.scan(String("/d/i.parquet"), SOURCE_PARQUET, isb.build()),
    )
    var refs: List[String] = [String("k")]
    var plan = _where(Expr.correlated_subquery(inner^, refs^, CORR_KIND_EXISTS))
    _admits(String("EXISTS (... LEFT.k > 1) over an inner scan with no k"), plan)
    var back = plan_from_bytes(plan_to_bytes(plan))
    assert_equal(back.structural_hash(), plan.structural_hash())


# =============================================================================
# Literals in a value position (`_literal_is_materializable`)
# =============================================================================


def test_every_literal_kind_broadcast_scalar_carries_is_admitted_as_a_value() raises:
    """DATE32, TIMESTAMP, INT32 and FLOAT32 each have an arm in the
    materializer's ladder, so each projects as itself."""
    var lits = List[ScalarValue]()
    lits.append(ScalarValue.date32(Int32(20456)))
    lits.append(ScalarValue.timestamp_micros(Int64(1_700_000_000_000_000)))
    lits.append(ScalarValue.from_int32(Int32(7)))
    lits.append(ScalarValue.from_float32(Float32(1.5)))
    for i in range(len(lits)):
        var xs = ExprArray()
        xs.append(Expr.alias(Expr.literal(lits[i].copy()), String("v")))
        _admits(
            String("project literal ") + String(i),
            LogicalPlan.project(xs^, _scan()),
        )


# =============================================================================
# IN-list values (`_check_in_list_values`, `_in_list_value_survives_kernel`)
# =============================================================================


def _in(col: String, var vals: List[ScalarValue]) raises -> LogicalPlan:
    return _where(Expr.in_list_node(_col(col), vals^))


def test_in_lists_every_kernel_carries_are_admitted() raises:
    """One admitted list per mirrored kernel arm, each at n = 2 so the
    membership kernel (not the folded comparison) is what would run."""
    var a: List[ScalarValue] = [
        ScalarValue.from_int64(Int64(2)), ScalarValue.null(DType.int64)
    ]
    _admits(String("k IN (2, NULL)"), _in(String("k"), a^))
    var b: List[ScalarValue] = [
        ScalarValue.from_int64(Int64(20456)), ScalarValue.from_int64(Int64(20458))
    ]
    _admits(String("d IN (20456, 20458)"), _in(String("d"), b^))
    var c: List[ScalarValue] = [
        ScalarValue.from_float(1.5), ScalarValue.from_int64(Int64(2))
    ]
    _admits(String("f IN (1.5, 2)"), _in(String("f"), c^))
    var d: List[ScalarValue] = [
        ScalarValue.from_string(String("a")), ScalarValue.from_string(String("b"))
    ]
    _admits(String("s IN ('a', 'b')"), _in(String("s"), d^))
    var e: List[ScalarValue] = [
        ScalarValue.from_bool(True), ScalarValue.from_bool(False)
    ]
    _admits(String("flag IN (TRUE, FALSE)"), _in(String("flag"), e^))


def test_an_in_list_over_a_computed_child_is_not_graded_by_column_type() raises:
    """When the IN-list's child is not a column reference (here `k + 1`),
    `_column_arrow_type` answers NULL and both rules decline. Asserted on an
    all-integer list, which is right under any reading; whether the gate should
    grade a computed child is open in komira#991, not pinned here."""
    var vals: List[ScalarValue] = [
        ScalarValue.from_int64(Int64(1)), ScalarValue.from_int64(Int64(2))
    ]
    _admits(
        String("(k + 1) IN (1, 2)"),
        _where(Expr.in_list_node(Expr.binary(BIN_ADD, _col("k"), _i(1)), vals^)),
    )


def test_a_float_member_of_an_int_list_is_refused_from_two_members() raises:
    """The module's own example: `id IN (3.0)` folds to `id = 3.0` and is
    right; `id IN (3.0, 5.0)` runs the integer kernel, which reads `int_val`
    (zero) for a FLOAT member."""
    var one: List[ScalarValue] = [ScalarValue.from_float(3.0)]
    _admits(String("k IN (3.0)"), _in(String("k"), one^))
    var two: List[ScalarValue] = [
        ScalarValue.from_float(3.0), ScalarValue.from_float(5.0)
    ]
    _refuses(
        String("k IN (3.0, 5.0)"), _in(String("k"), two^),
        PLAN_WIRE_INCOMPARABLE_LITERAL, String("_comparable_literal_i64"),
    )


def test_an_int8_member_of_a_float_list_is_refused() raises:
    """`_eval_in_list_float64` carries a FLOAT and an INT64/INT32 member; an
    INT8 member takes its `else` and probes 0.0."""
    var vals: List[ScalarValue] = [
        ScalarValue.from_int8(Int8(1)), ScalarValue.from_float(2.5)
    ]
    _refuses(
        String("f IN (int8 1, 2.5)"), _in(String("f"), vals^),
        PLAN_WIRE_INCOMPARABLE_LITERAL, String("_eval_in_list_float64"),
    )


def test_integer_members_of_a_dictionary_list_are_refused() raises:
    """A DICTIONARY column has no comparison domain, so rule 1 declines; the
    dictionary kernel then reads `string_val` (empty) for an integer member."""
    var vals: List[ScalarValue] = [
        ScalarValue.from_int64(Int64(1)), ScalarValue.from_int64(Int64(2))
    ]
    _refuses(
        String("dic IN (1, 2)"), _in(String("dic"), vals^),
        PLAN_WIRE_INCOMPARABLE_LITERAL, String("_eval_in_list_dictionary"),
    )


# =============================================================================
# Shapes the walk has no arm for: refused, never admitted unchecked
# =============================================================================


def test_a_payloadless_between_is_refused_as_unchecked() raises:
    _refuses(
        String("Expr(EXPR_BETWEEN)"), _where(Expr(EXPR_BETWEEN)),
        PLAN_WIRE_UNCHECKED_VALUE_SITE, String("has no payload field on `Expr`"),
    )


def test_an_undeclared_expr_tag_is_refused_as_unchecked() raises:
    """The bare `Expr(tag)` ctor takes any tag; 200 has no arm in the walk."""
    _refuses(
        String("Expr(200)"), _where(Expr(UInt8(200))),
        PLAN_WIRE_UNCHECKED_VALUE_SITE, String("expression tag 200 has no arm"),
    )


def test_an_aggregate_of_an_undeclared_function_is_refused() raises:
    """`AggExpr` takes any function tag; 99 has no arity, so the gate cannot
    say whether its argument slots are read."""
    var gb = ExprArray()
    var ax = AggExprArray()
    ax.append(AggExpr(UInt8(99), Optional(_col("k")), Optional(String("x"))))
    _refuses(
        String("agg fn 99"), LogicalPlan.aggregate(gb^, ax^, _scan()),
        PLAN_WIRE_AGG_ARG_DROPPED, String("aggregate function tag 99"),
    )


def test_a_bare_ctor_plan_of_no_arm_is_refused_as_unchecked() raises:
    _refuses(
        String("LogicalPlan(16)"), LogicalPlan(UInt8(16), _schema()),
        PLAN_WIRE_UNCHECKED_VALUE_SITE, String("plan tag 16"),
    )


# =============================================================================
# plan_wire_admit
# =============================================================================


def test_a_version_set_holds_versions_below_32_only() raises:
    """The set is a 32-bit mask: 31 is its last member, 32 is refused."""
    var top = PlanWireVersionSet.only(UInt32(31))
    assert_true(top.contains(UInt32(31)))
    var text = String("")
    try:
        _ = PlanWireVersionSet.only(UInt32(32))
    except e:
        text = String(e)
    assert_true(text.startswith(PLAN_WIRE_MALFORMED), "only(32): " + text)
    assert_true("cannot be a member" in text, text)


def test_a_varint_longer_than_ten_bytes_does_not_parse() raises:
    """Protobuf caps a varint at 10 bytes. Field 1 (varint) with a 10-byte
    value parses; with 11 bytes the top-level stream does not."""
    var ten: List[UInt8] = [UInt8(0x08)]
    for _ in range(9):
        ten.append(UInt8(0x80))
    ten.append(UInt8(0x01))
    _ = plan_wire_envelope_prescan(ten)
    var eleven: List[UInt8] = [UInt8(0x08)]
    for _ in range(10):
        eleven.append(UInt8(0x80))
    eleven.append(UInt8(0x01))
    var text = String("")
    try:
        _ = plan_wire_envelope_prescan(eleven)
    except e:
        text = String(e)
    assert_true(text.startswith(PLAN_WIRE_MALFORMED), "11-byte varint: " + text)
    assert_true("does not parse at byte offset 0" in text, text)


def test_bytes_that_are_no_field_stream_have_no_depth_and_are_refused() raises:
    """0x07 is field 0 with wire type 7: no field header at all. The depth walk
    stops at the top level, reporting no more depth than a top-level stream of
    one varint field (`format_version = 4`, nothing to descend into), and the
    gate refuses by name."""
    var bad: List[UInt8] = [UInt8(0x07)]
    var flat: List[UInt8] = [UInt8(0x08), UInt8(0x04)]
    assert_equal(plan_wire_apparent_depth(bad), plan_wire_apparent_depth(flat))
    var text = String("")
    try:
        plan_wire_admit(bad, PlanWireVersionSet.only(UInt32(4)))
    except e:
        text = String(e)
    assert_true(text.startswith(PLAN_WIRE_MALFORMED), "0x07: " + text)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

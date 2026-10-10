# =============================================================================
# optimizer_agg_group_fd: direct tests of the rewrite, every decline, the walk
# =============================================================================
#
# `GROUP BY a, a-1, a-2, a-3` has the groups of `GROUP BY a`: the three derived
# keys are deterministic functions of `a`. The rule drops them from the
# Aggregate and re-emits them in the post-aggregate Project. These tests call
# `elide_functionally_dependent_group_keys` directly (no pipeline), so each
# branch of `_build_fd_elided` and of the walk is reached in this package.
# Every test names the defect it catches. Guards that no constructor can
# violate (a schema whose width or names disagree with its node) are reached by
# editing the node's `output_schema` after construction, the state those guards
# exist to refuse.
# =============================================================================

from std.collections import Optional
from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.agg_expr import AggExpr, AGG_COUNT, AGG_SUM
from komira_plan_expr.expr import (
    Expr,
    BIN_ADD,
    BIN_SUB,
    EXPR_ALIAS,
    EXPR_COL_REF,
)
from komira_plan_expr.partition_expr import PF_RANK
from komira_plan_expr.partition_frame import PartitionFrame
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_expr.udf_data import (
    UdfData,
    UDF_KIND_MAP,
    UDF_KIND_AGG,
    UDF_NULL_PROPAGATE,
    UDF_STABILITY_IMMUTABLE,
    UDF_PAR_STATELESS,
    DTAG_I64,
)
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    CORR_KIND_EXISTS,
    JOIN_INNER,
    PLAN_AGGREGATE,
    PLAN_PROJECT,
    SOURCE_PARQUET,
)
from komira_optimizer.optimizer_agg_group_fd import (
    elide_functionally_dependent_group_keys,
    _derived_key_is_deterministic,
    _grouping_is_value_identity,
)


# -----------------------------------------------------------------------------
# fixtures
# -----------------------------------------------------------------------------


def _scan1(name: String, t: ArrowType) -> LogicalPlan:
    var sb = SchemaBuilder()
    sb.add_field(Field(name, t, False))
    return LogicalPlan.scan("hits.parquet", SOURCE_PARQUET, sb.build())


def _scan2(a: String, b: String) -> LogicalPlan:
    var sb = SchemaBuilder()
    sb.add_field(Field(a, ArrowType.INT64, False))
    sb.add_field(Field(b, ArrowType.INT64, False))
    return LogicalPlan.scan("hits.parquet", SOURCE_PARQUET, sb.build())


def _minus(c: String, k: Int) -> Expr:
    return Expr.binary(BIN_SUB, Expr.col_ref(c), Expr.literal(ScalarValue.from_int(k)))


def _count_star(name: String) -> AggExpr:
    var no_child: Optional[Expr] = None
    return AggExpr(AGG_COUNT, no_child^, Optional(name))


def _udf(kind: UInt8) -> OwnedPointer[UdfData]:
    var in_cols = List[Tuple[String, UInt8]]()
    in_cols.append(("ip", DTAG_I64))
    var out_cols = List[Tuple[String, UInt8]]()
    out_cols.append(("u", DTAG_I64))
    return OwnedPointer(UdfData(
        kind=kind,
        name=String("u"),
        input_columns=in_cols^,
        output_columns=out_cols^,
        operator_factory_id=UInt32(1),
        call_site_salt=UInt32(1),
        null_mode=UDF_NULL_PROPAGATE,
        stability=UDF_STABILITY_IMMUTABLE,
        parallelism_tag=UDF_PAR_STATELESS,
    ))


def _inner_two(body: Expr) -> ExprArray:
    """[ip, body AS k0]"""
    var inner = ExprArray()
    inner.append(Expr.col_ref("ip"))
    inner.append(Expr.alias(body.copy(), "k0"))
    return inner^


def _gb(a: String, b: String) -> ExprArray:
    var gb = ExprArray()
    gb.append(Expr.col_ref(a))
    gb.append(Expr.col_ref(b))
    return gb^


def _aggs1(var a: AggExpr) -> AggExprArray:
    var aggs = AggExprArray()
    aggs.append(a^)
    return aggs^


def _outer_ip_k0_c() -> ExprArray:
    """[ip, k0 AS m, c]"""
    var outer = ExprArray()
    outer.append(Expr.col_ref("ip"))
    outer.append(Expr.alias(Expr.col_ref("k0"), "m"))
    outer.append(Expr.col_ref("c"))
    return outer^


def _two_key(var child: LogicalPlan, body: Expr, var outer: ExprArray) -> LogicalPlan:
    """Project(outer) / Aggregate(ip, k0; count(*) AS c) / Project(ip, body AS k0)."""
    var inner_proj = LogicalPlan.project(_inner_two(body), child^)
    var agg = LogicalPlan.aggregate(_gb("ip", "k0"), _aggs1(_count_star("c")), inner_proj^)
    return LogicalPlan.project(outer^, agg^)


def _simple(t: ArrowType = ArrowType.INT64) -> LogicalPlan:
    return _two_key(_scan1("ip", t), _minus("ip", 1), _outer_ip_k0_c())


def _q35(var child: LogicalPlan) -> LogicalPlan:
    """Project [ip, k0 AS c1, k1 AS c2, k2 AS c3, c]
         Aggregate [ip, k0, k1, k2; count(*) AS c]
           Project [ip, (ip-1) AS k0, (ip-2) AS k1, (ip-3) AS k2]"""
    var inner = ExprArray()
    inner.append(Expr.col_ref("ip"))
    inner.append(Expr.alias(_minus("ip", 1), "k0"))
    inner.append(Expr.alias(_minus("ip", 2), "k1"))
    inner.append(Expr.alias(_minus("ip", 3), "k2"))
    var inner_proj = LogicalPlan.project(inner^, child^)
    var gb = ExprArray()
    gb.append(Expr.col_ref("ip"))
    gb.append(Expr.col_ref("k0"))
    gb.append(Expr.col_ref("k1"))
    gb.append(Expr.col_ref("k2"))
    var agg = LogicalPlan.aggregate(gb^, _aggs1(_count_star("c")), inner_proj^)
    var outer = ExprArray()
    outer.append(Expr.col_ref("ip"))
    outer.append(Expr.alias(Expr.col_ref("k0"), "c1"))
    outer.append(Expr.alias(Expr.col_ref("k1"), "c2"))
    outer.append(Expr.alias(Expr.col_ref("k2"), "c3"))
    outer.append(Expr.col_ref("c"))
    return LogicalPlan.project(outer^, agg^)


def _keys(imm plan: LogicalPlan) raises -> Int:
    """Group-key count of the Aggregate under the root Project."""
    return len(plan._project.value()[].child[]._aggregate.value()[].group_by)


def _inner_len(imm plan: LogicalPlan) raises -> Int:
    return len(
        plan._project.value()[].child[]._aggregate.value()[]
        .child[]._project.value()[].exprs
    )


def _sig(imm s: Schema) -> String:
    var out = String("")
    for i in range(s.num_columns()):
        out += s.field_name(i) + ":" + String(Int(s.field_arrow_type(i).type_id)) + ";"
    return out^


def _renamed(imm s: Schema, idx: Int, name: String) -> Schema:
    var sb = SchemaBuilder()
    for i in range(s.num_columns()):
        if i == idx:
            sb.add_field(Field(name, s.field_arrow_type(i), True))
        else:
            sb.add_field(s.field_at_unchecked(i))
    return sb.build()


def _retyped(imm s: Schema, idx: Int, t: ArrowType) -> Schema:
    var sb = SchemaBuilder()
    for i in range(s.num_columns()):
        if i == idx:
            sb.add_field(Field(s.field_name(i), t, True))
        else:
            sb.add_field(s.field_at_unchecked(i))
    return sb.build()


def _widened(imm s: Schema) -> Schema:
    var sb = SchemaBuilder()
    for i in range(s.num_columns()):
        sb.add_field(s.field_at_unchecked(i))
    sb.add_field(Field("extra", ArrowType.INT64, True))
    return sb.build()


def _narrowed(imm s: Schema) -> Schema:
    var sb = SchemaBuilder()
    for i in range(s.num_columns() - 1):
        sb.add_field(s.field_at_unchecked(i))
    return sb.build()


def _assert_declines(var plan: LogicalPlan, msg: String) raises:
    var before = _keys(plan)
    var out = elide_functionally_dependent_group_keys(plan^)
    assert_equal(_keys(out), before, msg)


# -----------------------------------------------------------------------------
# the rewrite
# -----------------------------------------------------------------------------


def test_q35_keeps_one_key_and_the_same_output_schema() raises:
    """Catches a rule that elides nothing, elides the base key, or changes the
    subtree's output columns (names, types or order)."""
    var plan = _q35(_scan1("ip", ArrowType.INT64))
    var sig = _sig(plan.output_schema)
    assert_equal(_keys(plan), 4)
    var out = elide_functionally_dependent_group_keys(plan^)
    assert_equal(_keys(out), 1)
    assert_equal(
        out._project.value()[].child[]._aggregate.value()[].group_by[0].col_ref_name(),
        String("ip"),
    )
    assert_equal(_sig(out.output_schema), sig)


def test_wrapped_outer_entries_get_the_body_and_keep_their_alias() raises:
    """Catches a fold that leaves `alias(col_ref(k))` pointing at a key the
    aggregate no longer produces, or drops the outer alias."""
    var out = elide_functionally_dependent_group_keys(_q35(_scan1("ip", ArrowType.INT64)))
    ref outer = out._project.value()[].exprs
    assert_equal(len(outer), 5)
    for i in range(1, 4):
        assert_equal(Int(outer[i].tag), Int(EXPR_ALIAS))
        assert_false(outer[i].alias_child_ref().tag == EXPR_COL_REF)
    assert_equal(outer[1].alias_name(), String("c1"))
    assert_equal(outer[3].alias_name(), String("c3"))
    assert_equal(outer[0].col_ref_name(), String("ip"), "a base key stays a col_ref")
    assert_equal(outer[4].col_ref_name(), String("c"), "an agg output stays a col_ref")


def test_bare_outer_col_ref_gets_the_inner_entry() raises:
    """`Project[ip, k0, c]`: a bare col_ref to an elided key becomes the inner
    entry `body AS k0`. Catches a fold that only handles the alias form."""
    var outer = ExprArray()
    outer.append(Expr.col_ref("ip"))
    outer.append(Expr.col_ref("k0"))
    outer.append(Expr.col_ref("c"))
    var plan = _two_key(_scan1("ip", ArrowType.INT64), _minus("ip", 1), outer^)
    var out = elide_functionally_dependent_group_keys(plan^)
    assert_equal(_keys(out), 1)
    ref e = out._project.value()[].exprs[1]
    assert_equal(Int(e.tag), Int(EXPR_ALIAS))
    assert_equal(e.alias_name(), String("k0"))
    assert_false(e.alias_child_ref().tag == EXPR_COL_REF)


def test_outer_expr_not_naming_an_elided_key_is_copied() raises:
    """`c + 1 AS c1` names no elided key, so the rewrite proceeds and keeps it.
    Catches a fold that declines on every computed outer entry."""
    var outer = _outer_ip_k0_c()
    outer.append(
        Expr.alias(
            Expr.binary(BIN_ADD, Expr.col_ref("c"), Expr.literal(ScalarValue.from_int(1))),
            "c_next",
        )
    )
    var plan = _two_key(_scan1("ip", ArrowType.INT64), _minus("ip", 1), outer^)
    var out = elide_functionally_dependent_group_keys(plan^)
    assert_equal(_keys(out), 1)
    assert_equal(out._project.value()[].exprs[3].alias_name(), String("c_next"))


def test_dead_inner_entry_dropped_only_when_no_agg_reads_it() raises:
    """The derived entry leaves the inner Project unless an aggregate input
    reads it, in any of its four child slots. Catches a needed-set that skips
    a slot (the aggregate would then read a dropped column)."""
    var plain = elide_functionally_dependent_group_keys(_simple())
    assert_equal(_inner_len(plain), 1, "unread derived entry is dropped")
    for slot in range(4):
        var ae = AggExpr(AGG_SUM, Optional(Expr.col_ref("ip")), Optional(String("c")))
        if slot == 0:
            ae.child = Optional(Expr.col_ref("k0"))
        elif slot == 1:
            ae.child1 = Optional(Expr.col_ref("k0"))
        elif slot == 2:
            ae.child2 = Optional(Expr.col_ref("k0"))
        else:
            ae.child3 = Optional(Expr.col_ref("k0"))
        var inner_proj = LogicalPlan.project(
            _inner_two(_minus("ip", 1)), _scan1("ip", ArrowType.INT64)
        )
        var agg = LogicalPlan.aggregate(_gb("ip", "k0"), _aggs1(ae^), inner_proj^)
        var plan = LogicalPlan.project(_outer_ip_k0_c(), agg^)
        var out = elide_functionally_dependent_group_keys(plan^)
        assert_equal(_keys(out), 1, "the key is still elided")
        assert_equal(_inner_len(out), 2, "an entry an aggregate reads is kept")


def test_estimated_groups_survive() raises:
    """Catches a rebuild that drops the aggregate's group estimate (the group
    set is unchanged, so the estimate still holds)."""
    var plan = _simple()
    plan._project.value()[].child[]._aggregate.value()[].estimated_groups = Optional(42)
    var out = elide_functionally_dependent_group_keys(plan^)
    assert_equal(_keys(out), 1)
    ref eg = out._project.value()[].child[]._aggregate.value()[].estimated_groups
    assert_true(Bool(eg))
    assert_equal(eg.value(), 42)


def test_rule_is_idempotent() raises:
    """Catches a second run that elides again or changes the schema."""
    var once = elide_functionally_dependent_group_keys(_q35(_scan1("ip", ArrowType.INT64)))
    var sig = _sig(once.output_schema)
    var twice = elide_functionally_dependent_group_keys(once^)
    assert_equal(_keys(twice), 1)
    assert_equal(_sig(twice.output_schema), sig)


# -----------------------------------------------------------------------------
# the declines (each returns the plan with its keys intact)
# -----------------------------------------------------------------------------


def test_udf_nodes_decline() raises:
    """Catches a rule that rewrites around a typed-UDF Project or Aggregate,
    whose output columns it cannot see."""
    var inner1 = LogicalPlan.project(_inner_two(_minus("ip", 1)), _scan1("ip", ArrowType.INT64))
    var agg1 = LogicalPlan.aggregate(_gb("ip", "k0"), _aggs1(_count_star("c")), inner1^)
    _assert_declines(
        LogicalPlan.project_with_udf(_outer_ip_k0_c(), agg1^, _udf(UDF_KIND_MAP)),
        "outer Project carries a UDF",
    )
    var inner2 = LogicalPlan.project(_inner_two(_minus("ip", 1)), _scan1("ip", ArrowType.INT64))
    var agg2 = LogicalPlan.aggregate_with_udf(
        _gb("ip", "k0"), _aggs1(_count_star("c")), inner2^, _udf(UDF_KIND_AGG)
    )
    _assert_declines(LogicalPlan.project(_outer_ip_k0_c(), agg2^), "Aggregate carries a UDF")
    var inner3 = LogicalPlan.project_with_udf(
        _inner_two(_minus("ip", 1)), _scan1("ip", ArrowType.INT64), _udf(UDF_KIND_MAP)
    )
    var agg3 = LogicalPlan.aggregate(_gb("ip", "k0"), _aggs1(_count_star("c")), inner3^)
    _assert_declines(LogicalPlan.project(_outer_ip_k0_c(), agg3^), "inner Project carries a UDF")


def test_shape_declines() raises:
    """No inner Project, one key, a computed key, a key renamed by the
    aggregate's de-duplication: each declines. Catches a missing shape guard."""
    var agg = LogicalPlan.aggregate(
        _gb("a", "b"), _aggs1(_count_star("c")), _scan2("a", "b")
    )
    var outer = ExprArray()
    outer.append(Expr.col_ref("a"))
    _assert_declines(LogicalPlan.project(outer^, agg^), "Aggregate directly over a Scan")

    var inner = ExprArray()
    inner.append(Expr.col_ref("ip"))
    var gb1 = ExprArray()
    gb1.append(Expr.col_ref("ip"))
    var agg1 = LogicalPlan.aggregate(
        gb1^, _aggs1(_count_star("c")),
        LogicalPlan.project(inner^, _scan1("ip", ArrowType.INT64)),
    )
    var o1 = ExprArray()
    o1.append(Expr.col_ref("ip"))
    _assert_declines(LogicalPlan.project(o1^, agg1^), "a single key")

    var gb2 = ExprArray()
    gb2.append(Expr.col_ref("ip"))
    gb2.append(_minus("ip", 1))
    var agg2 = LogicalPlan.aggregate(
        gb2^, _aggs1(_count_star("c")),
        LogicalPlan.project(_inner_two(_minus("ip", 1)), _scan1("ip", ArrowType.INT64)),
    )
    var o2 = ExprArray()
    o2.append(Expr.col_ref("ip"))
    _assert_declines(LogicalPlan.project(o2^, agg2^), "a computed group key")

    var agg3 = LogicalPlan.aggregate(
        _gb("ip", "ip"), _aggs1(_count_star("c")),
        LogicalPlan.project(_inner_two(_minus("ip", 1)), _scan1("ip", ArrowType.INT64)),
    )
    var o3 = ExprArray()
    o3.append(Expr.col_ref("ip"))
    _assert_declines(LogicalPlan.project(o3^, agg3^), "a key renamed ip_1")


def test_schema_guards_decline() raises:
    """A node whose `output_schema` disagrees with its expressions: the
    aggregate one column wider, the inner Project one column short, a key's
    inner field under another name. Catches a guard that trusts the schema."""
    var p1 = _simple()
    ref a1 = p1._project.value()[].child[]
    a1.output_schema = _widened(a1.output_schema)
    _assert_declines(p1^, "aggregate schema wider than keys + aggs")

    var p2 = _simple()
    ref i2 = p2._project.value()[].child[]._aggregate.value()[].child[]
    i2.output_schema = _narrowed(i2.output_schema)
    _assert_declines(p2^, "inner schema narrower than its exprs")

    var p3 = _simple()
    ref i3 = p3._project.value()[].child[]._aggregate.value()[].child[]
    i3.output_schema = _renamed(i3.output_schema, 1, "zz")
    _assert_declines(p3^, "no inner field carries the key's name")


def test_inner_entry_guards_decline() raises:
    """No pass-through base key; a derived entry that is not an alias; an
    alias under another name than its field. Catches a classifier that elides
    a key whose output name it would have to re-derive."""
    var inner = ExprArray()
    inner.append(Expr.alias(_minus("ip", 1), "k0"))
    inner.append(Expr.alias(_minus("ip", 2), "k1"))
    var agg = LogicalPlan.aggregate(
        _gb("k0", "k1"), _aggs1(_count_star("c")),
        LogicalPlan.project(inner^, _scan1("ip", ArrowType.INT64)),
    )
    var o = ExprArray()
    o.append(Expr.col_ref("k0"))
    _assert_declines(LogicalPlan.project(o^, agg^), "every key derived: no base")

    var p2 = _simple()
    p2._project.value()[].child[]._aggregate.value()[].child[]._project.value()[].exprs[1] = (
        _minus("ip", 1)
    )
    _assert_declines(p2^, "derived entry is a bare computed expr")

    var p3 = _simple()
    p3._project.value()[].child[]._aggregate.value()[].child[]._project.value()[].exprs[1] = (
        Expr.alias(_minus("ip", 1), "other")
    )
    _assert_declines(p3^, "alias name differs from the field name")


def test_derived_key_guards_decline() raises:
    """A UDF key (not deterministic), a constant key, a key over a non-key
    column, a key over a FLOAT base. Catches each elision that would merge or
    split groups."""
    var udf = Expr.udf_call(
        String("f"), Optional[Int](None), ArrowType.INT64, ArrowType.INT64,
        Expr.col_ref("ip"),
    )
    _assert_declines(
        _two_key(_scan1("ip", ArrowType.INT64), udf, _outer_ip_k0_c()), "UDF key"
    )
    _assert_declines(
        _two_key(
            _scan1("ip", ArrowType.INT64),
            Expr.literal(ScalarValue.from_int(7)),
            _outer_ip_k0_c(),
        ),
        "constant key",
    )
    var inner = ExprArray()
    inner.append(Expr.col_ref("ip"))
    inner.append(Expr.alias(_minus("b", 1), "k0"))
    var agg = LogicalPlan.aggregate(
        _gb("ip", "k0"), _aggs1(_count_star("c")),
        LogicalPlan.project(inner^, _scan2("ip", "b")),
    )
    _assert_declines(LogicalPlan.project(_outer_ip_k0_c(), agg^), "key over a non-key column")
    _assert_declines(_simple(ArrowType.FLOAT64), "FLOAT base column")


def test_outer_entry_naming_an_elided_key_declines() raises:
    """`k0 + 7 AS d` is neither `col_ref(k0)` nor `alias(col_ref(k0))`.
    Catches a fold that copies it verbatim (a dangling col_ref)."""
    var outer = ExprArray()
    outer.append(Expr.col_ref("ip"))
    outer.append(
        Expr.alias(
            Expr.binary(BIN_ADD, Expr.col_ref("k0"), Expr.literal(ScalarValue.from_int(7))),
            "d",
        )
    )
    outer.append(Expr.col_ref("c"))
    _assert_declines(
        _two_key(_scan1("ip", ArrowType.INT64), _minus("ip", 1), outer^), "computed outer entry"
    )


def test_postcondition_agg_name_shift_declines() raises:
    """An aggregate aliased like the elided key was de-duplicated to `k0_1`;
    without the key it would be named `k0`. Catches a rebuild that ships a
    renamed aggregate output."""
    var inner_proj = LogicalPlan.project(_inner_two(_minus("ip", 1)), _scan1("ip", ArrowType.INT64))
    var agg = LogicalPlan.aggregate(_gb("ip", "k0"), _aggs1(_count_star("k0")), inner_proj^)
    var outer = ExprArray()
    outer.append(Expr.col_ref("ip"))
    outer.append(Expr.alias(Expr.col_ref("k0"), "m"))
    outer.append(Expr.col_ref("k0_1"))
    _assert_declines(LogicalPlan.project(outer^, agg^), "agg output renamed")


def test_postcondition_output_schema_declines() raises:
    """The rebuilt subtree must match the old output schema in width, names
    and types. Catches a post-condition that skips any of the three."""
    var p1 = _simple()
    p1.output_schema = _widened(p1.output_schema)
    _assert_declines(p1^, "width")
    var p2 = _simple()
    p2.output_schema = _renamed(p2.output_schema, 1, "zz")
    _assert_declines(p2^, "name")
    var p3 = _simple()
    p3.output_schema = _retyped(p3.output_schema, 0, ArrowType.FLOAT64)
    _assert_declines(p3^, "type")


# -----------------------------------------------------------------------------
# the guards, called directly
# -----------------------------------------------------------------------------


def test_value_identity_guard() raises:
    """Catches a guard that admits any float width, or answers True for a
    column it cannot find."""
    var sb = SchemaBuilder()
    sb.add_field(Field("i", ArrowType.INT64, False))
    sb.add_field(Field("h", ArrowType.FLOAT16, False))
    sb.add_field(Field("f", ArrowType.FLOAT32, False))
    sb.add_field(Field("d", ArrowType.FLOAT64, False))
    var s = sb.build()
    assert_true(_grouping_is_value_identity(s, "i"))
    assert_false(_grouping_is_value_identity(s, "h"))
    assert_false(_grouping_is_value_identity(s, "f"))
    assert_false(_grouping_is_value_identity(s, "d"))
    assert_false(_grouping_is_value_identity(s, "missing"))


def test_determinism_guard() raises:
    """Catches a guard that admits an aggregate, a window function, a
    positional reference or a correlated subquery as a key, or swallows the
    correlated-subquery refusal of the UDF walk as 'deterministic'."""
    assert_true(_derived_key_is_deterministic(_minus("ip", 1)))
    assert_false(_derived_key_is_deterministic(Expr.agg_fn(AGG_SUM, Expr.col_ref("ip"))))
    assert_false(
        _derived_key_is_deterministic(
            Expr.window_fn(PF_RANK, String(""), 0, PartitionFrame.default_ordered())
        )
    )
    assert_false(_derived_key_is_deterministic(Expr.col_idx(0)))
    var refs = List[String]()
    refs.append(String("ip"))
    var corr = Expr.correlated_subquery(_scan1("ip", ArrowType.INT64), refs^, CORR_KIND_EXISTS)
    assert_false(_derived_key_is_deterministic(corr.copy()), "at the top")
    var nested = Expr.binary(BIN_ADD, corr^, Expr.literal(ScalarValue.from_int(1)))
    assert_false(_derived_key_is_deterministic(nested), "nested: the walk raises")
    var udf = Expr.udf_call(
        String("f"), Optional[Int](None), ArrowType.INT64, ArrowType.INT64,
        Expr.col_ref("ip"),
    )
    assert_false(_derived_key_is_deterministic(udf))


# -----------------------------------------------------------------------------
# the walk
# -----------------------------------------------------------------------------


def _inner_keys(imm plan: LogicalPlan) raises -> Int:
    """Key count of the q35 subtree rooted at `plan`, or -1 if `plan` is not
    a Project."""
    if plan.tag == PLAN_PROJECT:
        return _keys(plan)
    return -1


def test_walk_reaches_the_match_under_every_node_kind() raises:
    """Catches a walk arm that is missing or descends the wrong child."""
    var p = Expr.binary(BIN_ADD, Expr.col_ref("ip"), Expr.literal(ScalarValue.from_int(0)))
    var f = elide_functionally_dependent_group_keys(
        LogicalPlan.filter(p^, _q35(_scan1("ip", ArrowType.INT64)))
    )
    assert_equal(_keys(f._filter.value()[].child[]), 1, "filter")

    var desc = List[Bool]()
    desc.append(False)
    var keys = List[String]()
    keys.append(String("ip"))
    var s = elide_functionally_dependent_group_keys(
        LogicalPlan.sort(keys.copy(), desc.copy(), _q35(_scan1("ip", ArrowType.INT64)))
    )
    assert_equal(_keys(s._sort.value()[].child[]), 1, "sort")

    var l = elide_functionally_dependent_group_keys(
        LogicalPlan.limit(3, _q35(_scan1("ip", ArrowType.INT64)))
    )
    assert_equal(_keys(l._limit.value()[].child[]), 1, "limit")

    var nc: Optional[List[String]] = None
    var d = elide_functionally_dependent_group_keys(
        LogicalPlan.distinct(nc^, _q35(_scan1("ip", ArrowType.INT64)))
    )
    assert_equal(_keys(d._distinct.value()[].child[]), 1, "distinct")

    var t = elide_functionally_dependent_group_keys(
        LogicalPlan.topn(keys.copy(), desc.copy(), 2, _q35(_scan1("ip", ArrowType.INT64)))
    )
    assert_equal(_keys(t._topn.value()[].child[]), 1, "topn")

    var j = elide_functionally_dependent_group_keys(
        LogicalPlan.join(
            _q35(_scan1("ip", ArrowType.INT64)),
            _q35(_scan1("ip", ArrowType.INT64)),
            keys.copy(), keys.copy(), JOIN_INNER,
        )
    )
    assert_equal(_keys(j._join.value()[].left[]), 1, "join left")
    assert_equal(_keys(j._join.value()[].right[]), 1, "join right")

    var gb = ExprArray()
    gb.append(Expr.col_ref("ip"))
    var a = elide_functionally_dependent_group_keys(
        LogicalPlan.aggregate(gb^, _aggs1(_count_star("n")), _q35(_scan1("ip", ArrowType.INT64)))
    )
    assert_equal(Int(a.tag), Int(PLAN_AGGREGATE))
    assert_equal(_keys(a._aggregate.value()[].child[]), 1, "aggregate (no outer Project)")

    var o = ExprArray()
    o.append(Expr.col_ref("ip"))
    var p2 = Expr.binary(BIN_ADD, Expr.col_ref("ip"), Expr.literal(ScalarValue.from_int(0)))
    var pr = elide_functionally_dependent_group_keys(
        LogicalPlan.project(o^, LogicalPlan.filter(p2^, _q35(_scan1("ip", ArrowType.INT64))))
    )
    assert_equal(
        _keys(pr._project.value()[].child[]._filter.value()[].child[]), 1,
        "project over a non-aggregate",
    )


def test_match_site_rewrites_a_nested_match_first() raises:
    """q35 whose inner Project reads another q35: the walk recurses below the
    aggregate before rewriting the outer one. Catches a match site that skips
    its subtree."""
    var out = elide_functionally_dependent_group_keys(_q35(_q35(_scan1("ip", ArrowType.INT64))))
    assert_equal(_keys(out), 1, "outer")
    ref nested = (
        out._project.value()[].child[]._aggregate.value()[].child[]
        ._project.value()[].child[]
    )
    assert_equal(_inner_keys(nested), 1, "nested")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

# =============================================================================
# plan_scan_shares: every admission rule, and every OptimizerConfig field it
# reads
# =============================================================================
#
# The pass decides which scans are read once and which stay Parquet
# sources. Its outcome is invisible in query results (the rows are the same
# either way), so each rule is pinned here by the group set it produces on a
# small plan, with the config field at its default and at a value that flips
# the rule. Each test names the defect it catches.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.agg_expr import AggExpr, AGG_SUM
from komira_plan_expr.expr import Expr, BIN_GT
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    AggExprArray,
    ExprArray,
    LogicalPlan,
    JOIN_INNER,
    SOURCE_IN_MEMORY,
    SOURCE_PARQUET,
)
from komira_optimizer.optimizer_config import OptimizerConfig
from komira_optimizer.optimizer_scan_share import (
    DEDUP_ROW_THRESHOLD,
    ScanSharePlan,
    _dyn_narrow_cache_key,
    _scan_key,
    _session_cache_key,
    plan_scan_shares,
)


# -----------------------------------------------------------------------------
# fixtures
# -----------------------------------------------------------------------------


def _schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    sb.add_field(Field("x", ArrowType.INT64, False))
    sb.add_field(Field("f", ArrowType.FLOAT64, False))
    return sb.build()


def _gt(name: String, v: Int) -> Expr:
    return Expr.binary(
        BIN_GT, Expr.col_ref(name), Expr.literal(ScalarValue.from_int(v))
    )


def _pq(
    path: String,
    var filter: Optional[Expr] = None,
    var proj: Optional[List[String]] = None,
    rows: Optional[Int] = None,
) -> LogicalPlan:
    var rc: Optional[Int] = rows
    return LogicalPlan.scan(
        path, SOURCE_PARQUET, _schema(), proj^, filter^, rc^
    )


def _l1(s: String) -> List[String]:
    var out = List[String]()
    out.append(s)
    return out^


def _l2(a: String, b: String) -> List[String]:
    var out = List[String]()
    out.append(a)
    out.append(b)
    return out^


def _join(var l: LogicalPlan, var r: LogicalPlan) -> LogicalPlan:
    return LogicalPlan.join(l^, r^, _l1("k"), _l1("k"), JOIN_INNER)


def _agg(var child: LogicalPlan) -> LogicalPlan:
    var gb = ExprArray()
    gb.append(Expr.col_ref("k"))
    var aggs = AggExprArray()
    var c: Optional[Expr] = Optional(Expr.col_ref("x"))
    aggs.append(AggExpr(AGG_SUM, c^, Optional(String("s"))))
    return LogicalPlan.aggregate(gb^, aggs^, child^)


def _key(path: String) -> String:
    var none: Optional[Expr] = None
    return _scan_key(path, none^)


def _paths(sp: ScanSharePlan) -> String:
    """The group paths, comma-joined in decision order."""
    var out = String("")
    for i in range(sp.len()):
        if i > 0:
            out += ","
        out += sp.groups[i].path
    return out^


def _shares(plan: LogicalPlan, config: OptimizerConfig) raises -> String:
    return _paths(plan_scan_shares(plan, config))


def _dup_join(rows: Int) -> LogicalPlan:
    """JOIN(a, a): one file read twice in one plan."""
    return _join(_pq("a.parquet", rows=rows), _pq("a.parquet", rows=rows))


# -----------------------------------------------------------------------------
# config fields
# -----------------------------------------------------------------------------


def test_disable_scan_dedup_decides_nothing() raises:
    """`disable_scan_dedup=True` returns an empty plan where the default
    shares the duplicated scan. Catches the condition inverted or the field
    ignored (dedup could then not be turned off)."""
    var cfg = OptimizerConfig()
    assert_equal(_shares(_dup_join(10), cfg), "a.parquet")
    cfg.disable_scan_dedup = True
    assert_equal(_shares(_dup_join(10), cfg), "")


def test_disable_scan_dedup_for_agg_skips_only_agg_only_singletons() raises:
    """With the field set, a multi-table singleton whose only consumer is an
    Aggregate stays a Parquet source; a singleton a join reads is still
    admitted. Catches the `and` dropped (every singleton skipped) or the
    field ignored."""
    var cfg = OptimizerConfig()
    var plan = _join(_agg(_pq("a.parquet", rows=10)), _pq("b.parquet", rows=10))
    assert_equal(_shares(plan, cfg), "a.parquet,b.parquet")
    cfg.disable_scan_dedup_for_agg = True
    assert_equal(_shares(plan, cfg), "b.parquet")
    var no_agg = _join(_pq("a.parquet", rows=10), _pq("b.parquet", rows=10))
    assert_equal(_shares(no_agg, cfg), "a.parquet,b.parquet")


def test_agg_inmem_ceiling_keeps_large_agg_input_parquet() raises:
    """An agg-only singleton whose raw row count is ABOVE the ceiling stays a
    Parquet source; AT the ceiling it is admitted; a non-positive ceiling is
    the 4,000,000 default; an unknown count is not skipped by this rule (Step
    3 then skips it). Catches `>` changed to `>=` at the boundary and the
    field ignored (the in-memory aggregate would be planned over an input it
    refuses)."""
    var plan = _join(_agg(_pq("a.parquet", rows=100)), _pq("b.parquet", rows=10))
    var cfg = OptimizerConfig()
    assert_equal(_shares(plan, cfg), "a.parquet,b.parquet")
    cfg.agg_inmem_max_rows = 99
    assert_equal(_shares(plan, cfg), "b.parquet")
    cfg.agg_inmem_max_rows = 100
    assert_equal(_shares(plan, cfg), "a.parquet,b.parquet")
    cfg.agg_inmem_max_rows = 0
    assert_equal(_shares(plan, cfg), "a.parquet,b.parquet")
    cfg.agg_inmem_max_rows = 99
    var unknown = _join(_agg(_pq("a.parquet")), _pq("b.parquet", rows=10))
    assert_equal(_shares(unknown, cfg), "b.parquet")


def test_fact_stream_rule_a_protects_both_streaming_children() raises:
    """`fact_stream_protect_rows=64` keeps BOTH children of a streaming join
    with a child above 64 rows as Parquet sources; the default admits them; a
    scan outside the protected join is still admitted. Catches the threshold
    read swapped to the default (the 64-row fixture would never trip it)."""
    var plan = _join(_pq("a.parquet", rows=100), _pq("b.parquet", rows=10))
    var cfg = OptimizerConfig()
    assert_equal(_shares(plan, cfg), "a.parquet,b.parquet")
    cfg.fact_stream_protect_rows = 64
    assert_equal(_shares(plan, cfg), "")
    var outer = _join(
        _join(_pq("a.parquet", rows=100), _pq("b.parquet", rows=10)),
        _agg(_pq("c.parquet", rows=10)),
    )
    assert_equal(_shares(outer, cfg), "c.parquet")


def test_fact_stream_rule_b_breaker_child() raises:
    """A large UNFILTERED fact joined to a breaker (an Aggregate) stays a
    Parquet source under rule (b) when above the threshold; a filtered fact,
    a hoist large side, an agg-only fact and an unknown count are not
    protected by it. Catches each of rule (b)'s four guards dropped."""
    var cfg = OptimizerConfig()
    cfg.fact_stream_protect_rows = 64
    var plain = _join(_pq("a.parquet", rows=100), _agg(_pq("b.parquet", rows=10)))
    assert_equal(_shares(plain, cfg), "b.parquet")
    var dflt = OptimizerConfig()
    assert_equal(_shares(plain, dflt), "a.parquet,b.parquet")
    # Filtered fact (a Filter above it): raw count over-states it, not skipped.
    var filtered = _join(
        LogicalPlan.filter(_gt("x", 0), _pq("a.parquet", rows=100)),
        _agg(_pq("b.parquet", rows=10)),
    )
    assert_equal(_shares(filtered, cfg), "a.parquet,b.parquet")
    # Hoist large side: the hoist narrows it, not skipped (rule (a) is also
    # excluded by the hoist).
    var hoist = _join(
        _pq("a.parquet", rows=100), _pq("s.parquet", Optional(_gt("x", 1)), rows=5)
    )
    assert_equal(_shares(hoist, cfg), "a.parquet,s.parquet")
    # Agg-only fact: owned by the ceiling gate, not rule (b).
    var agg_only = _join(_agg(_pq("a.parquet", rows=100)), _pq("b.parquet", rows=10))
    assert_equal(_shares(agg_only, cfg), "a.parquet,b.parquet")
    # Unknown count: rule (b) does not fire; Step 3 drops it.
    var unknown = _join(_pq("a.parquet"), _agg(_pq("b.parquet", rows=10)))
    assert_equal(_shares(unknown, cfg), "b.parquet")


# -----------------------------------------------------------------------------
# admission rules at the default config
# -----------------------------------------------------------------------------


def test_nothing_to_share() raises:
    """No Parquet scan, and a single-table single scan, both give an empty
    plan. Catches a singleton admitted on a single-table query (a deep
    copy every call for no reuse)."""
    var cfg = OptimizerConfig()
    var mem = LogicalPlan.scan("m", SOURCE_IN_MEMORY, _schema())
    assert_equal(plan_scan_shares(mem, cfg).len(), 0)
    assert_equal(_shares(_pq("a.parquet", rows=10), cfg), "")


def test_duplicate_group_absorbs_filter_and_unions_projection() raises:
    """Two scans of one file with one filter become ONE group: union of their
    projections plus the filter's column, the filter absorbed, the session key
    over exactly that read, no dyn-filter slot. Catches a shared read missing
    a consumer's column or the filter's column (the absorbed filter could not
    be evaluated)."""
    var cfg = OptimizerConfig()
    var plan = _join(
        _pq("a.parquet", Optional(_gt("x", 1)), Optional(_l1("k")), 10),
        _pq("a.parquet", Optional(_gt("x", 1)), Optional(_l1("f")), 10),
    )
    var sp = plan_scan_shares(plan, cfg)
    assert_equal(sp.len(), 1)
    ref g = sp.groups[0]
    assert_equal(g.key, _scan_key("a.parquet", Optional(_gt("x", 1))))
    assert_equal(g.path, "a.parquet")
    assert_equal(len(g.union_proj.value()), 3)
    assert_equal(g.union_proj.value()[0], "k")
    assert_equal(g.union_proj.value()[1], "f")
    assert_equal(g.union_proj.value()[2], "x")
    assert_true(Bool(g.filter))
    var want = _session_cache_key(
        "a.parquet", Optional(_gt("x", 1)), g.union_proj.value().copy()
    )
    assert_equal(g.sess_key, want)
    assert_equal(g.dyn_narrow_key, "")
    assert_false(Bool(g.hoist))


def test_duplicate_group_projection_edge_cases() raises:
    """The filter column already projected is not added twice; an unprojected
    duplicate means read all columns (None) even with a filter; an unfiltered
    group absorbs nothing. Catches a duplicated column in the read or a
    projection forced on a consumer that needs every column."""
    var cfg = OptimizerConfig()
    var has_x = _join(
        _pq("a.parquet", Optional(_gt("x", 1)), Optional(_l2("k", "x")), 10),
        _pq("a.parquet", Optional(_gt("x", 1)), Optional(_l1("k")), 10),
    )
    var sp = plan_scan_shares(has_x, cfg)
    assert_equal(sp.len(), 1)
    assert_equal(len(sp.groups[0].union_proj.value()), 2)
    var all_cols = _join(
        _pq("a.parquet", Optional(_gt("x", 1)), Optional(_l1("k")), 10),
        _pq("a.parquet", Optional(_gt("x", 1)), rows=10),
    )
    var sp2 = plan_scan_shares(all_cols, cfg)
    assert_equal(sp2.len(), 1)
    assert_false(Bool(sp2.groups[0].union_proj))
    assert_true(Bool(sp2.groups[0].filter))
    var sp3 = plan_scan_shares(_dup_join(10), cfg)
    assert_equal(sp3.len(), 1)
    assert_false(Bool(sp3.groups[0].filter))
    assert_false(Bool(sp3.groups[0].union_proj))


def test_row_threshold() raises:
    """A group at DEDUP_ROW_THRESHOLD is shared; one row above is not; an
    unknown count is not. Catches a group admitted above the threshold."""
    var cfg = OptimizerConfig()
    assert_equal(_shares(_dup_join(DEDUP_ROW_THRESHOLD), cfg), "a.parquet")
    assert_equal(_shares(_dup_join(DEDUP_ROW_THRESHOLD + 1), cfg), "")
    var unknown = _join(_pq("a.parquet"), _pq("a.parquet"))
    assert_equal(_shares(unknown, cfg), "")


def test_hoist_group_carries_the_dynamic_filter_slot() raises:
    """JOIN(big, small WHERE ...): the big group carries the slot (small path,
    both join columns, the augmented small projection, the small filter, the
    small session key) and the dyn-narrow key composed from both session keys;
    the small group carries none. Catches a slot missing a field or a
    dyn-narrow key not composed from both session keys."""
    var cfg = OptimizerConfig()
    var plan = _join(
        _pq("big.parquet", rows=10),
        _pq("small.parquet", Optional(_gt("x", 1)), Optional(_l1("f")), 5),
    )
    var sp = plan_scan_shares(plan, cfg)
    assert_equal(_paths(sp), "big.parquet,small.parquet")
    ref big = sp.groups[0]
    assert_true(Bool(big.hoist))
    ref h = big.hoist.value()
    assert_equal(h.small_path, "small.parquet")
    assert_equal(h.small_join_col, "k")
    assert_equal(h.large_join_col, "k")
    assert_equal(len(h.small_proj.value()), 3)
    assert_equal(h.small_proj.value()[0], "f")
    assert_equal(h.small_proj.value()[1], "k")
    assert_equal(h.small_proj.value()[2], "x")
    assert_true(Bool(h.small_filter))
    var small_sess = _session_cache_key(
        "small.parquet", Optional(_gt("x", 1)), h.small_proj.value().copy()
    )
    assert_equal(h.small_sess_key, small_sess)
    assert_equal(big.dyn_narrow_key, _dyn_narrow_cache_key(big.sess_key, small_sess))
    assert_false(Bool(sp.groups[1].hoist))
    assert_equal(sp.groups[1].dyn_narrow_key, "")


def test_session_memo_off_declines_the_cross_call_bet_only() raises:
    """`session_memo=False` drops multi-table singletons, keeps a singleton
    with a hoist match, and leaves a within-plan duplicate alone. Catches the
    hoist exemption dropped (the large side would lose its dynamic-filter
    slot) or within-plan dedup switched off with the memo."""
    var cfg = OptimizerConfig()
    var two = _join(_pq("a.parquet", rows=10), _pq("b.parquet", rows=10))
    assert_equal(_shares(two, cfg), "a.parquet,b.parquet")
    assert_equal(_paths(plan_scan_shares(two, cfg, session_memo=False)), "")
    var hoist = _join(
        _pq("big.parquet", rows=10),
        _pq("small.parquet", Optional(_gt("x", 1)), rows=5),
    )
    assert_equal(
        _paths(plan_scan_shares(hoist, cfg, session_memo=False)), "big.parquet"
    )
    var dup_plus = _join(_dup_join(10), _pq("c.parquet", rows=10))
    assert_equal(
        _paths(plan_scan_shares(dup_plus, cfg, session_memo=False)), "a.parquet"
    )
    assert_equal(_shares(dup_plus, cfg), "a.parquet,c.parquet")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

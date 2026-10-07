# =============================================================================
# optimizer_scan_share: the plan walks and the scan-shape helpers
# =============================================================================
#
# `plan_scan_shares` decides from nine recursive plan walks that must all reach
# the same scans through the same node kinds. A walk that misses one kind
# makes a scan under that kind invisible to one gate and visible to the next,
# and the decision silently changes. Each walk is driven (here, or in
# test_optimizer_scan_share_hoist for the hoist and fact-stream walks) through every
# node kind it recurses into (Filter, Project, Aggregate, Sort, Limit, Distinct,
# TopN, PartitionBy, both sides of a Join) and through a kind it does not
# (Union), plus the non-Parquet and no-match leaves. Each test names the
# defect it catches.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.agg_expr import AggExpr, AGG_SUM
from komira_plan_expr.expr import Expr, BIN_GT
from komira_plan_expr.partition_expr import PartitionExpr
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    AggExprArray,
    ExprArray,
    LogicalPlan,
    JOIN_INNER,
    SOURCE_IN_MEMORY,
    SOURCE_PARQUET,
)
from komira_optimizer.optimizer_scan_share import (
    ScanSharePlan,
    ScanShareGroup,
    _collect_scan_keys,
    _collect_union_projection,
    _count_plan_joins,
    _extract_scan_metadata,
    _join_key_is_int64,
    _lookup_first_filter,
    _lookup_first_path,
    _lookup_row_count,
    _scan_consumer_is_aggregate_only,
    _scan_field_is_int64,
    _scan_key,
    _scan_matching_key_is_filtered,
    _scan_raw_row_count,
    _unwrap_to_scan,
)
from komira_collections.slab import Slab


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


def _mem(name: String) -> LogicalPlan:
    return LogicalPlan.scan(name, SOURCE_IN_MEMORY, _schema())


def _l1(s: String) -> List[String]:
    var out = List[String]()
    out.append(s)
    return out^


def _join(var l: LogicalPlan, var r: LogicalPlan) -> LogicalPlan:
    return LogicalPlan.join(l^, r^, _l1("k"), _l1("k"), JOIN_INNER)


def _union(var a: LogicalPlan, var b: LogicalPlan) -> LogicalPlan:
    var schema = a.output_schema.copy()
    var kids = List[OwnedPointer[LogicalPlan]]()
    kids.append(OwnedPointer(a^))
    kids.append(OwnedPointer(b^))
    return LogicalPlan.union(kids^, schema^)


comptime N_KINDS = 8
"""Wrapper kinds: 0 Filter, 1 Project, 2 Aggregate, 3 Sort, 4 Limit,
5 Distinct, 6 TopN, 7 PartitionBy."""


def _wrap(kind: Int, var child: LogicalPlan) raises -> LogicalPlan:
    """`child` under one node of the given kind (schema-preserving except the
    Aggregate, which groups by `k`)."""
    if kind == 0:
        return LogicalPlan.filter(_gt("k", 0), child^)
    if kind == 1:
        var ex = ExprArray()
        ex.append(Expr.col_ref("k"))
        ex.append(Expr.col_ref("x"))
        ex.append(Expr.col_ref("f"))
        return LogicalPlan.project(ex^, child^)
    if kind == 2:
        var gb = ExprArray()
        gb.append(Expr.col_ref("k"))
        var aggs = AggExprArray()
        var c: Optional[Expr] = Optional(Expr.col_ref("x"))
        aggs.append(AggExpr(AGG_SUM, c^, Optional(String("s"))))
        return LogicalPlan.aggregate(gb^, aggs^, child^)
    if kind == 3:
        var d = List[Bool]()
        d.append(False)
        return LogicalPlan.sort(_l1("k"), d^, child^)
    if kind == 4:
        return LogicalPlan.limit(5, child^)
    if kind == 5:
        var nc: Optional[List[String]] = None
        return LogicalPlan.distinct(nc^, child^)
    if kind == 6:
        var d = List[Bool]()
        d.append(False)
        return LogicalPlan.topn(_l1("k"), d^, 3, child^)
    var d = List[Bool]()
    d.append(False)
    return LogicalPlan.partition_by(
        List[String](), _l1("k"), d^, List[PartitionExpr](), child^
    )


def _key(path: String) -> String:
    var none: Optional[Expr] = None
    return _scan_key(path, none^)


def _fkey(path: String, var f: Expr) -> String:
    return _scan_key(path, Optional[Expr](f^))


# -----------------------------------------------------------------------------
# scan-shape helpers
# -----------------------------------------------------------------------------


def test_unwrap_to_scan_classifies_every_leaf() raises:
    """1 = unfiltered Parquet, 2 = filtered Parquet, None = not Parquet or not
    a scan; a Project is looked through. Catches the hoist admitting an
    in-memory source or missing a scan under a column-narrowing Project."""
    var u = _unwrap_to_scan(_pq("a.parquet"))
    assert_equal(u.value(), 1)
    var f = _unwrap_to_scan(_pq("a.parquet", Optional(_gt("x", 1))))
    assert_equal(f.value(), 2)
    assert_false(Bool(_unwrap_to_scan(_mem("m"))))
    var p = _unwrap_to_scan(_wrap(1, _pq("a.parquet")))
    assert_equal(p.value(), 1)
    assert_false(Bool(_unwrap_to_scan(_wrap(0, _pq("a.parquet")))))


def test_scan_raw_row_count_reads_the_footer_count() raises:
    """Present, absent, through a Project, and None for any other node.
    Catches the both-filtered tiebreak reading a count off the wrong node."""
    assert_equal(_scan_raw_row_count(_pq("a.parquet", rows=7)).value(), 7)
    assert_false(Bool(_scan_raw_row_count(_pq("a.parquet"))))
    assert_equal(
        _scan_raw_row_count(_wrap(1, _pq("a.parquet", rows=9))).value(), 9
    )
    assert_false(Bool(_scan_raw_row_count(_wrap(4, _pq("a.parquet", rows=9)))))


def test_extract_scan_metadata_both_arms() raises:
    """Direct scan and Project(scan), each with and without filter, projection
    and schema. Catches a snapshot that drops the filter or the projection the
    hoist later uses as the small side's read."""
    var full = _extract_scan_metadata(
        _pq("a.parquet", Optional(_gt("x", 1)), Optional(_l1("k")))
    )
    assert_equal(full.path.value(), "a.parquet")
    assert_true(Bool(full.filter))
    assert_equal(full.projection.value()[0], "k")
    assert_true(Bool(full.schema))

    var bare = _pq("b.parquet")
    bare._scan.value()[].schema = None
    var m = _extract_scan_metadata(bare)
    assert_equal(m.path.value(), "b.parquet")
    assert_false(Bool(m.filter))
    assert_false(Bool(m.projection))
    assert_false(Bool(m.schema))

    var pfull = _extract_scan_metadata(
        _wrap(1, _pq("c.parquet", Optional(_gt("x", 1)), Optional(_l1("k"))))
    )
    assert_equal(pfull.path.value(), "c.parquet")
    assert_true(Bool(pfull.filter))
    assert_true(Bool(pfull.projection))
    assert_true(Bool(pfull.schema))

    var inner = _pq("d.parquet")
    inner._scan.value()[].schema = None
    var pm = _extract_scan_metadata(_wrap(1, inner^))
    assert_equal(pm.path.value(), "d.parquet")
    assert_false(Bool(pm.filter))
    assert_false(Bool(pm.projection))
    assert_false(Bool(pm.schema))


def test_int64_key_checks() raises:
    """`_scan_field_is_int64` and `_join_key_is_int64`: INT64 column, non-INT64
    column, missing column, missing schema. Catches the dynamic filter (an
    INT64-only builder) being planned over a column of another type."""
    var s: Optional[Schema] = Optional(_schema())
    assert_true(_scan_field_is_int64(s, "k"))
    assert_false(_scan_field_is_int64(s, "f"))
    assert_false(_scan_field_is_int64(s, "nope"))
    var none: Optional[Schema] = None
    assert_false(_scan_field_is_int64(none, "k"))

    var p = _pq("a.parquet")
    assert_true(_join_key_is_int64(p._scan.value()[], "k"))
    assert_false(_join_key_is_int64(p._scan.value()[], "f"))
    assert_false(_join_key_is_int64(p._scan.value()[], "nope"))
    p._scan.value()[].schema = None
    assert_false(_join_key_is_int64(p._scan.value()[], "k"))


def test_scan_key_includes_the_filter_fingerprint() raises:
    """Same path, different filter = different key; no filter = path plus an
    empty fingerprint. Catches two differently filtered scans of one file
    sharing one read (a wrong answer)."""
    var a = _key("a.parquet")
    var b = _fkey("a.parquet", _gt("x", 1))
    var c = _fkey("a.parquet", _gt("x", 2))
    assert_true(a != b)
    assert_true(b != c)
    assert_equal(a, String("a.parquet") + "\0\0\0")
    assert_equal(ScanSharePlan(Slab[ScanShareGroup]()).len(), 0)


# -----------------------------------------------------------------------------
# the walks, through every node kind
# -----------------------------------------------------------------------------


def test_key_and_lookup_walks_reach_through_every_kind() raises:
    """`_collect_scan_keys`, `_lookup_first_path`, `_lookup_row_count`,
    `_lookup_first_filter` and `_collect_union_projection` find a filtered,
    projected scan under each kind. Catches a kind dropped from one walk: its
    scans would be keyed but never found (or found but never keyed)."""
    for kind in range(N_KINDS):
        var plan = _wrap(
            kind, _pq("a.parquet", Optional(_gt("x", 1)), Optional(_l1("k")), 11)
        )
        var keys = List[String]()
        _collect_scan_keys(plan, keys)
        assert_equal(len(keys), 1, "keys, kind " + String(kind))
        var k = keys[0]
        assert_equal(_lookup_first_path(plan, k).value(), "a.parquet")
        assert_equal(_lookup_row_count(plan, k).value(), 11)
        assert_true(Bool(_lookup_first_filter(plan, k)))
        var up = _collect_union_projection(plan, k)
        assert_equal(len(up.value()), 1)


def test_lookups_search_the_right_join_side() raises:
    """With the target only on the right of a Join the lookups fall through
    the left side's None. Catches a lookup that stops at the left child."""
    var plan = _join(_pq("l.parquet", rows=1), _pq("r.parquet", rows=2))
    var k = _key("r.parquet")
    assert_equal(_lookup_first_path(plan, k).value(), "r.parquet")
    assert_equal(_lookup_row_count(plan, k).value(), 2)
    var keys = List[String]()
    _collect_scan_keys(plan, keys)
    assert_equal(len(keys), 2)
    # Left side found first.
    var kl = _key("l.parquet")
    assert_equal(_lookup_first_path(plan, kl).value(), "l.parquet")
    assert_equal(_lookup_row_count(plan, kl).value(), 1)
    # Filter lookups on both sides.
    var fplan = _join(
        _pq("l.parquet", Optional(_gt("x", 1))),
        _pq("r.parquet", Optional(_gt("x", 2))),
    )
    assert_true(Bool(_lookup_first_filter(fplan, _fkey("l.parquet", _gt("x", 1)))))
    assert_true(Bool(_lookup_first_filter(fplan, _fkey("r.parquet", _gt("x", 2)))))


def test_lookups_miss_on_unwalked_kinds_and_non_parquet() raises:
    """A Union is not walked, an in-memory scan has no key, a key that matches
    nothing finds nothing, and a matched scan without a row count or filter
    answers None. Catches a walk inventing a path, count or filter."""
    var u = _union(_pq("a.parquet", rows=3), _pq("a.parquet", rows=3))
    var k = _key("a.parquet")
    var keys = List[String]()
    _collect_scan_keys(u, keys)
    assert_equal(len(keys), 0)
    assert_false(Bool(_lookup_first_path(u, k)))
    assert_false(Bool(_lookup_row_count(u, k)))
    assert_false(Bool(_lookup_first_filter(u, k)))
    assert_false(Bool(_collect_union_projection(u, k)))

    var m = _mem("m")
    _collect_scan_keys(m, keys)
    assert_equal(len(keys), 0)
    assert_false(Bool(_lookup_first_path(m, k)))
    assert_false(Bool(_lookup_row_count(m, k)))
    assert_false(Bool(_lookup_first_filter(m, k)))

    var other = _pq("b.parquet", rows=3)
    assert_false(Bool(_lookup_first_path(other, k)))
    assert_false(Bool(_lookup_row_count(other, k)))
    assert_false(Bool(_lookup_first_filter(other, k)))

    var plain = _pq("a.parquet")
    assert_false(Bool(_lookup_row_count(plain, k)))
    assert_false(Bool(_lookup_first_filter(plain, k)))


def test_union_projection_rules() raises:
    """Union of the projections of every duplicate (each column once); None
    when any duplicate reads all columns or nothing matches. Catches a shared
    read missing a column one consumer needs."""
    var both_proj = _join(
        _pq("a.parquet", proj=Optional(_l1("k"))),
        _pq("a.parquet", proj=Optional(_l1("x"))),
    )
    var k = _key("a.parquet")
    var up = _collect_union_projection(both_proj, k)
    assert_equal(len(up.value()), 2)
    assert_equal(up.value()[0], "k")
    assert_equal(up.value()[1], "x")

    var same = _join(
        _pq("a.parquet", proj=Optional(_l1("k"))),
        _pq("a.parquet", proj=Optional(_l1("k"))),
    )
    assert_equal(len(_collect_union_projection(same, k).value()), 1)

    var one_all = _join(_pq("a.parquet", proj=Optional(_l1("k"))), _pq("a.parquet"))
    assert_false(Bool(_collect_union_projection(one_all, k)))
    assert_false(Bool(_collect_union_projection(_pq("b.parquet"), k)))


def test_count_plan_joins_through_every_kind() raises:
    """One join under each kind counts 1, nested joins add, a Union is not
    walked. Catches a kind that hides a join from the count."""
    for kind in range(N_KINDS):
        var plan = _wrap(kind, _join(_pq("a.parquet"), _pq("b.parquet")))
        assert_equal(_count_plan_joins(plan), 1, "kind " + String(kind))
    var nested = _join(_join(_pq("a.parquet"), _pq("b.parquet")), _pq("c.parquet"))
    assert_equal(_count_plan_joins(nested), 2)
    var right_nested = _join(_pq("c.parquet"), _join(_pq("a.parquet"), _pq("b.parquet")))
    assert_equal(_count_plan_joins(right_nested), 2)
    assert_equal(
        _count_plan_joins(_union(_join(_pq("a.parquet"), _pq("b.parquet")), _pq("c.parquet"))),
        0,
    )


def test_aggregate_only_consumer_walk() raises:
    """A scan whose nearest non-Filter/Project ancestor is an Aggregate is
    agg-only; a Join, Sort, Limit, Distinct, TopN or PartitionBy in between
    resets it; no match is False; one non-agg duplicate makes it False.
    Catches the agg-only gates firing on a scan a join also reads."""
    var k = _key("a.parquet")
    assert_true(_scan_consumer_is_aggregate_only(_wrap(2, _pq("a.parquet")), k))
    # Filter and Project are transparent under the Aggregate.
    assert_true(
        _scan_consumer_is_aggregate_only(_wrap(2, _wrap(0, _pq("a.parquet"))), k)
    )
    assert_true(
        _scan_consumer_is_aggregate_only(_wrap(2, _wrap(1, _pq("a.parquet"))), k)
    )
    # Every other kind between the Aggregate and the scan resets the flag.
    for kind in range(3, N_KINDS):
        assert_false(
            _scan_consumer_is_aggregate_only(
                _wrap(2, _wrap(kind, _pq("a.parquet"))), k
            ),
            "kind " + String(kind),
        )
    assert_false(
        _scan_consumer_is_aggregate_only(
            _wrap(2, _join(_pq("a.parquet"), _pq("b.parquet"))), k
        )
    )
    assert_false(
        _scan_consumer_is_aggregate_only(
            _wrap(2, _join(_pq("b.parquet"), _pq("a.parquet"))), k
        )
    )
    # No aggregate at all.
    assert_false(_scan_consumer_is_aggregate_only(_pq("a.parquet"), k))
    # No match (another file, an in-memory source, a Union).
    assert_false(_scan_consumer_is_aggregate_only(_wrap(2, _pq("b.parquet")), k))
    assert_false(_scan_consumer_is_aggregate_only(_wrap(2, _mem("m")), k))
    assert_false(
        _scan_consumer_is_aggregate_only(
            _wrap(2, _union(_pq("a.parquet"), _pq("a.parquet"))), k
        )
    )
    # A filtered scan keys with its filter.
    assert_true(
        _scan_consumer_is_aggregate_only(
            _wrap(2, _pq("a.parquet", Optional(_gt("x", 1)))),
            _fkey("a.parquet", _gt("x", 1)),
        )
    )
    # Two matches, one under the Aggregate and one under a Join: not agg-only.
    var mixed = _join(_wrap(2, _pq("a.parquet")), _pq("a.parquet"))
    assert_false(_scan_consumer_is_aggregate_only(mixed, k))


def test_filtered_state_walk() raises:
    """True for a pushed filter or a Filter ancestor; False for a bare scan;
    the walk stops at the first match. Catches FACT-STREAM rule (b) treating a
    filtered fact's raw row count as its data volume."""
    var k = _key("a.parquet")
    assert_true(_scan_matching_key_is_filtered(_wrap(0, _pq("a.parquet")), k))
    assert_true(
        _scan_matching_key_is_filtered(
            _pq("a.parquet", Optional(_gt("x", 1))),
            _fkey("a.parquet", _gt("x", 1)),
        )
    )
    for kind in range(1, N_KINDS):
        assert_false(
            _scan_matching_key_is_filtered(_wrap(kind, _pq("a.parquet")), k),
            "kind " + String(kind),
        )
        # A Filter ABOVE the kind still counts.
        assert_true(
            _scan_matching_key_is_filtered(
                _wrap(0, _wrap(kind, _pq("a.parquet"))), k
            ),
            "filter above kind " + String(kind),
        )
    # Right side of a join, and the first match wins (the second, filtered,
    # duplicate is never visited).
    assert_true(
        _scan_matching_key_is_filtered(
            _join(_pq("b.parquet"), _wrap(0, _pq("a.parquet"))), k
        )
    )
    assert_false(
        _scan_matching_key_is_filtered(
            _join(_pq("a.parquet"), _wrap(0, _pq("a.parquet"))), k
        )
    )
    assert_false(_scan_matching_key_is_filtered(_mem("m"), k))
    assert_false(_scan_matching_key_is_filtered(_pq("b.parquet"), k))
    assert_false(
        _scan_matching_key_is_filtered(
            _wrap(0, _union(_pq("a.parquet"), _pq("a.parquet"))), k
        )
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

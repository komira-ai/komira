# =============================================================================
# optimizer_scan_share: dyn-filter hoist detection, cache keys, protected keys
# =============================================================================
#
# `_detect_hoist_matches` decides which large scan's read may be narrowed by a
# small filtered relation's join keys. A wrong match either narrows a read
# that must not be narrowed (a wrong answer on an outer join) or plans a
# filter over a key the INT64-only builder cannot build. The cache-key helpers must agree with each
# other exactly, or one read gets two different keys. The two protected
# key collections decide which scans stay Parquet sources. Each test names the
# defect it catches.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_collections.slab import Slab
from komira_plan_expr.agg_expr import AggExpr, AGG_SUM
from komira_plan_expr.expr import Expr, BIN_GT, BIN_EQ
from komira_plan_expr.partition_expr import PartitionExpr
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    AggExprArray,
    ExprArray,
    LogicalPlan,
    JOIN_ANTI,
    JOIN_FULL,
    JOIN_INNER,
    JOIN_LEFT,
    JOIN_SEMI,
    SOURCE_IN_MEMORY,
    SOURCE_PARQUET,
)
from komira_optimizer.optimizer_scan_share import (
    _HoistMatch,
    _collect_fact_stream_protect_keys,
    _collect_streaming_join_protected_keys,
    _detect_hoist_matches,
    _dyn_narrow_cache_key,
    _find_hoist_match,
    _hoist_small_augmented_proj,
    _hoist_small_session_key,
    _join_child_protected_scan_key,
    _scan_key,
    _session_cache_key,
    _streamable_child_row_count,
    _streamable_join_child_key,
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


def _small(rows: Optional[Int] = None) -> LogicalPlan:
    """The small, filtered side: `small.parquet WHERE x > 1`."""
    return _pq("small.parquet", Optional(_gt("x", 1)), rows=rows)


def _big(rows: Optional[Int] = None) -> LogicalPlan:
    """The large, unfiltered side."""
    return _pq("big.parquet", rows=rows)


def _l1(s: String) -> List[String]:
    var out = List[String]()
    out.append(s)
    return out^


def _join_on(
    var l: LogicalPlan, var r: LogicalPlan, jt: UInt8, key: String = "k"
) -> LogicalPlan:
    return LogicalPlan.join(l^, r^, _l1(key), _l1(key), jt)


def _join(var l: LogicalPlan, var r: LogicalPlan) -> LogicalPlan:
    return _join_on(l^, r^, JOIN_INNER)


def _union(var a: LogicalPlan, var b: LogicalPlan) -> LogicalPlan:
    var schema = a.output_schema.copy()
    var kids = List[OwnedPointer[LogicalPlan]]()
    kids.append(OwnedPointer(a^))
    kids.append(OwnedPointer(b^))
    return LogicalPlan.union(kids^, schema^)


def _project(var child: LogicalPlan) -> LogicalPlan:
    var ex = ExprArray()
    ex.append(Expr.col_ref("k"))
    ex.append(Expr.col_ref("x"))
    ex.append(Expr.col_ref("f"))
    return LogicalPlan.project(ex^, child^)


def _wrap(kind: Int, var child: LogicalPlan) raises -> LogicalPlan:
    """0 Filter, 1 Project, 2 Aggregate, 3 Sort, 4 Limit, 5 Distinct, 6 TopN,
    7 PartitionBy."""
    if kind == 0:
        return LogicalPlan.filter(_gt("k", 0), child^)
    if kind == 1:
        return _project(child^)
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


def _matches(plan: LogicalPlan) raises -> Slab[_HoistMatch]:
    var out = Slab[_HoistMatch]()
    _detect_hoist_matches(plan, out)
    return out^


def _hm(
    var proj: Optional[List[String]], var filter: Optional[Expr]
) -> _HoistMatch:
    return _HoistMatch(
        String("L"), String("lk"), String("small.parquet"), filter^, proj^,
        String("sk"),
    )


# -----------------------------------------------------------------------------
# _detect_hoist_matches
# -----------------------------------------------------------------------------


def test_large_left_small_right_records_one_match() raises:
    """JOIN(big, small WHERE ...) on an INT64 key: ONE match, large=left. Every
    field is checked. Catches a swapped build side or a
    large key that will never equal the dedup key."""
    var m = _matches(_join(_big(), _small()))
    assert_equal(m.len(), 1)
    assert_equal(m[0].large_key, _key("big.parquet"))
    assert_equal(m[0].large_join_col, "k")
    assert_equal(m[0].small_path, "small.parquet")
    assert_true(Bool(m[0].small_filter))
    assert_false(Bool(m[0].small_proj))
    assert_equal(m[0].small_join_col, "k")


def test_small_left_large_right_records_one_match() raises:
    """The mirror shape, through the second branch; the small side's
    projection is carried. Catches the second branch reading the wrong side's
    key column."""
    var small = _pq("small.parquet", Optional(_gt("x", 1)), Optional(_l1("x")))
    var plan = LogicalPlan.join(
        small^, _big(), _l1("x"), _l1("k"), JOIN_INNER
    )
    var m = _matches(plan)
    assert_equal(m.len(), 1)
    assert_equal(m[0].large_key, _key("big.parquet"))
    assert_equal(m[0].large_join_col, "k")
    assert_equal(m[0].small_join_col, "x")
    assert_equal(m[0].small_proj.value()[0], "x")


def test_semi_is_admitted_and_unsafe_types_are_not() raises:
    """SEMI is bloom-safe both ways; LEFT, ANTI and FULL are not admitted.
    Catches a hoist narrowing the preserved side of an outer or anti join,
    which drops rows the join must emit."""
    assert_equal(_matches(_join_on(_big(), _small(), JOIN_SEMI)).len(), 1)
    assert_equal(_matches(_join_on(_small(), _big(), JOIN_SEMI)).len(), 1)
    assert_equal(_matches(_join_on(_big(), _small(), JOIN_LEFT)).len(), 0)
    assert_equal(_matches(_join_on(_small(), _big(), JOIN_ANTI)).len(), 0)
    assert_equal(_matches(_join_on(_big(), _small(), JOIN_FULL)).len(), 0)


def test_shape_refusals() raises:
    """No match for: a multi-key join, a non-INT64 key on either side's small
    scan, a self-join on one file, no filtered side, and an in-memory side.
    Each refusal is the ONLY failing condition of its case, except the
    no-filtered-side case (`big.parquet` twice, so also one file). Catches a
    filter built over the wrong type, a self-join paired with itself, and a
    hoist with no selective side."""
    var two = List[String]()
    two.append("k")
    two.append("x")
    var multi = LogicalPlan.join(_big(), _small(), two.copy(), two.copy(), JOIN_INNER)
    assert_equal(_matches(multi).len(), 0)
    assert_equal(_matches(_join_on(_big(), _small(), JOIN_INNER, "f")).len(), 0)
    assert_equal(_matches(_join_on(_small(), _big(), JOIN_INNER, "f")).len(), 0)
    var self_l = _pq("same.parquet", Optional(_gt("x", 1)))
    var self_r = _pq("same.parquet", Optional(_gt("x", 2)))
    assert_equal(_matches(_join(self_l^, self_r^)).len(), 0)
    assert_equal(_matches(_join(_big(), _big())).len(), 0)
    var mem = LogicalPlan.scan("m", SOURCE_IN_MEMORY, _schema())
    assert_equal(_matches(_join(mem^, _small())).len(), 0)


def test_both_filtered_row_count_tiebreak() raises:
    """Both sides filtered: emit only the direction whose small side has the
    smaller raw row count; equal or unknown counts emit both. Catches a
    wrong-direction match whose build side is the bigger relation."""
    var a = _pq("a.parquet", Optional(_gt("x", 1)), rows=100)
    var b = _pq("b.parquet", Optional(_gt("x", 2)), rows=10)
    var m = _matches(_join(a^, b^))
    assert_equal(m.len(), 1)
    # b is the smaller side: it is the small one, a the large one, and the
    # large key carries a's filter.
    assert_equal(m[0].small_path, "b.parquet")
    assert_equal(m[0].large_key, _fkey("a.parquet", _gt("x", 1)))

    var a2 = _pq("a.parquet", Optional(_gt("x", 1)), rows=10)
    var b2 = _pq("b.parquet", Optional(_gt("x", 2)), rows=100)
    var m2 = _matches(_join(a2^, b2^))
    assert_equal(m2.len(), 1)
    assert_equal(m2[0].small_path, "a.parquet")

    var a3 = _pq("a.parquet", Optional(_gt("x", 1)), rows=10)
    var b3 = _pq("b.parquet", Optional(_gt("x", 2)), rows=10)
    assert_equal(_matches(_join(a3^, b3^)).len(), 2)

    var a4 = _pq("a.parquet", Optional(_gt("x", 1)), rows=10)
    var b4 = _pq("b.parquet", Optional(_gt("x", 2)))
    assert_equal(_matches(_join(a4^, b4^)).len(), 2)
    var a5 = _pq("a.parquet", Optional(_gt("x", 1)))
    var b5 = _pq("b.parquet", Optional(_gt("x", 2)), rows=10)
    assert_equal(_matches(_join(a5^, b5^)).len(), 2)


def test_project_over_scan_is_looked_through() raises:
    """JOIN(PROJECT(big), PROJECT(small)) still matches. Catches a hoist lost
    whenever projection pushdown leaves a Project above a scan."""
    assert_equal(_matches(_join(_project(_big()), _project(_small()))).len(), 1)
    assert_equal(_matches(_join(_project(_small()), _project(_big()))).len(), 1)


def test_detect_recurses_through_every_kind() raises:
    """A matching join under each wrapper kind, under either side of an outer
    join, and nothing under a Union. Catches a kind that hides a q17-shape
    join from the hoist."""
    for kind in range(8):
        var plan = _wrap(kind, _join(_big(), _small()))
        assert_equal(_matches(plan).len(), 1, "kind " + String(kind))
    var outer_l = _join_on(_join(_big(), _small()), _pq("c.parquet"), JOIN_FULL)
    assert_equal(_matches(outer_l).len(), 1)
    var outer_r = _join_on(_pq("c.parquet"), _join(_big(), _small()), JOIN_FULL)
    assert_equal(_matches(outer_r).len(), 1)
    assert_equal(_matches(_union(_join(_big(), _small()), _big())).len(), 0)


# -----------------------------------------------------------------------------
# hoist lookups and cache keys
# -----------------------------------------------------------------------------


def test_find_hoist_match() raises:
    """Index of the first match by large key, -1 when absent. Catches a fact
    scan wrongly treated as (or not as) a hoist target."""
    var m = _matches(_join(_big(), _small()))
    assert_equal(_find_hoist_match(m, _key("big.parquet")), 0)
    assert_equal(_find_hoist_match(m, _key("small.parquet")), -1)
    assert_equal(_find_hoist_match(Slab[_HoistMatch](), _key("big.parquet")), -1)


def test_small_side_projection_augmentation() raises:
    """The small side's read projection gains the join key when absent (not
    twice when present) and every filter column it lacks; with no projection
    it is just the key plus the filter's columns. Catches a small read that
    cannot evaluate its own filter or produce the key column."""
    var lacking = _hoist_small_augmented_proj(
        _hm(Optional(_l1("a")), Optional(_gt("z", 1)))
    )
    assert_equal(len(lacking.value()), 3)
    assert_equal(lacking.value()[0], "a")
    assert_equal(lacking.value()[1], "sk")
    assert_equal(lacking.value()[2], "z")

    var has_both = List[String]()
    has_both.append("sk")
    has_both.append("z")
    var present = _hoist_small_augmented_proj(
        _hm(Optional(has_both^), Optional(_gt("z", 1)))
    )
    assert_equal(len(present.value()), 2)

    var none_proj: Optional[List[String]] = None
    var none_filter: Optional[Expr] = None
    var bare = _hoist_small_augmented_proj(_hm(none_proj^, none_filter^))
    assert_equal(len(bare.value()), 1)
    assert_equal(bare.value()[0], "sk")


def test_session_cache_key_shape() raises:
    """Path, filter fingerprint and SORTED projection (or "*"), triple-NUL
    separated. Catches two projections of one column set that differ only in
    order getting different keys, and a projected and unprojected read
    colliding."""
    var p1 = List[String]()
    p1.append("c")
    p1.append("a")
    p1.append("b")
    var none: Optional[Expr] = None
    var k1 = _session_cache_key("p", none, Optional(p1^))
    assert_equal(k1, String("p") + "\0\0\0" + "" + "\0\0\0" + "a,b,c")
    var p2 = List[String]()
    p2.append("b")
    p2.append("c")
    p2.append("a")
    assert_equal(_session_cache_key("p", none, Optional(p2^)), k1)
    var no_proj: Optional[List[String]] = None
    var star = _session_cache_key("p", none, no_proj)
    assert_equal(star, String("p") + "\0\0\0" + "" + "\0\0\0" + "*")
    var filtered = _session_cache_key("p", Optional(_gt("x", 1)), no_proj)
    assert_true(filtered != star)


def test_small_session_key_matches_the_augmented_read() raises:
    """The small side's session key is `_session_cache_key` over the AUGMENTED
    projection, with and without a filter, and pins the
    `_dyn_narrow_cache_key` format. Catches `_hoist_small_session_key` keying
    a projection other than the one `ScanShareHoist.small_proj` carries."""
    var hm = _hm(Optional(_l1("a")), Optional(_gt("z", 1)))
    var want = _session_cache_key(
        "small.parquet",
        Optional(_gt("z", 1)),
        _hoist_small_augmented_proj(hm),
    )
    assert_equal(_hoist_small_session_key(hm), want)
    var no_filter: Optional[Expr] = None
    var hm2 = _hm(Optional(_l1("a")), None)
    var want2 = _session_cache_key(
        "small.parquet", no_filter, _hoist_small_augmented_proj(hm2)
    )
    assert_equal(_hoist_small_session_key(hm2), want2)
    assert_equal(
        _dyn_narrow_cache_key("L", "S"),
        String("L") + "\0\0\0" + "DYN:" + "\0\0\0" + "S",
    )


# -----------------------------------------------------------------------------
# protected keys
# -----------------------------------------------------------------------------


def test_streaming_join_child_key() raises:
    """Only an unfiltered Parquet scan (directly or under a Project) with an
    INT64 key yields a key. Catches the (unused) collection keying a filtered
    or non-Parquet child."""
    var k = _join_child_protected_scan_key(_big(), "k")
    assert_equal(k.value(), _key("big.parquet"))
    assert_equal(
        _join_child_protected_scan_key(_project(_big()), "k").value(),
        _key("big.parquet"),
    )
    assert_false(Bool(_join_child_protected_scan_key(_small(), "k")))
    assert_false(Bool(_join_child_protected_scan_key(_big(), "f")))
    var mem = LogicalPlan.scan("m", SOURCE_IN_MEMORY, _schema())
    assert_false(Bool(_join_child_protected_scan_key(mem, "k")))


def test_streaming_join_protected_keys() raises:
    """INNER, SEMI, LEFT and ANTI single-key joins with no residual and two
    eligible children contribute both keys; FULL, multi-key, a residual or one
    ineligible child contribute none; every wrapper kind is walked. Catches a
    join type or gate dropped from the collection."""
    for jt in [JOIN_INNER, JOIN_SEMI, JOIN_LEFT, JOIN_ANTI]:
        var out = List[String]()
        _collect_streaming_join_protected_keys(
            _join_on(_big(), _pq("b2.parquet"), jt), out
        )
        assert_equal(len(out), 2)
    var none_out = List[String]()
    _collect_streaming_join_protected_keys(
        _join_on(_big(), _pq("b2.parquet"), JOIN_FULL), none_out
    )
    var two = List[String]()
    two.append("k")
    two.append("x")
    _collect_streaming_join_protected_keys(
        LogicalPlan.join(_big(), _pq("b2.parquet"), two.copy(), two.copy(), JOIN_INNER),
        none_out,
    )
    var resid = Optional[OwnedPointer[Expr]](OwnedPointer(_gt("x", 3)))
    _collect_streaming_join_protected_keys(
        LogicalPlan.join(
            _big(), _pq("b2.parquet"), _l1("k"), _l1("k"), JOIN_INNER,
            residual=resid^,
        ),
        none_out,
    )
    _collect_streaming_join_protected_keys(_join(_big(), _small()), none_out)
    _collect_streaming_join_protected_keys(_join(_small(), _big()), none_out)
    assert_equal(len(none_out), 0)
    for kind in range(8):
        var out = List[String]()
        _collect_streaming_join_protected_keys(
            _wrap(kind, _join(_big(), _pq("b2.parquet"))), out
        )
        assert_equal(len(out), 2, "kind " + String(kind))
    var nested = List[String]()
    _collect_streaming_join_protected_keys(
        _join_on(_pq("c.parquet"), _join(_big(), _pq("b2.parquet")), JOIN_FULL),
        nested,
    )
    assert_equal(len(nested), 2)
    var unioned = List[String]()
    _collect_streaming_join_protected_keys(
        _union(_join(_big(), _pq("b2.parquet")), _big()), unioned
    )
    assert_equal(len(unioned), 0)


def test_streamable_child_key_and_row_count() raises:
    """Project? -> Filter? -> Parquet scan with an INT64 key yields the scan's
    own key (with its pushed filter) and its raw row count; an in-memory scan,
    a non-INT64 key or another node kind yields None. Catches a FILTER-node
    child (q9's part) left unseen by FACT-STREAM rule (a)."""
    var chain = _project(LogicalPlan.filter(_gt("k", 0), _big(100)))
    assert_equal(_streamable_join_child_key(chain, "k").value(), _key("big.parquet"))
    assert_equal(_streamable_child_row_count(chain).value(), 100)
    assert_equal(
        _streamable_join_child_key(_small(5), "k").value(),
        _fkey("small.parquet", _gt("x", 1)),
    )
    assert_false(Bool(_streamable_join_child_key(_big(), "f")))
    var mem = LogicalPlan.scan("m", SOURCE_IN_MEMORY, _schema())
    assert_false(Bool(_streamable_join_child_key(mem, "k")))
    assert_false(Bool(_streamable_join_child_key(_wrap(4, _big()), "k")))
    assert_false(Bool(_streamable_child_row_count(_big())))
    assert_false(Bool(_streamable_child_row_count(_wrap(4, _big(9)))))


def _fact_keys(
    plan: LogicalPlan, hoist: Slab[_HoistMatch], t: Int
) raises -> Int:
    var out = List[String]()
    _collect_fact_stream_protect_keys(plan, hoist, t, out)
    return len(out)


def test_fact_stream_protect_keys() raises:
    """Both children of an eligible streaming join with one child's raw count
    above the threshold, unless a child is a hoist large key; never for FULL,
    multi-key, residual, or a non-streamable child; every kind is walked.
    Catches rule (a) protecting a hoist-narrowed fact (a regression) or
    missing a large fact on either side."""
    var none = Slab[_HoistMatch]()
    # Large on the left, then on the right; strictly above the threshold.
    assert_equal(_fact_keys(_join(_big(100), _pq("b2.parquet", rows=5)), none, 50), 2)
    assert_equal(_fact_keys(_join(_pq("b2.parquet", rows=5), _big(100)), none, 50), 2)
    assert_equal(_fact_keys(_join(_big(100), _pq("b2.parquet", rows=5)), none, 100), 0)
    assert_equal(_fact_keys(_join(_big(), _pq("b2.parquet")), none, 1), 0)
    for jt in [JOIN_SEMI, JOIN_LEFT, JOIN_ANTI]:
        assert_equal(
            _fact_keys(_join_on(_big(100), _pq("b2.parquet"), jt), none, 50), 2
        )
    assert_equal(
        _fact_keys(_join_on(_big(100), _pq("b2.parquet"), JOIN_FULL), none, 50), 0
    )
    var two = List[String]()
    two.append("k")
    two.append("x")
    assert_equal(
        _fact_keys(
            LogicalPlan.join(_big(100), _pq("b2.parquet"), two.copy(), two.copy(), JOIN_INNER),
            none, 50,
        ),
        0,
    )
    var resid = Optional[OwnedPointer[Expr]](OwnedPointer(_gt("x", 3)))
    assert_equal(
        _fact_keys(
            LogicalPlan.join(
                _big(100), _pq("b2.parquet"), _l1("k"), _l1("k"), JOIN_INNER,
                residual=resid^,
            ),
            none, 50,
        ),
        0,
    )
    # A non-streamable child on either side.
    assert_equal(_fact_keys(_join(_wrap(2, _big(100)), _pq("b2.parquet")), none, 50), 0)
    assert_equal(_fact_keys(_join(_big(100), _wrap(2, _pq("b2.parquet"))), none, 50), 0)
    # Hoist exclusion, by either child's key.
    var hl = Slab[_HoistMatch]()
    hl.append(_HoistMatch(_key("big.parquet"), String("k"), String("s"), None, None, String("k")))
    assert_equal(_fact_keys(_join(_big(100), _pq("b2.parquet")), hl, 50), 0)
    var hr = Slab[_HoistMatch]()
    hr.append(_HoistMatch(_key("b2.parquet"), String("k"), String("s"), None, None, String("k")))
    assert_equal(_fact_keys(_join(_big(100), _pq("b2.parquet")), hr, 50), 0)
    # Every wrapper kind, both sides of an outer join, not a Union.
    for kind in range(8):
        assert_equal(
            _fact_keys(_wrap(kind, _join(_big(100), _pq("b2.parquet"))), none, 50),
            2,
            "kind " + String(kind),
        )
    assert_equal(
        _fact_keys(
            _join_on(_pq("c.parquet"), _join(_big(100), _pq("b2.parquet")), JOIN_FULL),
            none, 50,
        ),
        2,
    )
    assert_equal(
        _fact_keys(_union(_join(_big(100), _pq("b2.parquet")), _big()), none, 50), 0
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

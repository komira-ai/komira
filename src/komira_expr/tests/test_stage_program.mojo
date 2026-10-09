# =============================================================================
# Unit tests for the Stage[Program] IR markers (stage_program.mojo)
# =============================================================================
#
# What each group proves:
#   - tags: the BREAKER_* / JOIN_* constants hold the numbers the module
#     header documents, and the thirteen breaker tags are pairwise distinct
#     (a duplicated tag would send two breaker kinds down one Stage arm).
#   - accessor rows: every BreakerLike conformer answers all nine accessors,
#     with its own parameters where it carries them and -1 elsewhere (the
#     table in the BreakerLike docstring, extended with the struct docstrings
#     of the later arms). Each spec is instantiated with parameter values
#     used by no other slot, so an accessor returning the wrong parameter, or
#     a -1 row returning a parameter, reads as a wrong number.
#   - sentinels: NoFilter keeps every row and lane; NoProjects and
#     ProjectListStub refuse a projected emit with their documented message;
#     make_default and the discriminators return the documented values.
#   - PredicateFilter: keep_row / keep_simd forward to the wrapped
#     ExprXBool's scalar and SIMD evaluators, and bind reaches the wrapped
#     predicate (proved by the column the predicate reads after bind).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.batch_view import BatchView, batch_view_over
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, Schema
from komira_plan_expr.expr import Expr
from komira_udf.column_resolver import ColumnResolver
from komira_expr.expr_x import ExprXBool
from komira_expr.stage_program import (
    BREAKER_NONE,
    BREAKER_HASH_AGG,
    BREAKER_SORT,
    BREAKER_TOPN,
    BREAKER_WINDOW,
    BREAKER_JOIN_PROBE,
    BREAKER_DISTINCT,
    BREAKER_PARTITION_TOPN,
    BREAKER_ASOF_JOIN,
    BREAKER_JOIN_BUILD,
    BREAKER_ASOF_JOIN_BUILD,
    BREAKER_PARTITION_UDF,
    BREAKER_WINDOW_UDF,
    JOIN_INNER,
    JOIN_LEFT,
    JOIN_RIGHT,
    JOIN_SEMI,
    JOIN_ANTI,
    JOIN_OUTER,
    BreakerLike,
    FilterLike,
    ProjectsLike,
    NoFilter,
    NoProjects,
    NoBreaker,
    PredicateFilter,
    predicate_filter,
    HashAggSpec,
    SortSpec,
    TopNSpec,
    WindowSpec,
    PartitionUdfSpec,
    WindowUdfSpec,
    JoinProbeSpec,
    DistinctSpec,
    PartitionTopNSpec,
    AsofJoinSpec,
    JoinBuildSpec,
    AsofJoinBuildSpec,
    ProjectListStub,
    StageProgram,
)


# =============================================================================
# Fixtures
# =============================================================================


def _batch_ab() raises -> RecordBatch:
    """Two Int64 columns: a = [0, 1, ..., 7], b = [70, 60, ..., 0]."""
    var va = List[Scalar[DType.int64]]()
    var vb = List[Scalar[DType.int64]]()
    for i in range(8):
        va.append(Scalar[DType.int64](Int64(i)))
        vb.append(Scalar[DType.int64](Int64(70 - 10 * i)))
    var schema = Schema.from_fields_2(
        Field("a", DType.int64, False), Field("b", DType.int64, False)
    )
    return RecordBatch.from_typed_columns_2(
        schema^,
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(va^)
        ),
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(vb^)
        ),
    )


struct GtNamed[name: StringLiteral, t: Int](ExprXBool):
    """`<name> > t` over an Int64 column found by name at bind.

    `_idx` starts at 0 (column `a`), not -1, so a bind that never reaches
    the predicate reads the wrong column and fails an assertion instead of
    faulting."""

    var _idx: Int

    def __init__(out self):
        self._idx = 0

    def bind(mut self, resolver: ColumnResolver) raises:
        self._idx = resolver.index_for(String(Self.name))

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.bool, W]:
        return batch.col_i64(self._idx).load[W](i).gt(
            SIMD[DType.int64, W](Int64(Self.t))
        )

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Bool:
        return batch.col_i64(self._idx).load[1](i)[0] > Int64(Self.t)

    @staticmethod
    def depth() -> Int:
        return 1

    @staticmethod
    def to_expr() raises -> Expr:
        raise Error(String("GtNamed.to_expr: not needed"))


struct ConstBool[v: Bool](ExprXBool):
    """A constant predicate that keeps the trait's default (no-op) bind."""

    def __init__(out self):
        pass

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.bool, W]:
        return SIMD[DType.bool, W](fill=Self.v)

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Bool:
        return Self.v

    @staticmethod
    def depth() -> Int:
        return 1

    @staticmethod
    def to_expr() raises -> Expr:
        raise Error(String("ConstBool.to_expr: not needed"))


def _row[B: BreakerLike]() -> List[Int]:
    """The nine BreakerLike accessors of `B`, in the docstring table's
    column order: tag, n_keys, n_aggs, n_sort_keys, topn_n, n_part_keys,
    n_window_fns, n_probe_keys, join_t."""
    var r = List[Int]()
    r.append(B.tag())
    r.append(B.n_keys_static())
    r.append(B.n_aggs_static())
    r.append(B.n_sort_keys_static())
    r.append(B.topn_n_static())
    r.append(B.n_part_keys_static())
    r.append(B.n_window_fns_static())
    r.append(B.n_probe_keys_static())
    r.append(B.join_t_static())
    return r^


def _expect_row(
    got: List[Int],
    tag: Int,
    n_keys: Int,
    n_aggs: Int,
    n_sort_keys: Int,
    topn_n: Int,
    n_part_keys: Int,
    n_window_fns: Int,
    n_probe_keys: Int,
    join_t: Int,
) raises:
    assert_equal(len(got), 9)
    assert_equal(got[0], tag, "tag")
    assert_equal(got[1], n_keys, "n_keys")
    assert_equal(got[2], n_aggs, "n_aggs")
    assert_equal(got[3], n_sort_keys, "n_sort_keys")
    assert_equal(got[4], topn_n, "topn_n")
    assert_equal(got[5], n_part_keys, "n_part_keys")
    assert_equal(got[6], n_window_fns, "n_window_fns")
    assert_equal(got[7], n_probe_keys, "n_probe_keys")
    assert_equal(got[8], join_t, "join_t")


def _bind_breaker[B: BreakerLike](mut b: B) raises:
    """Runs the trait's default bind (the spec markers carry no Expr)."""
    var resolver = ColumnResolver()
    b.bind(resolver)


# =============================================================================
# Tags
# =============================================================================


def test_breaker_and_join_constants() raises:
    """The numbers the module documents; the typed path's two build arms
    sit at 9 / 10 after the query-shape arms 0..8."""
    assert_equal(BREAKER_NONE, 0)
    assert_equal(BREAKER_HASH_AGG, 1)
    assert_equal(BREAKER_SORT, 2)
    assert_equal(BREAKER_TOPN, 3)
    assert_equal(BREAKER_WINDOW, 4)
    assert_equal(BREAKER_JOIN_PROBE, 5)
    assert_equal(BREAKER_DISTINCT, 6)
    assert_equal(BREAKER_PARTITION_TOPN, 7)
    assert_equal(BREAKER_ASOF_JOIN, 8)
    assert_equal(BREAKER_JOIN_BUILD, 9)
    assert_equal(BREAKER_ASOF_JOIN_BUILD, 10)
    assert_equal(BREAKER_PARTITION_UDF, 11)
    assert_equal(BREAKER_WINDOW_UDF, 12)
    assert_equal(JOIN_INNER, 1)
    assert_equal(JOIN_LEFT, 2)
    assert_equal(JOIN_RIGHT, 3)
    assert_equal(JOIN_SEMI, 4)
    assert_equal(JOIN_ANTI, 5)
    assert_equal(JOIN_OUTER, 6)


def test_breaker_tags_pairwise_distinct() raises:
    """Each conformer's runtime tag() is distinct from every other's."""
    var tags = List[Int]()
    tags.append(NoBreaker.tag())
    tags.append(HashAggSpec[1, 1].tag())
    tags.append(SortSpec[1].tag())
    tags.append(TopNSpec[1, 1].tag())
    tags.append(WindowSpec[1, 1].tag())
    tags.append(JoinProbeSpec[1, JOIN_INNER].tag())
    tags.append(DistinctSpec[1].tag())
    tags.append(PartitionTopNSpec[1, 1, 1].tag())
    tags.append(AsofJoinSpec[1].tag())
    tags.append(JoinBuildSpec[1, 1].tag())
    tags.append(AsofJoinBuildSpec[1, 1].tag())
    tags.append(PartitionUdfSpec[1].tag())
    tags.append(WindowUdfSpec[1].tag())
    assert_equal(len(tags), 13)
    for i in range(len(tags)):
        for j in range(i + 1, len(tags)):
            assert_true(tags[i] != tags[j], String("tags ", i, " and ", j))


# =============================================================================
# Accessor rows, one per conformer
# =============================================================================


def test_no_breaker_row() raises:
    _expect_row(_row[NoBreaker](), 0, -1, -1, -1, -1, -1, -1, -1, -1)


def test_hash_agg_row() raises:
    _expect_row(_row[HashAggSpec[3, 5]](), 1, 3, 5, -1, -1, -1, -1, -1, -1)


def test_hash_agg_scalar_agg_shape_row() raises:
    """The degenerate 0-key, 1-agg scalar-agg lowering keeps n_keys 0, not
    -1: 0 is a carried value, -1 means "not carried"."""
    _expect_row(_row[HashAggSpec[0, 1]](), 1, 0, 1, -1, -1, -1, -1, -1, -1)


def test_sort_row() raises:
    _expect_row(_row[SortSpec[4]](), 2, -1, -1, 4, -1, -1, -1, -1, -1)


def test_topn_row() raises:
    _expect_row(_row[TopNSpec[2, 10]](), 3, -1, -1, 2, 10, -1, -1, -1, -1)


def test_window_row() raises:
    _expect_row(_row[WindowSpec[6, 7]](), 4, -1, -1, -1, -1, 6, 7, -1, -1)


def test_join_probe_rows() raises:
    _expect_row(
        _row[JoinProbeSpec[8, JOIN_LEFT]](), 5, -1, -1, -1, -1, -1, -1, 8, 2
    )
    _expect_row(
        _row[JoinProbeSpec[3, JOIN_OUTER]](), 5, -1, -1, -1, -1, -1, -1, 3, 6
    )


def test_distinct_row() raises:
    _expect_row(_row[DistinctSpec[9]](), 6, 9, -1, -1, -1, -1, -1, -1, -1)


def test_partition_topn_row() raises:
    _expect_row(
        _row[PartitionTopNSpec[11, 12, 13]](), 7, -1, -1, 12, 13, 11, -1, -1, -1
    )


def test_asof_join_row() raises:
    _expect_row(_row[AsofJoinSpec[1]](), 8, -1, -1, -1, -1, -1, -1, 1, -1)


def test_join_build_row() raises:
    """n_aggs carries the payload count for the build arms."""
    _expect_row(_row[JoinBuildSpec[14, 15]](), 9, 14, 15, -1, -1, -1, -1, -1, -1)


def test_asof_join_build_row() raises:
    _expect_row(
        _row[AsofJoinBuildSpec[16, 17]](), 10, 16, 17, -1, -1, -1, -1, -1, -1
    )


def test_partition_udf_row() raises:
    _expect_row(_row[PartitionUdfSpec[18]](), 11, -1, -1, -1, -1, 18, -1, -1, -1)


def test_window_udf_row() raises:
    _expect_row(_row[WindowUdfSpec[19]](), 12, -1, -1, -1, -1, 19, -1, -1, -1)


def test_breaker_default_bind_is_noop() raises:
    """The BreakerLike default bind runs on every marker and leaves the
    marker's value unchanged."""
    var nb = NoBreaker(21)
    _bind_breaker(nb)
    assert_equal(nb.sentinel, 21)
    var h = HashAggSpec[1, 1](22)
    _bind_breaker(h)
    assert_equal(h.sentinel, 22)
    var s = SortSpec[1](23)
    _bind_breaker(s)
    assert_equal(s.sentinel, 23)
    var t = TopNSpec[1, 1](24)
    _bind_breaker(t)
    assert_equal(t.sentinel, 24)
    var w = WindowSpec[1, 1](25)
    _bind_breaker(w)
    assert_equal(w.sentinel, 25)
    var jp = JoinProbeSpec[1, JOIN_INNER](26)
    _bind_breaker(jp)
    assert_equal(jp.sentinel, 26)
    var d = DistinctSpec[1](27)
    _bind_breaker(d)
    assert_equal(d.sentinel, 27)
    var pt = PartitionTopNSpec[1, 1, 1](28)
    _bind_breaker(pt)
    assert_equal(pt.sentinel, 28)
    var aj = AsofJoinSpec[1](29)
    _bind_breaker(aj)
    assert_equal(aj.sentinel, 29)
    var jb = JoinBuildSpec[1, 1](30)
    _bind_breaker(jb)
    assert_equal(jb.sentinel, 30)
    var ab = AsofJoinBuildSpec[1, 1](31)
    _bind_breaker(ab)
    assert_equal(ab.sentinel, 31)
    var pu = PartitionUdfSpec[1](32)
    _bind_breaker(pu)
    assert_equal(pu.sentinel, 32)
    var wu = WindowUdfSpec[1](33)
    _bind_breaker(wu)
    assert_equal(wu.sentinel, 33)


# =============================================================================
# Sentinels
# =============================================================================


def _filter_default[F: FilterLike]() -> F:
    return F.make_default()


def _projects_default[P: ProjectsLike]() -> P:
    return P.make_default()


def test_no_filter_keeps_everything() raises:
    """fdescribe 0; every row and every lane kept; bind is a no-op."""
    var batch = _batch_ab()
    var bv = batch_view_over(batch)
    assert_equal(NoFilter.fdescribe(), 0)
    var f = _filter_default[NoFilter]()
    assert_equal(f.sentinel, 0)
    var resolver = ColumnResolver()
    f.bind(resolver)
    assert_equal(f.sentinel, 0)
    for i in range(8):
        assert_true(f.keep_row(bv, i))
    var lanes = f.keep_simd[4](bv, 4)
    for j in range(4):
        assert_true(Bool(lanes[j]))


def test_no_projects_refuses_projected_emit() raises:
    """pdescribe 0; make_default 0; bind no-op; emit_projected raises."""
    var batch = _batch_ab()
    var bv = batch_view_over(batch)
    assert_equal(NoProjects.pdescribe(), 0)
    var p = _projects_default[NoProjects]()
    assert_equal(p.sentinel, 0)
    var resolver = ColumnResolver()
    p.bind(resolver)
    var survivors = List[Int]()
    survivors.append(0)
    var msg = String("")
    try:
        _ = p.emit_projected(bv, survivors)
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "NoProjects.emit_projected: pass-through must emit via gather_batch",
    )


def test_project_list_stub() raises:
    """pdescribe is the arity; make_default 0; emit_projected raises."""
    var batch = _batch_ab()
    var bv = batch_view_over(batch)
    assert_equal(ProjectListStub[3].pdescribe(), 3)
    assert_equal(ProjectListStub[0].pdescribe(), 0)
    var p = _projects_default[ProjectListStub[3]]()
    assert_equal(p.sentinel, 0)
    var resolver = ColumnResolver()
    p.bind(resolver)
    var msg = String("")
    try:
        _ = p.emit_projected(bv, List[Int]())
    except e:
        msg = String(e)
    assert_equal(
        msg, "ProjectListStub.emit_projected: marker stub — use ProjectList"
    )


def test_stage_program_marker() raises:
    """The aggregate is a copyable POD marker over its three slots."""
    var sp = StageProgram[NoFilter, NoProjects, HashAggSpec[2, 3]](7)
    var copy = sp
    assert_equal(copy.sentinel, 7)
    assert_equal(
        StageProgram[NoFilter, NoProjects, HashAggSpec[2, 3]].Breaker.tag(),
        BREAKER_HASH_AGG,
    )


# =============================================================================
# PredicateFilter
# =============================================================================


def test_predicate_filter_forwards_scalar_and_simd() raises:
    """b > 25 over b = [70, 60, 50, 40, 30, 20, 10, 0]: rows 0..4 kept.

    The predicate is bound to `b` (column 1) through the filter's bind;
    unbound it would read `a` (column 0), where `a > 25` keeps no row."""
    var batch = _batch_ab()
    var bv = batch_view_over(batch)
    assert_equal(PredicateFilter[GtNamed["b", 25]].fdescribe(), 1)
    var f = predicate_filter(GtNamed["b", 25]())
    var resolver = ColumnResolver.from_arrow_schema(batch.schema)
    f.bind(resolver)
    assert_equal(f.pred._idx, 1)
    var want = List[Bool]()
    for k in range(8):
        want.append(k <= 4)
    for i in range(8):
        assert_equal(f.keep_row(bv, i), want[i], String("row ", i))
    var lo = f.keep_simd[4](bv, 0)
    var hi = f.keep_simd[4](bv, 4)
    for j in range(4):
        assert_equal(Bool(lo[j]), want[j], String("lane ", j))
        assert_equal(Bool(hi[j]), want[4 + j], String("lane ", 4 + j))


def test_predicate_filter_unbound_reads_initial_column() raises:
    """Without bind the same filter reads `a`: a > 25 keeps nothing. This
    is the control that makes the bound case above mean something."""
    var batch = _batch_ab()
    var bv = batch_view_over(batch)
    var f = PredicateFilter[GtNamed["b", 25]](pred=GtNamed["b", 25]())
    for i in range(8):
        assert_false(f.keep_row(bv, i))


def test_predicate_filter_over_default_bind_predicate() raises:
    """A predicate with the ExprXBool default bind: bind is a no-op and the
    Predicate eval_scalar default forwards to eval_scalar_s."""
    var batch = _batch_ab()
    var bv = batch_view_over(batch)
    var t = predicate_filter(ConstBool[True]())
    var fl = predicate_filter(ConstBool[False]())
    var resolver = ColumnResolver.from_arrow_schema(batch.schema)
    t.bind(resolver)
    fl.bind(resolver)
    assert_true(t.keep_row(bv, 3))
    assert_false(fl.keep_row(bv, 3))
    assert_true(t.pred.eval_scalar(bv, 0))
    assert_false(fl.pred.eval_scalar(bv, 0))
    var lanes = fl.keep_simd[8](bv, 0)
    for j in range(8):
        assert_false(Bool(lanes[j]))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

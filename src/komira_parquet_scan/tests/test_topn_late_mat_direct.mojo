# The scan side of the two-phase top-N:
#   - the stamp operator appends the flat row group a morsel came from, for
#     a whole row group's partition id and a split one's, on an empty batch
#     too;
#   - the winners' row groups come back distinct and ascending; an empty
#     answer needs none; a non-empty answer without the stamp column, or
#     with a negative stamp, is refused;
#   - the route counters add up and reset;
#   - the two phases over a file of four 50-row row groups with many equal
#     keys (the winners tie across two row groups): phase 1 projects the key
#     alone and stamps, phase 2 claims only the winners' row groups with the
#     full projection, and each answer is exactly the first n rows of a full
#     sort by (key, file order), for an n inside one row group's ties and an
#     n across two;
#   - the stamp names each row's own row group when every morsel holds one
#     unit, and `topn_stamp_is_exact` is false exactly when a coarse row-range
#     emit puts several row groups' rows under one stamp. The comparator the
#     tests sort by models the top-N sink's tie rule; the sink is not run.

from std.memory import Pointer
from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_async.ops.waker_sink import NoopSink
from komira_collections.slab import Slab
from komira_fs.column_set import ColumnSet
from komira_fs.file_discovery import EagerGlobDiscovery
from komira_fs.local_fs import LocalFs
from komira_morsel.dynamic_join_filter import DynamicJoinFilter
from komira_morsel.morsel import Morsel
from komira_parquet.runtime_footer_cache import ParquetMetadataCache
from komira_parquet_scan.parquet_reader_factory import ParquetReaderFactory
from komira_parquet_scan.parquet_source import ParquetSource
from komira_parquet_scan.parquet_source_options import (
    SUB_SLOT_STRIDE,
    ParquetScanOptions,
    rg_partition_id,
    topn_stamp_is_exact,
    unit_partition_id,
)
from komira_plan_expr.expr_pool import ExprPool
from komira_runtime_paths import test_tmpdir
from komira_test_parquet_file import TestColumn, TestFileLayout, write_parquet_file
from komira_parquet_scan.topn_late_mat import (
    TOPN_LATE_MAT_RG_COLUMN,
    TopNRowGroupStampOp,
    reset_topn_late_mat_counters,
    topn_late_mat_phase2_units,
    topn_late_mat_record,
    topn_late_mat_runs,
    topn_late_mat_winner_row_groups,
)


comptime _FS = LocalFs[NoopSink]
comptime _NW = 3
comptime _RG_ROWS = 50
comptime _ROWS = 200


def _batch(name: String, values: List[Int64]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(name, ArrowType.INT64, False))
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(values)))
    return rbb.build(sb.build())


def test_the_stamp_is_the_row_group_of_the_partition_id() raises:
    var op = TopNRowGroupStampOp()
    for which in range(3):
        var rg = 7 if which < 2 else 0
        var pid = rg_partition_id(rg) if which != 1 else unit_partition_id(rg, SUB_SLOT_STRIDE - 1)
        var keys: List[Int64] = [Int64(30), Int64(10), Int64(20)]
        var m = Morsel(_batch("key", keys^), 0, pid)
        var res = op.execute(m)
        assert_true(res.is_need_more_input())
        assert_equal(m.batch.num_columns(), 2)
        var f = m.batch.schema.field_at(1)
        assert_equal(f.name, String(TOPN_LATE_MAT_RG_COLUMN))
        assert_true(f.arrow_type == ArrowType.INT64)
        var col = m.batch.column_as_primitive[DType.int64](1)
        for i in range(3):
            assert_equal(Int(col.get(i)), rg)
    var empty = Morsel(_batch("key", List[Int64]()), 0, rg_partition_id(2))
    _ = op.execute(empty)
    assert_equal(empty.batch.num_rows(), 0)
    assert_equal(empty.batch.num_columns(), 2)


def test_winner_row_groups_and_refusals() raises:
    var stamps: List[Int64] = [Int64(9), Int64(2), Int64(9), Int64(0), Int64(2)]
    assert_equal(topn_late_mat_winner_row_groups(_batch(String(TOPN_LATE_MAT_RG_COLUMN), stamps^)), [0, 2, 9])
    assert_equal(len(topn_late_mat_winner_row_groups(_batch("key", List[Int64]()))), 0)
    with assert_raises(contains="no __komira_topn_late_mat_rg column"):
        var keys: List[Int64] = [Int64(1)]
        _ = topn_late_mat_winner_row_groups(_batch("key", keys^))
    with assert_raises(contains="negative row-group stamp"):
        var bad: List[Int64] = [Int64(1), Int64(-1)]
        _ = topn_late_mat_winner_row_groups(_batch(String(TOPN_LATE_MAT_RG_COLUMN), bad^))


def _key_of(r: Int) -> Int:
    """Row groups 1 and 3 hold the small keys (0 to 3), 0 and 2 the large
    (10 to 13): 25 rows share key 0, 12 in row group 1 and 13 in row group 3."""
    return r % 4 + (0 if (r // _RG_ROWS) % 2 == 1 else 10)


def _file() raises -> String:
    var path = test_tmpdir() + "/topn_late_mat.parquet"
    var key = List[Int]()
    var a = List[Int]()
    for r in range(_ROWS):
        key.append(_key_of(r))
        a.append(r)
    var cols = List[TestColumn]()
    cols.append(TestColumn.int64("key", key^))
    cols.append(TestColumn.int64("a", a^))
    write_parquet_file(path, cols, TestFileLayout([_RG_ROWS, _RG_ROWS, _RG_ROWS, _RG_ROWS], 0, False))
    return path^


struct _Collected(Movable):
    """The rows a source produced, morsels in (partition id, origin hint)
    order, rows in morsel order: the order the top-N sink breaks ties in."""

    var key: List[Int]
    var a: List[Int]
    var stamp: List[Int]
    var units: Int

    def __init__(out self):
        self.key = List[Int]()
        self.a = List[Int]()
        self.stamp = List[Int]()
        self.units = 0


def _collect(
    path: String,
    var cols: ColumnSet,
    var claim: Optional[List[Int]],
    stamp: Bool,
    var options: ParquetScanOptions = ParquetScanOptions.default(),
) raises -> _Collected:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0  # the origin of an absent dynamic filter
    var src = ParquetSource[_FS, EagerGlobDiscovery, origin_of(cache), origin_of(pool), origin_of(nf)](
        _FS.new(), path, ParquetReaderFactory[origin_of(cache), _FS].new(Pointer(to=cache)), cols^,
        Optional(Pointer(to=pool)), Optional[Pointer[DynamicJoinFilter, origin_of(nf)]](None), _NW,
        options=options^, claim_units=claim^,
    )
    var out = _Collected()
    out.units = src.claimable_units()
    var morsels = Slab[Morsel]()
    var op = TopNRowGroupStampOp()
    var live = List[Bool](length=_NW, fill=True)
    var n_live = _NW
    while n_live > 0:
        for w in range(_NW):
            if not live[w]:
                continue
            var m = src.next_morsel(w)
            if m:
                var mm = m.take()
                if stamp:
                    _ = op.execute(mm)
                morsels.append(mm^)
            else:
                live[w] = False
                n_live -= 1
    var order = List[Int]()
    for i in range(len(morsels)):
        order.append(i)
    for i in range(1, len(order)):
        var j = i
        while j > 0:
            ref p = morsels[order[j - 1]]
            ref q = morsels[order[j]]
            if not (p.partition_id > q.partition_id or (
                p.partition_id == q.partition_id and p.origin_hint > q.origin_hint
            )):
                break
            var t = order[j - 1]
            order[j - 1] = order[j]
            order[j] = t
            j -= 1
    for k in range(len(order)):
        ref bt = morsels[order[k]].batch
        var key = bt.column_at(0).as_primitive[DType.int64]()
        for r in range(bt.num_rows()):
            out.key.append(Int(key.get(r)))
            if bt.num_columns() > (2 if stamp else 1):
                out.a.append(Int(bt.column_at(1).as_primitive[DType.int64]().get(r)))
            if stamp:
                out.stamp.append(Int(bt.column_as_primitive[DType.int64](bt.num_columns() - 1).get(r)))
    return out^


def _top_n(c: _Collected, n: Int) -> List[Int]:
    """The positions of the first `n` rows ordered by key, equal keys in
    their collected order (a stable insertion sort)."""
    var idx = List[Int]()
    for i in range(len(c.key)):
        idx.append(i)
    for i in range(1, len(idx)):
        var j = i
        while j > 0 and c.key[idx[j - 1]] > c.key[idx[j]]:
            var t = idx[j - 1]
            idx[j - 1] = idx[j]
            idx[j] = t
            j -= 1
    var out = List[Int]()
    for i in range(n):
        out.append(idx[i])
    return out^


def _full_sort_top_n(n: Int) -> List[Int]:
    """The first `n` file rows by (key, row), from the rows as written."""
    var rows = List[Int]()
    for r in range(_ROWS):
        rows.append(r)
    for i in range(1, len(rows)):
        var j = i
        while j > 0 and (
            _key_of(rows[j - 1]) > _key_of(rows[j])
            or (_key_of(rows[j - 1]) == _key_of(rows[j]) and rows[j - 1] > rows[j])
        ):
            var t = rows[j - 1]
            rows[j - 1] = rows[j]
            rows[j] = t
            j -= 1
    var out = List[Int]()
    for i in range(n):
        out.append(rows[i])
    return out^


def test_two_phases_return_the_rows_of_a_full_sort_ties_included() raises:
    var path = _file()
    for n in [7, 15]:
        var want = _full_sort_top_n(n)
        var want_rgs = List[Int]()
        for i in range(len(want)):
            var rg = want[i] // _RG_ROWS
            var seen = False
            for j in range(len(want_rgs)):
                if want_rgs[j] == rg:
                    seen = True
            if not seen:
                want_rgs.append(rg)
        sort(want_rgs)
        # Phase 1: the key alone, stamped.
        var p1 = _collect(path, ColumnSet.columns([0]), None, True)
        assert_equal(p1.units, 4)
        var top1 = _top_n(p1, n)
        var stamps = List[Int64]()
        for i in range(len(top1)):
            stamps.append(Int64(p1.stamp[top1[i]]))
        var winners = topn_late_mat_winner_row_groups(_batch(String(TOPN_LATE_MAT_RG_COLUMN), stamps^))
        assert_equal(winners, want_rgs)
        # n = 7 is inside row group 1's ties; n = 15 reaches into row group 3.
        assert_equal(len(winners), 1 if n == 7 else 2)
        # Phase 2: the full projection over the winners' row groups only.
        var p2 = _collect(path, ColumnSet.all(), Optional(winners^), False)
        assert_equal(p2.units, len(want_rgs))
        var top2 = _top_n(p2, n)
        assert_equal(len(top2), n)
        for i in range(n):
            assert_equal(p2.a[top2[i]], want[i], "n=" + String(n) + " row " + String(i))
            assert_equal(p2.key[top2[i]], _key_of(want[i]))


def test_the_stamp_is_exact_unless_row_ranges_are_emitted_coarse() raises:
    var path = _file()
    for coarse in [False, True]:
        var opts = ParquetScanOptions.default()
        opts.subrg_mode = 2
        opts.subrg_units_per_rg = 2
        opts.subrg_emit_coarse = coarse
        opts.subrg_emit_rows = 1000
        assert_equal(topn_stamp_is_exact(opts), not coarse)
        var c = _collect(path, ColumnSet.all(), None, True, opts^)
        assert_equal(len(c.a), _ROWS)
        var wrong = 0
        for i in range(len(c.a)):
            if c.stamp[i] != c.a[i] // _RG_ROWS:
                wrong += 1
        # One unit per morsel stamps every row with its own row group; a
        # coarse morsel (all 200 rows fit in 1,000) takes its first unit's.
        if coarse:
            assert_true(wrong > 0)
        else:
            assert_equal(wrong, 0)
    assert_true(topn_stamp_is_exact(ParquetScanOptions.default()))


def test_the_route_counters() raises:
    reset_topn_late_mat_counters()
    topn_late_mat_record(3)
    topn_late_mat_record(4)
    assert_equal(topn_late_mat_runs(), 2)
    assert_equal(topn_late_mat_phase2_units(), 7)
    reset_topn_late_mat_counters()
    assert_equal(topn_late_mat_runs(), 0)
    assert_equal(topn_late_mat_phase2_units(), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

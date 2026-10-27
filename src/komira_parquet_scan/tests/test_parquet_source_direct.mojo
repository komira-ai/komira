# ParquetSource end to end on files written by komira_test_parquet_file,
# drained by 3 workers in turn, the morsels sorted by (partition id, origin
# hint) the way the collect sink sorts them, every row checked against the
# rows written:
#   - a plain scan in file order; the output schema; the hints;
#   - morsels cut to `morsel_rows` come back in file order;
#   - a pushed predicate prunes a row group at setup (claimable units, the
#     setup counters, no per-claim evaluation);
#   - a decode filter over a projection that is not the filter column: the
#     survivors' projection, a NULL in the filter column dropped, on each
#     payload route (the selection pipeline's dense batch with its mask,
#     gathered, late materialization off);
#   - a multi-file scan whose second file lacks the filter column: its rows
#     are filtered as NULL (all dropped for `x > 0`), and the projected
#     columns come back by name;
#   - claim units and a claim order; the worker count is checked.

from std.memory import Pointer
from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.record_batch import RecordBatch
from komira_async.ops.waker_sink import NoopSink
from komira_collections.slab import Slab
from komira_fs.column_set import ColumnSet
from komira_fs.file_discovery import EagerGlobDiscovery
from komira_fs.local_fs import LocalFs
from komira_morsel.dynamic_join_filter import DynamicJoinFilter
from komira_morsel.morsel import Morsel
from komira_morsel.morsel_source import MorselSourceImpl
from komira_parquet.runtime_footer_cache import ParquetMetadataCache
from komira_parquet_scan.parquet_reader_factory import ParquetReaderFactory
from komira_parquet_scan.parquet_source import ParquetSource
from komira_parquet_scan.parquet_source_options import ParquetScanOptions, rg_index_of_partition_id
from komira_parquet_scan.rg_prune_counter import (
    reset_rg_prune_counters,
    rg_prune_perclaim_evals,
    rg_prune_setup_evals,
    rg_prune_setup_pruned,
)
from komira_plan_expr.expr import BIN_GT, BIN_LT, Expr
from komira_plan_expr.expr_id import ExprId
from komira_plan_expr.expr_pool import ExprPool
from komira_plan_expr.scalar_value import ScalarValue
from komira_runtime_paths import test_tmpdir
from komira_scan_planning.source_capability_config import SourceCapabilityConfig
from komira_test_parquet_file import TestColumn, TestFileLayout, write_parquet_file

comptime _FS = LocalFs[NoopSink]
comptime _NW = 3


def _a(r: Int) -> Int:
    return r


def _b(r: Int) -> Int:
    return (r * 37) % 101


def _null_b(r: Int) -> Bool:
    return r % 13 == 5


def _file(name: String, rows: Int, rgs: List[Int], with_x: Bool, first: Int) raises -> String:
    """Columns a (INT64 = global row), b (OPTIONAL INT64, NULL every 13th
    row), s (string), and, when `with_x`, x (INT64 = global row % 3)."""
    var path = test_tmpdir() + "/" + name + ".parquet"
    var a = List[Int]()
    var b = List[Int]()
    var nb = List[Bool]()
    var s = List[String]()
    var x = List[Int]()
    for i in range(rows):
        var r = first + i
        a.append(_a(r))
        b.append(_b(r))
        nb.append(_null_b(r))
        s.append("s" + String(r % 5))
        x.append(r % 3)
    var cols = List[TestColumn]()
    cols.append(TestColumn.int64("a", a^))
    cols.append(TestColumn.int64("b", b^).with_nulls(nb^))
    cols.append(TestColumn.string("s", s^).dict_encoded())
    if with_x:
        cols.append(TestColumn.int64("x", x^))
    write_parquet_file(path, cols, TestFileLayout(rgs.copy(), 0, False))
    return path^


def _drain[S: MorselSourceImpl](src: S) raises -> List[Int]:
    """Every morsel, workers in turn; returns column 0 (INT64) of the rows
    in (partition id, origin hint) order, honouring a selection mask."""
    var morsels = Slab[Morsel]()
    var live = List[Bool](length=_NW, fill=True)
    var n_live = _NW
    while n_live > 0:
        for w in range(_NW):
            if not live[w]:
                continue
            var m = src.next_morsel(w)
            if m:
                morsels.append(m.take())
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
            var gt = p.partition_id > q.partition_id or (
                p.partition_id == q.partition_id and p.origin_hint > q.origin_hint
            )
            if not gt:
                break
            var t = order[j - 1]
            order[j - 1] = order[j]
            order[j] = t
            j -= 1
    var out = List[Int]()
    for k in range(len(order)):
        ref bt = morsels[order[k]].batch
        var col = bt.column_at(0).as_primitive[DType.int64]()
        for r in range(bt.num_rows()):
            if bt.has_selection_mask() and not bt.selection_mask_get(r):
                continue
            out.append(Int(col.get(r)))
    return out^


def _expect(rows: List[Int], want: List[Int]) raises:
    assert_equal(len(rows), len(want))
    for i in range(len(want)):
        assert_equal(rows[i], want[i], "row " + String(i))


def _lit(v: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int(v))


def test_a_plain_scan_in_file_order_and_cut_morsels() raises:
    var path = _file("plain", 150, [50, 50, 50], True, 0)
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0  # the origin of an absent dynamic filter
    for morsel_rows in [0, 16]:
        var caps = SourceCapabilityConfig.default()
        caps.morsel_rows = morsel_rows
        var src = ParquetSource[_FS, EagerGlobDiscovery, origin_of(cache), origin_of(pool), origin_of(nf)](
            _FS.new(), path, ParquetReaderFactory[origin_of(cache), _FS].new(Pointer(to=cache)), ColumnSet.all(),
            Optional(Pointer(to=pool)), Optional[Pointer[DynamicJoinFilter, origin_of(nf)]](None), _NW, caps=caps^,
        )
        assert_equal(src.num_row_groups(), 3)
        assert_equal(src.row_count_hint(), 150)
        assert_equal(src.output_schema().num_columns(), 4)
        var want = List[Int]()
        for r in range(150):
            want.append(r)
        _expect(_drain(src), want)


def test_a_pushed_predicate_prunes_at_setup() raises:
    reset_rg_prune_counters()
    var path = _file("pushed", 150, [50, 50, 50], True, 0)
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0  # the origin of an absent dynamic filter
    var pred = pool.register(Expr.binary(BIN_LT, Expr.col_ref("a"), _lit(60)))
    var caps = SourceCapabilityConfig.default()
    caps.pushed_predicate = Optional(pred)
    var src = ParquetSource[_FS, EagerGlobDiscovery, origin_of(cache), origin_of(pool), origin_of(nf)](
        _FS.new(), path, ParquetReaderFactory[origin_of(cache), _FS].new(Pointer(to=cache)), ColumnSet.all(),
        Optional(Pointer(to=pool)), Optional[Pointer[DynamicJoinFilter, origin_of(nf)]](None), _NW, caps=caps^,
    )
    assert_equal(src.claimable_units(), 2)
    assert_equal(rg_prune_setup_evals(), 1)
    assert_equal(rg_prune_setup_pruned(), 1)
    var rows = _drain(src)
    # The pushed predicate prunes; it does not filter rows (that is the
    # decode filter's job): the two surviving row groups come back whole.
    assert_equal(len(rows), 100)
    assert_equal(rg_prune_perclaim_evals(), 0)


def _filtered_rows(lo: Int, hi: Int, first: Int, rows: Int) -> List[Int]:
    """Global rows of `[first, first + rows)` with `lo < b < hi`, b not NULL."""
    var out = List[Int]()
    for r in range(first, first + rows):
        if not _null_b(r) and _b(r) > lo and _b(r) < hi:
            out.append(r)
    return out^


def _filter_source_rows(name: String, lo: Int, hi: Int, var options: ParquetScanOptions) raises -> List[Int]:
    var path = _file(name, 150, [50, 50, 50], True, 0)
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0  # the origin of an absent dynamic filter
    var stages = List[ExprId]()
    stages.append(pool.register(Expr.binary(BIN_GT, Expr.col_ref("b"), _lit(lo))))
    stages.append(pool.register(Expr.binary(BIN_LT, Expr.col_ref("b"), _lit(hi))))
    var caps = SourceCapabilityConfig.default()
    caps.decode_filter_stages = Optional(stages^)
    var src = ParquetSource[_FS, EagerGlobDiscovery, origin_of(cache), origin_of(pool), origin_of(nf)](
        _FS.new(), path, ParquetReaderFactory[origin_of(cache), _FS].new(Pointer(to=cache)), ColumnSet.columns([0, 2]),
        Optional(Pointer(to=pool)), Optional[Pointer[DynamicJoinFilter, origin_of(nf)]](None), _NW, caps=caps^,
        options=options^,
    )
    return _drain(src)


def test_a_decode_filter_on_each_payload_route() raises:
    # 10 < b < 95 keeps most rows (the selection pipeline defers); 10 < b < 20
    # keeps few (gathered). NULL b never survives.
    for wide in [True, False]:
        var hi = 95 if wide else 20
        var want = _filtered_rows(10, hi, 0, 150)
        _expect(_filter_source_rows("route_sel" + String(wide), 10, hi, ParquetScanOptions.default()), want)
        var no_pipe = ParquetScanOptions.default()
        no_pipe.sel_pipe_enabled = False
        _expect(_filter_source_rows("route_gather" + String(wide), 10, hi, no_pipe^), want)
        var no_late = ParquetScanOptions.default()
        no_late.late_mat_disabled = True
        _expect(_filter_source_rows("route_nolate" + String(wide), 10, hi, no_late^), want)


def test_a_file_without_the_filter_column_filters_it_as_null() raises:
    var p1 = _file("union1", 40, [20, 20], True, 0)
    _ = _file("union2", 30, [30], False, 40)
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0  # the origin of an absent dynamic filter
    var stages = List[ExprId]()
    stages.append(pool.register(Expr.binary(BIN_GT, Expr.col_ref("x"), _lit(0))))
    var caps = SourceCapabilityConfig.default()
    caps.decode_filter_stages = Optional(stages^)
    _ = p1
    var glob = test_tmpdir() + "/union*.parquet"
    var src = ParquetSource[_FS, EagerGlobDiscovery, origin_of(cache), origin_of(pool), origin_of(nf)](
        _FS.new(), glob, ParquetReaderFactory[origin_of(cache), _FS].new(Pointer(to=cache)), ColumnSet.columns([0]),
        Optional(Pointer(to=pool)), Optional[Pointer[DynamicJoinFilter, origin_of(nf)]](None), _NW, caps=caps^,
    )
    assert_equal(src.num_files(), 2)
    var want = List[Int]()
    for r in range(40):
        if r % 3 > 0:
            want.append(r)
    _expect(_drain(src), want)


def test_claim_units_order_and_the_worker_count() raises:
    var path = _file("claims", 200, [50, 50, 50, 50], True, 0)
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0  # the origin of an absent dynamic filter
    var src = ParquetSource[_FS, EagerGlobDiscovery, origin_of(cache), origin_of(pool), origin_of(nf)](
        _FS.new(), path, ParquetReaderFactory[origin_of(cache), _FS].new(Pointer(to=cache)), ColumnSet.all(),
        Optional(Pointer(to=pool)), Optional[Pointer[DynamicJoinFilter, origin_of(nf)]](None), _NW,
        claim_units=Optional[List[Int]]([3, 1]),
    )
    assert_equal(src.claimable_units(), 2)
    var rows = _drain(src)
    assert_equal(len(rows), 100)
    assert_equal(rows[0], 50)
    assert_equal(rows[99], 199)
    var src2 = ParquetSource[_FS, EagerGlobDiscovery, origin_of(cache), origin_of(pool), origin_of(nf)](
        _FS.new(), path, ParquetReaderFactory[origin_of(cache), _FS].new(Pointer(to=cache)), ColumnSet.all(),
        Optional(Pointer(to=pool)), Optional[Pointer[DynamicJoinFilter, origin_of(nf)]](None), _NW,
        claim_order=Optional[List[Int]]([2, 0, 3, 1]),
    )
    assert_true(src2.claim_order_active())
    assert_equal(src2.claim_unit_at(0), 2)
    assert_equal(src2.cursor_stride(), 1)
    assert_equal(len(_drain(src2)), 200)
    with assert_raises(contains="num_workers"):
        _ = ParquetSource[_FS, EagerGlobDiscovery, origin_of(cache), origin_of(pool), origin_of(nf)](
            _FS.new(), path, ParquetReaderFactory[origin_of(cache), _FS].new(Pointer(to=cache)), ColumnSet.all(),
            Optional(Pointer(to=pool)), Optional[Pointer[DynamicJoinFilter, origin_of(nf)]](None), 0,
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

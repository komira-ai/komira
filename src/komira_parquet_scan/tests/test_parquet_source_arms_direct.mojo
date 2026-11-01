# ParquetSource's filtered arms and routes, end to end on files written by
# komira_test_parquet_file (three row groups of 50; a = row, d = row % 7 as a
# dictionary chunk, t = a PLAIN string), drained by 3 workers in turn, every
# count and row checked against the rows written:
#   - count(*) with no filter: the footer counts;
#   - count(*) WHERE a >= 0: every row group counted from its statistics
#     (rgs_allmatch = 3) with the option on, decoded with it off, the same
#     count; WHERE a >= 60 counts exactly, late materialization on or off;
#   - count(*) WHERE d > 2 over the dictionary chunk: no whole decode;
#   - the dictionary survivors arm (selection pipeline off, filter column
#     not projected): the rows, no whole decode;
#   - the staged filter (a lead on a, a string conjunct deferred): the rows;
#   - a dynamic join filter's IN-list on a: exactly its keys;
#   - a top-N boundary: only the row groups whose key range can reach it;
#   - parked sub-morsels shared with idle workers: every row once;
#   - the cursor-grain route, the row-range split (fine and coarse) and the
#     fused hash-aggregate payload: every row.

from std.memory import Pointer
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_collections.slab import Slab
from komira_fs.column_set import ColumnSet
from komira_fs.file_discovery import EagerGlobDiscovery
from komira_fs.local_fs import LocalFs
from komira_morsel.dynamic_join_filter import DynamicJoinFilter
from komira_morsel.morsel import Morsel
from komira_morsel.morsel_source import MorselSourceImpl
from komira_morsel.topn_boundary import TopNBoundary
from komira_parquet.file_reader import ParquetFileReader
from komira_parquet.metadata_parser import parse_full_metadata
from komira_parquet.runtime_footer_cache import ParquetMetadataCache
from komira_parquet.staged_filter_trace import reset_staged_filter_counts, staged_filter_rg_count
from komira_parquet_scan.cursor_grain_feed import (
    cursor_grain_rg_count,
    reset_cursor_grain_counts,
    set_cursor_grain_enabled,
    whole_decode_calls,
)
from komira_parquet_scan.parquet_reader_factory import ParquetReaderFactory
from komira_parquet_scan.parquet_source import ParquetSource
from komira_parquet_scan.parquet_source_options import ParquetScanOptions
from komira_parquet_scan.topn_rg_bounds import build_topn_rg_prune_plan
from komira_plan_expr.expr import BIN_AND, BIN_GE, BIN_GT, BIN_LT, BIN_NE, Expr
from komira_plan_expr.expr_id import ExprId
from komira_plan_expr.expr_pool import ExprPool
from komira_plan_expr.scalar_value import ScalarValue
from komira_runtime_paths import test_tmpdir
from komira_scan_planning.source_capability_config import SourceCapabilityConfig
from komira_test_parquet_file import TestColumn, TestFileLayout, write_parquet_file

comptime _FS = LocalFs[NoopSink]
comptime _NW = 3
comptime _ROWS = 150


def _file(name: String) raises -> String:
    var path = test_tmpdir() + "/" + name + ".parquet"
    var a = List[Int]()
    var d = List[Int]()
    var t = List[String]()
    for r in range(_ROWS):
        a.append(r)
        d.append(r % 7)
        t.append("t" + String(r % 4))
    var cols = List[TestColumn]()
    cols.append(TestColumn.int64("a", a^))
    cols.append(TestColumn.int64("d", d^).dict_encoded())
    cols.append(TestColumn.string("t", t^))
    write_parquet_file(path, cols, TestFileLayout([50, 50, 50], 0, False))
    return path^


def _drain_morsels[S: MorselSourceImpl](src: S) raises -> Slab[Morsel]:
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
    return morsels^


def _count[S: MorselSourceImpl](src: S) raises -> Int:
    var ms = _drain_morsels(src)
    var n = 0
    for i in range(len(ms)):
        assert_equal(ms[i].batch.num_columns(), 0)
        n += ms[i].batch.num_rows()
    return n


def _rows[S: MorselSourceImpl](src: S) raises -> List[Int]:
    """Column 0 of every row (selection masks honoured), sorted."""
    var ms = _drain_morsels(src)
    var out = List[Int]()
    for i in range(len(ms)):
        ref bt = ms[i].batch
        var col = bt.column_at(0).as_primitive[DType.int64]()
        for r in range(bt.num_rows()):
            if bt.has_selection_mask() and not bt.selection_mask_get(r):
                continue
            out.append(Int(col.get(r)))
    sort(out)
    return out^


def _expect(rows: List[Int], want: List[Int]) raises:
    assert_equal(len(rows), len(want))
    for i in range(len(want)):
        assert_equal(rows[i], want[i], "row " + String(i))


def _lit(v: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int(v))


def _cmp(op: UInt8, col: String, v: Int) -> Expr:
    return Expr.binary(op, Expr.col_ref(col), _lit(v))


def _caps_filter(mut pool: ExprPool, var pred: Expr, count_only: Bool) -> SourceCapabilityConfig:
    var caps = SourceCapabilityConfig.default()
    var stages = List[ExprId]()
    stages.append(pool.register(pred^))
    caps.decode_filter_stages = Optional(stages^)
    caps.count_only = count_only
    return caps^


comptime _Src[c: Origin[mut=True], p: Origin[mut=True], f: Origin[mut=True]] = ParquetSource[
    _FS, EagerGlobDiscovery, c, p, f
]


def test_counts() raises:
    var path = _file("counts")
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var caps0 = SourceCapabilityConfig.default()
    caps0.count_only = True
    var src0 = _Src[origin_of(cache), origin_of(pool), origin_of(nf)](
        _FS.new(), path, ParquetReaderFactory[origin_of(cache), _FS].new(Pointer(to=cache)), ColumnSet.columns(List[Int]()),
        Optional(Pointer(to=pool)), Optional[Pointer[DynamicJoinFilter, origin_of(nf)]](None), _NW, caps=caps0^,
    )
    assert_equal(_count(src0), _ROWS)
    for allmatch in [True, False]:
        var opts = ParquetScanOptions.default()
        opts.rg_allmatch = allmatch
        var src = _Src[origin_of(cache), origin_of(pool), origin_of(nf)](
            _FS.new(), path, ParquetReaderFactory[origin_of(cache), _FS].new(Pointer(to=cache)),
            ColumnSet.columns(List[Int]()), Optional(Pointer(to=pool)),
            Optional[Pointer[DynamicJoinFilter, origin_of(nf)]](None), _NW,
            caps=_caps_filter(pool, _cmp(BIN_GE, "a", 0), True), options=opts^,
        )
        assert_equal(_count(src), _ROWS)
        assert_equal(src.rgs_allmatch(), 3 if allmatch else 0)
    var part = _Src[origin_of(cache), origin_of(pool), origin_of(nf)](
        _FS.new(), path, ParquetReaderFactory[origin_of(cache), _FS].new(Pointer(to=cache)),
        ColumnSet.columns(List[Int]()), Optional(Pointer(to=pool)),
        Optional[Pointer[DynamicJoinFilter, origin_of(nf)]](None), _NW,
        caps=_caps_filter(pool, _cmp(BIN_GE, "a", 60), True),
    )
    assert_equal(_count(part), _ROWS - 60)
    assert_equal(part.rgs_allmatch(), 1)
    # Late materialization off still counts (row groups 0 and 1 are decoded
    # with their filter columns and counted, row group 2 from its statistics).
    var no_late = ParquetScanOptions.default()
    no_late.late_mat_disabled = True
    var part_nl = _Src[origin_of(cache), origin_of(pool), origin_of(nf)](
        _FS.new(), path, ParquetReaderFactory[origin_of(cache), _FS].new(Pointer(to=cache)),
        ColumnSet.columns(List[Int]()), Optional(Pointer(to=pool)),
        Optional[Pointer[DynamicJoinFilter, origin_of(nf)]](None), _NW,
        caps=_caps_filter(pool, _cmp(BIN_GE, "a", 60), True), options=no_late^,
    )
    assert_equal(_count(part_nl), _ROWS - 60)


def test_dictionary_count_and_survivors_skip_the_decode() raises:
    var path = _file("dict")
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var want = List[Int]()
    for r in range(_ROWS):
        if r % 7 > 2:
            want.append(r)
    reset_cursor_grain_counts()
    var src = _Src[origin_of(cache), origin_of(pool), origin_of(nf)](
        _FS.new(), path, ParquetReaderFactory[origin_of(cache), _FS].new(Pointer(to=cache)),
        ColumnSet.columns(List[Int]()), Optional(Pointer(to=pool)),
        Optional[Pointer[DynamicJoinFilter, origin_of(nf)]](None), _NW, caps=_caps_filter(pool, _cmp(BIN_GT, "d", 2), True),
    )
    assert_equal(_count(src), len(want))
    assert_equal(whole_decode_calls(), 0)
    var opts = ParquetScanOptions.default()
    opts.sel_pipe_enabled = False
    var surv = _Src[origin_of(cache), origin_of(pool), origin_of(nf)](
        _FS.new(), path, ParquetReaderFactory[origin_of(cache), _FS].new(Pointer(to=cache)), ColumnSet.columns([0]),
        Optional(Pointer(to=pool)), Optional[Pointer[DynamicJoinFilter, origin_of(nf)]](None), _NW,
        caps=_caps_filter(pool, _cmp(BIN_GT, "d", 2), False), options=opts^,
    )
    _expect(_rows(surv), want)
    assert_equal(whole_decode_calls(), 0)


def test_the_staged_filter_through_the_source() raises:
    reset_staged_filter_counts()
    var path = _file("staged")
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var pred = Expr.binary(
        BIN_AND, _cmp(BIN_LT, "a", 20), Expr.binary(BIN_NE, Expr.col_ref("t"), Expr.literal(ScalarValue.from_string("t1")))
    )
    var src = _Src[origin_of(cache), origin_of(pool), origin_of(nf)](
        _FS.new(), path, ParquetReaderFactory[origin_of(cache), _FS].new(Pointer(to=cache)), ColumnSet.columns([0]),
        Optional(Pointer(to=pool)), Optional[Pointer[DynamicJoinFilter, origin_of(nf)]](None), _NW,
        caps=_caps_filter(pool, pred^, False),
    )
    var want = List[Int]()
    for r in range(20):
        if r % 4 != 1:
            want.append(r)
    _expect(_rows(src), want)
    assert_true(staged_filter_rg_count() > 0)


def test_a_dynamic_join_filter() raises:
    var path = _file("dyn")
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var keys: List[Int64] = [3, 77, 141]
    var built = DynamicJoinFilter.build_int64_from_list(keys)
    var df = built.take()
    var caps = SourceCapabilityConfig.default()
    caps.dynamic_filter_key_name = "a"
    var src = _Src[origin_of(cache), origin_of(pool), origin_of(df)](
        _FS.new(), path, ParquetReaderFactory[origin_of(cache), _FS].new(Pointer(to=cache)), ColumnSet.columns([0, 1]),
        Optional(Pointer(to=pool)), Optional(Pointer(to=df)), _NW, caps=caps^,
    )
    _expect(_rows(src), [3, 77, 141])


def test_a_top_n_boundary() raises:
    var path = _file("topn")
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var f = ParquetFileReader[_FS].open(path)
    var md = parse_full_metadata(f.metadata_bytes.view_range_ro(0, f.metadata_length))
    var plan = build_topn_rg_prune_plan(md, "a", False)
    var boundary = TopNBoundary.new(False)
    boundary.publish(30)
    var src = _Src[origin_of(cache), origin_of(pool), origin_of(nf)](
        _FS.new(), path, ParquetReaderFactory[origin_of(cache), _FS].new(Pointer(to=cache)), ColumnSet.columns([0]),
        Optional(Pointer(to=pool)), Optional[Pointer[DynamicJoinFilter, origin_of(nf)]](None), _NW,
        topn_boundary=Optional(boundary^), topn_prune=plan^,
    )
    var want = List[Int]()
    for r in range(50):
        want.append(r)
    _expect(_rows(src), want)


def test_parked_sub_morsels_shared() raises:
    var path = test_tmpdir() + "/parked.parquet"
    var a = List[Int]()
    for r in range(100):
        a.append(r)
    var cols = List[TestColumn]()
    cols.append(TestColumn.int64("a", a^))
    write_parquet_file(path, cols, TestFileLayout([60, 40], 0, False))
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var caps = SourceCapabilityConfig.default()
    caps.morsel_rows = 10
    var src = _Src[origin_of(cache), origin_of(pool), origin_of(nf)](
        _FS.new(), path, ParquetReaderFactory[origin_of(cache), _FS].new(Pointer(to=cache)), ColumnSet.all(),
        Optional(Pointer(to=pool)), Optional[Pointer[DynamicJoinFilter, origin_of(nf)]](None), _NW, caps=caps^,
        share_parked=True,
    )
    assert_true(src.parked_share_active())
    var want = List[Int]()
    for r in range(100):
        want.append(r)
    _expect(_rows(src), want)
    assert_true(src.parked_share_published() > 0)


def test_grain_split_and_hash_aggregate_routes() raises:
    var path = _file("routes")
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var want = List[Int]()
    for r in range(_ROWS):
        want.append(r)
    reset_cursor_grain_counts()
    set_cursor_grain_enabled(True)
    var g_opts = ParquetScanOptions.default()
    g_opts.cursor_grain_rows = 16
    var grain = _Src[origin_of(cache), origin_of(pool), origin_of(nf)](
        _FS.new(), path, ParquetReaderFactory[origin_of(cache), _FS].new(Pointer(to=cache)), ColumnSet.columns([0, 1]),
        Optional(Pointer(to=pool)), Optional[Pointer[DynamicJoinFilter, origin_of(nf)]](None), _NW, options=g_opts^,
    )
    _expect(_rows(grain), want)
    set_cursor_grain_enabled(False)
    assert_equal(cursor_grain_rg_count(), 3)
    for coarse in [False, True]:
        var s_opts = ParquetScanOptions.default()
        s_opts.subrg_mode = 2
        s_opts.subrg_units_per_rg = 3
        s_opts.subrg_emit_coarse = coarse
        s_opts.subrg_emit_rows = 40
        var split = _Src[origin_of(cache), origin_of(pool), origin_of(nf)](
            _FS.new(), path, ParquetReaderFactory[origin_of(cache), _FS].new(Pointer(to=cache)), ColumnSet.columns([0, 1]),
            Optional(Pointer(to=pool)), Optional[Pointer[DynamicJoinFilter, origin_of(nf)]](None), _NW, options=s_opts^,
        )
        _expect(_rows(split), want)
    var caps = SourceCapabilityConfig.default()
    caps.hash_agg_key_col_idx = Optional(0)
    caps.hash_agg_agg_col_indices = Optional[List[Int]]([1])
    var agg = _Src[origin_of(cache), origin_of(pool), origin_of(nf)](
        _FS.new(), path, ParquetReaderFactory[origin_of(cache), _FS].new(Pointer(to=cache)), ColumnSet.columns([0, 1]),
        Optional(Pointer(to=pool)), Optional[Pointer[DynamicJoinFilter, origin_of(nf)]](None), _NW, caps=caps^,
    )
    var ms = _drain_morsels(agg)
    var n = 0
    for i in range(len(ms)):
        assert_true(ms[i].hash_agg_decoded.__bool__())
        n += ms[i].hash_agg_decoded.value()[].num_rows
    assert_equal(n, _ROWS)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

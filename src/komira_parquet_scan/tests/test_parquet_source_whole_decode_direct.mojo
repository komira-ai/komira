# The morsel source against the whole row-group decode, column by column.
# Every source below is drained and each emitted row is compared, by the
# value of column "a", with the same row of `ParquetReader.decode_columns_subset`
# over the same projection: the column names, the Arrow types and every cell
# (a NULL included), with no row missing and none twice. Paths:
#   - the plain route over every column kind of the file (a NULL-bearing
#     dictionary column, UINT_32 / UINT_64 dictionary columns, a column
#     annotated TIMESTAMP_MICROS, a PLAIN column whose chunks store a
#     dictionary offset of 0), with and without dictionary preservation;
#   - the cursor-grain route: the columns the cursors read (a zero dictionary
#     offset among them) come from the cursors, and a projection holding a
#     TIMESTAMP-annotated or a NULL-bearing column is left to the whole
#     decode, with the type the whole decode gives;
#   - the row-range route (page units, equal ranges, shared dictionaries,
#     coarse morsels of several ranges concatenated): the same columns and
#     types as the whole decode over INT32, INT64 and DOUBLE columns, plain and
#     dictionary-encoded, and with no row dropped or repeated at any coarse
#     size; a range a cursor refuses (NULLs in one row group of a column that
#     passed the plan probe on row group 0) is cut from the whole decode and
#     may share a coarse morsel with ranges the cursors decoded;
#   - the unsigned dictionary columns under a pushed count and a pushed
#     filter: the fused dictionary paths decline them, so the source agrees
#     with decoding everything and evaluating the filter;
#   - a decode filter on a selective lead over a reordered projection, under
#     every combination of dictionary preservation, payload selection and the
#     staged filter: the survivors' columns in projection order.

from std.memory import ArcPointer, Pointer
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.record_batch import RecordBatch
from komira_async.ops.waker_sink import NoopSink
from komira_collections.slab import Slab
from komira_fs.column_set import ColumnSet
from komira_fs.file_discovery import EagerGlobDiscovery
from komira_fs.local_fs import LocalFs
from komira_morsel.dynamic_join_filter import DynamicJoinFilter
from komira_morsel.morsel import Morsel
from komira_morsel.morsel_source import MorselSourceImpl
from komira_parquet.file_reader import ParquetFileReader
from komira_parquet.metadata_parser import parse_full_metadata
from komira_parquet.payload_sel_trace import (
    PAYLOAD_SEL_ALL,
    PAYLOAD_SEL_OFF,
    payload_sel_hit_count,
    reset_payload_sel_counts,
    reset_payload_sel_gate,
    set_payload_sel_decode_mode,
)
from komira_parquet.runtime_footer_cache import ParquetMetadataCache
from komira_parquet.staged_filter_trace import (
    reset_staged_filter_counts,
    reset_staged_filter_gate,
    set_staged_filter_enabled,
    staged_filter_rg_count,
)
from komira_parquet_api.metadata import FileMetaData
from komira_parquet_scan.cursor_grain_feed import (
    cursor_grain_rg_count,
    reset_cursor_grain_counts,
    set_cursor_grain_enabled,
)
from komira_parquet_scan.parquet_reader import ParquetReader
from komira_parquet_scan.parquet_reader_factory import ParquetReaderFactory
from komira_parquet_scan.parquet_source import ParquetSource
from komira_parquet_scan.parquet_source_arms import stages_mask
from komira_parquet_scan.parquet_source_options import ParquetScanOptions
from komira_plan_expr.expr import BIN_GT, BIN_LT, Expr
from komira_plan_expr.expr_id import ExprId
from komira_plan_expr.expr_pool import ExprPool
from komira_plan_expr.scalar_value import ScalarValue
from komira_runtime_paths import test_tmpdir
from komira_scan_planning.source_capability_config import SourceCapabilityConfig
from komira_test_parquet_file import PT_INT32, PT_INT64, TestColumn, TestFileLayout, write_parquet_file

comptime _FS = LocalFs[NoopSink]
comptime _NW = 3
comptime _ROWS = 120
comptime _RG_ROWS = 40

# Column indices of the file.
comptime A = 0  # INT64 = row
comptime T = 1  # string, dictionary = "t" + row % 4
comptime N = 2  # INT64 dictionary, OPTIONAL, NULL when row % 5 == 2, else row % 6
comptime U32 = 3  # INT32 annotated UINT_32, dictionary = 2^31 + row % 4
comptime U64 = 4  # INT64 annotated UINT_64, dictionary = 2^63 + row % 4 (as the bits)
comptime TS = 5  # INT64 PLAIN = row * 1000, annotated TIMESTAMP (UTC, micros) by the LogicalType alone
comptime Z = 6  # INT64 PLAIN, every chunk storing dictionary_page_offset = 0 (= row * 3)
comptime F = 7  # DOUBLE PLAIN = row / 2
comptime D = 8  # INT64 dictionary = row % 7
comptime I = 9  # INT32 PLAIN = row * 5 - 100
comptime K = 10  # INT64 PLAIN = (row * 7) % 40, ten rows below 10 in every row group
comptime TSC = 11  # INT64 PLAIN = row * 1000, annotated by the ConvertedType TIMESTAMP_MICROS alone
comptime M = 12  # INT64 PLAIN OPTIONAL = row * 2, NULL for a third of the rows of row group 1 only
comptime _CT_UINT_32 = 13
comptime _CT_UINT_64 = 14
comptime _CT_TIMESTAMP_MICROS = 10

comptime _Src[c: Origin[mut=True], p: Origin[mut=True], f: Origin[mut=True]] = ParquetSource[
    _FS, EagerGlobDiscovery, c, p, f
]


def _file() raises -> String:
    var path = test_tmpdir() + "/source_whole_decode.parquet"
    var a = List[Int]()
    var t = List[String]()
    var n = List[Int]()
    var n_null = List[Bool]()
    var u32 = List[Int]()
    var u64 = List[Int]()
    var ts = List[Int]()
    var z = List[Int]()
    var f = List[Float64]()
    var d = List[Int]()
    var i = List[Int]()
    var k = List[Int]()
    var m = List[Int]()
    var m_null = List[Bool]()
    var lowest = -(1 << 62) - (1 << 62)
    for r in range(_ROWS):
        a.append(r)
        t.append("t" + String(r % 4))
        n.append(r % 6)
        n_null.append(r % 5 == 2)
        u32.append((1 << 31) + r % 4)
        u64.append(lowest + r % 4)
        ts.append(r * 1000)
        z.append(r * 3)
        f.append(Float64(r) / 2.0)
        d.append(r % 7)
        i.append(r * 5 - 100)
        k.append((r * 7) % 40)
        m.append(r * 2)
        m_null.append(r >= _RG_ROWS and r < 2 * _RG_ROWS and r % 3 == 0)
    var u32_col = TestColumn(String("u32"), PT_INT32, _CT_UINT_32)
    u32_col.ints = u32^
    var u64_col = TestColumn(String("u64"), PT_INT64, _CT_UINT_64)
    u64_col.ints = u64^
    var ts_col = TestColumn.int64("ts", ts.copy()).with_timestamp_logical_type(2)
    var tsc_col = TestColumn(String("tsc"), PT_INT64, _CT_TIMESTAMP_MICROS)
    tsc_col.ints = ts^
    var cols = List[TestColumn]()
    cols.append(TestColumn.int64("a", a^))
    cols.append(TestColumn.string("t", t^).dict_encoded())
    cols.append(TestColumn.int64("n", n^).with_nulls(n_null^).dict_encoded())
    cols.append(u32_col^.dict_encoded())
    cols.append(u64_col^.dict_encoded())
    cols.append(ts_col^)
    cols.append(TestColumn.int64("z", z^).with_zero_dictionary_offset())
    cols.append(TestColumn.float64("f", f^))
    cols.append(TestColumn.int64("d", d^).dict_encoded())
    cols.append(TestColumn.int32("i", i^))
    cols.append(TestColumn.int64("k", k^))
    cols.append(tsc_col^)
    cols.append(TestColumn.int64("m", m^).with_nulls(m_null^))
    write_parquet_file(path, cols, TestFileLayout([_RG_ROWS, _RG_ROWS, _RG_ROWS], 10, False))
    return path^


def _oracle_reader(path: String) raises -> ParquetReader[_FS]:
    var file = ParquetFileReader[_FS].open(path)
    var meta = parse_full_metadata(file.metadata_bytes.view_range_ro(0, file.metadata_length))
    return ParquetReader[_FS](_file=file^, _meta=ArcPointer[FileMetaData](meta^))


def _cell(b: RecordBatch, c: Int, r: Int) raises -> String:
    ref col = b.column_at(c)
    if col.is_null_at(r):
        return "NULL"
    var ty = col.arrow_type
    if ty == ArrowType.STRING:
        return col.as_string().get(r)
    if ty == ArrowType.DICTIONARY:
        return col.as_dictionary().get(r)
    if ty == ArrowType.INT32:
        return String(Int(col.as_primitive[DType.int32]().get(r)))
    if ty == ArrowType.UINT32:
        return String(Int(col.as_primitive[DType.uint32]().get(r)))
    if ty == ArrowType.UINT64:
        return String(col.as_primitive[DType.uint64]().get(r))
    if ty == ArrowType.FLOAT64:
        return String(Float64(col.as_primitive[DType.float64]().get(r)))
    if ty == ArrowType.INT64 or ty == ArrowType.TIMESTAMP_US or ty == ArrowType.TIMESTAMP:
        return String(Int(col.as_primitive[DType.int64]().get(r)))
    raise Error("test: a column type this test does not read: " + b.schema.field_name(c))


def _row_text(b: RecordBatch, r: Int) raises -> String:
    var out = String()
    for c in range(b.num_columns()):
        out += _cell(b, c, r) + "|"
    return out^


def _a_of(b: RecordBatch, r: Int) raises -> Int:
    for c in range(b.num_columns()):
        if b.schema.field_name(c) == "a":
            return Int(b.column_at(c).as_primitive[DType.int64]().get(r))
    raise Error("test: the projection has no column a")


def _drain[S: MorselSourceImpl](src: S) raises -> Slab[Morsel]:
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


struct _Oracle(Movable):
    """The whole decode of every row group over one projection: the
    batches, and each row's text by the row's value of column a."""

    var batches: List[RecordBatch]
    var text: List[String]  # by a
    var present: List[Bool]

    def __init__(out self, path: String, proj: List[Int], preserve_dict: Bool) raises:
        var reader = _oracle_reader(path)
        self.batches = List[RecordBatch]()
        self.text = List[String](length=_ROWS, fill=String())
        self.present = List[Bool](length=_ROWS, fill=False)
        for rg in range(reader.unit_count_for_file()):
            var b = reader.decode_columns_subset(rg, proj.copy(), preserve_dict)
            for r in range(b.num_rows()):
                var a = _a_of(b, r)
                self.text[a] = _row_text(b, r)
                self.present[a] = True
            self.batches.append(b^)


def _check_against(
    mut morsels: Slab[Morsel], oracle: _Oracle, want_rows: List[Bool], label: String
) raises:
    """Every emitted row (a selection mask honoured) is a row of `want_rows`
    exactly once and equals the whole decode's row; each batch has the whole
    decode's column names and types."""
    var seen = List[Int](length=_ROWS, fill=0)
    ref first = oracle.batches[0]
    for m in range(len(morsels)):
        ref bt = morsels[m].batch
        assert_equal(bt.num_columns(), first.num_columns(), label + ": column count")
        for c in range(bt.num_columns()):
            assert_equal(bt.schema.field_name(c), first.schema.field_name(c), label + ": name of column " + String(c))
            assert_true(
                bt.column_at(c).arrow_type == first.column_at(c).arrow_type,
                label + ": type of column " + bt.schema.field_name(c),
            )
        for r in range(bt.num_rows()):
            if bt.has_selection_mask() and not bt.selection_mask_get(r):
                continue
            var a = _a_of(bt, r)
            seen[a] += 1
            assert_equal(_row_text(bt, r), oracle.text[a], label + ": row a=" + String(a))
    for a in range(_ROWS):
        assert_equal(seen[a], 1 if want_rows[a] else 0, label + ": rows with a=" + String(a))


def _all_rows() -> List[Bool]:
    return List[Bool](length=_ROWS, fill=True)


def _run(
    path: String,
    proj: List[Int],
    preserve_dict: Bool,
    var options: ParquetScanOptions,
    var caps: SourceCapabilityConfig,
    mut pool: ExprPool,
    want_rows: List[Bool],
    label: String,
) raises:
    var cache = ParquetMetadataCache()
    var nf = 0
    var src = _Src[origin_of(cache), origin_of(pool), origin_of(nf)](
        _FS.new(), path, ParquetReaderFactory[origin_of(cache), _FS].new(Pointer(to=cache)),
        ColumnSet.columns(proj.copy()), Optional(Pointer(to=pool)),
        Optional[Pointer[DynamicJoinFilter, origin_of(nf)]](None), _NW,
        preserve_dict=preserve_dict, caps=caps^, options=options^,
    )
    var morsels = _drain(src)
    _check_against(morsels, _Oracle(path, proj, preserve_dict), want_rows, label)


def _plain(
    path: String, proj: List[Int], preserve_dict: Bool, var options: ParquetScanOptions, label: String
) raises:
    var pool = ExprPool()
    _run(path, proj, preserve_dict, options^, SourceCapabilityConfig.default(), pool, _all_rows(), label)


def test_the_plain_route_gives_the_whole_decode_of_every_column_kind() raises:
    var path = _file()
    var every: List[Int] = [A, T, N, U32, U64, TS, Z, F, D, I, K, TSC, M]
    for preserve in [False, True]:
        _plain(path, every, preserve, ParquetScanOptions.default(), "plain all preserve=" + String(preserve))
    # The same columns, one at a time after a: nothing depends on the
    # neighbours in the projection.
    for c in range(1, 13):
        _plain(path, [A, c], False, ParquetScanOptions.default(), "plain a + " + String(c))
    _plain(path, [TS, Z, N, A], False, ParquetScanOptions.default(), "plain reordered")


def test_the_cursor_grain_route_and_the_columns_it_leaves_to_the_whole_decode() raises:
    var path = _file()
    var opts = ParquetScanOptions.default()
    opts.cursor_grain_rows = 16
    # A zero dictionary offset, a plain INT32 and a DOUBLE: read by the cursors.
    reset_cursor_grain_counts()
    set_cursor_grain_enabled(True)
    _plain(path, [A, Z, I, F], False, opts.copy(), "grain z i f")
    var by_cursor = cursor_grain_rg_count()
    # A TIMESTAMP-annotated column and a column with NULLs are refused: the
    # whole decode's types and values.
    reset_cursor_grain_counts()
    _plain(path, [A, TS], False, opts.copy(), "grain ts")
    var ts_by_cursor = cursor_grain_rg_count()
    reset_cursor_grain_counts()
    _plain(path, [A, N], False, opts.copy(), "grain n")
    var n_by_cursor = cursor_grain_rg_count()
    reset_cursor_grain_counts()
    _plain(path, [A, Z, TS], False, opts.copy(), "grain z ts")
    var mixed_by_cursor = cursor_grain_rg_count()
    # A ConvertedType-only TIMESTAMP_MICROS does not re-label the whole
    # decode's type (INT64), so the cursors read it.
    reset_cursor_grain_counts()
    _plain(path, [A, TSC], False, opts.copy(), "grain tsc")
    var tsc_by_cursor = cursor_grain_rg_count()
    set_cursor_grain_enabled(False)
    assert_equal(by_cursor, 3)
    assert_equal(tsc_by_cursor, 3)
    assert_equal(ts_by_cursor, 0)
    assert_equal(n_by_cursor, 0)
    assert_equal(mixed_by_cursor, 0)


def test_the_row_range_route_gives_the_whole_decode() raises:
    var path = _file()
    var projections = List[List[Int]]()
    projections.append([A, Z])  # a zero dictionary offset
    projections.append([A, D, I, F, Z])  # INT64 dictionary, INT32, DOUBLE, INT64 plain
    projections.append([A, TS])  # refused: the whole decode's type
    projections.append([A, N])  # refused: a column with NULLs
    projections.append([A, U32, U64])  # refused: unsigned
    projections.append([A, TSC])  # a ConvertedType-only timestamp: read as the INT64 it is
    # NULLs in row group 1 only: the plan probe passes on row group 0, the
    # ranges of row group 1 are cut from the whole decode, and a coarse morsel
    # can join them with ranges the cursors decoded.
    projections.append([A, M, Z])
    var failures = String()
    for p in range(len(projections)):
        for mode in [1, 2]:
            for shared in [False, True]:
                for coarse in [False, True]:
                    var opts = ParquetScanOptions.default()
                    opts.subrg_mode = mode
                    opts.subrg_units_per_rg = 3
                    opts.subrg_shared = shared
                    opts.subrg_emit_coarse = coarse
                    opts.subrg_emit_rows = 50
                    var label = "rows p=" + String(p) + " mode=" + String(mode) + " shared=" + String(shared)
                    label += " coarse=" + String(coarse)
                    try:
                        _plain(path, projections[p], False, opts^, label)
                    except e:
                        failures += label + ": " + String(e) + "\n"
    assert_equal(failures, "")


def test_coarse_row_range_morsels_lose_and_repeat_no_row() raises:
    # The units a worker claims are concatenated into one morsel; the
    # concatenation takes INT32, INT64, DOUBLE, plain and dictionary-decoded
    # columns, from units of different row groups, at every size.
    var path = _file()
    for emit_rows in [1, 7, 40, 55, 1000]:
        for units in [1, 2, 5]:
            var opts = ParquetScanOptions.default()
            opts.subrg_mode = 2
            opts.subrg_units_per_rg = units
            opts.subrg_shared = True
            opts.subrg_emit_coarse = True
            opts.subrg_emit_rows = emit_rows
            _plain(path, [I, D, A, F, Z], False, opts.copy(), "coarse " + String(emit_rows) + "/" + String(units))
            _plain(path, [A, M, I], False, opts^, "coarse with NULLs " + String(emit_rows) + "/" + String(units))


def _lit(v: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int(v))


def _rows_where(mask: BooleanArray, rg: Int, mut rows: List[Bool]):
    for r in range(_RG_ROWS):
        rows[rg * _RG_ROWS + r] = mask.data.test(r)


def _filter_expectation(path: String, mut pool: ExprPool, mut stages: List[ExprId], var pred: Expr) raises -> List[Bool]:
    """The rows `pred` keeps, from the whole decode of every column the
    predicate names and the expression evaluator."""
    stages.append(pool.register(pred^))
    var reader = _oracle_reader(path)
    var rows = List[Bool](length=_ROWS, fill=False)
    for rg in range(reader.unit_count_for_file()):
        var b = reader.decode_columns_subset(rg, [U32, U64, K], False)
        _rows_where(stages_mask(pool, stages, b), rg, rows)
    return rows^


def test_unsigned_dictionary_columns_under_a_pushed_count_and_filter() raises:
    var path = _file()
    # u32 > 2^31 + 1 keeps the rows with row % 4 >= 2: sign extension of the
    # dictionary entries would keep none.
    var cases = List[Expr]()
    cases.append(Expr.binary(BIN_GT, Expr.col_ref("u32"), _lit((1 << 31) + 1)))
    cases.append(Expr.binary(BIN_GT, Expr.col_ref("u64"), _lit(0)))
    cases.append(Expr.binary(BIN_LT, Expr.col_ref("u64"), _lit(0)))
    for c in range(len(cases)):
        for count_only in [False, True]:
            var pool = ExprPool()
            var stages = List[ExprId]()
            var want = _filter_expectation(path, pool, stages, cases[c].copy())
            if c == 0:
                for r in range(_ROWS):
                    assert_equal(want[r], r % 4 >= 2)
            var caps = SourceCapabilityConfig.default()
            caps.decode_filter_stages = Optional(stages.copy())
            caps.count_only = count_only
            var cache = ParquetMetadataCache()
            var nf = 0
            var proj: List[Int] = [A] if count_only else [A, U32, U64]
            var src = _Src[origin_of(cache), origin_of(pool), origin_of(nf)](
                _FS.new(), path, ParquetReaderFactory[origin_of(cache), _FS].new(Pointer(to=cache)),
                ColumnSet.columns(proj^), Optional(Pointer(to=pool)),
                Optional[Pointer[DynamicJoinFilter, origin_of(nf)]](None), _NW, caps=caps^,
            )
            var morsels = _drain(src)
            var n_want = 0
            for r in range(_ROWS):
                if want[r]:
                    n_want += 1
            if count_only:
                var n = 0
                for m in range(len(morsels)):
                    n += morsels[m].batch.num_rows()
                assert_equal(n, n_want, "case " + String(c) + " count")
            else:
                _check_against(morsels, _Oracle(path, [A, U32, U64], False), want, "case " + String(c))


def test_a_selective_filter_over_a_reordered_projection_keeps_the_projection_order() raises:
    var path = _file()
    var projections = List[List[Int]]()
    projections.append([T, A])  # a dictionary column before the row id
    projections.append([I, T, K, A, N])  # the filter column inside the projection
    var kept = List[Bool](length=_ROWS, fill=False)
    for r in range(_ROWS):
        kept[r] = (r * 7) % 40 < 10
    for p in range(len(projections)):
        for preserve in [False, True]:
            for payload in [PAYLOAD_SEL_OFF, PAYLOAD_SEL_ALL]:
                for staged in [True, False]:
                    set_payload_sel_decode_mode(payload)
                    set_staged_filter_enabled(staged)
                    reset_staged_filter_counts()
                    reset_payload_sel_counts()
                    var pool = ExprPool()
                    var caps = SourceCapabilityConfig.default()
                    var stages = List[ExprId]()
                    stages.append(pool.register(Expr.binary(BIN_LT, Expr.col_ref("k"), _lit(10))))
                    # Every row passes the second conjunct, which the staged
                    # filter defers to the survivors of the first.
                    stages.append(pool.register(Expr.binary(BIN_GT, Expr.col_ref("i"), _lit(-101))))
                    caps.decode_filter_stages = Optional(stages^)
                    var label = "filter p=" + String(p) + " preserve=" + String(preserve) + " payload=" + String(payload)
                    label += " staged=" + String(staged)
                    _run(path, projections[p], preserve, ParquetScanOptions.default(), caps^, pool, kept, label)
                    # The lead k is a fixed-width column: the staged filter
                    # pays only when fixed-width columns may be decoded
                    # selectively.
                    if staged and payload == PAYLOAD_SEL_ALL:
                        assert_true(staged_filter_rg_count() > 0, label + ": the staged filter ran")
                    else:
                        assert_equal(staged_filter_rg_count(), 0, label)
                    if staged and payload == PAYLOAD_SEL_ALL and not preserve:
                        assert_true(payload_sel_hit_count() > 0, label + ": the selective decode ran")
    reset_payload_sel_gate()
    reset_staged_filter_gate()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

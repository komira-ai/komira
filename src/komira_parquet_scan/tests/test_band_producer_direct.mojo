# band_producer on a 4-worker runtime, folding into a test sink that sums a
# value per string key (and counts rows), checked against sums computed from
# the rows written:
#   - SUM(v), COUNT(*) GROUP BY k over three row groups, the value column
#     PLAIN DOUBLE, a dictionary DOUBLE, and the PLAIN column read in place
#     (zero copy);
#   - with an INT32 `d <= cutoff` filter carried on the band;
#   - a row group whose value column has a null aborts the run (empty result),
#     and so does a key column with a null;
#   - a plan whose key is not a dictionary string is refused, and a key that
#     is a PLAIN string aborts;
#   - a column whose annotation re-labels its type (a timestamp on an INT64, a
#     UINT_32 dictionary) aborts instead of folding the physical values;
#   - a footer dictionary offset of 0 on a PLAIN column does not stop the fold
#     and does not change its sums; a row group with fewer chunks than the
#     schema, or a footer row count that disagrees with the columns, aborts;
#   - the band width: the residency bound under the host profile's L3 cache,
#     the floor, and that equal profiles give equal widths.

from std.memory import ArcPointer
from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.band_view import BandView
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from komira_async_api.token import CancellationToken
from komira_collections.slab import Slab
from komira_engine_runtime.band_sink import BandSink
from komira_engine_runtime.host_profile import HostProfile, reference_host_profile
from komira_fs.local_fs import LocalFs
from komira_parquet.file_reader import ParquetFileReader
from komira_parquet.metadata_parser import parse_full_metadata
from komira_parquet_api.metadata import FileMetaData
from komira_parquet_scan.band_producer import BAND_MIN_ROWS, band_row_width, compute_band_rows, run_band_agg
from komira_parquet_scan.parquet_reader import ParquetReader
from komira_parquet_scan.subrg_agg_plan import SubrgAggPlan, resolve_reader_col_idx
from komira_runtime_paths import test_tmpdir
from komira_test_parquet_file import PT_INT32, TestColumn, TestFileLayout, write_parquet_file

comptime _FS = LocalFs[NoopSink]
comptime _ROWS = 300


struct _Sums(Movable, Deinitable):
    var keys: List[String]
    var sums: List[Float64]
    var counts: List[Int]

    def __init__(out self):
        self.keys = List[String]()
        self.sums = List[Float64]()
        self.counts = List[Int]()

    def add(mut self, key: String, v: Float64, n: Int):
        for i in range(len(self.keys)):
            if self.keys[i] == key:
                self.sums[i] += v
                self.counts[i] += n
                return
        self.keys.append(key)
        self.sums.append(v)
        self.counts.append(n)


struct _SumSink(BandSink, Movable, Deinitable):
    """SUM(column 1), COUNT(*) per string key (column 0, joined with column 2
    when `two_keys`), live rows only."""

    comptime WorkerLocal = _Sums

    var two_keys: Bool

    def __init__(out self, two_keys: Bool = False):
        self.two_keys = two_keys

    def init_worker_state(self) raises -> _Sums:
        return _Sums()

    def consume_band[o: Origin[mut=False]](self, mut local: _Sums, band: BandView[o]) raises:
        var vals = band.col_f64_span(1)
        for r in range(band.n_rows()):
            if not band.selection_live(r):
                continue
            var kb = band.resolve_string(0, r)
            var key = String()
            for i in range(kb.len()):
                key += chr(Int(kb.read_u8_at(i)))
            if self.two_keys:
                var kb2 = band.resolve_string(2, r)
                key += "|"
                for i in range(kb2.len()):
                    key += chr(Int(kb2.read_u8_at(i)))
            local.add(key, Float64(vals[r]), 1)

    def combine_workers(self, var locals: Slab[Optional[_Sums]], num_workers: Int) raises -> _Sums:
        var acc = _Sums()
        for w in range(num_workers):
            if locals[w]:
                var s = locals[w].take()
                for i in range(len(s.keys)):
                    acc.add(s.keys[i], s.sums[i], s.counts[i])
        return acc^

    def drain(self, var combined: _Sums, var output_schema: Schema) raises -> Slab[RecordBatch]:
        var sums = List[Scalar[DType.float64]]()
        var counts = List[Scalar[DType.int64]]()
        for i in range(len(combined.keys)):
            sums.append(combined.sums[i])
            counts.append(Int64(combined.counts[i]))
        var out = Slab[RecordBatch]()
        out.append(
            RecordBatch.from_typed_columns_3(
                output_schema^,
                Column.from_string(StringArray.from_strings(combined.keys)),
                Column.from_primitive[DType.float64](PrimitiveArray[DType.float64].from_list(sums^)),
                Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(counts^)),
            )
        )
        return out^


def _noop() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _runtime() raises -> PerCoreAsyncRuntime[NoopSink]:
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(4, _noop, BACKEND_MOCK)
    rt.start()
    return rt^


def _key(r: Int) -> String:
    return "g" + String(r % 4)


def _val(r: Int) -> Float64:
    return Float64(r % 9) * 0.5


def _file(name: String, null_row: Int) raises -> String:
    return _file_rgs(name, null_row, [100, 100, 100])


def _file_rgs(name: String, null_row: Int, rgs: List[Int]) raises -> String:
    """Row groups of `rgs` rows: k (string dictionary), v (DOUBLE PLAIN, pages
    of 30 rows), w (DOUBLE dictionary, = v), d (INT32 PLAIN, row), n (OPTIONAL
    DOUBLE = v, NULL at `null_row`), t (INT64 PLAIN, row), u (INT32 UINT_32
    dictionary, row % 4), nk (OPTIONAL string dictionary, NULL at row 150),
    ks (string PLAIN), k2 (string dictionary,
    "h" + row % 3)."""
    var path = test_tmpdir() + "/" + name + ".parquet"
    var k = List[String]()
    var v = List[Float64]()
    var d = List[Int]()
    var nn = List[Bool]()
    var nkn = List[Bool]()
    var u = List[Int]()
    var k2 = List[String]()
    var total = 0
    for g in range(len(rgs)):
        total += rgs[g]
    for r in range(total):
        k2.append("h" + String(r % 3))
        k.append(_key(r))
        v.append(_val(r))
        d.append(r)
        nn.append(r == null_row)
        nkn.append(r == 150)
        u.append(r % 4)
    var cols = List[TestColumn]()
    cols.append(TestColumn.string("k", k.copy()).dict_encoded())
    cols.append(TestColumn.float64("v", v.copy()).with_page_rows(30))
    cols.append(TestColumn.float64("w", v.copy()).dict_encoded())
    cols.append(TestColumn.int32("d", d.copy()))
    cols.append(TestColumn.float64("n", v^).with_nulls(nn^))
    cols.append(TestColumn.int64("t", d.copy()))
    var uc = TestColumn("u", PT_INT32, 13)
    uc.ints = u^
    cols.append(uc^.dict_encoded())
    cols.append(TestColumn.string("nk", k.copy()).with_nulls(nkn^).dict_encoded())
    cols.append(TestColumn.string("ks", k.copy()))
    cols.append(TestColumn.string("k2", k2^).dict_encoded())
    write_parquet_file(path, cols, TestFileLayout(rgs.copy(), 0, False))
    return path^


def _reader(path: String) raises -> ParquetReader[_FS]:
    var file = ParquetFileReader[_FS].open(path)
    var meta = parse_full_metadata(file.metadata_bytes.view_range_ro(0, file.metadata_length))
    return ParquetReader[_FS](_file=file^, _meta=ArcPointer[FileMetaData](meta^))


def _plan(
    reader: ParquetReader[_FS],
    value_col: String,
    with_d: Bool,
    key_col: String = "k",
    value_type: ArrowType = ArrowType.FLOAT64,
) -> SubrgAggPlan:
    var names: List[String] = [key_col, value_col]
    var types: List[ArrowType] = [ArrowType.STRING, value_type]
    if with_d:
        names.append("d")
        types.append(ArrowType.INT32)
    var idx = List[Int]()
    for i in range(len(names)):
        idx.append(resolve_reader_col_idx(reader, names[i]))
    return SubrgAggPlan(names^, idx^, types^, [0], True)


def _out_schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.STRING, False))
    sb.add_field(Field("sum", ArrowType.FLOAT64, False))
    sb.add_field(Field("count", ArrowType.INT64, False))
    return sb.build()


def _check(res: Slab[RecordBatch], cutoff: Int, rows: Int = _ROWS) raises:
    """`res` holds, per key, SUM(v) and COUNT(*) over rows `r <= cutoff` of the
    first `rows` rows."""
    assert_equal(len(res), 1)
    ref b = res[0]
    assert_equal(b.num_rows(), 4)
    for i in range(4):
        var key = b.column_at(0).as_string().get(i)
        var want_sum = 0.0
        var want_n = 0
        for r in range(min(rows, cutoff + 1)):
            if _key(r) == key:
                want_sum += _val(r)
                want_n += 1
        assert_equal(Float64(b.column_at(1).as_primitive[DType.float64]().get(i)), want_sum)
        assert_equal(Int(b.column_at(2).as_primitive[DType.int64]().get(i)), want_n)


def test_sums_per_key_on_every_value_arm() raises:
    var rt = _runtime()
    var host = reference_host_profile("test")
    for arm in range(3):
        var reader = _reader(_file("band" + String(arm), -1))
        var col = "w" if arm == 1 else "v"
        var plan = _plan(reader, col, False)
        var out = run_band_agg[_FS, _SumSink](
            rt.dispatcher(), CancellationToken.never(), _SumSink(), reader^, plan^, _out_schema(), 4, -1, 0, host,
            zero_copy=(arm == 2),
        )
        _check(out, _ROWS)
    rt.shutdown()


def test_the_band_carried_filter() raises:
    var rt = _runtime()
    var reader = _reader(_file("bandf", -1))
    var plan = _plan(reader, "v", True)
    var out = run_band_agg[_FS, _SumSink](
        rt.dispatcher(), CancellationToken.never(), _SumSink(), reader^, plan^, _out_schema(), 4, 2, 141,
        reference_host_profile("test"),
    )
    _check(out, 141)
    rt.shutdown()


def test_a_null_aborts_and_a_non_string_key_is_refused() raises:
    var rt = _runtime()
    var reader = _reader(_file("bandn", 150))
    var plan = _plan(reader, "n", False)
    var out = run_band_agg[_FS, _SumSink](
        rt.dispatcher(), CancellationToken.never(), _SumSink(), reader^, plan^, _out_schema(), 4, -1, 0,
        reference_host_profile("test"),
    )
    assert_equal(len(out), 0)
    var reader2 = _reader(_file("bandk", -1))
    var names: List[String] = ["d", "v"]
    var types: List[ArrowType] = [ArrowType.INT32, ArrowType.FLOAT64]
    var bad = SubrgAggPlan(names^, [3, 1], types^, [0], False)
    with assert_raises(contains="dictionary string"):
        _ = run_band_agg[_FS, _SumSink](
            rt.dispatcher(), CancellationToken.never(), _SumSink(), reader2^, bad^, _out_schema(), 4, -1, 0,
            reference_host_profile("test"),
        )
    rt.shutdown()


def _aborts(mut rt: PerCoreAsyncRuntime[NoopSink], var reader: ParquetReader[_FS], var plan: SubrgAggPlan) raises -> Bool:
    """True when the run is refused by a row group (an empty result)."""
    var out = run_band_agg[_FS, _SumSink](
        rt.dispatcher(), CancellationToken.never(), _SumSink(), reader^, plan^, _out_schema(), 4, -1, 0,
        reference_host_profile("test"),
    )
    return len(out) == 0


def _with_meta(name: String, meta: FileMetaData) raises -> ParquetReader[_FS]:
    var path = _file(name, -1)
    return ParquetReader[_FS](_file=ParquetFileReader[_FS].open(path), _meta=ArcPointer[FileMetaData](meta.copy()))


def test_a_nullable_key_and_a_plain_key_abort() raises:
    var rt = _runtime()
    var r2 = _reader(_file("bandnk", -1))
    var p2 = _plan(r2, "v", False, key_col="nk")
    assert_true(_aborts(rt, r2^, p2^))
    # A second key with a null, the driver clean.
    var r4 = _reader(_file("bandnk2", -1))
    var names: List[String] = ["k", "v", "nk"]
    var types: List[ArrowType] = [ArrowType.STRING, ArrowType.FLOAT64, ArrowType.STRING]
    var idx = List[Int]()
    for i in range(3):
        idx.append(resolve_reader_col_idx(r4, names[i]))
    var p4 = SubrgAggPlan(names^, idx^, types^, [0, 2], True)
    assert_true(_aborts(rt, r4^, p4^))
    var r3 = _reader(_file("bandks", -1))
    var p3 = _plan(r3, "v", False, key_col="ks")
    assert_true(_aborts(rt, r3^, p3^))
    rt.shutdown()


def test_a_relabelled_column_aborts_instead_of_folding_physical_values() raises:
    var rt = _runtime()
    # t is an INT64 carrying only the LogicalType TIMESTAMP, microseconds.
    var base = _reader(_file("bandts0", -1))
    var meta = base._meta[].copy()
    var ti = resolve_reader_col_idx(base, "t")
    meta.schema[ti + 1].logical_timestamp_unit = Optional[Int](2)
    var rt1 = _with_meta("bandts", meta)
    var p1 = _plan(rt1, "t", False, value_type=ArrowType.INT64)
    assert_true(_aborts(rt, rt1^, p1^))
    # The same INT64 column without the annotation folds (the run is not
    # refused for its type): the sink reads 8-byte values.
    var clean = _reader(_file("bandts1", -1))
    var pc = _plan(clean, "t", False, value_type=ArrowType.INT64)
    assert_false(_aborts(rt, clean^, pc^))
    # u is an unsigned dictionary column: its entries would be sign-extended.
    var r2 = _reader(_file("bandu", -1))
    var p2 = _plan(r2, "u", False, value_type=ArrowType.INT32)
    assert_true(_aborts(rt, r2^, p2^))
    rt.shutdown()


def test_a_zero_dictionary_offset_on_a_plain_column_still_folds() raises:
    var rt = _runtime()
    var base = _reader(_file("bandz0", -1))
    var meta = base._meta[].copy()
    var vi = resolve_reader_col_idx(base, "v")
    for g in range(len(meta.row_groups)):
        meta.row_groups[g].columns[vi].meta_data.dictionary_page_offset = Optional[Int](0)
    var reader = _with_meta("bandz", meta)
    var plan = _plan(reader, "v", False)
    var out = run_band_agg[_FS, _SumSink](
        rt.dispatcher(), CancellationToken.never(), _SumSink(), reader^, plan^, _out_schema(), 4, -1, 0,
        reference_host_profile("test"),
    )
    _check(out, _ROWS)
    rt.shutdown()


def test_a_short_row_group_and_a_wrong_row_count_abort() raises:
    var rt = _runtime()
    var base = _reader(_file("bands0", -1))
    # The last row group lacks the last chunk the schema names.
    var meta = base._meta[].copy()
    _ = meta.row_groups[2].columns.pop()
    var r1 = _with_meta("bands", meta)
    var p1 = _plan(r1, "v", False)
    assert_true(_aborts(rt, r1^, p1^))
    # A footer row count that disagrees with the columns.
    var meta2 = base._meta[].copy()
    meta2.row_groups[1].num_rows = 90
    var r2 = _with_meta("bandr", meta2)
    var p2 = _plan(r2, "v", False)
    assert_true(_aborts(rt, r2^, p2^))
    rt.shutdown()


def _host_with_l3(l3_bytes: Int) raises -> HostProfile:
    var host = reference_host_profile("test")
    host.hardware.l3_cache_bytes = l3_bytes
    return host^


def test_the_band_width() raises:
    var reader = _reader(_file("bandw", -1))
    var plan = _plan(reader, "v", True)
    assert_equal(band_row_width(plan), 4 + 8 + 4)
    var host = reference_host_profile("test")
    var w4 = compute_band_rows(plan, 4, host)
    assert_equal(w4, compute_band_rows(plan, 4, reference_host_profile("test")))
    # The width follows the host profile's L3 cache: half of it, split over
    # the workers, over the bytes of a row.
    assert_equal(compute_band_rows(plan, 4, _host_with_l3(256 * 1024)), 2048)
    assert_equal(compute_band_rows(plan, 4, _host_with_l3(512 * 1024)), 4096)
    assert_true(w4 >= BAND_MIN_ROWS)
    # More workers never widen the band; enough of them hit the floor.
    assert_true(compute_band_rows(plan, 64, host) <= w4)
    assert_equal(compute_band_rows(plan, 1 << 20, host), BAND_MIN_ROWS)


def _small_band_host() raises -> HostProfile:
    """An L3 so small that the band width is the 1,024-row floor."""
    return _host_with_l3(1024)


def test_row_groups_spanning_several_bands() raises:
    # 3 full bands and a short one in the first row group, 1 full and a short
    # band in the second.
    var rgs: List[Int] = [3 * BAND_MIN_ROWS + 7, BAND_MIN_ROWS + 476]
    var rows = 3 * BAND_MIN_ROWS + 7 + BAND_MIN_ROWS + 476
    var rt = _runtime()
    for arm in range(3):
        var reader = _reader(_file_rgs("bandm" + String(arm), -1, rgs))
        var col = "w" if arm == 1 else "v"
        var plan = _plan(reader, col, False)
        assert_equal(compute_band_rows(plan, 4, _small_band_host()), BAND_MIN_ROWS)
        var out = run_band_agg[_FS, _SumSink](
            rt.dispatcher(), CancellationToken.never(), _SumSink(), reader^, plan^, _out_schema(), 4, -1, 0,
            _small_band_host(), zero_copy=(arm == 2),
        )
        _check(out, rows, rows)
    # The filter carried over bands, in place and decoded.
    for zc in range(2):
        var reader = _reader(_file_rgs("bandmf" + String(zc), -1, rgs))
        var plan = _plan(reader, "v", True)
        var out = run_band_agg[_FS, _SumSink](
            rt.dispatcher(), CancellationToken.never(), _SumSink(), reader^, plan^, _out_schema(), 4, 2, 2777,
            _small_band_host(), zero_copy=(zc == 1),
        )
        _check(out, 2777, rows)
    rt.shutdown()


def test_the_filter_on_a_small_file_in_place() raises:
    var rt = _runtime()
    var reader = _reader(_file("bandfz", -1))
    var plan = _plan(reader, "v", True)
    var out = run_band_agg[_FS, _SumSink](
        rt.dispatcher(), CancellationToken.never(), _SumSink(), reader^, plan^, _out_schema(), 4, 2, 141,
        reference_host_profile("test"), zero_copy=True,
    )
    _check(out, 141)
    rt.shutdown()


def test_a_bad_filter_column_is_refused() raises:
    var rt = _runtime()
    # Out of range, a key column, and a non-INT32 column.
    var bad: List[Int] = [9, 0, 1]
    for i in range(3):
        var reader = _reader(_file("bandbf" + String(i), -1))
        var plan = _plan(reader, "v", True)
        with assert_raises(contains="filter column"):
            _ = run_band_agg[_FS, _SumSink](
                rt.dispatcher(), CancellationToken.never(), _SumSink(), reader^, plan^, _out_schema(), 4, bad[i], 5,
                reference_host_profile("test"),
            )
    rt.shutdown()


def _two_key_plan(reader: ParquetReader[_FS], second: String) -> SubrgAggPlan:
    var names: List[String] = ["k", "v", second]
    var types: List[ArrowType] = [ArrowType.STRING, ArrowType.FLOAT64, ArrowType.STRING]
    var idx = List[Int]()
    for i in range(3):
        idx.append(resolve_reader_col_idx(reader, names[i]))
    return SubrgAggPlan(names^, idx^, types^, [0, 2], True)


def test_two_clean_string_keys_fold_per_pair() raises:
    var rt = _runtime()
    var rgs: List[Int] = [BAND_MIN_ROWS + 300, 200]
    var rows = BAND_MIN_ROWS + 500
    for host_small in range(2):
        var reader = _reader(_file_rgs("bandk2" + String(host_small), -1, rgs))
        var plan = _two_key_plan(reader, "k2")
        var host = _small_band_host() if host_small == 1 else reference_host_profile("test")
        var out = run_band_agg[_FS, _SumSink](
            rt.dispatcher(), CancellationToken.never(), _SumSink(True), reader^, plan^, _out_schema(), 4, -1, 0, host,
        )
        assert_equal(len(out), 1)
        ref b = out[0]
        assert_equal(b.num_rows(), 12)
        for i in range(12):
            var key = b.column_at(0).as_string().get(i)
            var want_sum = 0.0
            var want_n = 0
            for r in range(rows):
                if _key(r) + "|h" + String(r % 3) == key:
                    want_sum += _val(r)
                    want_n += 1
            assert_true(want_n > 0)
            assert_equal(Float64(b.column_at(1).as_primitive[DType.float64]().get(i)), want_sum)
            assert_equal(Int(b.column_at(2).as_primitive[DType.int64]().get(i)), want_n)
    rt.shutdown()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

# The sub-row-group aggregate on files written by komira_test_parquet_file,
# run on a 4-worker runtime into a test sink that computes, per group,
# COUNT(*) and SUM / MIN / MAX of each value column with DuckDB's rules: a
# NULL key is its own group, NULL values are skipped, NaN is the largest
# float. The expected lines are computed from the rows written.
#   - every value arm (PLAIN INT32 widened to INT64, INT64 dictionary, PLAIN
#     and dictionary DOUBLE with NaN) under an INT64, INT32, composite and
#     STRING dictionary key; each chunk's columns carry the schema's types,
#     and the chunks are the cursor route's (two per 40,000-row group);
#   - a PLAIN key and a NULL key met in a row group's first chunk take the
#     whole-row-group decode, the NULL group included;
#   - a NULL met after a chunk was folded abandons the run (empty), as does
#     any refused row group under a STRING key;
#   - filters: the key keep-table, the gathered survivors, the resolved
#     filter for other shapes, the statistics prune (an all-pruned file is an
#     answer with no group), and a STRING key's all / none / partial chunks,
#     with an arithmetic predicate on a numeric key beside the STRING key;
#   - the chunk type rule (types and the footer's nullability), an OPTIONAL
#     column without a NULL staying on the cursors, columns the cursors refuse
#     (a timestamp-only annotation, an unsigned key) and a footer count the
#     chunks disagree with decoded whole with the same answer, a zero
#     dictionary offset on a PLAIN column, and plans the route refuses.

from std.collections import Dict
from std.math import isnan
from std.memory import ArcPointer, Pointer
from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from komira_async_api.token import CancellationToken
from komira_buffer.heap_region import HeapRegion
from komira_collections.slab import Slab
from komira_fs.local_fs import LocalFs
from komira_parquet.file_reader import ParquetFileReader
from komira_parquet.metadata_parser import parse_full_metadata
from komira_parquet_api.metadata import FileMetaData
from komira_parquet_scan.parquet_reader import ParquetReader
from komira_parquet_scan.rg_prune_counter import rg_prune_setup_pruned
from komira_parquet_scan.scan_chunk_sink import ScanChunkSink
from komira_parquet_scan.subrg_agg_chunk_schema import subrg_agg_build_chunk_schema, subrg_agg_chunk_arrow_type
from komira_parquet_scan.subrg_agg_executor import run_subrg_agg
from komira_parquet_scan.subrg_agg_plan import SubrgAggPlan, resolve_reader_col_idx
from komira_parquet_scan.subrg_filter_gather import (
    subrg_filter_gathered_count,
    subrg_filter_keylut_count,
    subrg_filter_skipped_count,
)
from komira_plan_expr.expr import BIN_ADD, BIN_AND, BIN_EQ, BIN_GE, BIN_LT, UN_NOT, Expr
from komira_plan_expr.scalar_value import ScalarValue
from komira_runtime_paths import test_tmpdir
from komira_test_parquet_file import TestColumn, TestFileLayout, write_parquet_file

comptime _FS = LocalFs[NoopSink]
comptime _ROWS = 100_000


# -----------------------------------------------------------------------------
# The test sink
# -----------------------------------------------------------------------------


def _fmt(x: Float64) -> String:
    return "NaN" if isnan(x) else String(x)


@always_inline
def _f_lt(a: Float64, b: Float64) -> Bool:
    """DuckDB's float order: NaN is the largest value."""
    if isnan(a):
        return False
    if isnan(b):
        return True
    return a < b


struct _Acc(Movable, Deinitable):
    """Per group: the row count, and per value column the non-NULL count,
    sum, min and max (flattened `g * nv + j`)."""

    var nv: Int
    var index: Dict[String, Int]
    var keys: List[String]
    var counts: List[Int]
    var n: List[Int]
    var sums: List[Float64]
    var mins: List[Float64]
    var maxs: List[Float64]
    var chunks: Int
    var type_errors: Int

    def __init__(out self, nv: Int):
        self.nv = nv
        self.index = Dict[String, Int]()
        self.keys = List[String]()
        self.counts = List[Int]()
        self.n = List[Int]()
        self.sums = List[Float64]()
        self.mins = List[Float64]()
        self.maxs = List[Float64]()
        self.chunks = 0
        self.type_errors = 0

    def group(mut self, key: String) raises -> Int:
        if key in self.index:
            return self.index[key]
        var g = len(self.keys)
        self.index[key] = g
        self.keys.append(key)
        self.counts.append(0)
        for _ in range(self.nv):
            self.n.append(0)
            self.sums.append(0.0)
            self.mins.append(0.0)
            self.maxs.append(0.0)
        return g

    def add_value(mut self, g: Int, j: Int, x: Float64):
        var i = g * self.nv + j
        if self.n[i] == 0:
            self.mins[i] = x
            self.maxs[i] = x
        else:
            if _f_lt(x, self.mins[i]):
                self.mins[i] = x
            if _f_lt(self.maxs[i], x):
                self.maxs[i] = x
        self.n[i] += 1
        self.sums[i] += x

    def merge(mut self, other: _Acc) raises:
        self.chunks += other.chunks
        self.type_errors += other.type_errors
        for og in range(len(other.keys)):
            var g = self.group(other.keys[og])
            self.counts[g] += other.counts[og]
            for j in range(self.nv):
                var oi = og * self.nv + j
                var i = g * self.nv + j
                if other.n[oi] == 0:
                    continue
                if self.n[i] == 0:
                    self.mins[i] = other.mins[oi]
                    self.maxs[i] = other.maxs[oi]
                else:
                    if _f_lt(other.mins[oi], self.mins[i]):
                        self.mins[i] = other.mins[oi]
                    if _f_lt(self.maxs[i], other.maxs[oi]):
                        self.maxs[i] = other.maxs[oi]
                self.n[i] += other.n[oi]
                self.sums[i] += other.sums[oi]

    def lines(self) -> List[String]:
        var out = List[String]()
        for g in range(len(self.keys)):
            var line = self.keys[g] + "|" + String(self.counts[g])
            for j in range(self.nv):
                var i = g * self.nv + j
                if self.n[i] == 0:
                    line += "|NULL|NULL|NULL"
                else:
                    line += "|" + _fmt(self.sums[i]) + "|" + _fmt(self.mins[i]) + "|" + _fmt(self.maxs[i])
            out.append(line)
        sort(out)
        return out^


def _key_strings(col: Column[HeapRegion], n: Int) raises -> List[String]:
    var out = List[String](capacity=n)
    if col.is_string_dict():
        var table = List[String]()
        for e in range(col.dict_size()):
            var bv = col.string_dict_value_at(e)
            var raw = List[UInt8](capacity=bv.len())
            for i in range(bv.len()):
                raw.append(bv.read_u8_at(i))
            table.append(String(unsafe_from_utf8=Span(raw)))
        for r in range(n):
            out.append("NULL" if col.is_null_at(r) else table[col.string_dict_code_at(r)])
        return out^
    if col.is_numeric_dict():
        for r in range(n):
            out.append("NULL" if col.is_null_at(r) else String(col.dict_value_i64(col.dict_code_at(r))))
        return out^
    if col.arrow_type == ArrowType.STRING:
        var a = col.as_string()
        for r in range(n):
            out.append("NULL" if col.is_null_at(r) else a.get(r))
        return out^
    var flat = _values(col, n)
    for r in range(n):
        out.append("NULL" if col.is_null_at(r) else String(Int(flat[r])))
    return out^


def _values(col: Column[HeapRegion], n: Int) raises -> List[Float64]:
    """The column as Float64 (a NULL row's slot is 0)."""
    var out = List[Float64](capacity=n)
    if col.is_numeric_dict():
        return _values(col.resolve_numeric_dict_to_flat(), n)
    if col.arrow_type == ArrowType.INT64:
        var a = col.as_primitive[DType.int64]()
        for r in range(n):
            out.append(0.0 if col.is_null_at(r) else Float64(a.get(r)))
    elif col.arrow_type == ArrowType.INT32:
        var a = col.as_primitive[DType.int32]()
        for r in range(n):
            out.append(0.0 if col.is_null_at(r) else Float64(a.get(r)))
    elif col.arrow_type == ArrowType.UINT32:
        var a = col.as_primitive[DType.uint32]()
        for r in range(n):
            out.append(0.0 if col.is_null_at(r) else Float64(a.get(r)))
    elif col.arrow_type == ArrowType.TIMESTAMP_US:
        var a = col.as_primitive[DType.int64]()
        for r in range(n):
            out.append(0.0 if col.is_null_at(r) else Float64(a.get(r)))
    elif col.arrow_type == ArrowType.FLOAT64:
        var a = col.as_primitive[DType.float64]()
        for r in range(n):
            out.append(0.0 if col.is_null_at(r) else a.get(r))
    else:
        raise Error("test sink: unexpected value column type " + String(col.arrow_type))
    return out^


struct _GroupSink(ScanChunkSink, Movable, Deinitable):
    """Groups by the key columns `keys` (joined with ","), aggregates the
    value columns `vals`."""

    comptime WorkerLocal = _Acc
    var keys: List[Int]
    var vals: List[Int]

    def __init__(out self, var keys: List[Int], var vals: List[Int]):
        self.keys = keys^
        self.vals = vals^

    def init_worker_state(self) raises -> _Acc:
        return _Acc(len(self.vals))

    def consume_chunk[o_local: Origin[mut=True]](
        self, ref [o_local] local: _Acc, rg_idx: Int, chunk_idx: Int, var batch: RecordBatch
    ) raises:
        local.chunks += 1
        var n = batch.num_rows()
        for c in range(batch.num_columns()):
            ref col = batch.column_at(c)
            if not col.is_dictionary() and not col.is_string_dict() and col.arrow_type != batch.schema.field_at(c).arrow_type:
                local.type_errors += 1
            # The footer's nullability (kn and sn are OPTIONAL, the rest
            # REQUIRED), and no NULL under a field that says it holds none.
            var fname = batch.schema.field_name(c)
            if batch.schema.field_nullable(c) != (fname == "kn" or fname == "sn"):
                local.type_errors += 1
            if not batch.schema.field_nullable(c):
                for r in range(n):
                    if col.is_null_at(r):
                        local.type_errors += 1
        var key_cols = List[List[String]]()
        for k in range(len(self.keys)):
            key_cols.append(_key_strings(batch.column_at(self.keys[k]), n))
        var val_cols = List[List[Float64]]()
        for j in range(len(self.vals)):
            val_cols.append(_values(batch.column_at(self.vals[j]), n))
        for r in range(n):
            var key = key_cols[0][r]
            for k in range(1, len(self.keys)):
                key += "," + key_cols[k][r]
            var g = local.group(key)
            local.counts[g] += 1
            for j in range(len(self.vals)):
                if not batch.column_at(self.vals[j]).is_null_at(r):
                    local.add_value(g, j, val_cols[j][r])

    def combine_workers[disp_o: Origin[mut=True]](
        self,
        var locals: Slab[Optional[_Acc]],
        num_workers: Int,
        dispatcher_ptr: Pointer[LocalDispatcher[NoopSink], disp_o],
        var cancel_token: CancellationToken,
    ) raises -> _Acc:
        var acc = _Acc(len(self.vals))
        for w in range(num_workers):
            if locals[w]:
                var one = locals[w].take()
                acc.merge(one)
        return acc^

    def drain[disp_o: Origin[mut=True]](
        self,
        var combined: _Acc,
        var output_schema: Schema,
        dispatcher_ptr: Pointer[LocalDispatcher[NoopSink], disp_o],
        var cancel_token: CancellationToken,
    ) raises -> Slab[RecordBatch]:
        var lines = combined.lines()
        lines.insert(0, "#chunks=" + String(combined.chunks) + " type_errors=" + String(combined.type_errors))
        var rbb = RecordBatchBuilder.with_capacity(1)
        rbb.add_column(Column.from_string(StringArray.from_strings(lines)))
        var out = Slab[RecordBatch]()
        out.append(rbb.build(output_schema^))
        return out^


# -----------------------------------------------------------------------------
# Files, plans and the expected lines
# -----------------------------------------------------------------------------


def _f(r: Int) -> Float64:
    if r % 1000 == 3:
        return Float64(0.0) / Float64(0.0)
    return Float64(r % 11) * 0.5


def _file(name: String, rgs: List[Int], null_row: Int) raises -> String:
    """Columns k (INT64 dictionary, 100 + r % 5), k32 (INT32 dictionary,
    r % 3), s (STRING dictionary, "s" + r % 4), v (INT32 PLAIN, r % 1000),
    w (INT64 dictionary, (r % 7) * 10), f (DOUBLE PLAIN, (r % 11) / 2, NaN
    where r % 1000 == 3: only in group s3), fd (DOUBLE dictionary, = f),
    kn (OPTIONAL INT64 dictionary = k, NULL at `null_row`), kp (INT64 PLAIN,
    r % 5), sn (OPTIONAL STRING dictionary = s, NULL at `null_row`); kn and sn
    in pages of 10,000 rows."""
    var path = test_tmpdir() + "/" + name + ".parquet"
    var total = 0
    for i in range(len(rgs)):
        total += rgs[i]
    var k = List[Int]()
    var k32 = List[Int]()
    var s = List[String]()
    var v = List[Int]()
    var w = List[Int]()
    var f = List[Float64]()
    var kp = List[Int]()
    var nulls = List[Bool]()
    for r in range(total):
        k.append(100 + r % 5)
        k32.append(r % 3)
        s.append("s" + String(r % 4))
        v.append(r % 1000)
        w.append((r % 7) * 10)
        f.append(_f(r))
        kp.append(r % 5)
        nulls.append(r == null_row)
    var cols = List[TestColumn]()
    cols.append(TestColumn.int64("k", k.copy()).dict_encoded())
    cols.append(TestColumn.int32("k32", k32^).dict_encoded())
    cols.append(TestColumn.string("s", s.copy()).dict_encoded())
    cols.append(TestColumn.int32("v", v^))
    cols.append(TestColumn.int64("w", w^).dict_encoded())
    cols.append(TestColumn.float64("f", f.copy()))
    cols.append(TestColumn.float64("fd", f^).dict_encoded())
    cols.append(TestColumn.int64("kn", k^).dict_encoded().with_nulls(nulls.copy()).with_page_rows(10_000))
    cols.append(TestColumn.int64("kp", kp^))
    cols.append(TestColumn.string("sn", s^).dict_encoded().with_nulls(nulls^).with_page_rows(10_000))
    write_parquet_file(path, cols, TestFileLayout(rgs.copy(), 0, False))
    return path^


def _rgs() -> List[Int]:
    return [40_000, 40_000, 20_000]


def _reader(path: String) raises -> ParquetReader[_FS]:
    var file = ParquetFileReader[_FS].open(path)
    var meta = parse_full_metadata(file.metadata_bytes.view_range_ro(0, file.metadata_length))
    return ParquetReader[_FS](_file=file^, _meta=ArcPointer[FileMetaData](meta^))


def _type_of(name: String) -> ArrowType:
    if name == "s" or name == "sn":
        return ArrowType.STRING
    if name == "k32" or name == "v":
        return ArrowType.INT32
    if name == "f" or name == "fd":
        return ArrowType.FLOAT64
    return ArrowType.INT64


def _plan(reader: ParquetReader[_FS], names: List[String], n_keys: Int) -> SubrgAggPlan:
    """The first `n_keys` names are the group keys."""
    var idx = List[Int]()
    var types = List[ArrowType]()
    var has_string = False
    for i in range(len(names)):
        idx.append(resolve_reader_col_idx(reader, names[i]))
        types.append(_type_of(names[i]))
        if i < n_keys and _type_of(names[i]) == ArrowType.STRING:
            has_string = True
    var keys = List[Int]()
    for i in range(n_keys):
        keys.append(i)
    return SubrgAggPlan(names.copy(), idx^, types^, keys^, has_string)


def _key_of(name: String, r: Int, null_row: Int) -> String:
    if (name == "kn" or name == "sn") and r == null_row:
        return "NULL"
    if name == "k" or name == "kn":
        return String(100 + r % 5)
    if name == "k32":
        return String(r % 3)
    if name == "kp":
        return String(r % 5)
    return "s" + String(r % 4)


def _val_of(name: String, r: Int) -> Float64:
    if name == "v":
        return Float64(r % 1000)
    if name == "w":
        return Float64((r % 7) * 10)
    return _f(r)


def _expected(names: List[String], n_keys: Int, keep: List[Bool], null_row: Int) raises -> List[String]:
    """The lines `_GroupSink` drains for the rows `keep` marks."""
    var acc = _Acc(len(names) - n_keys)
    for r in range(len(keep)):
        if not keep[r]:
            continue
        var key = _key_of(names[0], r, null_row)
        for k in range(1, n_keys):
            key += "," + _key_of(names[k], r, null_row)
        var g = acc.group(key)
        acc.counts[g] += 1
        for j in range(n_keys, len(names)):
            acc.add_value(g, j - n_keys, _val_of(names[j], r))
    return acc.lines()


def _all_rows() -> List[Bool]:
    var keep = List[Bool](capacity=_ROWS)
    for _ in range(_ROWS):
        keep.append(True)
    return keep^


def _noop() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _runtime() raises -> PerCoreAsyncRuntime[NoopSink]:
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(4, _noop, BACKEND_MOCK)
    rt.start()
    return rt^


def _out_schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("line", ArrowType.STRING, False))
    return sb.build()


def _run(
    mut rt: PerCoreAsyncRuntime[NoopSink], path: String, names: List[String], n_keys: Int, var pred: Optional[Expr]
) raises -> Slab[RecordBatch]:
    return _run_on(rt, _reader(path), names, n_keys, pred^)


def _run_on(
    mut rt: PerCoreAsyncRuntime[NoopSink],
    var reader: ParquetReader[_FS],
    names: List[String],
    n_keys: Int,
    var pred: Optional[Expr],
) raises -> Slab[RecordBatch]:
    var plan = _plan(reader, names, n_keys)
    var schema = subrg_agg_build_chunk_schema(reader, plan)
    var has_pred = pred.__bool__()
    var keys = List[Int]()
    for i in range(n_keys):
        keys.append(i)
    var vals = List[Int]()
    for i in range(n_keys, len(names)):
        vals.append(i)
    return run_subrg_agg[_FS, _GroupSink](
        rt.dispatcher(), CancellationToken.never(), _GroupSink(keys^, vals^), reader^, plan^, schema^,
        has_pred, pred^, _out_schema(), 4,
    )


def _lines(res: Slab[RecordBatch]) raises -> List[String]:
    """The drained lines, the `#chunks` header first."""
    assert_equal(len(res), 1)
    var a = res[0].column_at(0).as_string()
    var out = List[String]()
    for i in range(res[0].num_rows()):
        out.append(a.get(i))
    return out^


def _check(res: Slab[RecordBatch], want: List[String], header: String) raises:
    var got = _lines(res)
    assert_equal(got[0], header)
    assert_equal(len(got) - 1, len(want))
    for i in range(len(want)):
        assert_equal(got[i + 1], want[i])


def _lit(v: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int(v))


# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------


def test_every_value_arm_under_each_key_kind() raises:
    var rt = _runtime()
    var path = _file("sagg_arms", _rgs(), -1)
    var vals: List[String] = ["v", "w", "f", "fd"]
    var key_sets: List[List[String]] = [["k"], ["k32"], ["k32", "k"], ["s"]]
    for ks in range(len(key_sets)):
        var names = key_sets[ks].copy()
        for j in range(len(vals)):
            names.append(vals[j])
        var nk = len(key_sets[ks])
        var res = _run(rt, path, names, nk, None)
        # Two chunks per 40,000-row group and one for the last: the cursor
        # route, every column of the type its schema field names.
        _check(res, _expected(names, nk, _all_rows(), -1), "#chunks=5 type_errors=0")
    # DuckDB's float order, spelled out: only s3 holds NaN, which is its MAX
    # (and makes its SUM NaN); every group's MIN is 0.
    var names: List[String] = ["s", "f"]
    var got = _lines(_run(rt, path, names, 1, None))
    assert_equal(got[1], "s0|25000|62497.5|0.0|5.0")
    assert_equal(got[4], "s3|25000|NaN|0.0|NaN")
    rt.shutdown()


def test_the_chunk_type_rule() raises:
    assert_true(subrg_agg_chunk_arrow_type(ArrowType.INT32, False) == ArrowType.INT64)
    assert_true(subrg_agg_chunk_arrow_type(ArrowType.INT64, False) == ArrowType.INT64)
    assert_true(subrg_agg_chunk_arrow_type(ArrowType.FLOAT32, False) == ArrowType.FLOAT64)
    assert_true(subrg_agg_chunk_arrow_type(ArrowType.FLOAT64, False) == ArrowType.FLOAT64)
    assert_true(subrg_agg_chunk_arrow_type(ArrowType.STRING, False) == ArrowType.STRING)
    assert_true(subrg_agg_chunk_arrow_type(ArrowType.INT32, True) == ArrowType.INT32)
    assert_true(subrg_agg_chunk_arrow_type(ArrowType.STRING, True) == ArrowType.STRING)
    var reader = _reader(_file("sagg_rule", [1_000], -1))
    var names: List[String] = ["k32", "v", "f"]
    var schema = subrg_agg_build_chunk_schema(reader, _plan(reader, names, 1))
    assert_true(schema.field_at(0).arrow_type == ArrowType.INT32)
    assert_true(schema.field_at(1).arrow_type == ArrowType.INT64)
    assert_true(schema.field_at(2).arrow_type == ArrowType.FLOAT64)
    assert_equal(schema.field_at(1).name, "v")
    # Nullability is the footer's: REQUIRED columns are not nullable, an
    # OPTIONAL key and an OPTIONAL value are, whether or not they hold a null.
    for i in range(3):
        assert_false(schema.field_at(i).nullable)
    var opt_names: List[String] = ["kn", "k32", "sn"]
    var opt = subrg_agg_build_chunk_schema(reader, _plan(reader, opt_names, 1))
    assert_true(opt.field_at(0).nullable)
    assert_false(opt.field_at(1).nullable)
    assert_true(opt.field_at(2).nullable)


def test_plain_key_and_early_null_take_the_whole_row_group() raises:
    var rt = _runtime()
    # kp is PLAIN: every row group is decoded whole, one chunk each.
    var path = _file("sagg_plain", _rgs(), -1)
    var names: List[String] = ["kp", "v", "f"]
    _check(_run(rt, path, names, 1, None), _expected(names, 1, _all_rows(), -1), "#chunks=3 type_errors=0")
    # A NULL key in row group 0's first chunk: that row group is decoded
    # whole and the NULL row is its own group; the others take the cursors.
    var npath = _file("sagg_null5", _rgs(), 5)
    var nnames: List[String] = ["kn", "v", "fd"]
    var res = _run(rt, npath, nnames, 1, None)
    var want = _expected(nnames, 1, _all_rows(), 5)
    _check(res, want, "#chunks=4 type_errors=0")
    assert_equal(want[5], "NULL|1|5.0|5.0|5.0|2.5|2.5|2.5")
    rt.shutdown()


def test_a_late_null_or_a_string_key_refusal_abandons_the_run() raises:
    var rt = _runtime()
    # Row 35,000 is in row group 0's second chunk: its first chunk was
    # already folded, so the run is abandoned rather than counted twice.
    var path = _file("sagg_null35k", _rgs(), 35_000)
    var names: List[String] = ["kn", "v"]
    assert_equal(len(_run(rt, path, names, 1, None)), 0)
    # A STRING key refused anywhere, even in a first chunk, abandons it.
    var spath = _file("sagg_snull5", _rgs(), 5)
    var snames: List[String] = ["sn", "v"]
    assert_equal(len(_run(rt, spath, snames, 1, None)), 0)
    # No row group: nothing to fold.
    var epath = test_tmpdir() + "/sagg_empty.parquet"
    var e = List[TestColumn]()
    e.append(TestColumn.int64("k", List[Int]()).dict_encoded())
    e.append(TestColumn.int32("v", List[Int]()))
    write_parquet_file(epath, e, TestFileLayout.single())
    var enames: List[String] = ["k", "v"]
    assert_equal(len(_run(rt, epath, enames, 1, None)), 0)
    rt.shutdown()


def _keep(pred_k_min: Int, v_max: Int) -> List[Bool]:
    """Rows with k >= `pred_k_min` and v < `v_max`."""
    var keep = List[Bool](capacity=_ROWS)
    for r in range(_ROWS):
        keep.append(100 + r % 5 >= pred_k_min and r % 1000 < v_max)
    return keep^


def test_filters_on_each_arm() raises:
    var rt = _runtime()
    var path = _file("sagg_filter", _rgs(), -1)
    var k_ge = Expr.binary(BIN_GE, Expr.col_ref("k"), _lit(102))
    var v_lt = Expr.binary(BIN_LT, Expr.col_ref("v"), _lit(500))
    # The key keep-table: COUNT(*) GROUP BY k WHERE k >= 102, each chunk's
    # codes compacted (no value column to fill).
    var lut0 = subrg_filter_keylut_count()
    var only_k: List[String] = ["k"]
    _check(_run(rt, path, only_k, 1, k_ge.copy()), _expected(only_k, 1, _keep(102, 1000), -1), "#chunks=5 type_errors=0")
    assert_equal(subrg_filter_keylut_count() - lut0, 5)
    # Gathered survivors of a `column <cmp> literal` tree.
    var g0 = subrg_filter_gathered_count()
    var names: List[String] = ["k", "v", "f"]
    var both = Expr.binary(BIN_AND, k_ge.copy(), v_lt.copy())
    _check(_run(rt, path, names, 1, both^), _expected(names, 1, _keep(102, 500), -1), "#chunks=5 type_errors=0")
    assert_equal(subrg_filter_gathered_count() - g0, 5)
    # Other shapes over the dictionary key: NOT, and arithmetic.
    var not_lt = Expr.unary(UN_NOT, Expr.binary(BIN_LT, Expr.col_ref("k"), _lit(102)))
    _check(_run(rt, path, names, 1, not_lt^), _expected(names, 1, _keep(102, 1000), -1), "#chunks=5 type_errors=0")
    var plus = Expr.binary(BIN_GE, Expr.binary(BIN_ADD, Expr.col_ref("k"), _lit(0)), _lit(102))
    _check(_run(rt, path, names, 1, plus^), _expected(names, 1, _keep(102, 1000), -1), "#chunks=5 type_errors=0")
    rt.shutdown()


def test_the_statistics_prune_and_an_empty_answer() raises:
    var rt = _runtime()
    var path = _file("sagg_prune", _rgs(), -1)
    var names: List[String] = ["k", "v"]
    # v is at most 999 in every row group: all three are pruned, and the
    # answer is a drained batch with no group, not an abandoned run.
    var p0 = rg_prune_setup_pruned()
    var none = Expr.binary(BIN_GE, Expr.col_ref("v"), _lit(5000))
    _check(_run(rt, path, names, 1, none^), List[String](), "#chunks=0 type_errors=0")
    assert_equal(rg_prune_setup_pruned() - p0, 3)
    rt.shutdown()


def test_a_string_key_chunk_folds_whole_skips_or_abandons() raises:
    var rt = _runtime()
    var path = _file("sagg_sfilter", _rgs(), -1)
    var names: List[String] = ["s", "v"]
    var all_pass = Expr.binary(BIN_GE, Expr.col_ref("v"), _lit(0))
    _check(_run(rt, path, names, 1, all_pass^), _expected(names, 1, _all_rows(), -1), "#chunks=5 type_errors=0")
    var s0 = subrg_filter_skipped_count()
    var none_pass = Expr.binary(BIN_LT, Expr.binary(BIN_ADD, Expr.col_ref("v"), _lit(0)), _lit(-1))
    _check(_run(rt, path, names, 1, none_pass^), List[String](), "#chunks=0 type_errors=0")
    assert_true(subrg_filter_skipped_count() - s0 >= 1)
    var partial = Expr.binary(BIN_LT, Expr.col_ref("v"), _lit(500))
    assert_equal(len(_run(rt, path, names, 1, partial^)), 0)
    var on_key = Expr.binary(BIN_EQ, Expr.col_ref("s"), Expr.literal(ScalarValue.from_string("s1")))
    assert_equal(len(_run(rt, path, names, 1, on_key^)), 0)
    rt.shutdown()


def test_a_string_and_numeric_key_chunk_evaluates_arithmetic_on_the_numeric_key() raises:
    # Keys [s, k]: the k column stays a numeric dictionary in the chunk, and
    # `k + 0` is not a `column <cmp> literal` leaf, so the selection must be
    # computed on k's flat values. Every row passes `k + 0 >= 100` (folded,
    # DuckDB's groups), none passes `k + 0 < 100` (an empty answer), and
    # `k + 0 >= 102` keeps part of each chunk (the run is abandoned).
    var rt = _runtime()
    var path = _file("sagg_sk_arith", _rgs(), -1)
    var names: List[String] = ["s", "k", "v"]
    var k_plus = Expr.binary(BIN_ADD, Expr.col_ref("k"), _lit(0))
    var all_pass = Expr.binary(BIN_GE, k_plus.copy(), _lit(100))
    _check(_run(rt, path, names, 2, all_pass^), _expected(names, 2, _all_rows(), -1), "#chunks=5 type_errors=0")
    var none_pass = Expr.binary(BIN_LT, k_plus.copy(), _lit(100))
    _check(_run(rt, path, names, 2, none_pass^), List[String](), "#chunks=0 type_errors=0")
    var partial = Expr.binary(BIN_GE, k_plus^, _lit(102))
    assert_equal(len(_run(rt, path, names, 2, partial^)), 0)
    rt.shutdown()


def test_an_optional_column_without_a_null_stays_on_the_cursors() raises:
    # kn and sn are OPTIONAL but hold no NULL: the cursors take them (five
    # chunks), the aggregate equals the rows written, and every chunk's field
    # is nullable as the footer says (the sink counts a mismatch).
    var rt = _runtime()
    var path = _file("sagg_optional", _rgs(), -1)
    var knames: List[String] = ["kn", "v", "fd"]
    _check(_run(rt, path, knames, 1, None), _expected(knames, 1, _all_rows(), -1), "#chunks=5 type_errors=0")
    var snames: List[String] = ["sn", "v", "f"]
    _check(_run(rt, path, snames, 1, None), _expected(snames, 1, _all_rows(), -1), "#chunks=5 type_errors=0")
    var filtered = Expr.binary(BIN_GE, Expr.col_ref("kn"), _lit(102))
    var fnames: List[String] = ["kn", "v"]
    _check(
        _run(rt, path, fnames, 1, filtered^), _expected(fnames, 1, _keep(102, 1000), -1), "#chunks=5 type_errors=0"
    )
    rt.shutdown()


def _patched(name: String) raises -> ParquetReader[_FS]:
    """The `_file()` footer (columns k, k32, s, v, w, f, fd, kn, kp, sn =
    schema elements 1 to 10) with w carrying only the LogicalType TIMESTAMP,
    k32 annotated UINT_32 and v (it is PLAIN) storing dictionary offset 0."""
    var path = _file(name, _rgs(), -1)
    var meta = _reader(path)._meta[].copy()
    meta.schema[5].logical_timestamp_unit = Optional[Int](2)
    meta.schema[2].converted_type = Optional[Int](13)
    for rg in range(3):
        meta.row_groups[rg].columns[3].meta_data.dictionary_page_offset = Optional[Int](0)
    return ParquetReader[_FS](_file=ParquetFileReader[_FS].open(path), _meta=ArcPointer[FileMetaData](meta^))


def test_what_the_cursors_refuse_is_decoded_whole_with_the_same_answer() raises:
    var rt = _runtime()
    # v with a zero dictionary offset stays on the cursors (five chunks).
    var vnames: List[String] = ["k", "v", "f"]
    _check(
        _run_on(rt, _patched("sagg_p1"), vnames, 1, None), _expected(vnames, 1, _all_rows(), -1),
        "#chunks=5 type_errors=0",
    )
    # A timestamp-only annotation on a value column: every row group is
    # decoded whole (three chunks), and the sums are those of the rows.
    var wnames: List[String] = ["k", "w", "v"]
    _check(
        _run_on(rt, _patched("sagg_p2"), wnames, 1, None), _expected(wnames, 1, _all_rows(), -1),
        "#chunks=3 type_errors=0",
    )
    # An unsigned INT32 key: the same.
    var knames: List[String] = ["k32", "v"]
    _check(
        _run_on(rt, _patched("sagg_p3"), knames, 1, None), _expected(knames, 1, _all_rows(), -1),
        "#chunks=3 type_errors=0",
    )
    # With a filter on top of the relabelled column.
    var w_lt = Expr.binary(BIN_LT, Expr.col_ref("w"), _lit(40))
    var keep = List[Bool](capacity=_ROWS)
    for r in range(_ROWS):
        keep.append((r % 7) * 10 < 40)
    _check(
        _run_on(rt, _patched("sagg_p4"), wnames, 1, w_lt^), _expected(wnames, 1, keep, -1), "#chunks=3 type_errors=0"
    )
    rt.shutdown()


def test_a_footer_count_the_chunks_disagree_with_is_decoded_whole() raises:
    var rt = _runtime()
    # Row group 0 claims one row fewer than its chunks hold: it is declined
    # before any chunk is folded and decoded whole (one chunk), the other two
    # row groups take the cursors (two and one).
    var path = _file("sagg_count", _rgs(), -1)
    var meta = _reader(path)._meta[].copy()
    meta.row_groups[0].num_rows = 39_999
    var reader = ParquetReader[_FS](_file=ParquetFileReader[_FS].open(path), _meta=ArcPointer[FileMetaData](meta^))
    var names: List[String] = ["k", "v"]
    var res = _run_on(rt, reader^, names, 1, None)
    _check(res, _expected(names, 1, _all_rows(), -1), "#chunks=4 type_errors=0")
    # A STRING key declined that way abandons the run, as any refusal does.
    var meta2 = _reader(path)._meta[].copy()
    meta2.row_groups[0].columns[3].meta_data.num_values = 39_999
    var reader2 = ParquetReader[_FS](_file=ParquetFileReader[_FS].open(path), _meta=ArcPointer[FileMetaData](meta2^))
    var snames: List[String] = ["s", "v"]
    assert_equal(len(_run_on(rt, reader2^, snames, 1, None)), 0)
    rt.shutdown()


def test_plans_the_route_refuses() raises:
    var rt = _runtime()
    var path = _file("sagg_refuse", [1_000], -1)
    with assert_raises(contains="is STRING but not a group key"):
        var names: List[String] = ["k", "s"]
        _ = _run(rt, path, names, 1, None)
    with assert_raises(contains="must be INT32 or INT64"):
        var names: List[String] = ["fd", "v"]
        _ = _run(rt, path, names, 1, None)
    with assert_raises(contains="no group key"):
        var names: List[String] = ["v"]
        _ = _run(rt, path, names, 0, None)
    rt.shutdown()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

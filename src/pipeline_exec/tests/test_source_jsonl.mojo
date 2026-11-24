# =============================================================================
# SOURCE_JSONL: one newline-delimited JSON file read at the spec's schema
# =============================================================================
#
# Each file is written here in the test's scratch directory, and the source the
# spec builds is drained by workers claiming in turn, the way the driver's
# workers do. What these tests prove:
#
#   * test_every_row_comes_back_at_the_schema_in_its_order: the columns are
#     the spec's, in its order (not the file's key order), at its types; a key
#     a line lacks reads NULL, a JSON null reads NULL, an integer read as a
#     FLOAT64 key is that float, an escaped quote is unescaped, and a key the
#     schema does not name (here a nested object) is skipped. Morsels of two
#     rows give every row once.
#   * test_a_file_of_several_chunks_gives_every_row_once: a file longer than the
#     reader's 4 MiB chunk is read as several batches, served by one cursor:
#     every id comes back once, in file order.
#   * test_an_empty_file_is_no_row_at_the_schema: no morsel, and the source's
#     schema is still the spec's (the collect sink's empty output reads it).
#   * test_a_last_line_without_a_newline_is_read and
#     test_a_compressed_file_is_read: the last line of a file that does not end
#     in a newline is a row, plain and gzip-compressed (`.jsonl.gz`).
#   * test_a_schema_of_no_column_counts_the_objects: a spec of no column (what a
#     count(*) reads) gives one row per object, and a blank line is no row.
#   * test_a_line_that_is_not_an_object_is_refused_naming_the_file_and_line,
#     test_a_value_of_another_type_is_refused_naming_the_file_and_line,
#     test_a_missing_file_is_refused_naming_it and
#     test_a_spec_with_no_path_is_refused: each is an error whose text names
#     the file (and the line), never a batch with rows missing.
#   * test_a_plan_over_a_jsonl_file_runs_end_to_end: RealBuilder builds the
#     SOURCE_JSONL member of a segment, and run_plan gives the rows a filter
#     keeps, projected, in file order, on one worker and on three.

from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from arrow.arrow_types import ArrowType
from arrow.schema import Field, RecordBatch, Schema, SchemaBuilder
from async_api.token import CancellationToken
from containers.slab import Slab
from morsel.morsel import Morsel
from morsel.morsel_source import MorselSourceImpl
from parquet.runtime_footer_cache import ParquetMetadataCache
from parquet_api import CompressionCodec
from parquet_codec.compression import compress, compress_bound
from physical_plan.physical_plan import (
    KEY_DTYPE_NONE,
    MorselOp,
    ORDER_NONE,
    SegmentDescPod,
    SINK_COLLECT,
    SINK_ORIENT_COLUMNAR,
    SOURCE_JSONL,
    SourceSpecPod,
)
from pipeline_exec.fake_dispatch import InlineDispatch
from pipeline_exec.plan_harness import (
    chain,
    column_names,
    int64_column,
    null_column,
    project_columns,
    string_column,
)
from pipeline_exec.real_builder import RealBuilder
from pipeline_exec.run_plan import run_plan
from pipeline_exec.source_jsonl import build_jsonl_source
from plan_expr.expr import BIN_GE, Expr
from plan_expr.expr_pool import ExprPool
from plan_expr.scalar_value import ScalarValue
from runtime_paths import test_tmpdir

comptime NW = 3


# ---- helpers -----------------------------------------------------------------


def _write(name: String, text: String) raises -> String:
    var path = test_tmpdir() + "/" + name
    var fh = open(path, "w")
    fh.write(text)
    fh.close()
    return path^


def _schema(
    a: String, ta: ArrowType, b: String = "", tb: ArrowType = ArrowType.NULL,
    c: String = "", tc: ArrowType = ArrowType.NULL,
) -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(a, ta, True))
    if b.byte_length() > 0:
        sb.add_field(Field(b, tb, True))
    if c.byte_length() > 0:
        sb.add_field(Field(c, tc, True))
    return sb.build()


def _source(path: String, var schema: Schema, morsel_rows: Int = 2) raises -> Slab[Morsel]:
    var spec = SourceSpecPod.jsonl(String(path), schema^)
    return _drain(build_jsonl_source(spec, morsel_rows))


def _drain[S: MorselSourceImpl](src: S) raises -> Slab[Morsel]:
    """Every morsel, the workers claiming in turn until each has been told
    the input ended."""
    var out = Slab[Morsel]()
    var live = List[Bool](length=NW, fill=True)
    var n_live = NW
    while n_live > 0:
        for w in range(NW):
            if not live[w]:
                continue
            var m = src.next_morsel(w)
            if m:
                out.append(m.take())
            else:
                live[w] = False
                n_live -= 1
    return out^


def _in_position_order(ref morsels: Slab[Morsel]) -> List[Int]:
    """Indices of `morsels` sorted by (partition id, origin hint)."""
    var order = List[Int]()
    for i in range(len(morsels)):
        order.append(i)
    for i in range(1, len(order)):
        var j = i
        while j > 0:
            ref p = morsels[order[j - 1]]
            ref q = morsels[order[j]]
            var after = p.partition_id > q.partition_id or (
                p.partition_id == q.partition_id
                and p.origin_hint > q.origin_hint
            )
            if not after:
                break
            var t = order[j - 1]
            order[j - 1] = order[j]
            order[j] = t
            j -= 1
    return order^


def _ints(ref morsels: Slab[Morsel], col: Int) raises -> List[Int]:
    var out = List[Int]()
    var order = _in_position_order(morsels)
    for k in range(len(order)):
        var values = int64_column(morsels[order[k]].batch, col)
        for i in range(len(values)):
            out.append(values[i])
    return out^


def _strings(ref morsels: Slab[Morsel], col: Int) raises -> List[String]:
    var out = List[String]()
    var order = _in_position_order(morsels)
    for k in range(len(order)):
        var values = string_column(morsels[order[k]].batch, col)
        for i in range(len(values)):
            out.append(values[i])
    return out^


def _floats(ref morsels: Slab[Morsel], col: Int) raises -> List[Float64]:
    var out = List[Float64]()
    var order = _in_position_order(morsels)
    for k in range(len(order)):
        ref batch = morsels[order[k]].batch
        var values = batch.column_at(col).as_primitive[DType.float64]()
        for i in range(batch.num_rows()):
            out.append(values.get(i))
    return out^


def _nulls(ref morsels: Slab[Morsel], col: Int) -> List[Bool]:
    var out = List[Bool]()
    var order = _in_position_order(morsels)
    for k in range(len(order)):
        var values = null_column(morsels[order[k]].batch, col)
        for i in range(len(values)):
            out.append(values[i])
    return out^


def _rows(ref morsels: Slab[Morsel]) -> Int:
    var n = 0
    for i in range(len(morsels)):
        n += morsels[i].batch.num_rows()
    return n


def _segment(path: String, var schema: Schema, var ops: Slab[MorselOp]) -> SegmentDescPod:
    return SegmentDescPod(
        0,
        SOURCE_JSONL,
        SourceSpecPod.jsonl(String(path), schema^),
        ops^,
        SINK_COLLECT,
        KEY_DTYPE_NONE,
        SINK_ORIENT_COLUMNAR,
        -1,
        0,
        List[Int](),
        List[UInt8](),
        order_key_kind=ORDER_NONE,
        morsel_rows=2,
    )


# ---- rows and schema ---------------------------------------------------------


def test_every_row_comes_back_at_the_schema_in_its_order() raises:
    var path = _write(
        "rows.jsonl",
        String('{"id": 1, "s": "a", "f": 1.5, "extra": {"x": [1, 2]}}\n')
        + '{"s": "b", "id": 2}\n'
        + '{"id": 3, "f": 3, "s": "c\\"q"}\n'
        + '{"id": 4, "s": null, "f": -0.25}\n'
        + '{"f": 8.0, "id": 5, "s": "e"}\n',
    )
    var morsels = _source(
        path,
        _schema("s", ArrowType.STRING, "id", ArrowType.INT64, "f", ArrowType.FLOAT64),
    )
    assert_true(len(morsels) >= 3)
    var names = column_names(morsels[0].batch)
    assert_equal(len(names), 3)
    assert_equal(names[0], "s")
    assert_equal(names[1], "id")
    assert_equal(names[2], "f")
    assert_true(morsels[0].batch.schema.field_arrow_type(1) == ArrowType.INT64)
    assert_true(morsels[0].batch.schema.field_arrow_type(2) == ArrowType.FLOAT64)
    var ids = _ints(morsels, 1)
    assert_equal(len(ids), 5)
    for i in range(5):
        assert_equal(ids[i], i + 1)
    var s = _strings(morsels, 0)
    var s_null = _nulls(morsels, 0)
    assert_equal(s[0], "a")
    assert_equal(s[1], "b")
    assert_equal(s[2], 'c"q')
    assert_true(s_null[3])
    assert_equal(s[4], "e")
    assert_false(s_null[0] or s_null[1] or s_null[2] or s_null[4])
    var f = _floats(morsels, 2)
    var f_null = _nulls(morsels, 2)
    assert_equal(f[0], 1.5)
    assert_true(f_null[1])
    assert_equal(f[2], 3.0)
    assert_equal(f[3], -0.25)
    assert_equal(f[4], 8.0)
    assert_false(f_null[0] or f_null[2] or f_null[3] or f_null[4])


def test_a_file_of_several_chunks_gives_every_row_once() raises:
    # About 5.6 MiB, more than one 4 MiB chunk of the reader.
    comptime N = 120000
    var text = String()
    for i in range(N):
        text += '{"id": ' + String(i) + ', "pad": "xxxxxxxxxxxxxxxxxxxxxxxx"}\n'
    assert_true(text.byte_length() > 4 * 1024 * 1024)
    var morsels = _source(
        _write("chunks.jsonl", text), _schema("id", ArrowType.INT64), 4096
    )
    var ids = _ints(morsels, 0)
    assert_equal(len(ids), N)
    for i in range(N):
        assert_equal(ids[i], i, "row " + String(i))


def test_an_empty_file_is_no_row_at_the_schema() raises:
    var spec = SourceSpecPod.jsonl(
        _write("empty.jsonl", ""),
        _schema("id", ArrowType.INT64, "s", ArrowType.STRING),
    )
    var src = build_jsonl_source(spec, 2)
    var schema = src.output_schema()
    assert_equal(schema.num_columns(), 2)
    assert_equal(schema.field_name(0), "id")
    assert_equal(schema.field_name(1), "s")
    assert_equal(len(_drain(src)), 0)


def test_a_last_line_without_a_newline_is_read() raises:
    var morsels = _source(
        _write("no_newline.jsonl", '{"id": 7}\n{"id": 8}'),
        _schema("id", ArrowType.INT64),
    )
    var ids = _ints(morsels, 0)
    assert_equal(len(ids), 2)
    assert_equal(ids[0], 7)
    assert_equal(ids[1], 8)


def test_a_compressed_file_is_read() raises:
    var text = String('{"id": 1, "s": "x"}\n\n{"s": "y", "id": 2}\n{"id": 3}')
    var raw = text.as_bytes()
    var out = List[UInt8](length=compress_bound(CompressionCodec.GZIP, len(raw)), fill=0)
    var n = compress(CompressionCodec.GZIP, raw, Span(out))
    out.resize(n, 0)
    var path = test_tmpdir() + "/rows.jsonl.gz"
    var fh = open(path, "w")
    fh.write_bytes(Span(out))
    fh.close()
    var morsels = _source(path, _schema("id", ArrowType.INT64, "s", ArrowType.STRING))
    var ids = _ints(morsels, 0)
    assert_equal(len(ids), 3)
    for i in range(3):
        assert_equal(ids[i], i + 1)
    var s = _strings(morsels, 1)
    assert_equal(s[0], "x")
    assert_equal(s[1], "y")
    assert_true(_nulls(morsels, 1)[2])


def test_a_schema_of_no_column_counts_the_objects() raises:
    var none = SchemaBuilder()
    var morsels = _source(
        _write("no_column.jsonl", '{"a": 1}\n\n{"b": 2}\n{}\n'), none.build()
    )
    assert_equal(_rows(morsels), 3)


# ---- refusals ----------------------------------------------------------------


def test_a_line_that_is_not_an_object_is_refused_naming_the_file_and_line() raises:
    var path = _write("not_object.jsonl", '{"id": 1}\n[1, 2]\n')
    with assert_raises(contains="'" + path + "' cannot be read: jsonl: line 2"):
        _ = _source(path, _schema("id", ArrowType.INT64))


def test_a_value_of_another_type_is_refused_naming_the_file_and_line() raises:
    var path = _write("wrong_type.jsonl", '{"id": 1}\n{"id": 2}\n{"id": "three"}\n')
    with assert_raises(contains="'" + path + "' cannot be read: jsonl: line 3"):
        _ = _source(path, _schema("id", ArrowType.INT64))


def test_a_missing_file_is_refused_naming_it() raises:
    var path = test_tmpdir() + "/absent.jsonl"
    with assert_raises(contains="the JSONL file '" + path + "' cannot be read"):
        _ = _source(path, _schema("id", ArrowType.INT64))


def test_a_spec_with_no_path_is_refused() raises:
    var spec = SourceSpecPod.jsonl(String(""), _schema("id", ArrowType.INT64))
    with assert_raises(contains="a JSONL source names no path"):
        _ = build_jsonl_source(spec, 2)


# ---- through the builder and run_plan ----------------------------------------


def _plan_rows(path: String, workers: Int) raises -> RecordBatch:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var dispatch = InlineDispatch()
    var keep = Expr.binary(
        BIN_GE, Expr.col_ref("id"), Expr.literal(ScalarValue.from_int(3))
    )
    var names = List[String]()
    names.append("s")
    names.append("id")
    var descs = List[SegmentDescPod]()
    descs.append(
        _segment(
            path,
            _schema("id", ArrowType.INT64, "s", ArrowType.STRING),
            chain(MorselOp.filter(keep^), project_columns(names)),
        )
    )
    var out = run_plan(descs, builder, dispatch, workers, CancellationToken.new())
    return out.take(0)


def test_a_plan_over_a_jsonl_file_runs_end_to_end() raises:
    var text = String()
    for i in range(10):
        text += '{"s": "s' + String(i) + '", "id": ' + String(i) + "}\n"
    var path = _write("plan.jsonl", text)
    for workers in range(1, 4, 2):
        var batch = _plan_rows(path, workers)
        var names = column_names(batch)
        assert_equal(len(names), 2)
        assert_equal(names[0], "s")
        assert_equal(names[1], "id")
        var ids = int64_column(batch, 1)
        var s = string_column(batch, 0)
        assert_equal(len(ids), 7)
        for i in range(7):
            assert_equal(ids[i], i + 3)
            assert_equal(s[i], "s" + String(i + 3))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

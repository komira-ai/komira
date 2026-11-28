# =============================================================================
# SOURCE_ORC: one local ORC file read at the spec's columns
# =============================================================================
#
# Each file is written here with `write_orc_file` in the test's scratch
# directory, and the source the spec builds is drained by workers claiming in
# turn, the way the driver's workers do. What these tests prove:
#
#   * test_the_spec_columns_come_back_in_the_spec_order_at_their_types: the
#     columns are the spec's, in its order (not the file's), at its types, with
#     every value and every NULL of an int64, string, float64 and bool column
#     (a column the spec does not name is not read); morsels of two rows give
#     every row once, in file order.
#   * test_a_file_of_several_stripes_gives_every_row_once_in_order: a file cut
#     into stripes of three rows is read whole, every id once, in file order.
#   * test_a_zlib_and_a_zstd_file_read_the_same_as_an_uncompressed_one: the
#     codec is read from the footer; the rows are the same under each.
#   * test_a_schema_of_no_column_counts_the_file_rows: a spec of no column (what
#     a count(*) reads) gives the file's row count.
#   * test_a_file_of_no_row_is_no_morsel_and_keeps_the_spec_schema: no morsel,
#     and the source's schema is still the spec's.
#   * test_a_column_the_file_lacks_is_refused_naming_the_file_and_column,
#     test_a_column_bound_at_another_type_is_refused_naming_the_file_and_column,
#     test_a_missing_file_is_refused_naming_it,
#     test_a_file_that_is_not_orc_is_refused_naming_it and
#     test_a_spec_with_no_path_is_refused: each is an error whose text names
#     the file (and the column), never a batch with columns missing.
#   * test_a_plan_over_an_orc_file_runs_end_to_end: RealBuilder builds the
#     SOURCE_ORC member of a segment, and run_plan gives the rows a filter
#     keeps, projected, in file order, on one worker and on three.

from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from arrow.arrow_types import ArrowType
from arrow.boolean_array import BooleanArray
from arrow.column import Column
from arrow.column_builder import ColumnBuilder
from arrow.primitive_array import PrimitiveArray
from arrow.record_batch import RecordBatchBuilder
from arrow.schema import Field, RecordBatch, Schema, SchemaBuilder
from arrow.string_array import StringArray
from async_api.token import CancellationToken
from containers.slab import Slab
from morsel.morsel import Morsel
from morsel.morsel_source import MorselSourceImpl
from orc import (
    ORC_COMPRESSION_NONE,
    ORC_COMPRESSION_ZLIB,
    ORC_COMPRESSION_ZSTD,
    OrcWriterOptions,
    read_orc_tail,
    write_orc_file,
)
from parquet.runtime_footer_cache import ParquetMetadataCache
from physical_plan.physical_plan import (
    KEY_DTYPE_NONE,
    MorselOp,
    ORDER_NONE,
    SegmentDescPod,
    SINK_COLLECT,
    SINK_ORIENT_COLUMNAR,
    SOURCE_ORC,
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
from pipeline_exec.source_orc import build_orc_source
from plan_expr.expr import BIN_GE, Expr
from plan_expr.expr_pool import ExprPool
from plan_expr.scalar_value import ScalarValue
from runtime_paths import test_tmpdir

comptime NW = 3


# ---- helpers -----------------------------------------------------------------


def _table(rows: Int) raises -> RecordBatch:
    """Columns id (INT64, row 2 NULL), s (STRING, row 3 NULL), f (FLOAT64, row
    4 NULL) and b (BOOL, row 5 NULL) of `rows` rows: id r + 1, s "s<r>", f
    r * 0.5, b true on even r."""
    var ids = ColumnBuilder[DType.int64].with_capacity(rows)
    var fs = ColumnBuilder[DType.float64].with_capacity(rows)
    var bs = BooleanArray.allocate_nullable(rows)
    var s = List[String]()
    var s_valid = List[Bool]()
    for r in range(rows):
        if r == 2:
            ids.append_null()
        else:
            ids.append(Int64(r + 1))
        if r == 4:
            fs.append_null()
        else:
            fs.append(Float64(r) * 0.5)
        bs.set(r, r % 2 == 0)
        if r == 5:
            bs._set_null(r)
        s.append("s" + String(r))
        s_valid.append(r != 3)
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, True))
    sb.add_field(Field("s", ArrowType.STRING, True))
    sb.add_field(Field("f", ArrowType.FLOAT64, True))
    sb.add_field(Field("b", ArrowType.BOOL, True))
    var builder = RecordBatchBuilder()
    builder.add_column(ids^.materialize())
    builder.add_column(
        Column.from_string(StringArray.from_strings_with_validity(s, s_valid))
    )
    builder.add_column(fs^.materialize())
    builder.add_column(Column.from_boolean(bs))
    return builder.build(sb.build())


def _ids_and_strings(rows: Int) raises -> RecordBatch:
    var ids = PrimitiveArray[DType.int64].allocate(rows)
    var s = List[String]()
    for r in range(rows):
        ids.set(r, Int64(r))
        s.append("s" + String(r))
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, True))
    sb.add_field(Field("s", ArrowType.STRING, True))
    var builder = RecordBatchBuilder()
    builder.add_column(
        Column.from_primitive_with_arrow_type[DType.int64](ids^, ArrowType.INT64)
    )
    builder.add_column(Column.from_string(StringArray.from_strings(s)))
    return builder.build(sb.build())


def _write(
    name: String,
    ref batch: RecordBatch,
    codec: Int = ORC_COMPRESSION_NONE,
    stripe_rows: Int = 10000,
) raises -> String:
    var path = test_tmpdir() + "/" + name
    write_orc_file(
        batch, path, OrcWriterOptions(codec, stripe_rows, "UTC", stripe_rows, False)
    )
    return path^


def _schema(
    a: String,
    ta: ArrowType,
    b: String = "",
    tb: ArrowType = ArrowType.NULL,
    c: String = "",
    tc: ArrowType = ArrowType.NULL,
    d: String = "",
    td: ArrowType = ArrowType.NULL,
) -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(a, ta, True))
    if b.byte_length() > 0:
        sb.add_field(Field(b, tb, True))
    if c.byte_length() > 0:
        sb.add_field(Field(c, tc, True))
    if d.byte_length() > 0:
        sb.add_field(Field(d, td, True))
    return sb.build()


def _source(
    path: String, var schema: Schema, morsel_rows: Int = 2
) raises -> Slab[Morsel]:
    var spec = SourceSpecPod.orc(String(path), schema^)
    return _drain(build_orc_source(spec, morsel_rows))


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


def _bools(ref morsels: Slab[Morsel], col: Int) raises -> List[Bool]:
    var out = List[Bool]()
    var order = _in_position_order(morsels)
    for k in range(len(order)):
        ref batch = morsels[order[k]].batch
        var values = batch.column_at(col).as_boolean()
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


def _segment(
    path: String, var schema: Schema, var ops: Slab[MorselOp]
) -> SegmentDescPod:
    return SegmentDescPod(
        0,
        SOURCE_ORC,
        SourceSpecPod.orc(String(path), schema^),
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


def test_the_spec_columns_come_back_in_the_spec_order_at_their_types() raises:
    comptime N = 7
    var path = _write("rows.orc", _table(N))
    var morsels = _source(
        path,
        _schema(
            "b", ArrowType.BOOL,
            "f", ArrowType.FLOAT64,
            "id", ArrowType.INT64,
            "s", ArrowType.STRING,
        ),
    )
    assert_true(len(morsels) >= 3)
    var names = column_names(morsels[0].batch)
    assert_equal(len(names), 4)
    assert_equal(names[0], "b")
    assert_equal(names[1], "f")
    assert_equal(names[2], "id")
    assert_equal(names[3], "s")
    assert_true(morsels[0].batch.schema.field_arrow_type(0) == ArrowType.BOOL)
    assert_true(morsels[0].batch.schema.field_arrow_type(1) == ArrowType.FLOAT64)
    assert_true(morsels[0].batch.schema.field_arrow_type(2) == ArrowType.INT64)
    assert_true(morsels[0].batch.schema.field_arrow_type(3) == ArrowType.STRING)
    var ids = _ints(morsels, 2)
    var id_null = _nulls(morsels, 2)
    var s = _strings(morsels, 3)
    var s_null = _nulls(morsels, 3)
    var f = _floats(morsels, 1)
    var f_null = _nulls(morsels, 1)
    var b = _bools(morsels, 0)
    var b_null = _nulls(morsels, 0)
    assert_equal(len(ids), N)
    for r in range(N):
        assert_equal(id_null[r], r == 2)
        assert_equal(s_null[r], r == 3)
        assert_equal(f_null[r], r == 4)
        assert_equal(b_null[r], r == 5)
        if r != 2:
            assert_equal(ids[r], r + 1)
        if r != 3:
            assert_equal(s[r], "s" + String(r))
        if r != 4:
            assert_equal(f[r], Float64(r) * 0.5)
        if r != 5:
            assert_equal(b[r], r % 2 == 0)


def test_a_file_of_several_stripes_gives_every_row_once_in_order() raises:
    comptime N = 10
    var path = _write(
        "stripes.orc", _ids_and_strings(N), ORC_COMPRESSION_NONE, 3
    )
    var bytes = open(path, "r").read_bytes()
    assert_true(len(read_orc_tail(Span(bytes)).footer.stripes) > 1)
    var morsels = _source(
        path, _schema("s", ArrowType.STRING, "id", ArrowType.INT64), 4
    )
    var ids = _ints(morsels, 1)
    var s = _strings(morsels, 0)
    assert_equal(len(ids), N)
    for r in range(N):
        assert_equal(ids[r], r)
        assert_equal(s[r], "s" + String(r))


def test_a_zlib_and_a_zstd_file_read_the_same_as_an_uncompressed_one() raises:
    comptime N = 7
    var codecs = List[Int]()
    codecs.append(ORC_COMPRESSION_NONE)
    codecs.append(ORC_COMPRESSION_ZLIB)
    codecs.append(ORC_COMPRESSION_ZSTD)
    for k in range(len(codecs)):
        var path = _write("codec" + String(k) + ".orc", _table(N), codecs[k])
        var morsels = _source(
            path, _schema("id", ArrowType.INT64, "s", ArrowType.STRING)
        )
        var ids = _ints(morsels, 0)
        var id_null = _nulls(morsels, 0)
        var s = _strings(morsels, 1)
        assert_equal(len(ids), N)
        for r in range(N):
            assert_equal(id_null[r], r == 2)
            if r != 2:
                assert_equal(ids[r], r + 1)
            if r != 3:
                assert_equal(s[r], "s" + String(r))


def test_a_schema_of_no_column_counts_the_file_rows() raises:
    var path = _write("count.orc", _table(7))
    var morsels = _source(path, SchemaBuilder().build())
    assert_equal(_rows(morsels), 7)


def test_a_file_of_no_row_is_no_morsel_and_keeps_the_spec_schema() raises:
    var path = _write("no_row.orc", _ids_and_strings(0))
    var spec = SourceSpecPod.orc(
        path, _schema("s", ArrowType.STRING, "id", ArrowType.INT64)
    )
    var src = build_orc_source(spec, 2)
    var schema = src.output_schema()
    assert_equal(schema.num_columns(), 2)
    assert_equal(schema.field_name(0), "s")
    assert_equal(schema.field_name(1), "id")
    assert_equal(len(_drain(src)), 0)


# ---- refusals ----------------------------------------------------------------


def test_a_column_the_file_lacks_is_refused_naming_the_file_and_column() raises:
    var path = _write("lacks.orc", _table(3))
    with assert_raises(
        contains=(
            "the ORC file '" + path + "' cannot be read: the file has no"
            " column 'zz'"
        )
    ):
        _ = _source(path, _schema("id", ArrowType.INT64, "zz", ArrowType.INT64))


def test_a_column_bound_at_another_type_is_refused_naming_the_file_and_column() raises:
    var path = _write("other_type.orc", _table(3))
    with assert_raises(
        contains=(
            "the ORC file '" + path + "' cannot be read: column 'id' is bound"
            " at another type than the file holds"
        )
    ):
        _ = _source(path, _schema("id", ArrowType.STRING))


def test_a_missing_file_is_refused_naming_it() raises:
    var path = test_tmpdir() + "/absent.orc"
    with assert_raises(contains="the ORC file '" + path + "' cannot be read"):
        _ = _source(path, _schema("id", ArrowType.INT64))


def test_a_file_that_is_not_orc_is_refused_naming_it() raises:
    var path = test_tmpdir() + "/not_orc.orc"
    var fh = open(path, "w")
    fh.write("this is plain text, long enough to hold a postscript, not ORC")
    fh.close()
    with assert_raises(contains="the ORC file '" + path + "' cannot be read"):
        _ = _source(path, _schema("id", ArrowType.INT64))


def test_a_spec_with_no_path_is_refused() raises:
    var spec = SourceSpecPod.orc(String(""), _schema("id", ArrowType.INT64))
    with assert_raises(contains="an ORC source names no path"):
        _ = build_orc_source(spec, 2)


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


def test_a_plan_over_an_orc_file_runs_end_to_end() raises:
    var path = _write("plan.orc", _ids_and_strings(10))
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

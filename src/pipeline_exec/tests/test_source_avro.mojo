# =============================================================================
# SOURCE_AVRO: the columns a spec names of one Avro object container file
# =============================================================================
#
# Each file is written here in the test's scratch directory as OCF bytes
# encoded by this test from the Avro specification (a header with the writer
# schema and the codec, a sync marker, and one block of rows), not by the
# library's writer, and the source the spec builds is drained by workers
# claiming in turn, the way the driver's workers do. What these tests prove:
#
#   * test_the_spec_columns_come_back_in_the_spec_order: the columns are the
#     spec's, in its order (not the file's), at the file's types; a ["null",
#     string] union's null branch reads NULL; a column the spec does not name
#     (here `qty`) is dropped. Morsels of two rows give every row once.
#   * test_a_spec_of_no_column_keeps_the_row_count: a spec of no column (what
#     a count(*) reads) gives one row per record and no column.
#   * test_a_file_of_no_block_is_no_row_at_the_spec_schema: a file with a
#     header and no block gives no morsel, and the source's schema is the
#     spec's; with a spec of no column it gives no row either.
#   * test_each_column_type_outside_the_envelope_is_refused_by_name: an enum,
#     a nested record (also behind a ["null", record] union), an array, a map,
#     a union of two non-null branches and one of three, a duration, a uuid, a
#     timestamp-nanos and a local-timestamp-nanos column are each refused with
#     the decoder's token, naming the column and the file, by exact message,
#     from a file of no block: the check reads the header, not the rows.
#   * test_a_nullable_union_in_either_order_is_not_refused: ["null", T] and
#     [T, "null"] read as a nullable T column.
#   * test_a_column_the_file_lacks_or_types_otherwise_is_refused: a spec
#     naming a column the file does not hold, or holding one at another type,
#     is refused with AVRO_SOURCE_SCHEMA_MISMATCH by exact message.
#   * test_a_missing_file_is_refused_naming_it,
#     test_a_file_that_is_not_an_ocf_is_refused_naming_it,
#     test_a_block_that_does_not_decode_is_refused_naming_the_file and
#     test_a_spec_with_no_path_is_refused: each is an error whose text names
#     the file, never a batch with rows missing.
#   * test_a_plan_over_an_avro_file_runs_end_to_end: RealBuilder builds the
#     SOURCE_AVRO member of a segment, and run_plan gives the rows a filter
#     keeps, projected, in file order, on one worker and on three.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_true,
)

from arrow.arrow_types import ArrowType
from arrow.schema import Field, RecordBatch, Schema, SchemaBuilder
from async_api.token import CancellationToken
from containers.slab import Slab
from morsel.morsel import Morsel
from morsel.morsel_source import MorselSourceImpl
from parquet.runtime_footer_cache import ParquetMetadataCache
from physical_plan.physical_plan import (
    KEY_DTYPE_NONE,
    MorselOp,
    ORDER_NONE,
    SegmentDescPod,
    SINK_COLLECT,
    SINK_ORIENT_COLUMNAR,
    SOURCE_AVRO,
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
from pipeline_exec.source_avro import (
    AVRO_SOURCE_SCHEMA_MISMATCH,
    build_avro_source,
)
from plan_expr.expr import BIN_GE, Expr
from plan_expr.expr_pool import ExprPool
from plan_expr.scalar_value import ScalarValue
from runtime_paths import test_tmpdir

comptime NW = 3


# ---- OCF bytes, from the Avro specification ----------------------------------


def _enc_long(n: Int64, mut out: List[UInt8]):
    """`n` as an Avro long: zigzag, then a base-128 varint."""
    var zz = UInt64((n << 1) ^ (n >> 63))
    while True:
        var b = UInt8(zz & 0x7F)
        zz >>= 7
        if zz != 0:
            out.append(b | 0x80)
        else:
            out.append(b)
            break


def _enc_str(s: String, mut out: List[UInt8]):
    var b = s.as_bytes()
    _enc_long(Int64(len(b)), out)
    for i in range(len(b)):
        out.append(b[i])


def _ocf(schema: String, rows: Int, payload: List[UInt8]) -> List[UInt8]:
    """An OCF file of the null codec: the header, then one block of `rows`
    records holding `payload` when `rows` > 0, and no block otherwise."""
    var out: List[UInt8] = [0x4F, 0x62, 0x6A, 0x01]
    _enc_long(2, out)
    _enc_str("avro.schema", out)
    _enc_str(schema, out)
    _enc_str("avro.codec", out)
    _enc_str("null", out)
    _enc_long(0, out)
    for i in range(16):
        out.append(UInt8(0x50 + i))
    if rows > 0:
        _enc_long(Int64(rows), out)
        _enc_long(Int64(len(payload)), out)
        out.extend(Span(payload))
        for i in range(16):
            out.append(UInt8(0x50 + i))
    return out^


def _write(name: String, bytes: List[UInt8]) raises -> String:
    var path = test_tmpdir() + "/" + name
    var fh = open(path, "w")
    fh.write_bytes(Span(bytes))
    fh.close()
    return path^


comptime _ROWS_SCHEMA = (
    '{"type":"record","name":"R","fields":['
    '{"name":"id","type":"long"},'
    '{"name":"name","type":["null","string"]},'
    '{"name":"qty","type":"int"}]}'
)


def _rows_payload(n: Int) -> List[UInt8]:
    """Records id = 0 .. n - 1, name = "s<id>" (NULL when id % 4 == 1),
    qty = id * 10 - 25."""
    var p = List[UInt8]()
    for i in range(n):
        _enc_long(Int64(i), p)
        if i % 4 == 1:
            _enc_long(0, p)
        else:
            _enc_long(1, p)
            _enc_str("s" + String(i), p)
        _enc_long(Int64(i * 10 - 25), p)
    return p^


def _rows_file(name: String, n: Int) raises -> String:
    return _write(name, _ocf(_ROWS_SCHEMA, n, _rows_payload(n)))


# ---- helpers -----------------------------------------------------------------


def _schema(
    a: String = "", ta: ArrowType = ArrowType.NULL,
    b: String = "", tb: ArrowType = ArrowType.NULL,
) -> Schema:
    var sb = SchemaBuilder()
    if a.byte_length() > 0:
        sb.add_field(Field(a, ta, True))
    if b.byte_length() > 0:
        sb.add_field(Field(b, tb, True))
    return sb.build()


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


def _source(path: String, var schema: Schema) raises -> Slab[Morsel]:
    var spec = SourceSpecPod.avro(String(path), schema^)
    return _drain(build_avro_source(spec, 2))


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


def _refusal(path: String, var schema: Schema) -> String:
    """The message building the source raises, or "(built)"."""
    try:
        var spec = SourceSpecPod.avro(String(path), schema^)
        _ = build_avro_source(spec, 2)
    except e:
        return String(e)
    return String("(built)")


# ---- rows and schema ---------------------------------------------------------


def test_the_spec_columns_come_back_in_the_spec_order() raises:
    var morsels = _source(
        _rows_file("rows.avro", 5),
        _schema("name", ArrowType.STRING, "id", ArrowType.INT64),
    )
    assert_true(len(morsels) >= 3)
    var names = column_names(morsels[0].batch)
    assert_equal(len(names), 2)
    assert_equal(names[0], "name")
    assert_equal(names[1], "id")
    assert_true(morsels[0].batch.schema.field_arrow_type(0) == ArrowType.STRING)
    assert_true(morsels[0].batch.schema.field_arrow_type(1) == ArrowType.INT64)
    var ids = _ints(morsels, 1)
    assert_equal(len(ids), 5)
    for i in range(5):
        assert_equal(ids[i], i)
    var s = _strings(morsels, 0)
    var s_null = _nulls(morsels, 0)
    assert_equal(s[0], "s0")
    assert_true(s_null[1])
    assert_equal(s[2], "s2")
    assert_equal(s[3], "s3")
    assert_equal(s[4], "s4")
    assert_false(s_null[0] or s_null[2] or s_null[3] or s_null[4])


def test_a_spec_of_no_column_keeps_the_row_count() raises:
    var morsels = _source(_rows_file("count.avro", 7), _schema())
    assert_equal(_rows(morsels), 7)
    for i in range(len(morsels)):
        assert_equal(morsels[i].batch.num_columns(), 0)


def test_a_file_of_no_block_is_no_row_at_the_spec_schema() raises:
    var path = _write("empty.avro", _ocf(_ROWS_SCHEMA, 0, List[UInt8]()))
    var spec = SourceSpecPod.avro(
        String(path), _schema("id", ArrowType.INT64, "name", ArrowType.STRING)
    )
    var src = build_avro_source(spec, 2)
    var schema = src.output_schema()
    assert_equal(schema.num_columns(), 2)
    assert_equal(schema.field_name(0), "id")
    assert_equal(schema.field_name(1), "name")
    assert_equal(len(_drain(src)), 0)
    assert_equal(_rows(_source(path, _schema())), 0)


# ---- the type envelope -------------------------------------------------------


def _one_column(column_type: String) -> List[UInt8]:
    """A file of no block whose writer schema is {id: long, c: <type>}."""
    return _ocf(
        String('{"type":"record","name":"R","fields":[')
        + '{"name":"id","type":"long"},{"name":"c","type":'
        + column_type
        + "}]}",
        0,
        List[UInt8](),
    )


def _envelope_refusal(name: String, column_type: String) raises -> String:
    return _refusal(_write(name, _one_column(column_type)), _schema())


def _expected(name: String, token: String, what: String) -> String:
    return (
        token
        + ": column 'c' of the Avro file '"
        + test_tmpdir()
        + "/"
        + name
        + "' is "
        + what
        + ", which read_avro does not read yet"
    )


def test_each_column_type_outside_the_envelope_is_refused_by_name() raises:
    var files: List[String] = [
        "enum.avro",
        "record.avro",
        "null_record.avro",
        "array.avro",
        "map.avro",
        "union2.avro",
        "union3.avro",
        "duration.avro",
        "uuid.avro",
        "ts_nanos.avro",
        "local_ts_nanos.avro",
    ]
    var types: List[String] = [
        '{"type":"enum","name":"E","symbols":["A","B"]}',
        '{"type":"record","name":"In","fields":[{"name":"x","type":"int"}]}',
        '["null",{"type":"record","name":"In","fields":[{"name":"x","type":"int"}]}]',
        '{"type":"array","items":"int"}',
        '{"type":"map","values":"long"}',
        '["int","string"]',
        '["null","int","string"]',
        '{"type":"fixed","name":"D","size":12,"logicalType":"duration"}',
        '{"type":"string","logicalType":"uuid"}',
        '{"type":"long","logicalType":"timestamp-nanos"}',
        '{"type":"long","logicalType":"local-timestamp-nanos"}',
    ]
    var tokens: List[String] = [
        "AvroDecodeError.UNSUPPORTED_FIELD_KIND",
        "AvroDecodeError.UNSUPPORTED_FIELD_KIND",
        "AvroDecodeError.UNSUPPORTED_FIELD_KIND",
        "AvroDecodeError.UNSUPPORTED_FIELD_KIND",
        "AvroDecodeError.UNSUPPORTED_FIELD_KIND",
        "AvroDecodeError.UNSUPPORTED_UNION",
        "AvroDecodeError.UNSUPPORTED_UNION",
        "AvroDecodeError.UNSUPPORTED_COLUMN_TYPE",
        "AvroDecodeError.UNSUPPORTED_COLUMN_TYPE",
        "AvroDecodeError.UNSUPPORTED_COLUMN_TYPE",
        "AvroDecodeError.UNSUPPORTED_COLUMN_TYPE",
    ]
    var whats: List[String] = [
        "an enum",
        "a nested record",
        "a nested record",
        "an array",
        "a map",
        "a union of 2 branches",
        "a union of 3 branches",
        "a duration",
        "a uuid",
        "a timestamp-nanos",
        "a local-timestamp-nanos",
    ]
    for i in range(len(files)):
        assert_equal(
            _envelope_refusal(files[i], types[i]),
            _expected(files[i], tokens[i], whats[i]),
            types[i],
        )


def test_a_nullable_union_in_either_order_is_not_refused() raises:
    assert_equal(_envelope_refusal("null_first.avro", '["null","long"]'), "(built)")
    assert_equal(_envelope_refusal("null_last.avro", '["long","null"]'), "(built)")


# ---- refusals ----------------------------------------------------------------


def test_a_column_the_file_lacks_or_types_otherwise_is_refused() raises:
    var path = _rows_file("mismatch.avro", 2)
    assert_equal(
        _refusal(path, _schema("id", ArrowType.INT64, "zz", ArrowType.INT64)),
        String(AVRO_SOURCE_SCHEMA_MISMATCH)
        + ": the Avro file '"
        + path
        + "' has no column 'zz' (the file changed after the query was bound)",
    )
    assert_equal(
        _refusal(path, _schema("id", ArrowType.STRING)),
        String(AVRO_SOURCE_SCHEMA_MISMATCH)
        + ": column 'id' of the Avro file '"
        + path
        + "' is int64, and the query was bound at string (the file changed"
        " after the query was bound)",
    )


def test_a_missing_file_is_refused_naming_it() raises:
    var path = test_tmpdir() + "/absent.avro"
    var message = _refusal(path, _schema("id", ArrowType.INT64))
    assert_true(
        message.startswith(
            "pipeline_exec: the Avro file '" + path + "' cannot be read: "
        ),
        message,
    )


def test_a_file_that_is_not_an_ocf_is_refused_naming_it() raises:
    var text: List[UInt8] = [0x69, 0x64, 0x0A, 0x31, 0x0A]
    var path = _write("not_ocf.avro", text)
    var message = _refusal(path, _schema("id", ArrowType.INT64))
    assert_true(
        message.startswith(
            "pipeline_exec: the Avro file '" + path + "' cannot be read: "
        ),
        message,
    )


def test_a_block_that_does_not_decode_is_refused_naming_the_file() raises:
    # A block that says it holds 3 records but holds the bytes of one.
    var payload = _rows_payload(1)
    var path = _write("truncated.avro", _ocf(_ROWS_SCHEMA, 3, payload))
    var message = _refusal(path, _schema("id", ArrowType.INT64))
    assert_true(
        message.startswith(
            "pipeline_exec: the Avro file '" + path + "' cannot be decoded: "
        ),
        message,
    )


def test_a_spec_with_no_path_is_refused() raises:
    assert_equal(
        _refusal(String(""), _schema("id", ArrowType.INT64)),
        "pipeline_exec: an Avro source names no path",
    )


# ---- through the builder and run_plan ----------------------------------------


def _segment(path: String, var schema: Schema, var ops: Slab[MorselOp]) -> SegmentDescPod:
    return SegmentDescPod(
        0,
        SOURCE_AVRO,
        SourceSpecPod.avro(String(path), schema^),
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
    names.append("name")
    names.append("id")
    var descs = List[SegmentDescPod]()
    descs.append(
        _segment(
            path,
            _schema("id", ArrowType.INT64, "name", ArrowType.STRING),
            chain(MorselOp.filter(keep^), project_columns(names)),
        )
    )
    var out = run_plan(descs, builder, dispatch, workers, CancellationToken.new())
    return out.take(0)


def test_a_plan_over_an_avro_file_runs_end_to_end() raises:
    var path = _rows_file("plan.avro", 10)
    for workers in range(1, 4, 2):
        var batch = _plan_rows(path, workers)
        var names = column_names(batch)
        assert_equal(len(names), 2)
        assert_equal(names[0], "name")
        assert_equal(names[1], "id")
        var ids = int64_column(batch, 1)
        var s = string_column(batch, 0)
        var s_null = null_column(batch, 0)
        assert_equal(len(ids), 7)
        for i in range(7):
            var id = i + 3
            assert_equal(ids[i], id)
            if id % 4 == 1:
                assert_true(s_null[i], "row " + String(id) + " is NULL")
            else:
                assert_equal(s[i], "s" + String(id))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

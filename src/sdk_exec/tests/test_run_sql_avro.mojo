# =============================================================================
# test_run_sql_avro: read_avro over one local Avro file through run_sql
# =============================================================================
#
# Each query runs through `run_sql` (parse, bind the schema from the file's
# header, optimize, lower to a SOURCE_AVRO segment, run on the pipeline). The
# files are written here, in the test's scratch directory: `rows.avro` and
# `typed.avro` as OCF bytes this test encodes from the Avro specification
# (null codec), and one copy of the rows per codec written by the library's
# writer (`avro.write_avro_bytes`). A result is compared cell by cell in the
# canonical text of komira_plan_harness (`\N` is NULL, a date is its day
# number, a timestamp its microseconds, a decimal `<unscaled>e-<scale>`).
#
#   test_the_example_query_returns_the_rows_with_id_above_3
#       SELECT id, name FROM read_avro(..) WHERE id > 3 returns exactly the
#       rows 4 to 8, a NULL name included.
#   test_each_codec_written_by_the_library_reads_the_same_rows
#       a file written with the null, deflate, snappy and zstandard codecs
#       (the header says which) reads every row of the source, in id order.
#   test_a_projection_returns_the_columns_in_the_query_order
#       SELECT qty, id returns those two columns, in that order, at INT32 and
#       INT64.
#   test_count_star_and_a_null_filter_count_the_rows
#       count(*) reads no column and still counts every record; IS NULL over
#       a ["null", string] union counts the NULL branch.
#   test_decimal_date_and_timestamp_micros_read_at_their_types
#       a decimal(9,2) over bytes, a date and a timestamp-micros column read
#       as DECIMAL128(9,2), DATE32 and TIMESTAMP_US with their exact values
#       (a negative decimal, day -1 and the microsecond before the epoch
#       included), and a [string, "null"] union reads NULL in its second
#       branch.
#   test_a_file_of_no_block_returns_no_row
#       a header with no block is no row, and count(*) over it is 0.
#   test_duration_enum_and_nested_record_are_refused_by_name
#       each is refused at step execute, naming the decoder's token, the
#       column and the file: never a value.
#   test_a_glob_a_list_and_a_missing_file_are_refused
#       a glob is refused at bind by name, a list of files at parse (the
#       function takes one string path), a path with no file at bind.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from arrow.arrow_types import ArrowType
from avro import (
    AvroWriterOptions,
    AVRO_CODEC_DEFLATE,
    AVRO_CODEC_NULL,
    AVRO_CODEC_SNAPPY,
    AVRO_CODEC_ZSTANDARD,
    decode_ocf_header,
    read_avro_bytes,
    write_avro_bytes,
)
from komira_plan_harness import CanonPolicy, render_batch
from runtime_paths import test_tmpdir
from sdk_exec.engine_context import EngineContext
from sdk_exec.engine_options import EngineOptions
from sdk_exec.engine_sql import (
    SqlOutcome,
    STEP_BIND,
    STEP_EXECUTE,
    STEP_PARSE,
    run_sql,
)


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
        out.append(UInt8(0x30 + i))
    if rows > 0:
        _enc_long(Int64(rows), out)
        _enc_long(Int64(len(payload)), out)
        out.extend(Span(payload))
        for i in range(16):
            out.append(UInt8(0x30 + i))
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


def _rows_ocf() -> List[UInt8]:
    """Records id = 1 .. 8, name = "n<id>" (NULL for 2 and 5),
    qty = id * 10 - 25."""
    var p = List[UInt8]()
    for id in range(1, 9):
        _enc_long(Int64(id), p)
        if id == 2 or id == 5:
            _enc_long(0, p)
        else:
            _enc_long(1, p)
            _enc_str("n" + String(id), p)
        _enc_long(Int64(id * 10 - 25), p)
    return _ocf(_ROWS_SCHEMA, 8, p)


def _all_rows() -> List[String]:
    """The canonical rows of `rows.avro`, id order: id|name|qty."""
    var out = List[String]()
    for id in range(1, 9):
        var name = String("\\N") if id == 2 or id == 5 else "n" + String(id)
        out.append(String(id) + "|" + name + "|" + String(id * 10 - 25))
    return out^


comptime _TYPED_SCHEMA = (
    '{"type":"record","name":"T","fields":['
    '{"name":"id","type":"long"},'
    '{"name":"price","type":{"type":"bytes","logicalType":"decimal",'
    '"precision":9,"scale":2}},'
    '{"name":"d","type":{"type":"int","logicalType":"date"}},'
    '{"name":"ts","type":{"type":"long","logicalType":"timestamp-micros"}},'
    '{"name":"note","type":["string","null"]}]}'
)


def _typed_ocf() -> List[UInt8]:
    """Three records:
    1, 123.45 (unscaled 12345 = 0x3039), day 19000, 1640995200000000 us, "x"
    2, -0.01 (unscaled -1 = 0xFF), day 0, 0 us, NULL
    3, 0.00 (unscaled 0 = 0x00), day -1, -1 us, "z"."""
    var p = List[UInt8]()
    _enc_long(1, p)
    _enc_long(2, p)
    p.append(0x30)
    p.append(0x39)
    _enc_long(19000, p)
    _enc_long(1640995200000000, p)
    _enc_long(0, p)
    _enc_str("x", p)
    _enc_long(2, p)
    _enc_long(1, p)
    p.append(0xFF)
    _enc_long(0, p)
    _enc_long(0, p)
    _enc_long(1, p)
    _enc_long(3, p)
    _enc_long(1, p)
    p.append(0x00)
    _enc_long(-1, p)
    _enc_long(-1, p)
    _enc_long(0, p)
    _enc_str("z", p)
    return _ocf(_TYPED_SCHEMA, 3, p)


# ---- running and reading -----------------------------------------------------


def _new_context() raises -> EngineContext:
    return EngineContext(EngineOptions(worker_count=2))


def _run(mut ctx: EngineContext, sql: String) raises -> SqlOutcome:
    var out = run_sql(ctx, sql)
    if out.refusal:
        assert_true(
            False,
            "refused at "
            + out.refusal.value().step
            + ": "
            + out.refusal.value().reason
            + " -- "
            + sql,
        )
    return out^


def _cells(ref out: SqlOutcome) raises -> List[String]:
    """Every row of the result as its canonical cells joined by `|`, in the
    order the result holds them."""
    var rows = List[String]()
    for b in range(len(out.batches)):
        var canon = render_batch(out.batches[b], CanonPolicy())
        for r in range(canon.num_rows()):
            var line = String()
            for c in range(len(canon.rows[r])):
                if c > 0:
                    line += "|"
                line += canon.rows[r][c]
            rows.append(line^)
    return rows^


def _sorted(var rows: List[String]) -> List[String]:
    for i in range(1, len(rows)):
        var j = i
        while j > 0 and rows[j - 1] > rows[j]:
            var t = rows[j - 1]
            rows[j - 1] = rows[j]
            rows[j] = t
            j -= 1
    return rows^


def _expect_rows(got: List[String], want: List[String], what: String) raises:
    assert_equal(len(got), len(want), what + ": row count")
    for i in range(len(want)):
        assert_equal(got[i], want[i], what + ": row " + String(i))


def _count(mut ctx: EngineContext, sql: String) raises -> String:
    var out = _run(ctx, sql)
    var rows = _cells(out)
    assert_equal(len(rows), 1, sql)
    return rows[0]


def _refusal(
    mut ctx: EngineContext, sql: String, step: String
) raises -> String:
    var out = run_sql(ctx, sql)
    assert_false(out.ok(), "expected a refusal: " + sql)
    assert_equal(out.refusal.value().step, step, sql)
    return out.refusal.value().reason


# ---- rows --------------------------------------------------------------------


def test_the_example_query_returns_the_rows_with_id_above_3() raises:
    var path = _write("rows.avro", _rows_ocf())
    var ctx = _new_context()
    var out = _run(
        ctx, "SELECT id, name FROM read_avro('" + path + "') WHERE id > 3"
    )
    var want: List[String] = ["4|n4", "5|\\N", "6|n6", "7|n7", "8|n8"]
    _expect_rows(_sorted(_cells(out)), want, "id > 3")


def test_each_codec_written_by_the_library_reads_the_same_rows() raises:
    var source = read_avro_bytes(Span(_rows_ocf()))
    var codecs: List[Int] = [
        AVRO_CODEC_NULL,
        AVRO_CODEC_DEFLATE,
        AVRO_CODEC_SNAPPY,
        AVRO_CODEC_ZSTANDARD,
    ]
    var names: List[String] = ["null", "deflate", "snappy", "zstandard"]
    var ctx = _new_context()
    for i in range(len(codecs)):
        var bytes = write_avro_bytes(source, AvroWriterOptions(codecs[i]))
        assert_equal(decode_ocf_header(Span(bytes)).codec_tag, codecs[i], names[i])
        var path = _write("codec_" + names[i] + ".avro", bytes)
        var out = _run(
            ctx,
            "SELECT id, name, qty FROM read_avro('" + path + "') ORDER BY id",
        )
        _expect_rows(_cells(out), _all_rows(), names[i])


def test_a_projection_returns_the_columns_in_the_query_order() raises:
    var path = _write("projection.avro", _rows_ocf())
    var ctx = _new_context()
    var out = _run(
        ctx, "SELECT qty, id FROM read_avro('" + path + "') ORDER BY id"
    )
    ref batch = out.batches[0]
    assert_equal(batch.schema.num_columns(), 2)
    assert_equal(batch.schema.field_name(0), "qty")
    assert_equal(batch.schema.field_name(1), "id")
    assert_true(batch.schema.field_arrow_type(0) == ArrowType.INT32)
    assert_true(batch.schema.field_arrow_type(1) == ArrowType.INT64)
    var want = List[String]()
    for id in range(1, 9):
        want.append(String(id * 10 - 25) + "|" + String(id))
    _expect_rows(_cells(out), want, "qty, id")


def test_count_star_and_a_null_filter_count_the_rows() raises:
    var path = _write("count.avro", _rows_ocf())
    var ctx = _new_context()
    assert_equal(_count(ctx, "SELECT count(*) FROM read_avro('" + path + "')"), "8")
    assert_equal(
        _count(
            ctx,
            "SELECT count(*) FROM read_avro('" + path + "') WHERE name IS NULL",
        ),
        "2",
    )


def test_decimal_date_and_timestamp_micros_read_at_their_types() raises:
    var path = _write("typed.avro", _typed_ocf())
    var ctx = _new_context()
    var out = _run(
        ctx,
        "SELECT id, price, d, ts, note FROM read_avro('" + path
        + "') ORDER BY id",
    )
    ref schema = out.batches[0].schema
    assert_true(schema.field_arrow_type(1) == ArrowType.DECIMAL128)
    assert_equal(schema.field_at(1).decimal_precision, 9)
    assert_equal(schema.field_at(1).decimal_scale, 2)
    assert_true(schema.field_arrow_type(2) == ArrowType.DATE32)
    assert_true(schema.field_arrow_type(3) == ArrowType.TIMESTAMP_US)
    assert_true(schema.field_arrow_type(4) == ArrowType.STRING)
    var want: List[String] = [
        "1|12345e-2|19000|1640995200000000|x",
        "2|-1e-2|0|0|\\N",
        "3|0e-2|-1|-1|z",
    ]
    _expect_rows(_cells(out), want, "typed")


def test_a_file_of_no_block_returns_no_row() raises:
    var path = _write("empty.avro", _ocf(_ROWS_SCHEMA, 0, List[UInt8]()))
    var ctx = _new_context()
    var out = _run(ctx, "SELECT id, name FROM read_avro('" + path + "')")
    assert_equal(len(_cells(out)), 0)
    assert_equal(_count(ctx, "SELECT count(*) FROM read_avro('" + path + "')"), "0")


# ---- refusals ----------------------------------------------------------------


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


def test_duration_enum_and_nested_record_are_refused_by_name() raises:
    var files: List[String] = ["duration.avro", "enum.avro", "record.avro"]
    var types: List[String] = [
        '{"type":"fixed","name":"D","size":12,"logicalType":"duration"}',
        '{"type":"enum","name":"E","symbols":["A","B"]}',
        '{"type":"record","name":"In","fields":[{"name":"x","type":"int"}]}',
    ]
    var messages: List[String] = [
        "AvroDecodeError.UNSUPPORTED_COLUMN_TYPE: column 'c' of the Avro file"
        " '{}' is a duration, which read_avro does not read yet",
        "AvroDecodeError.UNSUPPORTED_FIELD_KIND: column 'c' of the Avro file"
        " '{}' is an enum, which read_avro does not read yet",
        "AvroDecodeError.UNSUPPORTED_FIELD_KIND: column 'c' of the Avro file"
        " '{}' is a nested record, which read_avro does not read yet",
    ]
    var ctx = _new_context()
    for i in range(len(files)):
        var path = _write(files[i], _one_column(types[i]))
        var reason = _refusal(
            ctx, "SELECT * FROM read_avro('" + path + "')", STEP_EXECUTE
        )
        var want = messages[i].replace("{}", path)
        assert_true(want in reason, reason)


def test_a_glob_a_list_and_a_missing_file_are_refused() raises:
    var ctx = _new_context()
    var glob = _refusal(
        ctx, "SELECT * FROM read_avro('d/*.avro')", STEP_BIND
    )
    assert_true("read_avro('d/*.avro') names a glob" in glob, glob)
    var listed = _refusal(
        ctx, "SELECT * FROM read_avro(['a.avro', 'b.avro'])", STEP_PARSE
    )
    assert_true("read_avro expects a string path" in listed, listed)
    _ = _refusal(
        ctx,
        "SELECT * FROM read_avro('" + test_tmpdir() + "/absent.avro')",
        STEP_BIND,
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

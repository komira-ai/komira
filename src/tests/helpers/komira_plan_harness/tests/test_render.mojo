# What canon prints for each type, and that NULL comes from validity alone.
#
# test_every_cell_of_every_type spells every cell of fixtures_every_type: a
# renderer that ignores validity prints the value stored under a NULL (99,
# "garbage", 2.0, ...) and fails here for every type at once. The string
# `\N` must print as `\\N`, never as the NULL cell `\N`.
# test_table_with_zero_row_chunks: a zero-row chunk (an engine's empty
# morsel) whose dictionary and list columns have no dictionary or child must
# neither fail the schema check nor be read, and the schema comes from the
# first chunk that holds rows. test_zero_row_chunk_with_another_name_is_refused
# and test_zero_row_chunk_with_another_nullability_is_refused: a renderer that
# skips a zero-row chunk's Fields entirely passes an empty morsel whose
# column is renamed or changes nullability; both must be refused.
# test_zero_row_chunk_with_another_type_is_refused: a renderer that compares
# a zero-row chunk's names and nullability but not its top-level type passes
# an empty date32 morsel among int32 chunks. The decimal and time zone tests:
# one that compares only the top-level type passes an empty decimal128 of
# another precision or scale, or an empty timestamp in another time zone,
# though a chunk with rows and those Fields would be refused.

from std.memory import bitcast
from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field
from komira_arrow.table import Table
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer

from komira_plan_harness import (
    CanonPolicy,
    check_batch,
    parse_canon,
    render_batch,
    render_table,
)
from komira_plan_harness.fixtures import (
    BatchBuilder,
    all_valid,
    decimal_column,
    fixed_column,
    ints,
    list_column,
    small_decimal,
    string_column,
    varlen_column,
)
from komira_plan_harness.fixtures_every_type import every_type_batch


def _expected_cells() -> List[List[String]]:
    """Per column of every_type_batch, in order: name, then its three
    cells. A cell starting with `*` is a suffix (the float32 decimal is the
    standard library's)."""
    var t: List[List[String]] = [
        ["b", "true", "\\N", "false"],
        ["i8", "-128", "\\N", "127"],
        ["i16", "-32768", "\\N", "32767"],
        ["i32", "-2147483648", "\\N", "2147483647"],
        ["i64", "-9223372036854775808", "\\N", "9223372036854775807"],
        ["u8", "0", "\\N", "255"],
        ["u16", "0", "\\N", "65535"],
        ["u32", "0", "\\N", "4294967295"],
        ["u64", "0", "\\N", "18446744073709551615"],
        ["f16", "1.0|0x3C00", "\\N", "-inf|0xFC00"],
        ["f32", "*|0x3DCCCCCD", "\\N", "NaN|0x7FC00000"],
        ["f64", "1.5|0x3FF8000000000000", "\\N", "-0.0|0x8000000000000000"],
        ["d32", "-1", "\\N", "19000"],
        ["d64", "86400000", "\\N", "-1"],
        ["t32s", "0", "\\N", "86399"],
        ["t32ms", "1", "\\N", "2"],
        ["t64us", "3", "\\N", "4"],
        ["t64ns", "5", "\\N", "6"],
        ["ts_s", "-1", "\\N", "1700000000"],
        ["ts_ms", "7", "\\N", "8"],
        ["ts_us", "9", "\\N", "10"],
        ["ts_ns", "11", "\\N", "12"],
        ["ts", "13", "\\N", "14"],
        ["dur_s", "-15", "\\N", "16"],
        ["dur_ms", "17", "\\N", "18"],
        ["dur_us", "19", "\\N", "20"],
        ["dur_ns", "21", "\\N", "22"],
        ["iym", "-13", "\\N", "14"],
        ["idt", "1d500ms", "\\N", "-2d-1ms"],
        ["imdn", "1m2d3ns", "\\N", "-1m-2d-3ns"],
        ["dec", "12345e-2", "\\N", "-5e-2"],
        [
            "dec_big",
            "18446744073709551616e0",
            "\\N",
            "-170141183460469231731687303715884105728e0",
        ],
        [
            "dec256",
            "-1e-4",
            "\\N",
            "6277101735386680763835789423207666416102355444464034512896e-4",
        ],
        ["s", "héllo", "\\N", "\\\\N"],
        ["ls", "a\\tb", "\\N", ""],
        ["bin", "00ff", "\\N", ""],
        ["lbin", "ab", "\\N", "0102"],
        ["fsb", "dead", "\\N", "beef"],
        ["nul", "\\N", "\\N", "\\N"],
        ["dict_s", "y", "\\N", "x"],
        ["dict_f", "2.5|0x4004000000000000", "\\N", "-1.0|0xBFF0000000000000"],
        ["lst", "[1,\\N,3]", "\\N", "[]"],
        ["llst", "[a\\,b]", "[]", "\\N"],
        ["fsl", "[1,2]", "\\N", "[-3,\\N]"],
        ["st", "{a:1,b:x}", "\\N", "{a:3,b:\\N}"],
        ["mp", "{a:\\N,b:2}", "\\N", "{}"],
        ["us", "(5:10)", "(7:q)", "(5:\\N)"],
        ["ud", "(1:true)", "(0:100)", "(1:false)"],
    ]
    return t^


def test_every_cell_of_every_type() raises:
    var batch = every_type_batch()
    var got = render_batch(batch, CanonPolicy.total())
    var want = _expected_cells()
    assert_equal(got.num_columns(), len(want))
    assert_equal(got.num_rows(), 3)
    var bad = String()
    for c in range(len(want)):
        assert_equal(got.names[c], want[c][0])
        for r in range(3):
            var w = want[c][r + 1]
            var g = got.rows[r][c]
            var ok: Bool
            if w.startswith("*"):
                ok = g.endswith(String(w[byte = 1 : w.byte_length()]))
            else:
                ok = g == w
            if not ok:
                bad += "\n  " + want[c][0] + " row " + String(r) + ": want [" + w + "] got [" + g + "]"
    if bad.byte_length() > 0:
        raise Error("cells differ:" + bad)


def test_schema_spelling() raises:
    var got = render_batch(every_type_batch(), CanonPolicy.total())
    var want: List[String] = [
        "b:bool?",
        "ts_us:timestamp_us(UTC)?",
        "ts:timestamp_us?",
        "dec:decimal128(38,2)?",
        "dec256:decimal256(76,4)?",
        "fsb:fixed_size_binary(2)?",
        "dict_s:dictionary<int64,string>?",
        "dict_f:dictionary<int32,float64>?",
        "nul:null?",
        "lst:list<int32>?",
        "llst:large_list<string>?",
        "fsl:fixed_size_list(2)<int16>?",
        "st:struct<a:int32,b:string>?",
        "mp:map<string,int64>?",
        "us:union_sparse(5,7)<int32,string>?",
        "ud:union_dense(0,1)<int64,bool>?",
    ]
    for w in want:
        var found = False
        for e in got.schema:
            if e == w:
                found = True
        assert_true(found, String("schema entry missing: ") + w)
    # A non-nullable column has no `?`, and a name is escaped.
    var bb = BatchBuilder()
    var v: List[Int] = [1]
    bb.add(Field("a:b,c", ArrowType.INT32, False), fixed_column(ArrowType.INT32, 4, ints(v), all_valid(1)))
    var one = render_batch(bb.build(), CanonPolicy.total())
    assert_equal(one.schema[0], "a\\:b\\,c:int32")


def test_backslash_n_string_is_not_null() raises:
    """The string `\\N` and NULL must be different cells (a renderer that
    does not escape the backslash makes them equal)."""
    var vals: List[String] = ["\\N", "ignored", "a\\b"]
    var valid: List[Bool] = [True, False, True]
    var bb = BatchBuilder()
    bb.add(Field("s", ArrowType.STRING, True), string_column(vals, valid))
    var batch = bb.build()
    var got = render_batch(batch, CanonPolicy.total())
    assert_equal(got.rows[0][0], "\\\\N")
    assert_equal(got.rows[1][0], "\\N")
    assert_equal(got.rows[2][0], "a\\\\b")
    assert_true(got.rows[0][0] != got.rows[1][0])
    # The expected file that says "literal, NULL, literal" matches ...
    var good = String(
        "#! komira-plan-conformance v1\n#  order: total\n#  float: ulps=0\n"
        "s:string?\n\\\\N\n\\N\na\\\\b\n"
    )
    assert_true(check_batch(good, batch).ok())
    # ... and one that says NULL where the value is the string `\N` does not.
    var wrong = String(
        "#! komira-plan-conformance v1\n#  order: total\n#  float: ulps=0\n"
        "s:string?\n\\N\n\\N\na\\\\b\n"
    )
    var report = check_batch(wrong, batch)
    assert_equal(report.count(), 1)
    assert_equal(report.mismatches[0].row, 0)


def test_escapes_and_invalid_utf8() raises:
    var raw = List[List[UInt8]]()
    var r0: List[UInt8] = [0xFF, 0x41, 0xC3, 0xA9, 0x01, 0x09, 0x0A, 0x0D]
    raw.append(r0^)
    var bb = BatchBuilder()
    bb.add(Field("s", ArrowType.STRING, False), varlen_column(ArrowType.STRING, raw, all_valid(1)))
    var got = render_batch(bb.build(), CanonPolicy.total())
    assert_equal(got.rows[0][0], "\\xffAé\\x01\\t\\n\\r")


def _one_column_batch(t: ArrowType) raises -> RecordBatch:
    var bb = BatchBuilder()
    bb.add(
        Field("v", t, True),
        Column[HeapRegion](
            arrow_type=t,
            data=OwnedAlignedBuffer(16),
            offsets=None,
            validity=None,
            length=1,
            null_count=0,
            offset=0,
        ),
    )
    return bb.build()


def test_types_canon_cannot_render_are_refused_by_name() raises:
    var ts: List[ArrowType] = [
        ArrowType.BINARY_VIEW,
        ArrowType.UTF8_VIEW,
        ArrowType.LIST_VIEW,
        ArrowType.LARGE_LIST_VIEW,
    ]
    var names: List[String] = [
        "binary_view", "utf8_view", "list_view", "large_list_view"
    ]
    for i in range(len(ts)):
        var batch = _one_column_batch(ts[i])
        with assert_raises(contains=String("of type ") + names[i]):
            _ = render_batch(batch, CanonPolicy.total())


def test_field_and_column_must_agree() raises:
    var bb = BatchBuilder()
    var v: List[Int] = [1]
    bb.add(Field("v", ArrowType.INT32, True), fixed_column(ArrowType.INT64, 8, ints(v), all_valid(1)))
    var batch = bb.build()
    with assert_raises(contains="field says int32, column holds int64"):
        _ = render_batch(batch, CanonPolicy.total())


def test_selection_mask_drops_rows() raises:
    var bb = BatchBuilder()
    var v: List[Int] = [1, 2, 3]
    bb.add(Field("v", ArrowType.INT32, False), fixed_column(ArrowType.INT32, 4, ints(v), all_valid(3)))
    var batch = bb.build()
    var mask = BooleanArray.allocate(3)
    mask.set(0, True)
    mask.set(1, False)
    mask.set(2, True)
    batch.set_selection_mask(mask^)
    var got = render_batch(batch, CanonPolicy.total())
    assert_equal(got.num_rows(), 2)
    assert_equal(got.rows[0][0], "1")
    assert_equal(got.rows[1][0], "3")


def _int_batch(a: Int, b: Int) raises -> RecordBatch:
    var bb = BatchBuilder()
    var v: List[Int] = [a, b]
    bb.add(Field("v", ArrowType.INT64, False), fixed_column(ArrowType.INT64, 8, ints(v), all_valid(2)))
    return bb.build()


def test_table_renders_chunks_in_order() raises:
    var chunks = List[RecordBatch]()
    chunks.append(_int_batch(1, 2))
    chunks.append(_int_batch(3, 4))
    var schema = chunks[0].schema.copy()
    var table = Table.from_chunks(chunks^, schema^)
    var got = render_table(table, CanonPolicy.total())
    assert_equal(got.num_rows(), 4)
    for r in range(4):
        assert_equal(got.rows[r][0], String(r + 1))
    # The text form parses back to the same rows.
    var again = parse_canon(got.to_text())
    assert_equal(again.num_rows(), 4)


def _dict_batch(rows: Int) raises -> RecordBatch:
    """Two dictionary columns (string values, float64 values) and a
    list<int32> holding `rows` rows; with 0 rows they hold no dictionary and
    no child column, as an engine's empty morsel may, so the dictionaries
    spell `dictionary<index>` without a value type and the list cannot be
    read as a list."""
    var bb = BatchBuilder()
    var fs = Field.dictionary("s", ArrowType.INT64, False)
    var ff = Field.dictionary("f", ArrowType.INT32, False)
    var fl = Field.list_of("l", ArrowType.INT32, False)
    if rows == 0:
        bb.add(fs, _empty_column(ArrowType.DICTIONARY))
        bb.add(ff, _empty_column(ArrowType.DICTIONARY))
        bb.add(fl, _empty_column(ArrowType.LIST))
        return bb.build()
    var codes64 = List[Int64]()
    var codes = PrimitiveArray[DType.int32].allocate(rows)
    for r in range(rows):
        codes64.append(Int64(r % 2))
        codes.set(r, Int32(r % 2))
    var sv: List[String] = ["x", "y"]
    bb.add(fs, Column.from_int64_dict_indices(codes64^, sv^))
    var fv: List[Int64] = [
        bitcast[DType.int64](Float64(2.5)),
        bitcast[DType.int64](Float64(-1.0)),
    ]
    bb.add(ff, Column.from_numeric_dict[DType.int32, DType.float64](codes^, fv^))
    var items = List[Int]()
    var offs: List[Int] = [0]
    for r in range(rows):
        items.append(r)
        offs.append(r + 1)
    bb.add(fl, list_column(fixed_column(ArrowType.INT32, 4, ints(items), all_valid(rows)), offs, all_valid(rows)))
    return bb.build()


def _empty_column(t: ArrowType) -> Column[HeapRegion]:
    return Column[HeapRegion](
        arrow_type=t,
        data=OwnedAlignedBuffer(0),
        offsets=None,
        validity=None,
        length=0,
        null_count=0,
        offset=0,
    )


def test_table_with_zero_row_chunks() raises:
    """Engines emit empty morsels. A zero-row dictionary chunk has no value
    layout, so its schema text is not a full chunk's: render_table must
    skip it in the schema check and spell the schema (and the float widths)
    from the first chunk that holds rows, wherever that chunk is."""
    var chunks = List[RecordBatch]()
    chunks.append(_dict_batch(0))
    chunks.append(_dict_batch(2))
    chunks.append(_dict_batch(0))
    chunks.append(_dict_batch(1))
    var schema = chunks[1].schema.copy()
    var table = Table.from_chunks(chunks^, schema^)
    var got = render_table(table, CanonPolicy.total())
    assert_equal(got.schema[0], "s:dictionary<int64,string>")
    assert_equal(got.schema[1], "f:dictionary<int32,float64>")
    assert_equal(got.float_widths[1], 64)
    assert_equal(got.num_rows(), 3)
    assert_equal(got.rows[1][0], "y")
    assert_equal(got.rows[2][1], "2.5|0x4004000000000000")
    assert_equal(got.rows[2][2], "[0]")
    # Every chunk empty: the rows are none and the schema is chunk 0's.
    var empties = List[RecordBatch]()
    empties.append(_dict_batch(0))
    empties.append(_dict_batch(0))
    var es = empties[0].schema.copy()
    var none = render_table(Table.from_chunks(empties^, es^), CanonPolicy.total())
    assert_equal(none.num_rows(), 0)
    assert_equal(none.schema[0], "s:dictionary<int64>")


def _int32_batch(name: String, nullable: Bool, rows: Int) raises -> RecordBatch:
    var bb = BatchBuilder()
    var vals = List[Int]()
    for r in range(rows):
        vals.append(r)
    bb.add(
        Field(name, ArrowType.INT32, nullable),
        fixed_column(ArrowType.INT32, 4, ints(vals), all_valid(rows)),
    )
    return bb.build()


def test_zero_row_chunk_with_another_name_is_refused() raises:
    """An empty chunk is not rendered, but its column names are the
    result's: a zero-row chunk naming its column `b` where the others name
    it `a` is refused, before or after the chunk that holds rows."""
    for at_front in range(2):
        var chunks = List[RecordBatch]()
        if at_front == 1:
            chunks.append(_int32_batch("b", False, 0))
        chunks.append(_int32_batch("a", False, 2))
        if at_front == 0:
            chunks.append(_int32_batch("b", False, 0))
        var schema = chunks[at_front].schema.copy()
        var table = Table.from_chunks(chunks^, schema^)
        with assert_raises(contains="(zero rows) has another column name"):
            _ = render_table(table, CanonPolicy.total())
    # The same name and nullability passes.
    var ok = List[RecordBatch]()
    ok.append(_int32_batch("a", False, 0))
    ok.append(_int32_batch("a", False, 2))
    var os = ok[1].schema.copy()
    assert_equal(render_table(Table.from_chunks(ok^, os^), CanonPolicy.total()).num_rows(), 2)


def test_zero_row_chunk_with_another_nullability_is_refused() raises:
    """A zero-row chunk whose column is nullable where the others' is not
    (or not where they are) is refused; with every chunk empty, chunk 0 is
    the reference."""
    var chunks = List[RecordBatch]()
    chunks.append(_int32_batch("a", False, 2))
    chunks.append(_int32_batch("a", True, 0))
    var schema = chunks[0].schema.copy()
    with assert_raises(contains="(zero rows) has another column name"):
        _ = render_table(Table.from_chunks(chunks^, schema^), CanonPolicy.total())
    var empties = List[RecordBatch]()
    empties.append(_int32_batch("a", True, 0))
    empties.append(_int32_batch("a", False, 0))
    var es = empties[0].schema.copy()
    with assert_raises(contains="(zero rows) has another column name"):
        _ = render_table(Table.from_chunks(empties^, es^), CanonPolicy.total())


def _one_field_batch(f: Field, rows: Int) raises -> RecordBatch:
    """One column of `rows` rows for an int32, date32, timestamp or
    decimal128 Field."""
    var bb = BatchBuilder()
    var t = f.arrow_type
    if t == ArrowType.DECIMAL128:
        var limbs = List[List[UInt64]]()
        for r in range(rows):
            limbs.append(small_decimal(r, 2))
        bb.add(f, decimal_column(t, limbs, f.decimal_scale, all_valid(rows)))
        return bb.build()
    var vals = List[Int]()
    for r in range(rows):
        vals.append(r)
    var width = 4 if (t == ArrowType.INT32 or t == ArrowType.DATE32) else 8
    bb.add(f, fixed_column(t, width, ints(vals), all_valid(rows)))
    return bb.build()


def _zero_row_second(full: Field, empty: Field) raises -> Table:
    """A chunk of two rows with Field `full`, then a zero-row chunk with
    Field `empty`."""
    var chunks = List[RecordBatch]()
    chunks.append(_one_field_batch(full, 2))
    chunks.append(_one_field_batch(empty, 0))
    var schema = chunks[0].schema.copy()
    return Table.from_chunks(chunks^, schema^)


def test_zero_row_chunk_with_another_type_is_refused() raises:
    """A zero-row chunk whose column has the others' name and nullability
    but another top-level type (date32 where they hold int32) is refused,
    before or after the chunk that holds rows. The pair shares one buffer
    layout, so Table.from_chunks admits it (a pair it refuses, such as int64
    under int32, never reaches canon) and the refusal must be canon's."""
    var date = Field("a", ArrowType.DATE32, False)
    var narrow = Field("a", ArrowType.INT32, False)
    with assert_raises(contains="(zero rows) has another column name, type"):
        _ = render_table(_zero_row_second(narrow, date), CanonPolicy.total())
    var chunks = List[RecordBatch]()
    chunks.append(_one_field_batch(date, 0))
    chunks.append(_one_field_batch(narrow, 2))
    var schema = chunks[1].schema.copy()
    with assert_raises(contains="(zero rows) has another column name, type"):
        _ = render_table(Table.from_chunks(chunks^, schema^), CanonPolicy.total())
    # The same type passes.
    var same = render_table(_zero_row_second(narrow, narrow), CanonPolicy.total())
    assert_equal(same.num_rows(), 2)


def test_zero_row_chunk_with_another_decimal_is_refused() raises:
    """A zero-row decimal128 chunk whose Field has another scale, or another
    precision, than the reference's is refused; the same pair passes."""
    var ref_f = Field.decimal128("d", 38, 2, True)
    var other_scale = Field.decimal128("d", 38, 3, True)
    var other_precision = Field.decimal128("d", 20, 2, True)
    with assert_raises(contains="(zero rows) has another column name, type"):
        _ = render_table(_zero_row_second(ref_f, other_scale), CanonPolicy.total())
    with assert_raises(contains="(zero rows) has another column name, type"):
        _ = render_table(_zero_row_second(ref_f, other_precision), CanonPolicy.total())
    var same = render_table(_zero_row_second(ref_f, ref_f), CanonPolicy.total())
    assert_equal(same.num_rows(), 2)
    assert_equal(same.schema[0], "d:decimal128(38,2)?")


def test_zero_row_chunk_with_another_time_zone_is_refused() raises:
    """A zero-row timestamp chunk whose Field names another time zone, or
    none, where the reference names UTC is refused; the same zone passes."""
    var utc = Field.timestamp("t", ArrowType.TIMESTAMP_US, "UTC", False)
    var other = Field.timestamp("t", ArrowType.TIMESTAMP_US, "Europe/Paris", False)
    var naive = Field.timestamp("t", ArrowType.TIMESTAMP_US, "", False)
    with assert_raises(contains="(zero rows) has another column name, type"):
        _ = render_table(_zero_row_second(utc, other), CanonPolicy.total())
    with assert_raises(contains="(zero rows) has another column name, type"):
        _ = render_table(_zero_row_second(utc, naive), CanonPolicy.total())
    var same = render_table(_zero_row_second(utc, utc), CanonPolicy.total())
    assert_equal(same.num_rows(), 2)
    assert_equal(same.schema[0], "t:timestamp_us(UTC)")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

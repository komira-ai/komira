# What canon prints for each type, and that NULL comes from validity alone.
#
# test_every_cell_of_every_type spells every cell of fixtures_every_type: a
# renderer that ignores validity prints the value stored under a NULL (99,
# "garbage", 2.0, ...) and fails here for every type at once. The string
# `\N` must print as `\\N`, never as the NULL cell `\N`.

from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
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
    fixed_column,
    ints,
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
        ["mp", "{a:1,b:2}", "\\N", "{}"],
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
        "ts:timestamp?",
        "dec:decimal128(38,2)?",
        "dec256:decimal256(76,4)?",
        "dict_s:dictionary(int64)?",
        "nul:null?",
        "lst:list<item:int32?>?",
        "llst:large_list<item:string?>?",
        "fsl:fixed_size_list<item:int16?>?",
        "st:struct<a:int32,b:string?>?",
        "mp:map<entries:struct>?",
        "us:union_sparse(5,7)?",
        "ud:union_dense(0,1)?",
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
        ArrowType.ERROR,
    ]
    var names: List[String] = [
        "binary_view", "utf8_view", "list_view", "large_list_view", "error"
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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

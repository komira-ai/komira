# The type tree in the schema line, floats inside nested and dictionary
# columns, names that start with `#`, and slice offsets on every layout.
#
# Defects these catch: a schema line that spells only one level (two columns
# whose cells read alike, e.g. map<int32,string> and map<string,string>, get
# the same line); a nested float whose text depends on a decimal printer (a
# Python oracle could never match it); a dictionary float compared by its
# decimal text; a leading `#` read as a comment; a renderer that drops a
# column's slice offset on any layout, a dictionary's included; a dense union
# read by child index instead of type code; a map whose duplicate keys print
# in input order.

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer

from komira_plan_harness import CanonPolicy, check_batch, parse_canon, render_batch
from komira_plan_harness.fixtures import (
    BatchBuilder,
    all_valid,
    bool_column,
    decimal_column,
    fixed_column,
    ints,
    list_column,
    map_column,
    sliced,
    small_decimal,
    string_column,
    struct_column,
    union_column,
)


def _one(f: Field, var col: Column[HeapRegion]) raises -> RecordBatch:
    var bb = BatchBuilder()
    bb.add(f, col^)
    return bb.build()


def _u64(a: UInt64) -> List[UInt64]:
    var v: List[UInt64] = [a]
    return v^


# ---------------------------------------------------------------------------
# Floats inside nested values and dictionaries
# ---------------------------------------------------------------------------


def _nested_float_batch() raises -> RecordBatch:
    var bb = BatchBuilder()
    var lv: List[UInt64] = [0x3FF8000000000000, 0x8000000000000000, 0xFFF8000000000000]
    var lo: List[Int] = [0, 3]
    bb.add(
        Field.list_of("l", ArrowType.FLOAT64, False),
        list_column(fixed_column(ArrowType.FLOAT64, 8, lv, all_valid(3)), lo, all_valid(1)),
    )
    var sf = Field("s", ArrowType.STRUCT, False)
    sf.add_child("a", ArrowType.FLOAT32, True)
    sf.add_child("b", ArrowType.FLOAT16, True)
    bb.add(
        sf,
        struct_column(
            fixed_column(ArrowType.FLOAT32, 4, _u64(0x3DCCCCCD), all_valid(1)), "a",
            fixed_column(ArrowType.FLOAT16, 2, _u64(0x2E66), all_valid(1)), "b",
            all_valid(1),
        ),
    )
    var mk: List[String] = ["k"]
    var mo: List[Int] = [0, 1]
    bb.add(
        Field("m", ArrowType.MAP, False),
        map_column(
            string_column(mk, all_valid(1)),
            fixed_column(ArrowType.FLOAT64, 8, _u64(0x4004000000000000), all_valid(1)),
            mo,
            all_valid(1),
        ),
    )
    var codes = PrimitiveArray[DType.int32].allocate(1)
    codes.set(0, 0)
    var dv: List[Int64] = [Int64(0x3DCCCCCD)]
    bb.add(
        Field.dictionary("d", ArrowType.INT32, False),
        Column.from_numeric_dict[DType.int32, DType.float32](codes^, dv^),
    )
    bb.add(
        Field("h", ArrowType.FLOAT16, False),
        fixed_column(ArrowType.FLOAT16, 2, _u64(0x2E66), all_valid(1)),
    )
    return bb.build()


def test_floats_inside_nested_values_are_bits() raises:
    var got = render_batch(_nested_float_batch(), CanonPolicy.total())
    assert_equal(got.rows[0][0], "[0x3FF8000000000000,0x8000000000000000,NaN]")
    assert_equal(got.rows[0][1], "{a:0x3DCCCCCD,b:0x2E66}")
    assert_equal(got.rows[0][2], "{k:0x4004000000000000}")
    assert_true(got.rows[0][3].endswith("|0x3DCCCCCD"))
    assert_equal(got.float_widths[3], 32)
    assert_equal(got.schema[3], "d:dictionary<int32,float32>")


def test_a_python_spelling_of_the_same_floats_matches() raises:
    """What an oracle writes: exact decimals Mojo does not print (float32
    0.1 in full, float16 0.1 as 0.0999755859375), nested floats as bits, a
    NaN payload of another machine inside a list."""
    var expected = String(
        "#! komira-plan-conformance v1\n#  order: total\n#  float: ulps=0\n"
        "l:list<float64>\ts:struct<a:float32,b:float16>\tm:map<string,float64>\t"
        "d:dictionary<int32,float32>\th:float16\n"
        "[0x3FF8000000000000,0x8000000000000000,NaN]\t{a:0x3DCCCCCD,b:0x2E66}\t"
        "{k:0x4004000000000000}\t0.100000001490116119384765625|0x3DCCCCCD\t"
        "0.0999755859375\n"
    )
    var report = check_batch(expected, _nested_float_batch())
    if not report.ok():
        raise Error(String(report))


def test_a_dictionary_of_floats_takes_the_tolerance() raises:
    var expected = String(
        "#! komira-plan-conformance v1\n#  order: total\n#  float: ulps=1\n"
        "l:list<float64>\ts:struct<a:float32,b:float16>\tm:map<string,float64>\t"
        "d:dictionary<int32,float32>\th:float16\n"
        "[0x3FF8000000000000,0x8000000000000000,NaN]\t{a:0x3DCCCCCD,b:0x2E66}\t"
        "{k:0x4004000000000000}\t0.10000000894069671630859375|0x3DCCCCCE\t"
        "0.0999755859375\n"
    )
    assert_true(check_batch(expected, _nested_float_batch()).ok())


# ---------------------------------------------------------------------------
# The type tree
# ---------------------------------------------------------------------------


def _entry_and_cell(f: Field, var col: Column[HeapRegion]) raises -> Tuple[String, String]:
    var got = render_batch(_one(f, col^), CanonPolicy.total())
    return (got.schema[0], got.rows[0][0])


def test_types_whose_cells_read_alike_spell_apart() raises:
    var one: List[Int] = [1]
    var x: List[String] = ["x"]
    var s1: List[String] = ["1"]
    var mo: List[Int] = [0, 1]
    var a = _entry_and_cell(
        Field("m", ArrowType.MAP, False),
        map_column(fixed_column(ArrowType.INT32, 4, ints(one), all_valid(1)),
                   string_column(x, all_valid(1)), mo, all_valid(1)),
    )
    var b = _entry_and_cell(
        Field("m", ArrowType.MAP, False),
        map_column(string_column(s1, all_valid(1)), string_column(x, all_valid(1)), mo, all_valid(1)),
    )
    assert_equal(a[1], b[1])
    assert_equal(a[0], "m:map<int32,string>")
    assert_equal(b[0], "m:map<string,string>")

    var two: List[Int] = [2]
    var c = _entry_and_cell(
        Field("l", ArrowType.LIST, False),
        list_column(
            struct_column(fixed_column(ArrowType.INT32, 4, ints(one), all_valid(1)), "a",
                          fixed_column(ArrowType.INT32, 4, ints(two), all_valid(1)), "b",
                          all_valid(1)),
            mo, all_valid(1),
        ),
    )
    var d = _entry_and_cell(
        Field("l", ArrowType.LIST, False),
        list_column(
            struct_column(string_column(s1, all_valid(1)), "a",
                          fixed_column(ArrowType.INT32, 4, ints(two), all_valid(1)), "b",
                          all_valid(1)),
            mo, all_valid(1),
        ),
    )
    assert_equal(c[1], d[1])
    assert_equal(c[0], "l:list<struct<a:int32,b:int32>>")
    assert_equal(d[0], "l:list<struct<a:string,b:int32>>")

    var codes64: List[Int64] = [0]
    var dvals: List[String] = ["5"]
    var e = _entry_and_cell(
        Field.dictionary("d", ArrowType.INT64, False),
        Column.from_int64_dict_indices(codes64^, dvals^),
    )
    var codes = PrimitiveArray[DType.int64].allocate(1)
    codes.set(0, 0)
    var nv: List[Int64] = [5]
    var f = _entry_and_cell(
        Field.dictionary("d", ArrowType.INT64, False),
        Column.from_numeric_dict[DType.int64, DType.int64](codes^, nv^),
    )
    assert_equal(e[1], f[1])
    assert_equal(e[0], "d:dictionary<int64,string>")
    assert_equal(f[0], "d:dictionary<int64,int64>")


def test_a_name_starting_with_hash_is_escaped() raises:
    var v: List[Int] = [7]
    var batch = _one(Field("#x", ArrowType.INT32, False), fixed_column(ArrowType.INT32, 4, ints(v), all_valid(1)))
    var got = render_batch(batch, CanonPolicy.total())
    assert_equal(got.schema[0], "\\#x:int32")
    var again = parse_canon(got.to_text())
    assert_equal(again.num_columns(), 1)
    assert_equal(again.rows[0][0], "7")
    assert_true(check_batch(got.to_text(), batch).ok())


def test_duplicate_map_keys_have_one_text() raises:
    var k: List[String] = ["k", "k"]
    var v1: List[Int] = [2, 1]
    var v2: List[Int] = [1, 2]
    var mo: List[Int] = [0, 2]
    var a = _entry_and_cell(
        Field("m", ArrowType.MAP, False),
        map_column(string_column(k, all_valid(2)), fixed_column(ArrowType.INT64, 8, ints(v1), all_valid(2)), mo, all_valid(1)),
    )
    var b = _entry_and_cell(
        Field("m", ArrowType.MAP, False),
        map_column(string_column(k, all_valid(2)), fixed_column(ArrowType.INT64, 8, ints(v2), all_valid(2)), mo, all_valid(1)),
    )
    assert_equal(a[1], "{k:1,k:2}")
    assert_equal(b[1], a[1])


# ---------------------------------------------------------------------------
# Slice offsets
# ---------------------------------------------------------------------------


def test_slice_offsets_on_every_layout() raises:
    var bb = BatchBuilder()
    var i3: List[Int] = [10, 20, 30]
    bb.add(Field("i", ArrowType.INT32, False), sliced(fixed_column(ArrowType.INT32, 4, ints(i3), all_valid(3)), 1))
    var n3: List[Int] = [1, 99, 3]
    var nv: List[Bool] = [True, False, True]
    bb.add(Field("n", ArrowType.INT64, True), sliced(fixed_column(ArrowType.INT64, 8, ints(n3), nv), 1))
    var bv: List[Bool] = [True, True, True, False, True]
    bb.add(Field("b", ArrowType.BOOL, False), sliced(bool_column(bv, all_valid(5)), 3))
    var sv: List[String] = ["a", "b", "c"]
    bb.add(Field("s", ArrowType.STRING, False), sliced(string_column(sv, all_valid(3)), 1))
    var li: List[Int] = [1, 2, 3, 4]
    var lo: List[Int] = [0, 1, 3, 4]
    bb.add(
        Field.list_of("l", ArrowType.INT32, False),
        sliced(list_column(fixed_column(ArrowType.INT32, 4, ints(li), all_valid(4)), lo, all_valid(3)), 1),
    )
    var fi: List[Int] = [1, 2, 3, 4, 5, 6]
    bb.add(
        Field("f", ArrowType.FIXED_SIZE_LIST, False),
        sliced(Column.from_fixed_size_list(fixed_column(ArrowType.INT16, 2, ints(fi), all_valid(6)), 2, 3), 1),
    )
    var fsb = OwnedAlignedBuffer(6)
    var fb: List[UInt8] = [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]
    for k in range(6):
        fsb.write_u8_at(k, fb[k])
    bb.add(Field("x", ArrowType.FIXED_SIZE_BINARY, False), sliced(Column.from_fixed_size_binary(fsb^, 2, 3), 1))
    var dl = List[List[UInt64]]()
    for v in [1, 2, 3]:
        dl.append(small_decimal(v, 2))
    bb.add(Field.decimal128("dec", 38, 0, False), sliced(decimal_column(ArrowType.DECIMAL128, dl, 0, all_valid(3)), 1))
    var sa: List[Int] = [1, 2, 3]
    var sb: List[String] = ["x", "y", "z"]
    bb.add(
        Field("st", ArrowType.STRUCT, False),
        sliced(struct_column(fixed_column(ArrowType.INT32, 4, ints(sa), all_valid(3)), "a",
                             string_column(sb, all_valid(3)), "b", all_valid(3)), 1),
    )
    var mk: List[String] = ["a", "b", "c"]
    var mv: List[Int] = [1, 2, 3]
    var mo: List[Int] = [0, 1, 2, 3]
    bb.add(
        Field("m", ArrowType.MAP, False),
        sliced(map_column(string_column(mk, all_valid(3)), fixed_column(ArrowType.INT64, 8, ints(mv), all_valid(3)), mo, all_valid(3)), 1),
    )
    var ua: List[Int] = [10, 11, 12]
    var ub: List[String] = ["p", "q", "r"]
    var ucodes: List[Int] = [5, 7, 5]
    var uids: List[Int] = [5, 7]
    bb.add(
        Field.union("us", ArrowType.UNION_SPARSE, uids, False),
        sliced(union_column(False, ucodes, List[Int](), fixed_column(ArrowType.INT32, 4, ints(ua), all_valid(3)),
                            string_column(ub, all_valid(3)), uids), 1),
    )
    # Dense, with type codes (5, 9) that are not the child indices (0, 1).
    var da: List[Int] = [100]
    var dbv: List[Bool] = [True, False]
    var dcodes: List[Int] = [9, 5, 9]
    var doffs: List[Int] = [0, 0, 1]
    var dids: List[Int] = [5, 9]
    bb.add(
        Field.union("ud", ArrowType.UNION_DENSE, dids, False),
        sliced(union_column(True, dcodes, doffs, fixed_column(ArrowType.INT64, 8, ints(da), all_valid(1)),
                            bool_column(dbv, all_valid(2)), dids), 1),
    )
    # Dictionaries: the offset goes through dict_code_at, for 8-byte codes
    # into strings and 4-byte codes into numbers. Codes read without the
    # offset give the rows reversed.
    var dc64: List[Int64] = [1, 0, 1]
    var dsv: List[String] = ["p", "q"]
    bb.add(Field.dictionary("ds", ArrowType.INT64, False), sliced(Column.from_int64_dict_indices(dc64^, dsv^), 1))
    var dc32 = PrimitiveArray[DType.int32].allocate(3)
    dc32.set(0, 0)
    dc32.set(1, 1)
    dc32.set(2, 0)
    var dnv: List[Int64] = [7, 8]
    bb.add(
        Field.dictionary("dn", ArrowType.INT32, False),
        sliced(Column.from_numeric_dict[DType.int32, DType.int64](dc32^, dnv^), 1),
    )
    var got = render_batch(bb.build(), CanonPolicy.total())
    var want: List[List[String]] = [
        ["20", "\\N", "false", "b", "[2,3]", "[3,4]", "ccdd", "2e0", "{a:2,b:y}", "{b:2}", "(7:q)", "(5:100)", "p", "8"],
        ["30", "3", "true", "c", "[4]", "[5,6]", "eeff", "3e0", "{a:3,b:z}", "{c:3}", "(5:12)", "(9:false)", "q", "7"],
    ]
    var bad = String()
    for r in range(2):
        for c in range(len(want[r])):
            if got.rows[r][c] != want[r][c]:
                bad += "\n  " + got.names[c] + " row " + String(r) + ": want [" + want[r][c] + "] got [" + got.rows[r][c] + "]"
    if bad.byte_length() > 0:
        raise Error("sliced cells differ:" + bad)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

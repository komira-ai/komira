# The composite join's NULL keys over STRING, string-dictionary and mixed keys:
# a NULL in the later key matches nothing, on the build side, on the probe side
# and on both at once, even though the value under its cleared validity bit
# equals a real key on the other side. INNER emits only the pairs of valid
# rows; LEFT emits every probe row once, with build index -1 for the row whose
# key is NULL or whose build partner is NULL.
#
# Build rows hold [a, b, c] on the later key and probe rows hold [a, b, c], so
# the only joinable pairs are (0, 0) and (2, 2) once row 1 is NULL.

from std.testing import TestSuite, assert_equal

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.dictionary_array import StringDictionaryArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion

from komira_op_join_probe.join_key_extract import (
    extract_join_key_columns_serial,
)
from komira_op_join_probe.join_multi_key_builder import (
    MultiKeyHashJoinBuilder,
)

comptime ROWS = 3

# Which side holds the NULL in the later key.
comptime BUILD_NULL = 0
comptime PROBE_NULL = 1
comptime BOTH_NULL = 2

# The kind of the leading key; the later key is a string or a dictionary.
comptime LEAD_STRING = 0
comptime LEAD_DICT = 1
comptime LEAD_INT = 2


def _words() -> List[String]:
    var out = List[String]()
    out.append(String("a"))
    out.append(String("b"))
    out.append(String("c"))
    return out^


def _lead_col(lead: Int) raises -> Column[HeapRegion]:
    """The leading key: the same value on every row, never NULL."""
    if lead == LEAD_INT:
        var arr = PrimitiveArray[DType.int64].allocate(ROWS)
        var p = arr._typed_ptr_mut()
        for i in range(ROWS):
            p.store[width=1](i, Int64(5))
        return Column.from_primitive[DType.int64](arr^)
    if lead == LEAD_DICT:
        var idx = PrimitiveArray[DType.int32].allocate(ROWS)
        var p = idx._typed_ptr_mut()
        for i in range(ROWS):
            p.store[width=1](i, Int32(0))
        var one = List[String]()
        one.append(String("lead"))
        var da = StringDictionaryArray.from_parts(
            idx^, StringArray.from_strings(one)
        )
        return Column.from_dictionary(da)
    var same = List[String]()
    for _ in range(ROWS):
        same.append(String("lead"))
    return Column.from_string(StringArray.from_strings(same))


def _lead_type(lead: Int) -> ArrowType:
    if lead == LEAD_INT:
        return ArrowType.INT64
    if lead == LEAD_DICT:
        return ArrowType.DICTIONARY
    return ArrowType.STRING


def _later_string(has_null: Bool) raises -> Column[HeapRegion]:
    """The later key as STRING; row 1 is NULL but still holds the text `b`."""
    var valid = List[Bool]()
    for i in range(ROWS):
        valid.append(not (has_null and i == 1))
    var sa = StringArray.from_strings_with_validity(_words(), valid)
    return Column.from_string(sa^)


def _later_dict(has_null: Bool) raises -> Column[HeapRegion]:
    """The later key as a string dictionary; row 1 is NULL but its code points
    at `b`. Both sides share one dictionary, so the keys compare by code.
    """
    var idx = PrimitiveArray[DType.int32].allocate_nullable(ROWS)
    var p = idx._typed_ptr_mut()
    for i in range(ROWS):
        p.store[width=1](i, Int32(i))
    if has_null:
        idx._set_null(1)
    var da = StringDictionaryArray.from_parts(
        idx^, StringArray.from_strings(_words())
    )
    return Column.from_dictionary(da)


def _batch(
    var lead: Column[HeapRegion],
    var later: Column[HeapRegion],
    lead_type: ArrowType,
    later_type: ArrowType,
) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k0"), lead_type, False))
    sb.add_field(Field(String("k1"), later_type, True))
    var b = RecordBatchBuilder()
    b.add_column(lead^)
    b.add_column(later^)
    return b.build(sb.build())


def _side(lead: Int, later_dict: Bool, has_null: Bool) raises -> RecordBatch:
    if later_dict:
        return _batch(
            _lead_col(lead),
            _later_dict(has_null),
            _lead_type(lead),
            ArrowType.DICTIONARY,
        )
    return _batch(
        _lead_col(lead),
        _later_string(has_null),
        _lead_type(lead),
        ArrowType.STRING,
    )


def _names() -> List[String]:
    var out = List[String]()
    out.append(String("k0"))
    out.append(String("k1"))
    return out^


def _run(
    lead: Int, later_dict: Bool, null_side: Int, left: Bool, what: String
) raises:
    """Join and require that probe row 1 finds nothing: INNER emits the pairs
    (0, 0) and (2, 2); LEFT emits probe rows 0 and 2 with their partners and
    probe row 1 with build index -1.
    """
    var build_null = null_side == BUILD_NULL or null_side == BOTH_NULL
    var probe_null = null_side == PROBE_NULL or null_side == BOTH_NULL
    var build = _side(lead, later_dict, build_null)
    var probe = _side(lead, later_dict, probe_null)
    var names = _names()
    var bkeys = extract_join_key_columns_serial(build, names)
    var builder = MultiKeyHashJoinBuilder.build(bkeys^)
    var pkeys = extract_join_key_columns_serial(probe, names)
    var bm = List[Int]()
    var pm = List[Int]()
    if left:
        builder.probe_left_into(pkeys, bm, pm)
    else:
        builder.probe_inner_into(pkeys, bm, pm)
    var want = ROWS if left else ROWS - 1
    assert_equal(len(bm), want, what + ": wrong match count")
    assert_equal(len(pm), want, what + ": wrong probe index count")
    var seen = List[Int]()
    for _ in range(ROWS):
        seen.append(-2)
    for i in range(len(pm)):
        assert_equal(seen[pm[i]], -2, what + ": probe row emitted twice")
        seen[pm[i]] = bm[i]
    assert_equal(seen[0], 0, what + ": probe 0 joins build 0")
    assert_equal(seen[2], 2, what + ": probe 2 joins build 2")
    var null_row = -1 if left else -2
    assert_equal(seen[1], null_row, what + ": probe 1 matches nothing")


def _all_sides(
    lead: Int, later_dict: Bool, left: Bool, what: String
) raises:
    _run(lead, later_dict, BUILD_NULL, left, what + " build NULL")
    _run(lead, later_dict, PROBE_NULL, left, what + " probe NULL")
    _run(lead, later_dict, BOTH_NULL, left, what + " both NULL")


def test_string_inner_null_later_key_matches_nothing() raises:
    """STRING, STRING keys, INNER: a NULL later key joins no row."""
    _all_sides(LEAD_STRING, False, False, String("STRING INNER"))


def test_string_left_null_later_key_is_unmatched() raises:
    """STRING, STRING keys, LEFT: a NULL later key emits build index -1."""
    _all_sides(LEAD_STRING, False, True, String("STRING LEFT"))


def test_dict_inner_null_later_key_matches_nothing() raises:
    """Dictionary, dictionary keys, INNER: a NULL later key joins no row."""
    _all_sides(LEAD_DICT, True, False, String("DICT INNER"))


def test_dict_left_null_later_key_is_unmatched() raises:
    """Dictionary, dictionary keys, LEFT: a NULL later key emits -1."""
    _all_sides(LEAD_DICT, True, True, String("DICT LEFT"))


def test_int_string_inner_null_later_key_matches_nothing() raises:
    """INT64, STRING keys, INNER: a NULL later key joins no row."""
    _all_sides(LEAD_INT, False, False, String("INT+STRING INNER"))


def test_int_string_left_null_later_key_is_unmatched() raises:
    """INT64, STRING keys, LEFT: a NULL later key emits build index -1."""
    _all_sides(LEAD_INT, False, True, String("INT+STRING LEFT"))


def test_int_dict_inner_null_later_key_matches_nothing() raises:
    """INT64, dictionary keys, INNER: a NULL later key joins no row."""
    _all_sides(LEAD_INT, True, False, String("INT+DICT INNER"))


def test_int_dict_left_null_later_key_is_unmatched() raises:
    """INT64, dictionary keys, LEFT: a NULL later key emits build index -1."""
    _all_sides(LEAD_INT, True, True, String("INT+DICT LEFT"))


def main() raises:
    var suite = TestSuite()
    suite.test[test_string_inner_null_later_key_matches_nothing]()
    suite.test[test_string_left_null_later_key_is_unmatched]()
    suite.test[test_dict_inner_null_later_key_matches_nothing]()
    suite.test[test_dict_left_null_later_key_is_unmatched]()
    suite.test[test_int_string_inner_null_later_key_matches_nothing]()
    suite.test[test_int_string_left_null_later_key_is_unmatched]()
    suite.test[test_int_dict_inner_null_later_key_matches_nothing]()
    suite.test[test_int_dict_left_null_later_key_is_unmatched]()
    suite^.run()

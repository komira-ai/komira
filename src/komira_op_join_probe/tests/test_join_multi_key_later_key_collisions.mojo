# The composite join over integer, string, dictionary and mixed keys: rows that
# agree on every key but the last, or on the first key, and differ on a later
# key, do not join. Each test builds 64 rows that share the leading keys, then
# looks up 20000 probe rows, 64 of which equal a build row on every key. With
# so many probe rows against so few build rows, the others are likely to share
# a slot with a build row. INNER keeps exactly the 64 exact pairs; LEFT
# additionally emits every other probe row once, with build index -1.

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

comptime BUILD_ROWS = 64
comptime PROBE_ROWS = 20000


def _i64_col(imm values: List[Int64]) raises -> Column[HeapRegion]:
    var arr = PrimitiveArray[DType.int64].allocate(len(values))
    var p = arr._typed_ptr_mut()
    for i in range(len(values)):
        p.store[width=1](i, values[i])
    return Column.from_primitive[DType.int64](arr^)


def _str_col(imm values: List[String]) raises -> Column[HeapRegion]:
    var sa = StringArray.from_strings(values)
    return Column.from_string(sa^)


def _dict_col(
    imm codes: List[Int], imm dictionary: List[String]
) raises -> Column[HeapRegion]:
    var idx = PrimitiveArray[DType.int32].allocate(len(codes))
    var p = idx._typed_ptr_mut()
    for i in range(len(codes)):
        p.store[width=1](i, Int32(codes[i]))
    var da = StringDictionaryArray.from_parts(
        idx^, StringArray.from_strings(dictionary)
    )
    return Column.from_dictionary(da)


def _batch2(
    var c0: Column[HeapRegion],
    var c1: Column[HeapRegion],
    t0: ArrowType,
    t1: ArrowType,
) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k0"), t0, False))
    sb.add_field(Field(String("k1"), t1, False))
    var b = RecordBatchBuilder()
    b.add_column(c0^)
    b.add_column(c1^)
    return b.build(sb.build())


def _batch3(
    var c0: Column[HeapRegion],
    var c1: Column[HeapRegion],
    var c2: Column[HeapRegion],
    t0: ArrowType,
    t1: ArrowType,
    t2: ArrowType,
) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k0"), t0, False))
    sb.add_field(Field(String("k1"), t1, False))
    sb.add_field(Field(String("k2"), t2, False))
    var b = RecordBatchBuilder()
    b.add_column(c0^)
    b.add_column(c1^)
    b.add_column(c2^)
    return b.build(sb.build())


def _names(n_keys: Int) -> List[String]:
    var out = List[String]()
    for i in range(n_keys):
        out.append(String("k") + String(i))
    return out^


def _check(
    imm build: RecordBatch,
    imm probe: RecordBatch,
    n_keys: Int,
    left: Bool,
    what: String,
) raises:
    """Run the join and require: INNER emits exactly the 64 exact pairs; LEFT
    emits one pair per probe row, matched only for the first 64 probe rows.
    """
    var names = _names(n_keys)
    var bkeys = extract_join_key_columns_serial(build, names)
    var builder = MultiKeyHashJoinBuilder.build(bkeys^)
    var pkeys = extract_join_key_columns_serial(probe, names)
    var bm = List[Int]()
    var pm = List[Int]()
    if left:
        builder.probe_left_into(pkeys, bm, pm)
    else:
        builder.probe_inner_into(pkeys, bm, pm)
    var want = PROBE_ROWS if left else BUILD_ROWS
    assert_equal(len(bm), want, what + ": wrong match count")
    assert_equal(len(pm), want, what + ": wrong probe index count")
    var seen = List[Int]()
    for _ in range(PROBE_ROWS):
        seen.append(-2)
    for i in range(len(pm)):
        assert_equal(seen[pm[i]], -2, what + ": probe row emitted twice")
        seen[pm[i]] = bm[i]
    for j in range(PROBE_ROWS):
        var tag = ": probe " + String(j)
        if j < BUILD_ROWS:
            assert_equal(seen[j], j, what + ": exact pair for" + tag)
        elif left:
            assert_equal(seen[j], -1, what + tag + " unmatched")
        else:
            assert_equal(seen[j], -2, what + tag + " absent")


def _build_values(prefix: String) -> List[String]:
    var out = List[String]()
    for i in range(BUILD_ROWS):
        out.append(prefix + String(i))
    return out^


def _probe_values(prefix: String, other: String) -> List[String]:
    """Probe rows below BUILD_ROWS repeat the build values; the rest differ."""
    var out = List[String]()
    for j in range(PROBE_ROWS):
        if j < BUILD_ROWS:
            out.append(prefix + String(j))
        else:
            out.append(other + String(j))
    return out^


def _const_strings(n: Int, word: String) -> List[String]:
    var out = List[String]()
    for _ in range(n):
        out.append(word)
    return out^


def _const_i64(n: Int, v: Int64) -> List[Int64]:
    var out = List[Int64]()
    for _ in range(n):
        out.append(v)
    return out^


def _build_i64() -> List[Int64]:
    var out = List[Int64]()
    for i in range(BUILD_ROWS):
        out.append(Int64(i))
    return out^


def _probe_i64() -> List[Int64]:
    """Probe rows below BUILD_ROWS repeat the build values; the rest differ."""
    var out = List[Int64]()
    for j in range(PROBE_ROWS):
        out.append(Int64(j if j < BUILD_ROWS else j + 1000000))
    return out^


def _one_word(word: String) -> List[String]:
    var out = List[String]()
    out.append(word)
    return out^


def _zero_codes(n: Int) -> List[Int]:
    var out = List[Int]()
    for _ in range(n):
        out.append(0)
    return out^


def _wide_dictionary() -> List[String]:
    var out = List[String]()
    for i in range(PROBE_ROWS + 1):
        out.append(String("v") + String(i))
    return out^


def _build_codes() -> List[Int]:
    var out = List[Int]()
    for i in range(BUILD_ROWS):
        out.append(i)
    return out^


def _probe_codes() -> List[Int]:
    """Probe rows below BUILD_ROWS repeat the build codes; the rest differ."""
    var out = List[Int]()
    for j in range(PROBE_ROWS):
        out.append(j if j < BUILD_ROWS else j + 1)
    return out^


def _string_pair(left: Bool, what: String) raises:
    var shared = String("shared")
    var build = _batch2(
        _str_col(_const_strings(BUILD_ROWS, shared)),
        _str_col(_build_values("s")),
        ArrowType.STRING,
        ArrowType.STRING,
    )
    var probe = _batch2(
        _str_col(_const_strings(PROBE_ROWS, shared)),
        _str_col(_probe_values("s", "t")),
        ArrowType.STRING,
        ArrowType.STRING,
    )
    _check(build, probe, 2, left, what)


def _dict_pair(left: Bool, what: String) raises:
    # Both sides carry the same two dictionaries, so both keys compare by code.
    var d0 = _one_word("shared")
    var d1 = _wide_dictionary()
    var build = _batch2(
        _dict_col(_zero_codes(BUILD_ROWS), d0),
        _dict_col(_build_codes(), d1),
        ArrowType.DICTIONARY,
        ArrowType.DICTIONARY,
    )
    var probe = _batch2(
        _dict_col(_zero_codes(PROBE_ROWS), d0),
        _dict_col(_probe_codes(), d1),
        ArrowType.DICTIONARY,
        ArrowType.DICTIONARY,
    )
    _check(build, probe, 2, left, what)


def _mixed_pair(left: Bool, what: String) raises:
    var build = _batch2(
        _i64_col(_const_i64(BUILD_ROWS, 1)),
        _str_col(_build_values("s")),
        ArrowType.INT64,
        ArrowType.STRING,
    )
    var probe = _batch2(
        _i64_col(_const_i64(PROBE_ROWS, 1)),
        _str_col(_probe_values("s", "t")),
        ArrowType.INT64,
        ArrowType.STRING,
    )
    _check(build, probe, 2, left, what)


def _mixed_int_dict_pair(left: Bool, what: String) raises:
    # The dictionary key sits next to an integer key, so the mixed-key loop
    # reaches its same-dictionary branch.
    var d1 = _wide_dictionary()
    var build = _batch2(
        _i64_col(_const_i64(BUILD_ROWS, 1)),
        _dict_col(_build_codes(), d1),
        ArrowType.INT64,
        ArrowType.DICTIONARY,
    )
    var probe = _batch2(
        _i64_col(_const_i64(PROBE_ROWS, 1)),
        _dict_col(_probe_codes(), d1),
        ArrowType.INT64,
        ArrowType.DICTIONARY,
    )
    _check(build, probe, 2, left, what)


def _three_int_pair(left: Bool, what: String) raises:
    # Equal on the first two keys, different only on the last.
    var build = _batch3(
        _i64_col(_const_i64(BUILD_ROWS, 1)),
        _i64_col(_const_i64(BUILD_ROWS, 2)),
        _i64_col(_build_i64()),
        ArrowType.INT64,
        ArrowType.INT64,
        ArrowType.INT64,
    )
    var probe = _batch3(
        _i64_col(_const_i64(PROBE_ROWS, 1)),
        _i64_col(_const_i64(PROBE_ROWS, 2)),
        _i64_col(_probe_i64()),
        ArrowType.INT64,
        ArrowType.INT64,
        ArrowType.INT64,
    )
    _check(build, probe, 3, left, what)


def _three_string_pair(left: Bool, what: String) raises:
    var a = String("alpha")
    var b = String("beta")
    var build = _batch3(
        _str_col(_const_strings(BUILD_ROWS, a)),
        _str_col(_const_strings(BUILD_ROWS, b)),
        _str_col(_build_values("s")),
        ArrowType.STRING,
        ArrowType.STRING,
        ArrowType.STRING,
    )
    var probe = _batch3(
        _str_col(_const_strings(PROBE_ROWS, a)),
        _str_col(_const_strings(PROBE_ROWS, b)),
        _str_col(_probe_values("s", "t")),
        ArrowType.STRING,
        ArrowType.STRING,
        ArrowType.STRING,
    )
    _check(build, probe, 3, left, what)


def _three_dict_pair(left: Bool, what: String) raises:
    var da = _one_word("alpha")
    var db = _one_word("beta")
    var dc = _wide_dictionary()
    var build = _batch3(
        _dict_col(_zero_codes(BUILD_ROWS), da),
        _dict_col(_zero_codes(BUILD_ROWS), db),
        _dict_col(_build_codes(), dc),
        ArrowType.DICTIONARY,
        ArrowType.DICTIONARY,
        ArrowType.DICTIONARY,
    )
    var probe = _batch3(
        _dict_col(_zero_codes(PROBE_ROWS), da),
        _dict_col(_zero_codes(PROBE_ROWS), db),
        _dict_col(_probe_codes(), dc),
        ArrowType.DICTIONARY,
        ArrowType.DICTIONARY,
        ArrowType.DICTIONARY,
    )
    _check(build, probe, 3, left, what)


def test_string_inner_later_key_mismatch_does_not_join() raises:
    """Two STRING keys, INNER: only the 64 rows equal on both keys join."""
    _string_pair(False, String("STRING INNER"))


def test_string_left_later_key_mismatch_stays_unmatched() raises:
    """Two STRING keys, LEFT: rows equal only on the first stay unmatched."""
    _string_pair(True, String("STRING LEFT"))


def test_dict_inner_later_key_mismatch_does_not_join() raises:
    """Two same-dictionary keys, INNER: codes on the later key decide."""
    _dict_pair(False, String("DICT INNER"))


def test_dict_left_later_key_mismatch_stays_unmatched() raises:
    """Two same-dictionary keys, LEFT: codes on the later key decide."""
    _dict_pair(True, String("DICT LEFT"))


def test_mixed_inner_later_key_mismatch_does_not_join() raises:
    """An INT64 key then a STRING key, INNER: the string must match."""
    _mixed_pair(False, String("MIXED INNER"))


def test_mixed_left_later_key_mismatch_stays_unmatched() raises:
    """An INT64 key then a STRING key, LEFT: the string key must also match."""
    _mixed_pair(True, String("MIXED LEFT"))


def test_int_dict_inner_later_key_mismatch_does_not_join() raises:
    """An INT64 key then a dictionary key, INNER: codes decide."""
    _mixed_int_dict_pair(False, String("INT+DICT INNER"))


def test_int_dict_left_later_key_mismatch_stays_unmatched() raises:
    """An INT64 key then a dictionary key, LEFT: codes decide."""
    _mixed_int_dict_pair(True, String("INT+DICT LEFT"))


def test_three_int_inner_last_key_mismatch_does_not_join() raises:
    """Three INT64 keys equal but the last, INNER: the last key must match."""
    _three_int_pair(False, String("3xINT64 INNER"))


def test_three_int_left_last_key_mismatch_stays_unmatched() raises:
    """Three INT64 keys equal but the last, LEFT: the last key must match."""
    _three_int_pair(True, String("3xINT64 LEFT"))


def test_three_string_inner_last_key_mismatch_does_not_join() raises:
    """Three STRING keys equal but the last, INNER: the last key must match."""
    _three_string_pair(False, String("3xSTRING INNER"))


def test_three_string_left_last_key_mismatch_stays_unmatched() raises:
    """Three STRING keys equal but the last, LEFT: the last key must match."""
    _three_string_pair(True, String("3xSTRING LEFT"))


def test_three_dict_inner_last_key_mismatch_does_not_join() raises:
    """Three dictionary keys equal but the last, INNER: codes decide."""
    _three_dict_pair(False, String("3xDICT INNER"))


def test_three_dict_left_last_key_mismatch_stays_unmatched() raises:
    """Three dictionary keys equal but the last, LEFT: codes decide."""
    _three_dict_pair(True, String("3xDICT LEFT"))


def main() raises:
    var suite = TestSuite()
    suite.test[test_string_inner_later_key_mismatch_does_not_join]()
    suite.test[test_string_left_later_key_mismatch_stays_unmatched]()
    suite.test[test_dict_inner_later_key_mismatch_does_not_join]()
    suite.test[test_dict_left_later_key_mismatch_stays_unmatched]()
    suite.test[test_mixed_inner_later_key_mismatch_does_not_join]()
    suite.test[test_mixed_left_later_key_mismatch_stays_unmatched]()
    suite.test[test_int_dict_inner_later_key_mismatch_does_not_join]()
    suite.test[test_int_dict_left_later_key_mismatch_stays_unmatched]()
    suite.test[test_three_int_inner_last_key_mismatch_does_not_join]()
    suite.test[test_three_int_left_last_key_mismatch_stays_unmatched]()
    suite.test[test_three_string_inner_last_key_mismatch_does_not_join]()
    suite.test[test_three_string_left_last_key_mismatch_stays_unmatched]()
    suite.test[test_three_dict_inner_last_key_mismatch_does_not_join]()
    suite.test[test_three_dict_left_last_key_mismatch_stays_unmatched]()
    suite^.run()

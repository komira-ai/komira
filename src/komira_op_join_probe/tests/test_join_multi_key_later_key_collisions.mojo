# The composite join over string, dictionary and mixed keys: rows that agree on
# the first key and land in a slot that already holds a build row, but differ on
# a later key, do not join. Each test builds 64 rows that share the first key,
# then looks up 20000 probe rows, 64 of which equal a build row on every key.
# Many of the others pass the bloom filter and share a slot with a build row.
# INNER keeps exactly the 64 exact pairs; LEFT additionally emits every other
# probe row once, with build index -1.

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


def _names() -> List[String]:
    var out = List[String]()
    out.append(String("k0"))
    out.append(String("k1"))
    return out^


def _check(
    imm build: RecordBatch, imm probe: RecordBatch, left: Bool, what: String
) raises:
    """Run the join and require: INNER emits exactly the 64 exact pairs; LEFT
    emits one pair per probe row, matched only for the first 64 probe rows.
    """
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
        if j < BUILD_ROWS:
            assert_equal(seen[j], j, what + ": exact pair for probe " + String(j))
        elif left:
            assert_equal(seen[j], -1, what + ": probe " + String(j) + " unmatched")
        else:
            assert_equal(seen[j], -2, what + ": probe " + String(j) + " absent")


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


def _const_strings(n: Int) -> List[String]:
    var out = List[String]()
    for _ in range(n):
        out.append(String("shared"))
    return out^


def _string_pair(left: Bool, what: String) raises:
    var build = _batch2(
        _str_col(_const_strings(BUILD_ROWS)),
        _str_col(_build_values("s")),
        ArrowType.STRING,
        ArrowType.STRING,
    )
    var probe = _batch2(
        _str_col(_const_strings(PROBE_ROWS)),
        _str_col(_probe_values("s", "t")),
        ArrowType.STRING,
        ArrowType.STRING,
    )
    _check(build, probe, left, what)


def _dict_pair(left: Bool, what: String) raises:
    # Both sides carry the same two dictionaries, so both keys compare by code.
    var d0 = List[String]()
    d0.append(String("shared"))
    var d1 = List[String]()
    for i in range(PROBE_ROWS + 1):
        d1.append(String("v") + String(i))
    var bc0 = List[Int]()
    var bc1 = List[Int]()
    for i in range(BUILD_ROWS):
        bc0.append(0)
        bc1.append(i)
    var pc0 = List[Int]()
    var pc1 = List[Int]()
    for j in range(PROBE_ROWS):
        pc0.append(0)
        pc1.append(j if j < BUILD_ROWS else j + 1)
    var build = _batch2(
        _dict_col(bc0, d0),
        _dict_col(bc1, d1),
        ArrowType.DICTIONARY,
        ArrowType.DICTIONARY,
    )
    var probe = _batch2(
        _dict_col(pc0, d0),
        _dict_col(pc1, d1),
        ArrowType.DICTIONARY,
        ArrowType.DICTIONARY,
    )
    _check(build, probe, left, what)


def _mixed_pair(left: Bool, what: String) raises:
    var bk0 = List[Int64]()
    for _ in range(BUILD_ROWS):
        bk0.append(1)
    var pk0 = List[Int64]()
    for _ in range(PROBE_ROWS):
        pk0.append(1)
    var build = _batch2(
        _i64_col(bk0),
        _str_col(_build_values("s")),
        ArrowType.INT64,
        ArrowType.STRING,
    )
    var probe = _batch2(
        _i64_col(pk0),
        _str_col(_probe_values("s", "t")),
        ArrowType.INT64,
        ArrowType.STRING,
    )
    _check(build, probe, left, what)


def test_string_keys_inner_ignores_slot_mates_that_differ_on_a_later_key() raises:
    """Two STRING keys, INNER: only the 64 rows equal on both keys join."""
    _string_pair(False, String("STRING INNER"))


def test_string_keys_left_leaves_slot_mates_that_differ_unmatched() raises:
    """Two STRING keys, LEFT: rows equal only on the first key stay unmatched."""
    _string_pair(True, String("STRING LEFT"))


def test_dict_keys_inner_ignores_slot_mates_that_differ_on_a_later_key() raises:
    """Two same-dictionary keys, INNER: codes on the later key decide."""
    _dict_pair(False, String("DICT INNER"))


def test_dict_keys_left_leaves_slot_mates_that_differ_unmatched() raises:
    """Two same-dictionary keys, LEFT: codes on the later key decide."""
    _dict_pair(True, String("DICT LEFT"))


def test_mixed_keys_inner_ignores_slot_mates_that_differ_on_a_later_key() raises:
    """An INT64 key then a STRING key, INNER: the string key must also match."""
    _mixed_pair(False, String("MIXED INNER"))


def test_mixed_keys_left_leaves_slot_mates_that_differ_unmatched() raises:
    """An INT64 key then a STRING key, LEFT: the string key must also match."""
    _mixed_pair(True, String("MIXED LEFT"))


def main() raises:
    var suite = TestSuite()
    suite.test[test_string_keys_inner_ignores_slot_mates_that_differ_on_a_later_key]()
    suite.test[test_string_keys_left_leaves_slot_mates_that_differ_unmatched]()
    suite.test[test_dict_keys_inner_ignores_slot_mates_that_differ_on_a_later_key]()
    suite.test[test_dict_keys_left_leaves_slot_mates_that_differ_unmatched]()
    suite.test[test_mixed_keys_inner_ignores_slot_mates_that_differ_on_a_later_key]()
    suite.test[test_mixed_keys_left_leaves_slot_mates_that_differ_unmatched]()
    suite^.run()

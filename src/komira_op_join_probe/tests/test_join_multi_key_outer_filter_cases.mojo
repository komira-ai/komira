# Hand-written cases for the composite SEMI, ANTI, RIGHT and FULL probes with
# exact expected row indices. One logical case (a probe row matching two build
# rows, a probe row matching one, an unmatched probe row, a NULL probe row, an
# unmatched build row) runs over STRING, DICTIONARY (same and different
# dictionaries, DICTIONARY against STRING) and INT64/INT32 key families, so
# every per-family compare arm of each probe is exercised.
#
# Logical rows (key classes; -1 is NULL):
#   build: (0,0) (0,0) (1,1) (2,2)
#   probe: (0,0) (9,9) (1,1) (NULL,0)
# Expected: SEMI [0, 2]; ANTI [1, 3]; RIGHT pairs (build,probe)
# (0,0) (1,0) (2,2) (3,-1); FULL the RIGHT pairs plus (-1,1) and (-1,3).

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
from komira_op_join_probe.join_multi_key_filter import (
    multi_key_probe_semi,
    multi_key_probe_anti,
)
from komira_op_join_probe.join_multi_key_outer import (
    multi_key_probe_right_into,
    multi_key_probe_full_into,
)

comptime K_INT64 = 0
comptime K_INT32 = 1
comptime K_STRING = 3
comptime K_DICT = 4


def _text(c: Int) -> String:
    if c == 0:
        return String("a")
    if c == 1:
        return String("b")
    if c == 2:
        return String("c")
    return String("q")


def _make_col(
    kind: Int, cls: List[Int], reversed_dict: Bool
) raises -> Column[HeapRegion]:
    var n = len(cls)
    if kind == K_INT64:
        var arr = PrimitiveArray[DType.int64].allocate_nullable(n)
        var p = arr._typed_ptr_mut()
        for i in range(n):
            if cls[i] < 0:
                p.store[width=1](i, Int64(777))
                arr._set_null(i)
            else:
                p.store[width=1](i, Int64(cls[i]) + 1)
        return Column.from_primitive[DType.int64](arr^)
    if kind == K_INT32:
        var arr = PrimitiveArray[DType.int32].allocate_nullable(n)
        var p = arr._typed_ptr_mut()
        for i in range(n):
            if cls[i] < 0:
                p.store[width=1](i, Int32(777))
                arr._set_null(i)
            else:
                p.store[width=1](i, Int32(cls[i]) + 1)
        return Column.from_primitive[DType.int32](arr^)
    if kind == K_STRING:
        var vals = List[String]()
        var valid = List[Bool]()
        for i in range(n):
            if cls[i] < 0:
                vals.append(String("a"))
                valid.append(False)
            else:
                vals.append(_text(min(cls[i], 3)))
                valid.append(True)
        var sa = StringArray.from_strings_with_validity(vals, valid)
        return Column.from_string(sa^)
    # Dictionary of four entries "a" "b" "c" "q" (or the same entries in the
    # reverse order plus one extra entry), indexed by the logical text.
    var idx = PrimitiveArray[DType.int32].allocate_nullable(n)
    var p = idx._typed_ptr_mut()
    var dl = List[String]()
    for c in range(4):
        if reversed_dict:
            dl.append(_text(3 - c))
        else:
            dl.append(_text(c))
    if reversed_dict:
        dl.append(String("extra"))
    for i in range(n):
        if cls[i] < 0:
            p.store[width=1](i, Int32(0))
            idx._set_null(i)
        else:
            var t = min(cls[i], 3)
            if reversed_dict:
                p.store[width=1](i, Int32(3 - t))
            else:
                p.store[width=1](i, Int32(t))
    var dsa = StringArray.from_strings(dl)
    var da = StringDictionaryArray.from_parts(idx^, dsa^)
    return Column.from_dictionary(da)


def _arrow_type(kind: Int) -> ArrowType:
    if kind == K_INT64:
        return ArrowType.INT64
    if kind == K_INT32:
        return ArrowType.INT32
    if kind == K_STRING:
        return ArrowType.STRING
    return ArrowType.DICTIONARY


def _batch(
    kinds: List[Int], cls: List[List[Int]], reversed_dict: Bool
) raises -> RecordBatch:
    var sb = SchemaBuilder()
    var bb = RecordBatchBuilder()
    for k in range(len(kinds)):
        sb.add_field(Field("k" + String(k), _arrow_type(kinds[k]), True))
        bb.add_column(_make_col(kinds[k], cls[k], reversed_dict))
    return bb.build(sb.build())


def _pair(b: Int, p: Int) -> Int:
    return (b + 1) * 1000 + (p + 1)


def _sorted(l: List[Int]) -> List[Int]:
    var out = l.copy()
    for i in range(1, len(out)):
        var v = out[i]
        var j = i - 1
        while j >= 0 and out[j] > v:
            out[j + 1] = out[j]
            j -= 1
        out[j + 1] = v
    return out^


def _check_list(what: String, got: List[Int], want: List[Int]) raises:
    if got != want:
        var s = what + ": got ["
        for i in range(len(got)):
            s += String(got[i]) + ","
        s += "] want ["
        for i in range(len(want)):
            s += String(want[i]) + ","
        s += "]"
        raise Error(s)


def _pairs(imm bm: List[Int], imm pm: List[Int]) -> List[Int]:
    var out = List[Int]()
    for i in range(len(bm)):
        out.append(_pair(bm[i], pm[i]))
    return _sorted(out)


def _run_case(
    build_kinds: List[Int], probe_kinds: List[Int], probe_reversed_dict: Bool
) raises:
    var nk = len(build_kinds)
    var bcls = List[List[Int]]()
    var pcls = List[List[Int]]()
    var names = List[String]()
    for k in range(nk):
        names.append("k" + String(k))
        var b: List[Int] = [0, 0, 1, 2]
        var p: List[Int] = [0, 9, 1, -1]
        if k != 0:
            p = [0, 9, 1, 0]
        bcls.append(b^)
        pcls.append(p^)
    var bbatch = _batch(build_kinds, bcls, False)
    var pbatch = _batch(probe_kinds, pcls, probe_reversed_dict)
    var builder = MultiKeyHashJoinBuilder.build(
        extract_join_key_columns_serial(bbatch, names)
    )
    var pkeys = extract_join_key_columns_serial(pbatch, names)

    _check_list("SEMI", multi_key_probe_semi(builder, pkeys), [0, 2])
    _check_list("ANTI", multi_key_probe_anti(builder, pkeys), [1, 3])

    var bm = List[Int]()
    var pm = List[Int]()
    multi_key_probe_right_into(builder, pkeys, bm, pm)
    _check_list(
        "RIGHT",
        _pairs(bm, pm),
        _sorted([_pair(0, 0), _pair(1, 0), _pair(2, 2), _pair(3, -1)]),
    )

    bm = List[Int]()
    pm = List[Int]()
    multi_key_probe_full_into(builder, pkeys, bm, pm)
    _check_list(
        "FULL",
        _pairs(bm, pm),
        _sorted(
            [
                _pair(0, 0),
                _pair(1, 0),
                _pair(2, 2),
                _pair(3, -1),
                _pair(-1, 1),
                _pair(-1, 3),
            ]
        ),
    )


def test_string_keys() raises:
    _run_case([K_STRING, K_STRING], [K_STRING, K_STRING], False)


def test_string_with_int64_key() raises:
    _run_case([K_STRING, K_INT64], [K_STRING, K_INT64], False)


def test_dictionary_keys_same_dictionary() raises:
    _run_case([K_DICT, K_DICT], [K_DICT, K_DICT], False)


def test_dictionary_keys_different_dictionaries() raises:
    _run_case([K_DICT, K_DICT], [K_DICT, K_DICT], True)


def test_dictionary_against_string_keys() raises:
    _run_case([K_DICT, K_STRING], [K_STRING, K_DICT], False)


def test_dictionary_with_int64_key_same_dictionary() raises:
    _run_case([K_DICT, K_INT64], [K_DICT, K_INT64], False)


def test_dictionary_with_int64_key_different_dictionaries() raises:
    _run_case([K_DICT, K_INT64], [K_DICT, K_INT64], True)


def test_int64_keys() raises:
    _run_case([K_INT64, K_INT64], [K_INT64, K_INT64], False)


def test_mixed_int_width_keys() raises:
    _run_case([K_INT64, K_INT32], [K_INT32, K_INT64], False)


def test_single_string_key() raises:
    _run_case([K_STRING], [K_STRING], False)


def main() raises:
    var suite = TestSuite()
    suite.test[test_string_keys]()
    suite.test[test_string_with_int64_key]()
    suite.test[test_dictionary_keys_same_dictionary]()
    suite.test[test_dictionary_keys_different_dictionaries]()
    suite.test[test_dictionary_against_string_keys]()
    suite.test[test_dictionary_with_int64_key_same_dictionary]()
    suite.test[test_dictionary_with_int64_key_different_dictionaries]()
    suite.test[test_int64_keys]()
    suite.test[test_mixed_int_width_keys]()
    suite.test[test_single_string_key]()
    suite^.run()

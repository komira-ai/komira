# =============================================================================
# SortBuffer with a STRING key orders as DuckDB orders VARCHAR
# =============================================================================
#
# A STRING key (input column 0) and an INT64 payload `v` (the input row id,
# column 1) are fed from a batch and drained; the payload permutation is
# compared with DuckDB's, recorded from
#   CREATE TABLE t(k VARCHAR, v INT); INSERT INTO t VALUES (...);
#   SELECT v FROM t ORDER BY k [ASC|DESC];
# DuckDB's default VARCHAR collation is byte-wise: the shorter string first on
# a shared prefix, the empty string first, 'Z' (0x5A) before 'a' (0x61). The
# payload makes equal-key order visible.
# =============================================================================

from std.testing import TestSuite, assert_equal

from komira_arrow.arrow_types import ArrowType
from komira_arrow.batch_view import BatchView
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import Field, RecordBatch, RecordBatchBuilder, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion

from komira_op_sort.sort_stage_buffer import SortBuffer, SortKeyBlock
from komira_op_sort.sort_stage_columns import SORT_DIR_ASC_U8, SORT_DIR_DESC_U8
from komira_op_sort.sort_stage_payloads import PayloadCol_Typed
from komira_op_sort.sort_stage_string_key import SortKeyColumn_String


# The concrete typed buffer under test: a STRING key at input col 0 + an INT64
# payload (`v`, the stable row id) at input col 1.
comptime _KBStr = SortKeyBlock[SortKeyColumn_String[0]]
comptime _PayI64 = PayloadCol_Typed[DType.int64, 1]
comptime _Buf = SortBuffer[_KBStr, _PayI64]


# =============================================================================
# Builders
# =============================================================================


def _build_batch(keys: List[String], vals: List[Int64]) raises -> RecordBatch:
    """Build a 2-column RecordBatch: STRING key `k` (col 0) + INT64 payload `v`
    (col 1). One row per (keys[i], vals[i])."""
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), ArrowType.STRING, True))
    sb.add_field(Field(String("v"), ArrowType.INT64, True))
    var schema = sb.build()

    var rbb = RecordBatchBuilder.with_capacity(2)
    rbb.add_column(Column.from_string(StringArray.from_strings(keys)))
    var prim = PrimitiveArray[DType.int64].from_list(vals)
    rbb.add_column(Column.from_primitive[DType.int64](prim^))
    return rbb.build(schema^)


def _sorted_payloads(
    keys: List[String], vals: List[Int64], descending: Bool
) raises -> List[Int64]:
    """Drive the typed SortBuffer with `SortKeyColumn_String` over the hand-built
    batch; return the emitted payload column (`v`) in sorted order."""
    var dir_u8 = SORT_DIR_DESC_U8 if descending else SORT_DIR_ASC_U8
    var buf = _Buf.make_empty(len(keys))
    buf.set_direction(0, dir_u8)

    var rb = _build_batch(keys, vals)
    var bv = BatchView(rb)
    var n = bv.n_rows()
    for r in range(n):
        buf.feed_row[origin_of(rb)](bv, r)

    var out_opt = buf^.drain_to_record_batch()
    var out = out_opt.take()
    # Output schema is [k0 (STRING), payload0 (INT64)] -> payload at col 1.
    var ov = BatchView(out)
    var on = ov.n_rows()
    var result = List[Int64](capacity=on)
    for i in range(on):
        result.append(ov.col_i64(1).load[1](i)[0])
    return result^


def _assert_order(
    got: List[Int64], expected: List[Int64], label: String
) raises:
    assert_equal(len(got), len(expected), label + ": row count")
    for i in range(len(expected)):
        assert_equal(
            Int(got[i]),
            Int(expected[i]),
            label + ": position " + String(i),
        )


# =============================================================================
# VECTOR 1 — mixed ASCII-boundary + empty-string + prefix + dup (stability)
# =============================================================================
#
# Input rows (insertion order = payload v):
#   v=0 ""        v=1 "banana"   v=2 "Apple"   v=3 "apple"
#   v=4 "Banana"  v=5 ""         v=6 "app"     v=7 "banana"
#
# Covers: empty-string first; uppercase ('A'=0x41,'B'=0x42) before lowercase;
# "app" is a PREFIX of "apple" -> "app" < "apple"; duplicate "" (v=0,5) and
# duplicate "banana" (v=1,7) -> stability keeps input order within equal keys.


def _v1_keys() -> List[String]:
    return [
        String(""), String("banana"), String("Apple"), String("apple"),
        String("Banana"), String(""), String("app"), String("banana"),
    ]


def _v1_vals() -> List[Int64]:
    return [Int64(0), 1, 2, 3, 4, 5, 6, 7]


def test_sort_string_vector1_ascending() raises:
    """Vector 1, ASC. DuckDB oracle: SELECT v FROM t ORDER BY k ASC."""
    # DuckDB CLI output: 0 5 2 4 6 3 1 7
    var expected: List[Int64] = [Int64(0), 5, 2, 4, 6, 3, 1, 7]
    var got = _sorted_payloads(_v1_keys(), _v1_vals(), descending=False)
    _assert_order(got, expected, "v1 ASC")


def test_sort_string_vector1_descending() raises:
    """Vector 1, DESC. DuckDB oracle: SELECT v FROM t ORDER BY k DESC.

    Equal-key groups keep INPUT order (stable): "banana" -> 1,7; "" -> 0,5."""
    # DuckDB CLI output: 1 7 3 6 4 2 0 5
    var expected: List[Int64] = [Int64(1), 7, 3, 6, 4, 2, 0, 5]
    var got = _sorted_payloads(_v1_keys(), _v1_vals(), descending=True)
    _assert_order(got, expected, "v1 DESC")


# =============================================================================
# VECTOR 2 — tight ASCII-boundary (A/Z/a/z), ASC
# =============================================================================
#
# Input rows: v=10 "a"(0x61)  v=11 "Z"(0x5A)  v=12 "z"(0x7A)  v=13 "A"(0x41)
# Bytewise order: A(0x41) < Z(0x5A) < a(0x61) < z(0x7A).


def test_sort_string_vector2_ascii_boundary_ascending() raises:
    """Vector 2, ASC. DuckDB oracle confirms uppercase-before-lowercase."""
    var keys: List[String] = [String("a"), String("Z"), String("z"), String("A")]
    var vals: List[Int64] = [Int64(10), 11, 12, 13]
    # DuckDB CLI output: 13 11 10 12  (A, Z, a, z)
    var expected: List[Int64] = [Int64(13), 11, 10, 12]
    var got = _sorted_payloads(keys, vals, descending=False)
    _assert_order(got, expected, "v2 ASCII ASC")


# =============================================================================
# VECTOR 3 — single-row edge case, ASC
# =============================================================================


def test_sort_string_vector3_single_row() raises:
    """Single-row sort is identity. DuckDB oracle: 100."""
    var keys: List[String] = [String("alpha")]
    var vals: List[Int64] = [Int64(100)]
    var expected: List[Int64] = [Int64(100)]
    var got = _sorted_payloads(keys, vals, descending=False)
    _assert_order(got, expected, "v3 single")


def main() raises:
    var suite = TestSuite()
    suite.test[test_sort_string_vector1_ascending]()
    suite.test[test_sort_string_vector1_descending]()
    suite.test[test_sort_string_vector2_ascii_boundary_ascending]()
    suite.test[test_sort_string_vector3_single_row]()
    suite^.run()

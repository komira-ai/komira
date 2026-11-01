# =============================================================================
# sort_indices for nested types
# =============================================================================
#
# `sort_indices_nested` over the four nested type families:
#
#   * STRUCT     — per-field-then-recurse, ordered by Schema field index.
#   * LIST       — element-by-element lex; shorter prefix sorts first when
#                  common positions are equal.
#   * UNION      — dispatch by type-id (cross-child); within-child recurse on
#                  the selected child.  Sparse + dense.
#   * MAP        — RAISES (Arrow leaves Map ordering undefined).
#
# Columns are built with the `Column.from_struct` / `from_list` /
# `from_union` / `from_map` factories. Expected order (the same as
# `sort_indices_string` and Arrow C++ `SortIndices`):
#   ascending  -> NULLS FIRST, then increasing value.
#   descending -> NULLS LAST, then decreasing value.
#
# Each test asserts the returned indices form a permutation in [0, N).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false
from std.sys import size_of

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.list_array import ListArray
from komira_arrow.map_array import MapArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_arrow.struct_array import StructArray
from komira_arrow.union_array import UnionArray

from komira_op_sort.sort_nested import sort_indices_nested
from komira_buffer.heap_region import HeapRegion


# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------


def _int32_col(values: List[Int]) raises -> Column[HeapRegion]:
    """Build an INT32 Column[HeapRegion] from a List[Int]."""
    var vs = List[Scalar[DType.int32]]()
    for i in range(len(values)):
        vs.append(Scalar[DType.int32](values[i]))
    var arr = PrimitiveArray[DType.int32].from_list(vs)
    return Column.from_primitive[DType.int32](arr)


def _int64_col(values: List[Int]) raises -> Column[HeapRegion]:
    """Build an INT64 Column[HeapRegion] from a List[Int]."""
    var vs = List[Scalar[DType.int64]]()
    for i in range(len(values)):
        vs.append(Scalar[DType.int64](values[i]))
    var arr = PrimitiveArray[DType.int64].from_list(vs)
    return Column.from_primitive[DType.int64](arr)


def _string_col(values: List[String]) raises -> Column[HeapRegion]:
    """Build a STRING Column[HeapRegion] from a List[String]."""
    var sa = StringArray.from_strings(values)
    return Column.from_string(sa^)


def _assert_is_permutation(idx: PrimitiveArray[DType.int32], n: Int) raises:
    """Assert that `idx` is a permutation of [0, n)."""
    assert_equal(idx.length, n, "indices length matches input length")
    var seen = List[Bool]()
    for _ in range(n):
        seen.append(False)
    for i in range(n):
        var v = Int(idx.get(i))
        assert_true(v >= 0 and v < n, "index in range")
        assert_false(seen[v], "no duplicate index")
        seen[v] = True


def _assert_index_sequence(
    idx: PrimitiveArray[DType.int32], expected: List[Int]
) raises:
    """Assert the returned indices match `expected` in order."""
    assert_equal(idx.length, len(expected), "indices length")
    for i in range(len(expected)):
        assert_equal(Int(idx.get(i)), expected[i],
                     "index[" + String(i) + "] matches expected")


def _ints3(a: Int, b: Int, c: Int) -> List[Int]:
    """Build a List[Int] of 3 elements (Mojo 1.0.0b1 has no List(a,b,c) ctor)."""
    var out = List[Int]()
    out.append(a); out.append(b); out.append(c)
    return out^


def _ints4(a: Int, b: Int, c: Int, d: Int) -> List[Int]:
    """Build a List[Int] of 4 elements."""
    var out = List[Int]()
    out.append(a); out.append(b); out.append(c); out.append(d)
    return out^


def _ints1(a: Int) -> List[Int]:
    """Build a List[Int] of 1 element."""
    var out = List[Int]()
    out.append(a)
    return out^


def _strs1(a: String) -> List[String]:
    var out = List[String]()
    out.append(a)
    return out^


def _strs2(a: String, b: String) -> List[String]:
    var out = List[String]()
    out.append(a); out.append(b)
    return out^


def _strs3(a: String, b: String, c: String) -> List[String]:
    var out = List[String]()
    out.append(a); out.append(b); out.append(c)
    return out^


# -----------------------------------------------------------------------------
# T1-T4: STRUCT
# -----------------------------------------------------------------------------


def test_sort_struct_int_first_field() raises:
    """STRUCT<a:Int32, b:Int64> — first-field-dominates ordering.
    Rows: (3, 100), (1, 200), (2, 50).  Asc => row 1, 2, 0."""
    var col_a = _int32_col(_ints3(3, 1, 2))
    var col_b = _int64_col(_ints3(100, 200, 50))
    var names = List[String]()
    names.append(String("a"))
    names.append(String("b"))
    var sa = StructArray.from_columns_2(names, col_a^, col_b^)
    var col = Column.from_struct(sa)

    var idx = sort_indices_nested(col, False)
    _assert_is_permutation(idx, 3)
    var expected = _ints3(1, 2, 0)  # a values 1 < 2 < 3
    _assert_index_sequence(idx, expected)


def test_sort_struct_int_second_field_tiebreak() raises:
    """STRUCT<a:Int32, b:Int64> — first-field equal, second-field decides.
    Rows: (5, 30), (5, 10), (5, 20).  Asc => row 1 (b=10), row 2 (b=20), row 0 (b=30)."""
    var col_a = _int32_col(_ints3(5, 5, 5))
    var col_b = _int64_col(_ints3(30, 10, 20))
    var names = List[String]()
    names.append(String("a"))
    names.append(String("b"))
    var sa = StructArray.from_columns_2(names, col_a^, col_b^)
    var col = Column.from_struct(sa)

    var idx = sort_indices_nested(col, False)
    _assert_is_permutation(idx, 3)
    var expected = _ints3(1, 2, 0)
    _assert_index_sequence(idx, expected)


def test_sort_struct_with_null_row() raises:
    """STRUCT<a:Int32> with row 1 null at outer level.  Mirrors the
    `sort_indices_string` null collation: ASC => NULLS FIRST.
    Rows: (10), NULL, (5).  Asc => row 1 (NULL first), row 2 (5), row 0 (10)."""
    var col_a = _int32_col(_ints3(10, 0, 5))  # value at NULL slot is arbitrary
    var names = List[String]()
    names.append(String("a"))

    # Build nullable struct: pass valid_mask with row 1 = False.
    var valid = List[Bool]()
    valid.append(True)
    valid.append(False)
    valid.append(True)
    var sa = StructArray.from_columns_1_nullable(names, col_a^, valid)
    var col = Column.from_struct(sa)

    var idx = sort_indices_nested(col, False)
    _assert_is_permutation(idx, 3)
    # ASC NULLS FIRST: row 1 (NULL), row 2 (5), row 0 (10).
    assert_equal(Int(idx.get(0)), 1, "NULL first")
    assert_equal(Int(idx.get(1)), 2, "5 second")
    assert_equal(Int(idx.get(2)), 0, "10 third")


def test_sort_struct_string_field() raises:
    """STRUCT<name:Utf8, age:Int32> — recursion through STRING child.
    Rows: ('charlie', 30), ('alice', 25), ('bob', 28).  Asc => row 1, 2, 0."""
    var names_field = List[String]()
    names_field.append(String("charlie"))
    names_field.append(String("alice"))
    names_field.append(String("bob"))
    var col_n = _string_col(names_field)
    var col_a = _int32_col(_ints3(30, 25, 28))
    var struct_names = List[String]()
    struct_names.append(String("name"))
    struct_names.append(String("age"))
    var sa = StructArray.from_columns_2(struct_names, col_n^, col_a^)
    var col = Column.from_struct(sa)

    var idx = sort_indices_nested(col, False)
    _assert_is_permutation(idx, 3)
    var expected = _ints3(1, 2, 0)  # alice < bob < charlie
    _assert_index_sequence(idx, expected)


# -----------------------------------------------------------------------------
# T5-T9: LIST
# -----------------------------------------------------------------------------


def test_sort_list_int_lex() raises:
    """LIST<Int64> — element-by-element comparison.
    Rows: [3,1], [1,5], [2,2].  Asc => row 1, 2, 0 (lex by first element)."""
    var lists = List[List[Int]]()
    var l0 = List[Int]()
    l0.append(3); l0.append(1)
    lists.append(l0^)
    var l1 = List[Int]()
    l1.append(1); l1.append(5)
    lists.append(l1^)
    var l2 = List[Int]()
    l2.append(2); l2.append(2)
    lists.append(l2^)

    var arr = ListArray.from_int_lists(lists)
    var col = Column.from_list(arr)

    var idx = sort_indices_nested(col, False)
    _assert_is_permutation(idx, 3)
    var expected = _ints3(1, 2, 0)
    _assert_index_sequence(idx, expected)


def test_sort_list_int_prefix_shorter_first() raises:
    """LIST<Int64> — shorter prefix sorts first when common positions equal.
    Rows: [1,2,3], [1,2], [1,2,4].  Asc => row 1 (prefix), row 0, row 2."""
    var lists = List[List[Int]]()
    var l0 = List[Int]()
    l0.append(1); l0.append(2); l0.append(3)
    lists.append(l0^)
    var l1 = List[Int]()
    l1.append(1); l1.append(2)
    lists.append(l1^)
    var l2 = List[Int]()
    l2.append(1); l2.append(2); l2.append(4)
    lists.append(l2^)

    var arr = ListArray.from_int_lists(lists)
    var col = Column.from_list(arr)

    var idx = sort_indices_nested(col, False)
    _assert_is_permutation(idx, 3)
    var expected = _ints3(1, 0, 2)  # [1,2] < [1,2,3] < [1,2,4]
    _assert_index_sequence(idx, expected)


def test_sort_list_empty_lists() raises:
    """LIST<Int64> — two empty lists equal; empty < non-empty.
    Rows: [5], [], [10], [].  Asc => row 1, row 3, row 0, row 2."""
    var lists = List[List[Int]]()
    var l0 = List[Int]()
    l0.append(5)
    lists.append(l0^)
    var l1 = List[Int]()  # empty
    lists.append(l1^)
    var l2 = List[Int]()
    l2.append(10)
    lists.append(l2^)
    var l3 = List[Int]()  # empty
    lists.append(l3^)

    var arr = ListArray.from_int_lists(lists)
    var col = Column.from_list(arr)

    var idx = sort_indices_nested(col, False)
    _assert_is_permutation(idx, 4)
    # Two empties [], [] first (stable: row 1 then row 3), then [5], then [10].
    var expected = _ints4(1, 3, 0, 2)
    _assert_index_sequence(idx, expected)


def test_sort_list_with_null_outer() raises:
    """LIST<Int64> with null outer row.  ASC => NULLS FIRST (per Arrow /
    string-sort convention).
    Rows: [3], NULL, [1].  Asc => row 1 (NULL), row 2 (=[1]), row 0 (=[3])."""
    var lists = List[List[Int]]()
    var l0 = List[Int]()
    l0.append(3)
    lists.append(l0^)
    var l1 = List[Int]()  # null slot — empty span
    lists.append(l1^)
    var l2 = List[Int]()
    l2.append(1)
    lists.append(l2^)

    var valid = List[Bool]()
    valid.append(True)
    valid.append(False)
    valid.append(True)

    var arr = ListArray.from_int_lists_nullable(lists, valid)
    var col = Column.from_list(arr)

    var idx = sort_indices_nested(col, False)
    _assert_is_permutation(idx, 3)
    assert_equal(Int(idx.get(0)), 1, "NULL first")
    assert_equal(Int(idx.get(1)), 2, "[1] second")
    assert_equal(Int(idx.get(2)), 0, "[3] third")


def test_sort_list_string() raises:
    """LIST<Utf8> — recursion through STRING child.
    Rows: ['c'], ['a', 'b'], ['b'].  Asc => row 1 (['a',...] lex first), row 2, row 0."""
    var lists = List[List[String]]()
    var l0 = List[String]()
    l0.append(String("c"))
    lists.append(l0^)
    var l1 = List[String]()
    l1.append(String("a"))
    l1.append(String("b"))
    lists.append(l1^)
    var l2 = List[String]()
    l2.append(String("b"))
    lists.append(l2^)

    var valid = List[Bool]()
    valid.append(True)
    valid.append(True)
    valid.append(True)

    var arr = ListArray.from_string_lists(lists, valid)
    var col = Column.from_list(arr)

    var idx = sort_indices_nested(col, False)
    _assert_is_permutation(idx, 3)
    var expected = _ints3(1, 2, 0)  # ['a','b'] < ['b'] < ['c']
    _assert_index_sequence(idx, expected)


# -----------------------------------------------------------------------------
# T10-T13: UNION (sparse + dense)
# -----------------------------------------------------------------------------


def test_sort_union_sparse_same_type_id() raises:
    """UNION_SPARSE<Int32, Utf8> — same type-id rows, child compare decides.
    All rows use child 0 (Int32 with type-id 5).
    Children (sparse: both full length 3): Int32 = [30, 10, 20]; Utf8 = ['x','y','z'].
    types_buf = [5, 5, 5].  Asc => row 1 (10), row 2 (20), row 0 (30)."""
    var col_i = _int32_col(_ints3(30, 10, 20))
    var col_s = _string_col(_strs3(String("x"), String("y"), String("z")))

    var type_ids = List[Int]()
    type_ids.append(5)
    type_ids.append(7)

    var types = List[Int8]()
    types.append(Int8(5))
    types.append(Int8(5))
    types.append(Int8(5))

    var ua = UnionArray.sparse_from_children_2(type_ids, types, col_i^, col_s^)
    var col = Column.from_union(ua)

    var idx = sort_indices_nested(col, False)
    _assert_is_permutation(idx, 3)
    var expected = _ints3(1, 2, 0)
    _assert_index_sequence(idx, expected)


def test_sort_union_sparse_cross_type() raises:
    """UNION_SPARSE<Int32, Utf8> — different type-ids; type-id order dominates.
    types_buf = [7, 5, 7].  type-id 5 (Int32) sorts before type-id 7 (Utf8).
    Row 1 has type-id 5 -> first.  Rows 0 and 2 have type-id 7 -> ordered by Utf8 child.
    Utf8 child values: ['m', '?', 'a'] (Utf8 child at indices 0 and 2; '?' is unused at idx 1).
    Row 2 (Utf8='a') < row 0 (Utf8='m') => result [1, 2, 0]."""
    var col_i = _int32_col(_ints3(99, 42, 7))
    var col_s = _string_col(_strs3(String("m"), String("?"), String("a")))

    var type_ids = List[Int]()
    type_ids.append(5)  # Int32 child first
    type_ids.append(7)  # Utf8 child second

    var types = List[Int8]()
    types.append(Int8(7))  # row 0 -> Utf8('m')
    types.append(Int8(5))  # row 1 -> Int32(42)
    types.append(Int8(7))  # row 2 -> Utf8('a')

    var ua = UnionArray.sparse_from_children_2(type_ids, types, col_i^, col_s^)
    var col = Column.from_union(ua)

    var idx = sort_indices_nested(col, False)
    _assert_is_permutation(idx, 3)
    var expected = _ints3(1, 2, 0)  # type-id 5 first, then Utf8('a') < Utf8('m')
    _assert_index_sequence(idx, expected)


def test_sort_union_dense_same_type_id() raises:
    """UNION_DENSE<Int32, Utf8> — same type-id rows, dense offsets honored.
    types_buf = [5, 5, 5].  offsets = [2, 0, 1].
    Int32 child = [10, 30, 20].  So row 0 -> child[2]=20, row 1 -> child[0]=10, row 2 -> child[1]=30.
    Asc => row 1 (10), row 0 (20), row 2 (30)."""
    var col_i = _int32_col(_ints3(10, 30, 20))
    var col_s = _string_col(_strs1(String("x")))  # placeholder; never selected

    var type_ids = List[Int]()
    type_ids.append(5)
    type_ids.append(7)

    var types = List[Int8]()
    types.append(Int8(5))
    types.append(Int8(5))
    types.append(Int8(5))

    var offsets = List[Int32]()
    offsets.append(Int32(2))  # row 0 -> child[2]=20
    offsets.append(Int32(0))  # row 1 -> child[0]=10
    offsets.append(Int32(1))  # row 2 -> child[1]=30

    var ua = UnionArray.dense_from_children_2(
        type_ids, types, offsets, col_i^, col_s^
    )
    var col = Column.from_union(ua)

    var idx = sort_indices_nested(col, False)
    _assert_is_permutation(idx, 3)
    var expected = _ints3(1, 0, 2)
    _assert_index_sequence(idx, expected)


def test_sort_union_dense_cross_type() raises:
    """UNION_DENSE<Int32, Utf8> — cross-type ordering dominates.
    Int32 child = [42] (1 row).  Utf8 child = ['m', 'a'] (2 rows).
    types_buf = [7, 5, 7].  offsets = [0, 0, 1].
    Row 0 -> Utf8[0]='m'; row 1 -> Int32[0]=42; row 2 -> Utf8[1]='a'.
    Asc => row 1 (type-id 5 first), row 2 (Utf8 'a'), row 0 (Utf8 'm')."""
    var col_i = _int32_col(_ints1(42))
    var col_s = _string_col(_strs2(String("m"), String("a")))

    var type_ids = List[Int]()
    type_ids.append(5)
    type_ids.append(7)

    var types = List[Int8]()
    types.append(Int8(7))  # row 0 -> Utf8[0]
    types.append(Int8(5))  # row 1 -> Int32[0]
    types.append(Int8(7))  # row 2 -> Utf8[1]

    var offsets = List[Int32]()
    offsets.append(Int32(0))
    offsets.append(Int32(0))
    offsets.append(Int32(1))

    var ua = UnionArray.dense_from_children_2(
        type_ids, types, offsets, col_i^, col_s^
    )
    var col = Column.from_union(ua)

    var idx = sort_indices_nested(col, False)
    _assert_is_permutation(idx, 3)
    var expected = _ints3(1, 2, 0)
    _assert_index_sequence(idx, expected)


# -----------------------------------------------------------------------------
# T14: MAP — raises UnsupportedSortKey
# -----------------------------------------------------------------------------


def test_sort_map_raises_unsupported() raises:
    """MAP sort key is undefined per Arrow spec.  Verify the raise contains
    'MAP' so the error is intelligible to callers (matches DuckDB / Arrow C++
    / DataFusion behavior)."""
    var maps = List[List[Tuple[String, Int]]]()
    var m0 = List[Tuple[String, Int]]()
    m0.append((String("foo"), 1))
    maps.append(m0^)
    var m1 = List[Tuple[String, Int]]()
    m1.append((String("bar"), 2))
    maps.append(m1^)

    var arr = MapArray.from_string_int_maps(maps)
    var col = Column.from_map(arr)

    var raised = False
    var msg = String("")
    try:
        var _idx = sort_indices_nested(col, False)
    except e:
        raised = True
        msg = String(e)

    assert_true(raised, "MAP sort must raise")
    # naive substring check via byte buffers (Mojo 1.0.0b1 String indexing
    # requires byte-level access for fixed-position lookup).
    var msg_bytes = msg.as_bytes()
    var probe = String("MAP")
    var probe_bytes = probe.as_bytes()
    var mn = len(msg_bytes)
    var pn = len(probe_bytes)
    var contains_map = False
    if mn >= pn:
        var i = 0
        while i + pn <= mn:
            var is_match = True
            for j in range(pn):
                if msg_bytes[i + j] != probe_bytes[j]:
                    is_match = False
                    break
            if is_match:
                contains_map = True
                break
            i += 1
    assert_true(contains_map, "error message mentions MAP")


# -----------------------------------------------------------------------------
# T15-T16: descending direction
# -----------------------------------------------------------------------------


def test_sort_struct_descending() raises:
    """STRUCT<a:Int32> — descending direction.  DESC => NULLS LAST (per
    string-sort convention; mirrors Arrow C++).
    Rows: (10), (5), NULL.  Desc => row 0 (10), row 1 (5), row 2 (NULL last)."""
    var col_a = _int32_col(_ints3(10, 5, 0))
    var names = List[String]()
    names.append(String("a"))
    var valid = List[Bool]()
    valid.append(True)
    valid.append(True)
    valid.append(False)
    var sa = StructArray.from_columns_1_nullable(names, col_a^, valid)
    var col = Column.from_struct(sa)

    var idx = sort_indices_nested(col, True)
    _assert_is_permutation(idx, 3)
    var expected = _ints3(0, 1, 2)  # 10 > 5 > NULL last
    _assert_index_sequence(idx, expected)


def test_sort_list_descending() raises:
    """LIST<Int64> — descending direction.
    Rows: [1], [3], [2].  Desc => row 1 (=[3]), row 2 (=[2]), row 0 (=[1])."""
    var lists = List[List[Int]]()
    var l0 = List[Int]()
    l0.append(1)
    lists.append(l0^)
    var l1 = List[Int]()
    l1.append(3)
    lists.append(l1^)
    var l2 = List[Int]()
    l2.append(2)
    lists.append(l2^)

    var arr = ListArray.from_int_lists(lists)
    var col = Column.from_list(arr)

    var idx = sort_indices_nested(col, True)
    _assert_is_permutation(idx, 3)
    var expected = _ints3(1, 2, 0)
    _assert_index_sequence(idx, expected)


def main() raises:
    var suite = TestSuite()
    suite.test[test_sort_struct_int_first_field]()
    suite.test[test_sort_struct_int_second_field_tiebreak]()
    suite.test[test_sort_struct_with_null_row]()
    suite.test[test_sort_struct_string_field]()
    suite.test[test_sort_list_int_lex]()
    suite.test[test_sort_list_int_prefix_shorter_first]()
    suite.test[test_sort_list_empty_lists]()
    suite.test[test_sort_list_with_null_outer]()
    suite.test[test_sort_list_string]()
    suite.test[test_sort_union_sparse_same_type_id]()
    suite.test[test_sort_union_sparse_cross_type]()
    suite.test[test_sort_union_dense_same_type_id]()
    suite.test[test_sort_union_dense_cross_type]()
    suite.test[test_sort_map_raises_unsupported]()
    suite.test[test_sort_struct_descending]()
    suite.test[test_sort_list_descending]()
    suite^.run()

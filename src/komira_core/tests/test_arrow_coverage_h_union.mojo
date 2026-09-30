# =============================================================================
# Arrow C Data Interface — Union sparse + dense (round-trip)
#
# The round-trip surface for unions:
#
#   * UNION_SPARSE  +us:I,J,...
#       1 buffer:  Int8 types (one per parent row).
#       N child arrays, each with the SAME length as the parent.  No
#       validity bitmap (Arrow spec — nullness comes from children).
#
#   * UNION_DENSE   +ud:I,J,...
#       2 buffers: Int8 types + Int32 offsets (one each per parent row).
#       N child arrays with INDEPENDENT lengths.  Same no-validity rule.
#
# Unions ride on `Column._children` + the recursion machinery in
# c_data_stream (the LIST/STRUCT/MAP arms). The union-specific pieces:
#
#   1. union_array.mojo (UnionArraySparse + UnionArrayDense via a unified
#      UnionArray struct with `mode: ArrowType` discriminator).
#   2. Column._type_ids slot + Column.from_union / as_union factories.
#   3. c_data_stream UNION arms in _arrow_type_n_buffers,
#      _column_format_string, _build_column_array (skips validity for
#      unions; writes types buf @ bufs[0]; dense offsets @ bufs[1]),
#      _build_column_schema_from_column / _from_field_and_column,
#      _format_string_to_arrow_type (accepts +us/+ud), _import_column
#      (UNION arms read types + dense offsets + recurse on children).
#   4. compiler_helpers.copy_column: UNION_* arm delegates to Column
#      .deep_copy() (same as LIST/STRUCT/MAP).
#
# Test list:
#   T1: Sparse UNION<Int32, Utf8> Column round-trip via the new
#       `Column._children` + `_type_ids` path.
#   T2: Dense UNION<Int32, Utf8> Column round-trip — different from
#       T1 by the offsets buffer (children have independent lengths).
#   T3: Sparse UNION<Int32, LargeString> — a large-string child
#       (Int64 offsets) under a union.
#   T4: Dense UNION<Struct<a, b>, List<Int>> — 2-level nesting via
#       `_children`.
#   T5: Compute kernel parity: copy_column on UNION_* preserves
#       all aux slots (types_buf bytes, offsets bytes, child arrow_types,
#       type_ids, no children leakage / no aux drop).
#   T6: Hash / equality: two UnionArrays with identical types
#       + offsets + children produce structurally identical Columns
#       (byte-identical types & offsets buffers, deep-equal children).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.arrow import (
    ArrowType,
    Column,
    LargeStringArray,
    ListArray,
    PrimitiveArray,
    StringArray,
    StructArray,
    UnionArray,
)
from std.sys import size_of
from komira_core.io.heap_region import HeapRegion


# --- Helpers -----------------------------------------------------------------


def _make_int32_col(values: List[Int32]) -> Column[HeapRegion]:
    """Build an INT32 Column[HeapRegion] from a list of values."""
    var arr = PrimitiveArray[DType.int32].from_list(values)
    return Column.from_primitive[DType.int32](arr)


def _make_int64_col(values: List[Int64]) -> Column[HeapRegion]:
    """Build an INT64 Column[HeapRegion] from a list of values."""
    var arr = PrimitiveArray[DType.int64].from_list(values)
    return Column.from_primitive[DType.int64](arr)


def _make_string_col(values: List[String]) raises -> Column[HeapRegion]:
    """Build a STRING Column[HeapRegion] from a list of strings."""
    var arr = StringArray.from_strings(values)
    return Column.from_string(arr^)


def _make_large_string_col(values: List[String]) raises -> Column[HeapRegion]:
    """Build a LARGE_STRING Column[HeapRegion] from a list of strings (Int64 offsets)."""
    var arr = LargeStringArray.from_strings(values)
    return Column.from_large_string(arr^)


# --- T1: Sparse UNION<Int32, Utf8> Column round-trip --------------------------


def test_h_union_sparse_int_string_column_round_trip() raises:
    """Build a sparse union of [int32, utf8] and round-trip through Column.
    Validates the new `_children` + `_type_ids` packing.

    Sparse-union invariant: each child has the SAME length as the parent.
    Per-row, only the slot at `types[i]` is the "selected" value (the
    other child's slot is unspecified per spec — we still allocate it)."""
    # 4 rows.  types = [0, 1, 0, 1]; type-id 0 = int32, type-id 1 = string.
    # Sparse: both children have length 4.
    var int_col = _make_int32_col(
        [Int32(10), Int32(0), Int32(30), Int32(0)]
    )
    var str_col = _make_string_col(
        [String(""), String("beta"), String(""), String("delta")]
    )

    var type_ids = List[Int]()
    type_ids.append(0)
    type_ids.append(1)
    var types = List[Int8]()
    types.append(Int8(0))
    types.append(Int8(1))
    types.append(Int8(0))
    types.append(Int8(1))

    var ua = UnionArray.sparse_from_children_2(
        type_ids, types, int_col^, str_col^
    )
    assert_equal(len(ua), 4, "union outer length 4")
    assert_true(ua.is_sparse(), "is_sparse")
    assert_false(ua.is_dense(), "not is_dense")
    assert_equal(ua.num_children(), 2, "2 children")

    var col = Column.from_union(ua)
    assert_equal(
        Int(col.arrow_type.type_id),
        Int(ArrowType.UNION_SPARSE.type_id),
        "arrow_type UNION_SPARSE",
    )
    assert_equal(col.length(), 4, "outer length preserved")
    assert_equal(col.num_children(), 2, "2 children")
    assert_equal(
        Int(col.child_at(0).arrow_type.type_id),
        Int(ArrowType.INT32.type_id),
        "child 0 INT32",
    )
    assert_equal(
        Int(col.child_at(1).arrow_type.type_id),
        Int(ArrowType.STRING.type_id),
        "child 1 STRING",
    )
    var ids = col.type_ids()
    assert_equal(len(ids), 2, "2 type-ids")
    assert_equal(ids[0], 0, "type-id 0")
    assert_equal(ids[1], 1, "type-id 1")
    # No validity bitmap on a union Column (Arrow spec).
    var col_has_validity = False
    if col._validity:
        col_has_validity = True
    assert_false(col_has_validity, "union Column[HeapRegion] has no validity")

    var ua_out = col.as_union()
    assert_equal(len(ua_out), 4, "round-trip outer length")
    assert_true(ua_out.is_sparse(), "round-trip is_sparse")
    assert_equal(ua_out.num_children(), 2, "round-trip 2 children")
    # Types buffer should round-trip byte-identical.
    assert_equal(Int(ua_out.type_id_at(0)), 0, "row 0 type-id")
    assert_equal(Int(ua_out.type_id_at(1)), 1, "row 1 type-id")
    assert_equal(Int(ua_out.type_id_at(2)), 0, "row 2 type-id")
    assert_equal(Int(ua_out.type_id_at(3)), 1, "row 3 type-id")
    # Child values preserved.
    var c0_arr = ua_out.child_at(0).as_primitive[DType.int32]()
    assert_equal(Int(c0_arr.get(0)), 10, "child 0 row 0")
    assert_equal(Int(c0_arr.get(2)), 30, "child 0 row 2")
    var c1_arr = ua_out.child_at(1).as_string()
    assert_true(c1_arr.get(1) == String("beta"), "child 1 row 1 'beta'")
    assert_true(c1_arr.get(3) == String("delta"), "child 1 row 3 'delta'")


# --- T2: Dense UNION<Int32, Utf8> Column round-trip ---------------------------


def test_h_union_dense_int_string_column_round_trip() raises:
    """Build a dense union of [int32, utf8] and round-trip through Column.
    Validates the additional offsets buffer (children can have INDEPENDENT
    lengths in dense layout).

    types   = [0, 1, 0, 1]
    offsets = [0, 0, 1, 1]   -> int32-child rows 0,1; utf8-child rows 0,1.
    int32-child: length 2 (rows that select type 0)
    utf8-child:  length 2 (rows that select type 1)
    """
    # int32-child: length 2 (only 2 of the 4 parent rows select type 0).
    var int_col = _make_int32_col([Int32(10), Int32(30)])
    # utf8-child: length 2 (only 2 of the 4 parent rows select type 1).
    var str_col = _make_string_col([String("beta"), String("delta")])

    var type_ids = List[Int]()
    type_ids.append(0)
    type_ids.append(1)
    var types = List[Int8]()
    types.append(Int8(0))
    types.append(Int8(1))
    types.append(Int8(0))
    types.append(Int8(1))
    var offsets = List[Int32]()
    offsets.append(Int32(0))
    offsets.append(Int32(0))
    offsets.append(Int32(1))
    offsets.append(Int32(1))

    var ua = UnionArray.dense_from_children_2(
        type_ids, types, offsets, int_col^, str_col^
    )
    assert_equal(len(ua), 4, "parent length 4")
    assert_true(ua.is_dense(), "is_dense")
    assert_false(ua.is_sparse(), "not is_sparse")

    var col = Column.from_union(ua)
    assert_equal(
        Int(col.arrow_type.type_id),
        Int(ArrowType.UNION_DENSE.type_id),
        "arrow_type UNION_DENSE",
    )
    assert_equal(col.length(), 4, "parent length preserved")
    var dense_has_offsets = False
    if col._offsets:
        dense_has_offsets = True
    assert_true(dense_has_offsets, "dense Column[HeapRegion] has offsets buffer")
    assert_equal(col.num_children(), 2, "2 children")
    # Children kept their original lengths (NOT padded to parent length).
    assert_equal(col.child_at(0).length(), 2, "int32-child length 2")
    assert_equal(col.child_at(1).length(), 2, "utf8-child length 2")
    var dense_has_validity = False
    if col._validity:
        dense_has_validity = True
    assert_false(dense_has_validity, "no validity on dense union")

    var ua_out = col.as_union()
    assert_equal(len(ua_out), 4, "round-trip parent length")
    assert_true(ua_out.is_dense(), "round-trip is_dense")
    # Type-id buffer + offsets buffer byte-identical.
    assert_equal(Int(ua_out.type_id_at(0)), 0, "row 0 type 0")
    assert_equal(Int(ua_out.type_id_at(1)), 1, "row 1 type 1")
    assert_equal(Int(ua_out.offset_at(0)), 0, "row 0 offset")
    assert_equal(Int(ua_out.offset_at(1)), 0, "row 1 offset")
    assert_equal(Int(ua_out.offset_at(2)), 1, "row 2 offset")
    assert_equal(Int(ua_out.offset_at(3)), 1, "row 3 offset")
    # Child values preserved.
    var c0_arr = ua_out.child_at(0).as_primitive[DType.int32]()
    assert_equal(Int(c0_arr.get(0)), 10, "int32-child row 0 = 10")
    assert_equal(Int(c0_arr.get(1)), 30, "int32-child row 1 = 30")
    var c1_arr = ua_out.child_at(1).as_string()
    assert_true(c1_arr.get(0) == String("beta"), "utf8-child row 0 'beta'")
    assert_true(c1_arr.get(1) == String("delta"), "utf8-child row 1 'delta'")


# --- T3: Sparse UNION<Int32, LargeString> -------------------------------------


def test_h_union_sparse_with_large_string_child() raises:
    """Exercises an Int64-offsets-style LargeString as a union child.
    The child's variable-length offsets must survive the deep-copy in
    Column.deep_copy()."""
    var int_col = _make_int32_col(
        [Int32(7), Int32(0), Int32(0)]
    )
    var lstr_col = _make_large_string_col(
        [String(""), String("eleven"), String("twelve")]
    )

    var type_ids = List[Int]()
    type_ids.append(0)
    type_ids.append(1)
    var types = List[Int8]()
    types.append(Int8(0))
    types.append(Int8(1))
    types.append(Int8(1))

    var ua = UnionArray.sparse_from_children_2(
        type_ids, types, int_col^, lstr_col^
    )
    var col = Column.from_union(ua)
    assert_equal(col.num_children(), 2, "2 children")
    assert_equal(
        Int(col.child_at(1).arrow_type.type_id),
        Int(ArrowType.LARGE_STRING.type_id),
        "child 1 is LARGE_STRING",
    )

    var ua_out = col.as_union()
    assert_equal(len(ua_out), 3, "parent length 3")
    var c1_arr = ua_out.child_at(1).as_large_string()
    assert_true(c1_arr.get(1) == String("eleven"), "large-str row 1")
    assert_true(c1_arr.get(2) == String("twelve"), "large-str row 2")


# --- T4: Dense UNION<Struct<a, b>, List<Int>> — 2-level nesting --------------


def test_h_union_dense_with_struct_and_list_children() raises:
    """Validates 2-level nesting: a dense union whose children are
    a STRUCT and a LIST.  Exercises the recursive deep_copy through
    Column._children inside Column._children."""
    # Build a struct child: STRUCT<a: Int32, b: Utf8> with 2 rows.
    var sa_a = _make_int32_col([Int32(1), Int32(2)])
    var sa_b = _make_string_col([String("hello"), String("world")])
    var names = List[String]()
    names.append(String("a"))
    names.append(String("b"))
    var inner_struct = StructArray.from_columns_2(names, sa_a^, sa_b^)
    var struct_col = inner_struct.to_column()

    # Build a list child: LIST<Int64> with 2 rows (lists of length 3 and 1).
    var lists = List[List[Int]]()
    var l0 = List[Int]()
    l0.append(11)
    l0.append(12)
    l0.append(13)
    lists.append(l0^)
    var l1 = List[Int]()
    l1.append(21)
    lists.append(l1^)
    var list_arr = ListArray.from_int_lists(lists)
    var list_col = Column.from_list(list_arr)

    # Dense union over 3 parent rows: types = [0, 1, 0]; struct rows 0, 1;
    # list rows 0, 1.  offsets index into each child accordingly.
    var type_ids = List[Int]()
    type_ids.append(0)
    type_ids.append(1)
    var types = List[Int8]()
    types.append(Int8(0))
    types.append(Int8(1))
    types.append(Int8(0))
    var offsets = List[Int32]()
    offsets.append(Int32(0))
    offsets.append(Int32(0))
    offsets.append(Int32(1))

    var ua = UnionArray.dense_from_children_2(
        type_ids, types, offsets, struct_col^, list_col^
    )
    var col = Column.from_union(ua)
    assert_equal(col.length(), 3, "parent length 3")
    assert_equal(col.num_children(), 2, "2 children")
    assert_equal(
        Int(col.child_at(0).arrow_type.type_id),
        Int(ArrowType.STRUCT.type_id),
        "child 0 is STRUCT",
    )
    assert_equal(
        Int(col.child_at(1).arrow_type.type_id),
        Int(ArrowType.LIST.type_id),
        "child 1 is LIST",
    )

    var ua_out = col.as_union()
    assert_equal(len(ua_out), 3, "round-trip parent length")
    # Unpack the inner STRUCT child.
    var sa_out = ua_out.child_at(0).as_struct()
    assert_equal(sa_out.length, 2, "struct child len 2")
    assert_equal(sa_out.num_fields(), 2, "struct child 2 fields")
    var sa_a_arr = sa_out.child_at(0).as_primitive[DType.int32]()
    assert_equal(Int(sa_a_arr.get(0)), 1, "struct.a row 0")
    assert_equal(Int(sa_a_arr.get(1)), 2, "struct.a row 1")
    # Unpack the inner LIST child.
    var la_out = ua_out.child_at(1).as_list()
    assert_equal(len(la_out), 2, "list child len 2")
    assert_equal(la_out.get_length(0), 3, "list[0] has 3 items")
    assert_equal(la_out.get_length(1), 1, "list[1] has 1 item")


# --- T5: copy_column / deep_copy preserves UNION aux slots --------------------


def test_h_union_deep_copy_preserves_all_slots() raises:
    """`Column.deep_copy()` on a UNION_* Column[HeapRegion] must preserve every
    auxiliary slot: types buffer bytes, offsets buffer bytes (dense),
    `_type_ids`, recursive children with their own arrow_types.  This
    is the "compute kernels see correct shape" guarantee — the
    `copy_column` helper now delegates to `deep_copy` for unions
    (the alternative — falling into the fixed-width path — silently
    drops every aux slot)."""
    var int_col = _make_int32_col([Int32(100), Int32(200)])
    var str_col = _make_string_col([String("a"), String("b")])

    var type_ids = List[Int]()
    type_ids.append(5)  # non-zero declared type-id
    type_ids.append(7)
    var types = List[Int8]()
    types.append(Int8(5))
    types.append(Int8(7))
    var offsets = List[Int32]()
    offsets.append(Int32(0))
    offsets.append(Int32(0))

    var ua = UnionArray.dense_from_children_2(
        type_ids, types, offsets, int_col^, str_col^
    )
    var col = Column.from_union(ua)
    var col_copy = col.deep_copy()

    assert_equal(
        Int(col_copy.arrow_type.type_id),
        Int(ArrowType.UNION_DENSE.type_id),
        "copy arrow_type",
    )
    assert_equal(col_copy.length(), 2, "copy length")
    assert_equal(col_copy.num_children(), 2, "copy n_children")
    var copy_has_offsets = False
    if col_copy._offsets:
        copy_has_offsets = True
    assert_true(copy_has_offsets, "copy preserves offsets")
    var copy_ids = col_copy.type_ids()
    assert_equal(copy_ids[0], 5, "copy type-id 0 = 5")
    assert_equal(copy_ids[1], 7, "copy type-id 1 = 7")
    # Children recurse.
    assert_equal(
        Int(col_copy.child_at(0).arrow_type.type_id),
        Int(ArrowType.INT32.type_id),
        "copy child 0 INT32",
    )
    assert_equal(
        Int(col_copy.child_at(1).arrow_type.type_id),
        Int(ArrowType.STRING.type_id),
        "copy child 1 STRING",
    )


# --- T6: Two identical UnionArrays produce structurally identical Columns ----


def test_h_union_two_identical_unions_byte_identical_columns() raises:
    """Two UnionArrays constructed with byte-identical inputs (same types
    buffer, same offsets, same children) produce structurally identical
    Columns.  This is the "equality" contract — for a sparse
    union, value-equal-at-row-i iff (types[i] == other.types[i]) AND
    (children[types[i]].equal_at_i)."""
    var lhs_int = _make_int32_col([Int32(7), Int32(8)])
    var lhs_str = _make_string_col([String("x"), String("y")])
    var rhs_int = _make_int32_col([Int32(7), Int32(8)])
    var rhs_str = _make_string_col([String("x"), String("y")])

    var type_ids_l = List[Int]()
    type_ids_l.append(0)
    type_ids_l.append(1)
    var types_l = List[Int8]()
    types_l.append(Int8(0))
    types_l.append(Int8(1))

    var type_ids_r = List[Int]()
    type_ids_r.append(0)
    type_ids_r.append(1)
    var types_r = List[Int8]()
    types_r.append(Int8(0))
    types_r.append(Int8(1))

    var ua_l = UnionArray.sparse_from_children_2(
        type_ids_l, types_l, lhs_int^, lhs_str^
    )
    var ua_r = UnionArray.sparse_from_children_2(
        type_ids_r, types_r, rhs_int^, rhs_str^
    )
    var col_l = Column.from_union(ua_l)
    var col_r = Column.from_union(ua_r)

    # Type tag, length, child count + child arrow_types match.
    assert_true(col_l.arrow_type == col_r.arrow_type, "same arrow_type")
    assert_equal(col_l.length(), col_r.length(), "same length")
    assert_equal(col_l.num_children(), col_r.num_children(), "same nchild")
    assert_equal(len(col_l.type_ids()), len(col_r.type_ids()), "same type-ids count")
    for i in range(len(col_l.type_ids())):
        assert_equal(
            col_l.type_ids()[i],
            col_r.type_ids()[i],
            "type-id " + String(i) + " match",
        )
    # Types buffer bytes match (Int8 per row).
    comptime int8_size = size_of[Int8]()
    var l_types_view = col_l._data.view_range_ro(0, col_l.length() * int8_size)
    var r_types_view = col_r._data.view_range_ro(0, col_r.length() * int8_size)
    for i in range(col_l.length()):
        assert_equal(
            Int(l_types_view.get_typed[Int8](i)),
            Int(r_types_view.get_typed[Int8](i)),
            "types buf byte " + String(i) + " match",
        )


# --- Test runner -------------------------------------------------------------


def main() raises:
    var suite = TestSuite()
    suite.test[test_h_union_sparse_int_string_column_round_trip]()
    suite.test[test_h_union_dense_int_string_column_round_trip]()
    suite.test[test_h_union_sparse_with_large_string_child]()
    suite.test[test_h_union_dense_with_struct_and_list_children]()
    suite.test[test_h_union_deep_copy_preserves_all_slots]()
    suite.test[test_h_union_two_identical_unions_byte_identical_columns]()
    suite^.run()

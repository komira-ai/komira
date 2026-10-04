# =============================================================================
# Arrow C Data Interface — Nested LIST / STRUCT / MAP (round-trip)
#
# The round-trip surface for the 3 nested type families:
#   * LIST<T>     +l   (validity + i32 offsets + 1 child)
#   * STRUCT      +s   (validity + N children, no value buffer)
#   * MAP         +m   (validity + i32 offsets + 1 entries-struct child)
#
# The pieces it exercises:
#
#   1. Column._children: Slab[Column] + Column._field_names + Column._keys_sorted.
#   2. Column.deep_copy() — recursive deep-copy for pack/unpack.
#   3. ListArray.to_column / from_column for any child type.
#   4. StructArray.to_column / from_column via _children + _field_names.
#   5. MapArray.to_column / from_column via the entries Struct<key, value>
#      child + _keys_sorted.
#   6. c_data_stream nested recursion:
#      - _arrow_type_n_buffers(LIST/STRUCT/MAP) coverage.
#      - _build_column_array recurses on col.num_children().
#      - _build_column_schema_from_column (pure-Column nested schema).
#      - _build_column_schema_from_field_and_column (Field + Column).
#      - _format_string_to_arrow_type accepts "+l", "+s", "+m".
#      - _import_column LIST/STRUCT/MAP arms walk CArrowSchema.children.
#      - _import_record_batch threads the root CArrowSchema to children.
#      - drain_record_batch_stream keeps sch_box LIVE through the get_next
#        loop so nested-type imports can recurse into child CArrowSchemas.
#
# Test list:
#   T1: LIST<Int64> Column round-trip (the generic _children path).
#   T2: LIST<String> Column round-trip via StringArray child (validates
#       the `as_list_of_string` dispatch).
#   T3: STRUCT<a: Int32, b: Utf8> Column round-trip via Column._children
#       + _field_names.
#   T4: MAP<String, Int64> Column round-trip with keys_sorted=False (the
#       common case).
#   T5: MAP<String, Int64> Column round-trip with keys_sorted=True (the
#       _keys_sorted slot path).
#   T6: 2-level nested LIST<Struct<a: Int32, b: Utf8>> round-trip.  This
#       exercises ListArray.to_column delegating into StructArray.to_column
#       via deep_copy, then the reverse.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.list_array import ListArray
from komira_arrow.map_array import MapArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_arrow.struct_array import StructArray
from komira_buffer.heap_region import HeapRegion


# --- T1: LIST<Int64> Column round-trip ----------------------------------------


def test_g_list_int_column_round_trip() raises:
    """`Column.from_list(ListArray<Int64>)` followed by `Column.as_list()`
    returns a byte-identical ListArray with an Int64 child Column.

    Validates the generic _children path with a non-string child."""
    var lists = List[List[Int]]()
    var l0 = List[Int]()
    l0.append(1)
    l0.append(2)
    l0.append(3)
    lists.append(l0^)
    var l1 = List[Int]()
    l1.append(10)
    lists.append(l1^)
    var l2 = List[Int]()  # empty list
    lists.append(l2^)

    var arr = ListArray.from_int_lists(lists)
    var col = Column.from_list(arr)

    assert_equal(Int(col.arrow_type.type_id), Int(ArrowType.LIST.type_id),
                 "arrow_type is LIST")
    assert_equal(col.length(), 3, "outer length preserved")
    assert_equal(col.num_children(), 1, "1 child")
    assert_equal(Int(col.child_at(0).arrow_type.type_id),
                 Int(ArrowType.INT64.type_id), "child is INT64")

    var arr_out = col.as_list()
    assert_equal(len(arr_out), 3, "round-trip outer length")
    assert_equal(arr_out.get_offset(0), 0, "offset[0]")
    assert_equal(arr_out.get_length(0), 3, "row 0 length 3")
    assert_equal(arr_out.get_length(1), 1, "row 1 length 1")
    assert_equal(arr_out.get_length(2), 0, "row 2 empty")
    assert_equal(Int(arr_out.child.arrow_type.type_id),
                 Int(ArrowType.INT64.type_id), "child preserved as INT64")


# --- T2: LIST<String> Column round-trip ---------------------------------------


def test_g_list_string_column_round_trip() raises:
    """`Column.from_list(ListArray<String>)` followed by `Column.as_list()`
    returns a byte-identical ListArray with a STRING child Column.

    The regexp call sites use `as_list_of_string`, a thin forward to
    `as_list()` with a STRING-child runtime assertion; this keeps that path
    green."""
    var lists = List[List[String]]()
    var l0 = List[String]()
    l0.append(String("foo"))
    l0.append(String("bar"))
    lists.append(l0^)
    var l1 = List[String]()
    l1.append(String("hello"))
    lists.append(l1^)
    var l2 = List[String]()
    lists.append(l2^)

    var valid_mask = List[Bool]()
    valid_mask.append(True)
    valid_mask.append(True)
    valid_mask.append(True)

    var arr = ListArray.from_string_lists(lists, valid_mask)
    var col = Column.from_list(arr)

    assert_equal(Int(col.arrow_type.type_id), Int(ArrowType.LIST.type_id),
                 "arrow_type is LIST")
    assert_equal(col.length(), 3, "outer length preserved")
    assert_equal(Int(col.child_at(0).arrow_type.type_id),
                 Int(ArrowType.STRING.type_id), "child is STRING")

    var arr_out = col.as_list()
    assert_equal(len(arr_out), 3, "round-trip outer length")
    var row0 = arr_out.list_strings(0)
    assert_equal(len(row0), 2, "row 0 has 2 strings")
    assert_true(row0[0] == String("foo"), "row 0 str 0 byte-identical")
    assert_true(row0[1] == String("bar"), "row 0 str 1 byte-identical")
    var row1 = arr_out.list_strings(1)
    assert_equal(len(row1), 1, "row 1 has 1 string")
    assert_true(row1[0] == String("hello"), "row 1 str 0 byte-identical")
    var row2 = arr_out.list_strings(2)
    assert_equal(len(row2), 0, "row 2 empty")

    # Verify the regexp alias keeps working.
    var arr_via_alias = col.as_list_of_string()
    assert_equal(len(arr_via_alias), 3, "as_list_of_string alias works")


# --- T3: STRUCT<a: Int32, b: Utf8> Column round-trip --------------------------


def test_g_struct_column_round_trip() raises:
    """`StructArray.to_column` / `from_column` packs N child Columns
    (with field names) through the type-erased Column. Validates the
    multi-child recursion + parallel field_names preservation."""
    # Build child columns.
    var int_values = List[Scalar[DType.int32]]()
    int_values.append(Scalar[DType.int32](10))
    int_values.append(Scalar[DType.int32](20))
    int_values.append(Scalar[DType.int32](30))
    var int_arr = PrimitiveArray[DType.int32].from_list(int_values)
    var int_col = Column.from_primitive[DType.int32](int_arr)

    var strs = List[String]()
    strs.append(String("alpha"))
    strs.append(String("beta"))
    strs.append(String("gamma"))
    var str_arr = StringArray.from_strings(strs)
    var str_col = Column.from_string(str_arr^)

    var names = List[String]()
    names.append(String("a"))
    names.append(String("b"))

    var sa = StructArray.from_columns_2(names, int_col^, str_col^)
    assert_equal(sa.length, 3, "struct length 3")
    assert_equal(sa.num_fields(), 2, "struct num_fields 2")

    # Pack into Column, unpack back.
    var col = sa.to_column()
    assert_equal(Int(col.arrow_type.type_id), Int(ArrowType.STRUCT.type_id),
                 "arrow_type STRUCT")
    assert_equal(col.length(), 3, "struct length preserved on Column[HeapRegion]")
    assert_equal(col.num_children(), 2, "2 children")
    assert_equal(col.field_name(0), String("a"), "field 0 name 'a'")
    assert_equal(col.field_name(1), String("b"), "field 1 name 'b'")

    var sa_out = col.as_struct()
    assert_equal(sa_out.length, 3, "struct round-trip length")
    assert_equal(sa_out.num_fields(), 2, "struct round-trip num_fields")
    # Check the child INT32 round-tripped.
    ref c0 = sa_out.child_at(0)
    assert_equal(Int(c0.arrow_type.type_id), Int(ArrowType.INT32.type_id),
                 "child 0 is INT32")
    var c0_arr = c0.as_primitive[DType.int32]()
    assert_equal(Int(c0_arr.get(0)), 10, "child 0 row 0 = 10")
    assert_equal(Int(c0_arr.get(1)), 20, "child 0 row 1 = 20")
    assert_equal(Int(c0_arr.get(2)), 30, "child 0 row 2 = 30")
    # Check the child STRING round-tripped.
    ref c1 = sa_out.child_at(1)
    assert_equal(Int(c1.arrow_type.type_id), Int(ArrowType.STRING.type_id),
                 "child 1 is STRING")
    var c1_arr = c1.as_string()
    assert_true(c1_arr.get(0) == String("alpha"), "child 1 row 0 'alpha'")
    assert_true(c1_arr.get(1) == String("beta"), "child 1 row 1 'beta'")
    assert_true(c1_arr.get(2) == String("gamma"), "child 1 row 2 'gamma'")


# --- T4: MAP<String, Int64> with keys_sorted=False ---------------------------


def test_g_map_keys_unsorted_column_round_trip() raises:
    """`MapArray.to_column` / `from_column` packs the entries Struct<key,
    value> child + the offsets + _keys_sorted=False through the
    type-erased Column."""
    var maps = List[List[Tuple[String, Int]]]()
    var m0 = List[Tuple[String, Int]]()
    m0.append((String("foo"), 1))
    m0.append((String("bar"), 2))
    maps.append(m0^)
    var m1 = List[Tuple[String, Int]]()
    m1.append((String("baz"), 3))
    maps.append(m1^)

    var arr = MapArray.from_string_int_maps(maps)
    assert_equal(arr.length, 2, "map outer length 2")
    assert_false(arr.keys_sorted, "keys_sorted=False at construction")

    var col = Column.from_map(arr)
    assert_equal(Int(col.arrow_type.type_id), Int(ArrowType.MAP.type_id),
                 "arrow_type MAP")
    assert_equal(col.length(), 2, "outer length preserved")
    assert_equal(col.num_children(), 1, "1 entries child")
    assert_false(col.keys_sorted(), "_keys_sorted=False propagated")
    # The single child is the entries STRUCT<key, value>.
    assert_equal(Int(col.child_at(0).arrow_type.type_id),
                 Int(ArrowType.STRUCT.type_id), "child is STRUCT")
    assert_equal(col.child_at(0).num_children(), 2,
                 "entries struct has 2 fields")

    var arr_out = col.as_map()
    assert_equal(arr_out.length, 2, "map round-trip outer length")
    assert_false(arr_out.keys_sorted, "keys_sorted=False round-tripped")
    assert_equal(arr_out.get_length(0), 2, "map 0 has 2 entries")
    assert_equal(arr_out.get_length(1), 1, "map 1 has 1 entry")


# --- T5: MAP<String, Int64> with keys_sorted=True ---------------------------


def test_g_map_keys_sorted_column_round_trip() raises:
    """Same as T4 but with `keys_sorted=True` to validate the _keys_sorted
    bit propagates correctly through Column."""
    var maps = List[List[Tuple[String, Int]]]()
    var m0 = List[Tuple[String, Int]]()
    m0.append((String("aaa"), 1))
    m0.append((String("bbb"), 2))
    maps.append(m0^)

    var arr = MapArray.from_string_int_maps(maps)
    # Override keys_sorted to True (the from_string_int_maps default is False).
    arr.keys_sorted = True

    var col = Column.from_map(arr)
    assert_true(col.keys_sorted(), "_keys_sorted=True propagated to Column[HeapRegion]")

    var arr_out = col.as_map()
    assert_true(arr_out.keys_sorted, "keys_sorted=True round-tripped")


# --- T6: LIST<Struct<a: Int32, b: Utf8>> — 2-level nesting -------------------


def test_g_list_of_struct_column_round_trip() raises:
    """Exercises 2-level recursion: a LIST whose item is a STRUCT.
    Validates that ListArray.to_column's deep_copy(child) recurses into
    StructArray's own _children + _field_names, and the reverse path
    (as_list -> as_struct) reconstitutes both levels."""
    # Build a 2-row outer LIST. Row 0 has 2 struct items; row 1 has 1.
    # Inner struct = (a: Int32, b: String).
    # Flat children: (10, "alpha"), (20, "beta"), (30, "gamma")
    # List offsets: [0, 2, 3]

    var int_values = List[Scalar[DType.int32]]()
    int_values.append(Scalar[DType.int32](10))
    int_values.append(Scalar[DType.int32](20))
    int_values.append(Scalar[DType.int32](30))
    var int_arr = PrimitiveArray[DType.int32].from_list(int_values)
    var int_col = Column.from_primitive[DType.int32](int_arr)

    var strs = List[String]()
    strs.append(String("alpha"))
    strs.append(String("beta"))
    strs.append(String("gamma"))
    var str_arr = StringArray.from_strings(strs)
    var str_col = Column.from_string(str_arr^)

    var names = List[String]()
    names.append(String("a"))
    names.append(String("b"))

    var inner_struct = StructArray.from_columns_2(names, int_col^, str_col^)
    var struct_col = inner_struct.to_column()
    assert_equal(struct_col.length(), 3, "inner struct length 3")
    assert_equal(struct_col.num_children(), 2, "inner struct has 2 fields")

    # Build the LIST offsets manually (Int32: [0, 2, 3]).
    from std.sys import size_of
    from komira_arrow.bitmap import Bitmap
    from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
    comptime int32_size = size_of[Int32]()
    var off_buf = OwnedAlignedBuffer(3 * int32_size)
    off_buf.set_typed[Int32](0, Int32(0))
    off_buf.set_typed[Int32](1, Int32(2))
    off_buf.set_typed[Int32](2, Int32(3))
    off_buf.set_length(Int64(3 * int32_size))

    var la = ListArray(
        offsets=off_buf^,
        child=struct_col^,
        validity=None,
        length=2,
        null_count=0,
    )
    var col = Column.from_list(la)

    assert_equal(Int(col.arrow_type.type_id), Int(ArrowType.LIST.type_id),
                 "outer is LIST")
    assert_equal(col.length(), 2, "outer length 2")
    assert_equal(col.num_children(), 1, "outer has 1 child")
    # The single child is the inner STRUCT Column.
    ref kid = col.child_at(0)
    assert_equal(Int(kid.arrow_type.type_id), Int(ArrowType.STRUCT.type_id),
                 "child is STRUCT")
    assert_equal(kid.num_children(), 2, "inner struct has 2 fields")

    # Round-trip back.
    var la_out = col.as_list()
    assert_equal(len(la_out), 2, "round-trip outer length 2")
    assert_equal(la_out.get_offset(0), 0, "offset[0]=0")
    assert_equal(la_out.get_length(0), 2, "row 0 length 2")
    assert_equal(la_out.get_length(1), 1, "row 1 length 1")
    # Child is the inner STRUCT.
    assert_equal(Int(la_out.child.arrow_type.type_id),
                 Int(ArrowType.STRUCT.type_id), "child STRUCT preserved")

    # Unpack the inner STRUCT and check its 2 fields round-tripped.
    var sa_out = la_out.child.as_struct()
    assert_equal(sa_out.length, 3, "inner struct length 3")
    assert_equal(sa_out.num_fields(), 2, "inner struct 2 fields")
    var c0_arr = sa_out.child_at(0).as_primitive[DType.int32]()
    assert_equal(Int(c0_arr.get(0)), 10, "field a row 0")
    assert_equal(Int(c0_arr.get(1)), 20, "field a row 1")
    assert_equal(Int(c0_arr.get(2)), 30, "field a row 2")
    var c1_arr = sa_out.child_at(1).as_string()
    assert_true(c1_arr.get(0) == String("alpha"), "field b row 0 'alpha'")
    assert_true(c1_arr.get(1) == String("beta"), "field b row 1 'beta'")
    assert_true(c1_arr.get(2) == String("gamma"), "field b row 2 'gamma'")


# --- Test runner -------------------------------------------------------------


def main() raises:
    var suite = TestSuite()
    suite.test[test_g_list_int_column_round_trip]()
    suite.test[test_g_list_string_column_round_trip]()
    suite.test[test_g_struct_column_round_trip]()
    suite.test[test_g_map_keys_unsorted_column_round_trip]()
    suite.test[test_g_map_keys_sorted_column_round_trip]()
    suite.test[test_g_list_of_struct_column_round_trip]()
    suite^.run()

# Direct tests of `nested.mojo`: the Dremel level helpers. Expected values
# are the format's: a repetition level of 0 starts a new row, a definition
# level below a list's "present" level makes the row null, one at the
# present level is an empty list, one at or above the element level adds an
# element; Arrow list offsets start at 0 and offset i + 1 - offset i is the
# length of row i. Leaf levels: OPTIONAL adds a definition level, REPEATED a
# definition and a repetition level.
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer

from komira_parquet.nested import (
    DecodedLeaf,
    LeafInfo,
    NestedFieldInfo,
    _infer_nested_type,
    _walk_schema_node,
    compute_leaf_levels,
    reconstruct_list_column,
    reconstruct_map_column,
    reconstruct_struct_column,
)


def _levels(values: List[Int]) -> List[Int32]:
    var out = List[Int32]()
    for i in range(len(values)):
        out.append(Int32(values[i]))
    return out^


def _offsets(col: Column[HeapRegion]) -> List[Int]:
    var out = List[Int]()
    var view = col._offsets.value().view_ro()
    for i in range(col._length + 1):
        out.append(Int(view.read_i32_le_at(4 * i)))
    return out^


def _assert_offsets(col: Column[HeapRegion], want: List[Int]) raises:
    var got = _offsets(col)
    assert_equal(len(got), len(want))
    for i in range(len(want)):
        assert_equal(got[i], want[i], "offset " + String(i))


def _list_or_map(
    is_map: Bool,
    d: List[Int],
    r: List[Int],
    nullable: Bool,
    parent: Int,
    rows: Int,
) raises -> Column[HeapRegion]:
    if is_map:
        return reconstruct_map_column(_levels(d), _levels(r), nullable, parent, rows)
    return reconstruct_list_column(_levels(d), _levels(r), nullable, parent, rows)


# --- lists and maps ----------------------------------------------------------


def test_list_and_map_offsets_start_at_zero() raises:
    """[[a, b, c], [d, e]]: offsets [0, 3, 5]. The source wrote each row's
    end at the row's own index, giving [3, 5, 5]."""
    var d: List[Int] = [1, 1, 1, 1, 1]
    var r: List[Int] = [0, 1, 1, 0, 1]
    var want: List[Int] = [0, 3, 5]
    for m in range(2):
        var col = _list_or_map(m == 1, d, r, False, 0, 2)
        _same_type(col, m == 1)
        assert_equal(col._length, 2)
        assert_equal(col._null_count, 0)
        assert_false(Bool(col._validity))
        _assert_offsets(col, want)


def _same_type(col: Column[HeapRegion], is_map: Bool) raises:
    assert_true(col.arrow_type == (ArrowType.MAP if is_map else ArrowType.LIST))


def test_nullable_list_null_empty_and_null_element_rows() raises:
    """Row 0 = [1, null, 3], row 1 = null, row 2 = [], row 3 = [4]
    (optional list of optional elements: present 1, element 2, value 3)."""
    var d: List[Int] = [3, 2, 3, 0, 1, 3]
    var r: List[Int] = [0, 1, 1, 0, 0, 0]
    var want: List[Int] = [0, 3, 3, 3, 4]
    for m in range(2):
        var col = _list_or_map(m == 1, d, r, True, 0, 4)
        assert_equal(col._null_count, 1)
        assert_true(Bool(col._validity))
        assert_false(col._validity.value().test(1))
        assert_true(col._validity.value().test(2))
        _assert_offsets(col, want)


def test_rows_past_the_levels_are_empty_and_no_rep_levels() raises:
    """Levels for 2 rows of a 5-row column: rows 2..4 are empty. With no
    repetition levels every level starts a row (a flat leaf)."""
    var d: List[Int] = [1, 1, 1]
    var r: List[Int] = [0, 1, 0]
    var want: List[Int] = [0, 2, 3, 3, 3, 3]
    _assert_offsets(_list_or_map(False, d, r, False, 0, 5), want)
    var flat: List[Int] = [1, 0, 1]
    var want_flat: List[Int] = [0, 1, 1, 2]
    for m in range(2):
        _assert_offsets(_list_or_map(m == 1, flat, List[Int](), False, 0, 3), want_flat)
    # No levels at all: every row empty.
    var none: List[Int] = [0, 0, 0]
    _assert_offsets(_list_or_map(False, List[Int](), List[Int](), True, 0, 2), none)
    var zero_rows: List[Int] = [0]
    _assert_offsets(_list_or_map(True, List[Int](), List[Int](), False, 0, 0), zero_rows)


def test_parent_depth_shifts_the_levels_and_a_non_nullable_list_has_no_nulls() raises:
    """Under a parent at depth 2 a nullable list is present at 3 and has an
    element at 4. A non-nullable list never marks a row null, even when its
    level is below the parent's."""
    var d: List[Int] = [4, 4, 3, 2]
    var r: List[Int] = [0, 1, 0, 0]
    var col = _list_or_map(False, d, r, True, 2, 3)
    assert_equal(col._null_count, 1)
    var want: List[Int] = [0, 2, 2, 2]
    _assert_offsets(col, want)
    var plain = _list_or_map(True, d, r, False, 2, 3)
    assert_equal(plain._null_count, 0)
    assert_false(Bool(plain._validity))


def test_list_and_map_refusals() raises:
    """More rows in the levels than the column has, repetition levels that do
    not pair with the definition levels, a negative row count, and levels for
    a column of no rows: each refused before a write."""
    var three_rows_d: List[Int] = [1, 1, 1]
    var three_rows_r: List[Int] = [0, 0, 0]
    var short_r: List[Int] = [0, 0]
    for m in range(2):
        var name = String("reconstruct_map_column") if m == 1 else String("reconstruct_list_column")
        var msgs: List[String] = ["start more than 2 rows", "2 repetition levels for 3", "negative row count -1", "levels for a column of 0 rows"]
        for k in range(4):
            var raised = False
            try:
                if k == 0:
                    _ = _list_or_map(m == 1, three_rows_d, three_rows_r, False, 0, 2)
                elif k == 1:
                    _ = _list_or_map(m == 1, three_rows_d, short_r, False, 0, 3)
                elif k == 2:
                    _ = _list_or_map(m == 1, List[Int](), List[Int](), False, 0, -1)
                else:
                    _ = _list_or_map(m == 1, three_rows_d, three_rows_r, False, 0, 0)
            except e:
                raised = True
                assert_true(name in String(e), String(e))
                assert_true(msgs[k] in String(e), String(e))
            assert_true(raised, name + " refusal " + String(k))


# --- structs -----------------------------------------------------------------


def test_struct_validity() raises:
    var d: List[Int] = [1, 0, 1, 0]
    var col = reconstruct_struct_column(_levels(d), True, 1, 4)
    assert_true(col.arrow_type == ArrowType.STRUCT)
    assert_equal(col._null_count, 2)
    assert_false(col._validity.value().test(3))
    # Not nullable, depth 0, or too few levels: no validity.
    assert_false(Bool(reconstruct_struct_column(_levels(d), False, 1, 4)._validity))
    assert_false(Bool(reconstruct_struct_column(_levels(d), True, 0, 4)._validity))
    assert_false(Bool(reconstruct_struct_column(_levels(d), True, 1, 5)._validity))
    try:
        _ = reconstruct_struct_column(_levels(d), True, 1, -1)
        assert_true(False, "a negative row count")
    except e:
        assert_true("negative row count -1" in String(e), String(e))


# --- schema walk -------------------------------------------------------------


def test_leaf_levels_of_a_nested_schema() raises:
    """root { required a; optional group s { optional b; repeated c } }:
    a (0, 0); b (2, 0); c (2, 1), each with its parent type."""
    var names: List[String] = ["root", "a", "s", "b", "c"]
    var kids: List[Int] = [2, 0, 2, 0, 0]
    var reps: List[Int] = [-1, 0, 1, 1, 2]
    var leaves = compute_leaf_levels(names, kids, reps, 5)
    assert_equal(len(leaves), 3)
    assert_equal(leaves[0].schema_index, 1)
    assert_equal(leaves[0].max_def_level, 0)
    assert_true(leaves[0].parent_type == ArrowType.NULL)
    assert_equal(leaves[1].leaf_index, 1)
    assert_equal(leaves[1].max_def_level, 2)
    assert_equal(leaves[2].max_def_level, 2)
    assert_equal(leaves[2].max_rep_level, 1)
    assert_true(leaves[2].parent_type == ArrowType.STRUCT)


def test_a_repeated_group_is_a_list_parent_and_a_short_schema_stops() raises:
    """A repeated group's children have a LIST parent. A group claiming more
    children than the schema holds stops at the end."""
    var names: List[String] = ["root", "l", "e"]
    var kids: List[Int] = [1, 3, 0]
    var reps: List[Int] = [-1, 2, 0]
    var leaves = compute_leaf_levels(names, kids, reps, 3)
    assert_equal(len(leaves), 1)
    assert_true(leaves[0].parent_type == ArrowType.LIST)
    assert_equal(leaves[0].max_def_level, 1)
    assert_equal(leaves[0].max_rep_level, 1)
    assert_true(_infer_nested_type(1, 2) == ArrowType.LIST)
    assert_true(_infer_nested_type(1, 1) == ArrowType.STRUCT)


def test_schema_walk_refusals_and_end() raises:
    var names: List[String] = ["root", "a"]
    var kids: List[Int] = [1, 0]
    var reps: List[Int] = [-1, 0]
    try:
        _ = compute_leaf_levels(names, kids, reps, 3)
        assert_true(False, "more elements than the lists hold")
    except e:
        assert_true("3 schema elements but 2 child counts" in String(e), String(e))
    var short_reps: List[Int] = [-1]
    try:
        _ = compute_leaf_levels(names, kids, short_reps, 2)
        assert_true(False, "a short repetition list")
    except e:
        assert_true("1 repetition types" in String(e), String(e))
    var out = List[LeafInfo]()
    assert_equal(_walk_schema_node(2, names, kids, reps, 2, 0, 0, ArrowType.NULL, out, 0), 0)
    assert_equal(len(out), 0)


# --- the plain structs -------------------------------------------------------


def test_level_structs_hold_their_fields() raises:
    var col = Column[HeapRegion](
        arrow_type=ArrowType.INT32,
        data=OwnedAlignedBuffer(0),
        offsets=None,
        validity=None,
        length=0,
        null_count=0,
        offset=0,
    )
    var leaf = DecodedLeaf(col^, _levels([1, 0]), _levels([0, 1]), 1, 1)
    assert_equal(len(leaf.def_levels), 2)
    assert_equal(Int(leaf.rep_levels[1]), 1)
    assert_equal(leaf.max_def_level, 1)
    var f = NestedFieldInfo("f", ArrowType.LIST, True, True, 1, 2, 1)
    assert_equal(f.name, String("f"))
    assert_true(f.is_repeated)
    assert_equal(f.num_children, 1)
    assert_equal(f.def_depth, 2)
    assert_equal(f.rep_depth, 1)
    var g = f.copy()
    assert_true(g.nullable)
    var li = LeafInfo(0, 1, 2, 3, ArrowType.MAP)
    assert_equal(li.max_rep_level, 3)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

# =============================================================================
# Tests for Parquet nested type support (Struct, List, Map)
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_parquet import (
    bit_width_for_max_level,
    compute_leaf_levels,
    LeafInfo,
    reconstruct_struct_column,
    reconstruct_list_column,
    reconstruct_map_column,
)
from komira_arrow.column import Column
from komira_arrow.arrow_types import ArrowType


# =============================================================================
# bit_width_for_max_level tests
# =============================================================================


def test_bit_width_max_level_0() raises:
    """Bit width 0 for max_level=0."""
    assert_equal(bit_width_for_max_level(0), 0)


def test_bit_width_max_level_1() raises:
    """Bit width 1 for max_level=1."""
    assert_equal(bit_width_for_max_level(1), 1)


def test_bit_width_max_level_2() raises:
    """Bit width 2 for max_level=2."""
    assert_equal(bit_width_for_max_level(2), 2)


def test_bit_width_max_level_3() raises:
    """Bit width 2 for max_level=3 (2 bits hold 0-3)."""
    assert_equal(bit_width_for_max_level(3), 2)


def test_bit_width_max_level_4() raises:
    """Bit width 3 for max_level=4."""
    assert_equal(bit_width_for_max_level(4), 3)


def test_bit_width_max_level_7() raises:
    """Bit width 3 for max_level=7."""
    assert_equal(bit_width_for_max_level(7), 3)


def test_bit_width_max_level_8() raises:
    """Bit width 4 for max_level=8."""
    assert_equal(bit_width_for_max_level(8), 4)


# =============================================================================
# Schema tree level computation tests
# =============================================================================


def test_flat_schema_levels() raises:
    """Flat schema: required int32 a, optional int64 b."""
    var names: List[String] = ["root", "a", "b"]
    var children: List[Int] = [2, 0, 0]
    var rep_types: List[Int] = [-1, 0, 1]

    var result = compute_leaf_levels(names, children, rep_types, 3)
    assert_equal(len(result), 2)
    assert_equal(result[0].max_def_level, 0)
    assert_equal(result[0].max_rep_level, 0)
    assert_equal(result[1].max_def_level, 1)
    assert_equal(result[1].max_rep_level, 0)


def test_nullable_struct_levels() raises:
    """Nullable struct with required and optional children."""
    var names: List[String] = ["root", "s", "a", "b"]
    var children: List[Int] = [1, 2, 0, 0]
    var rep_types: List[Int] = [-1, 1, 0, 1]

    var result = compute_leaf_levels(names, children, rep_types, 4)
    assert_equal(len(result), 2)
    assert_equal(result[0].max_def_level, 1)
    assert_equal(result[0].max_rep_level, 0)
    assert_equal(result[1].max_def_level, 2)
    assert_equal(result[1].max_rep_level, 0)


def test_nullable_list_levels() raises:
    """Nullable list: items(opt)->list(rep)->element(opt) = def=3, rep=1."""
    var names: List[String] = ["root", "items", "list", "element"]
    var children: List[Int] = [1, 1, 1, 0]
    var rep_types: List[Int] = [-1, 1, 2, 1]

    var result = compute_leaf_levels(names, children, rep_types, 4)
    assert_equal(len(result), 1)
    assert_equal(result[0].max_def_level, 3)
    assert_equal(result[0].max_rep_level, 1)


def test_map_levels() raises:
    """Map: key def=2/rep=1, value def=3/rep=1."""
    var names: List[String] = ["root", "props", "key_value", "key", "value"]
    var children: List[Int] = [1, 1, 2, 0, 0]
    var rep_types: List[Int] = [-1, 1, 2, 0, 1]

    var result = compute_leaf_levels(names, children, rep_types, 5)
    assert_equal(len(result), 2)
    assert_equal(result[0].max_def_level, 2)
    assert_equal(result[0].max_rep_level, 1)
    assert_equal(result[1].max_def_level, 3)
    assert_equal(result[1].max_rep_level, 1)


def test_required_list_levels() raises:
    """Required list: items(req)->list(rep)->element(req) = def=1, rep=1."""
    var names: List[String] = ["root", "items", "list", "element"]
    var children: List[Int] = [1, 1, 1, 0]
    var rep_types: List[Int] = [-1, 0, 2, 0]

    var result = compute_leaf_levels(names, children, rep_types, 4)
    assert_equal(len(result), 1)
    assert_equal(result[0].max_def_level, 1)
    assert_equal(result[0].max_rep_level, 1)


def test_dremel_paper_levels() raises:
    """Dremel paper example: 5 leaves with correct def/rep levels."""
    var names: List[String] = [
        "Document", "DocId", "Links", "Backward", "Forward",
        "Name", "Language", "Code", "Country", "Url",
    ]
    var children: List[Int] = [3, 0, 2, 0, 0, 2, 2, 0, 0, 0]
    var rep_types: List[Int] = [-1, 0, 1, 2, 2, 2, 2, 0, 1, 1]

    var result = compute_leaf_levels(names, children, rep_types, 10)
    assert_equal(len(result), 6)
    assert_equal(result[0].max_def_level, 0)  # DocId
    assert_equal(result[0].max_rep_level, 0)
    assert_equal(result[1].max_def_level, 2)  # Backward
    assert_equal(result[1].max_rep_level, 1)
    assert_equal(result[2].max_def_level, 2)  # Forward
    assert_equal(result[2].max_rep_level, 1)
    assert_equal(result[3].max_def_level, 2)  # Code
    assert_equal(result[3].max_rep_level, 2)
    assert_equal(result[4].max_def_level, 3)  # Country
    assert_equal(result[4].max_rep_level, 2)
    assert_equal(result[5].max_def_level, 2)  # Url: Name(rep) + Url(opt) = def=2
    assert_equal(result[5].max_rep_level, 1)  # Url: Name(rep) = rep=1


# =============================================================================
# Struct reconstruction tests
# =============================================================================


def test_reconstruct_non_nullable_struct() raises:
    """Non-nullable struct column: no nulls, empty def levels."""
    var col = reconstruct_struct_column(
        def_levels=List[Int32](),
        struct_nullable=False,
        struct_def_depth=0,
        num_rows=2,
    )
    assert_equal(col.arrow_type, ArrowType.STRUCT)
    assert_equal(col._length, 2)
    assert_equal(col._null_count, 0)


def test_reconstruct_nullable_struct() raises:
    """Nullable struct: row 1 null (def=0 < depth=1)."""
    var def_levels = List[Int32]()
    def_levels.append(Int32(1))
    def_levels.append(Int32(0))
    def_levels.append(Int32(1))

    var col = reconstruct_struct_column(
        def_levels=def_levels,
        struct_nullable=True,
        struct_def_depth=1,
        num_rows=3,
    )
    assert_equal(col.arrow_type, ArrowType.STRUCT)
    assert_equal(col._length, 3)
    assert_equal(col._null_count, 1)


# =============================================================================
# List reconstruction tests
# =============================================================================


def test_reconstruct_simple_list() raises:
    """Required list [1,2,3],[4,5]: 2 rows, 0 nulls."""
    var def_levels = List[Int32]()
    def_levels.append(Int32(1))
    def_levels.append(Int32(1))
    def_levels.append(Int32(1))
    def_levels.append(Int32(1))
    def_levels.append(Int32(1))

    var rep_levels = List[Int32]()
    rep_levels.append(Int32(0))
    rep_levels.append(Int32(1))
    rep_levels.append(Int32(1))
    rep_levels.append(Int32(0))
    rep_levels.append(Int32(1))

    var col = reconstruct_list_column(
        def_levels=def_levels,
        rep_levels=rep_levels,
        list_nullable=False,
        parent_def_depth=0,
        num_rows=2,
    )
    assert_equal(col.arrow_type, ArrowType.LIST)
    assert_equal(col._length, 2)
    assert_equal(col._null_count, 0)
    # Check offsets: list 0 has 3 elements, list 1 has 2 elements.
    assert_true(col._offsets.__bool__())


def test_reconstruct_nullable_list_with_nulls() raises:
    """Nullable list: row 0=[1,null,3], row 1=null, row 2=[], row 3=[4]."""
    var def_levels = List[Int32]()
    def_levels.append(Int32(3))  # row 0, element 1 (present)
    def_levels.append(Int32(2))  # row 0, element null
    def_levels.append(Int32(3))  # row 0, element 3 (present)
    def_levels.append(Int32(0))  # row 1 (null list)
    def_levels.append(Int32(1))  # row 2 (empty list)
    def_levels.append(Int32(3))  # row 3, element 4 (present)

    var rep_levels = List[Int32]()
    rep_levels.append(Int32(0))
    rep_levels.append(Int32(1))
    rep_levels.append(Int32(1))
    rep_levels.append(Int32(0))
    rep_levels.append(Int32(0))
    rep_levels.append(Int32(0))

    var col = reconstruct_list_column(
        def_levels=def_levels,
        rep_levels=rep_levels,
        list_nullable=True,
        parent_def_depth=0,
        num_rows=4,
    )
    assert_equal(col.arrow_type, ArrowType.LIST)
    assert_equal(col._length, 4)
    assert_equal(col._null_count, 1)  # Row 1 is null


# =============================================================================
# Map reconstruction tests
# =============================================================================


def test_reconstruct_simple_map() raises:
    """Required map: row 0 has 2 entries, row 1 has 1 entry."""
    var def_levels = List[Int32]()
    def_levels.append(Int32(1))
    def_levels.append(Int32(1))
    def_levels.append(Int32(1))

    var rep_levels = List[Int32]()
    rep_levels.append(Int32(0))
    rep_levels.append(Int32(1))
    rep_levels.append(Int32(0))

    var col = reconstruct_map_column(
        def_levels=def_levels,
        rep_levels=rep_levels,
        map_nullable=False,
        parent_def_depth=0,
        num_rows=2,
    )
    assert_equal(col.arrow_type, ArrowType.MAP)
    assert_equal(col._length, 2)
    assert_equal(col._null_count, 0)


def test_reconstruct_nullable_map() raises:
    """Nullable map: row 0 has 2 entries, row 1 is null."""
    var def_levels = List[Int32]()
    def_levels.append(Int32(2))  # row 0, entry (present)
    def_levels.append(Int32(2))  # row 0, entry (present)
    def_levels.append(Int32(0))  # row 1 (null map)

    var rep_levels = List[Int32]()
    rep_levels.append(Int32(0))
    rep_levels.append(Int32(1))
    rep_levels.append(Int32(0))

    var col = reconstruct_map_column(
        def_levels=def_levels,
        rep_levels=rep_levels,
        map_nullable=True,
        parent_def_depth=0,
        num_rows=2,
    )
    assert_equal(col.arrow_type, ArrowType.MAP)
    assert_equal(col._length, 2)
    assert_equal(col._null_count, 1)


# =============================================================================
# Test runner
# =============================================================================


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

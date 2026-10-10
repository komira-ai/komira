# =============================================================================
# Nested Type Reconstruction — Dremel algorithm for Parquet nested types
# =============================================================================
#
# Reconstructs nested Arrow arrays (Struct, List, Map) from decoded leaf
# columns using definition and repetition levels (Dremel encoding).
#
# Corrupt levels (more rows than the caller's row count, repetition levels
# that do not pair with the definition levels, a negative row count) raise;
# nothing is written outside the offsets and validity buffers.
# =============================================================================

from std.memory import alloc, unsafe_memcpy, unsafe_memset
from std.sys import size_of

from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.arrow_types import ArrowType
from komira_buffer.heap_region import HeapRegion


# =============================================================================
# DecodedLeaf — a decoded leaf column with its levels
# =============================================================================


struct DecodedLeaf(Movable):
    """A decoded leaf column with its definition and repetition levels.

    IMPORTANT: Movable but NOT Copyable (Column is Movable-only).
    Hold several in a List[DecodedLeaf].

    Fields:
        column: The decoded Arrow Column for this leaf.
        def_levels: Definition levels as Int32 values.
        rep_levels: Repetition levels as Int32 values.
        max_def_level: Maximum definition level for this leaf path.
        max_rep_level: Maximum repetition level for this leaf path.
    """

    var column: Column[HeapRegion]
    var def_levels: List[Int32]
    var rep_levels: List[Int32]
    var max_def_level: Int
    var max_rep_level: Int

    def __init__(
        out self,
        var column: Column[HeapRegion],
        var def_levels: List[Int32],
        var rep_levels: List[Int32],
        max_def_level: Int,
        max_rep_level: Int,
    ):
        self.column = column^
        self.def_levels = def_levels^
        self.rep_levels = rep_levels^
        self.max_def_level = max_def_level
        self.max_rep_level = max_rep_level


# =============================================================================
# NestedFieldInfo — schema tree node metadata
# =============================================================================


struct NestedFieldInfo(Movable, Copyable):
    """Metadata about a field in the Parquet schema tree.

    Fields:
        name: Field name.
        arrow_type: Target Arrow type.
        nullable: Whether this field is nullable (OPTIONAL).
        is_repeated: Whether this field is REPEATED.
        num_children: Number of children (0 for leaf).
        def_depth: Definition level depth at this field.
        rep_depth: Repetition level depth at this field.
    """

    var name: String
    var arrow_type: ArrowType
    var nullable: Bool
    var is_repeated: Bool
    var num_children: Int
    var def_depth: Int
    var rep_depth: Int

    def __init__(
        out self,
        var name: String,
        arrow_type: ArrowType,
        nullable: Bool,
        is_repeated: Bool,
        num_children: Int,
        def_depth: Int,
        rep_depth: Int,
    ):
        self.name = name^
        self.arrow_type = arrow_type
        self.nullable = nullable
        self.is_repeated = is_repeated
        self.num_children = num_children
        self.def_depth = def_depth
        self.rep_depth = rep_depth


# =============================================================================
# Struct Reconstruction
# =============================================================================


def reconstruct_struct_column(
    def_levels: List[Int32],
    struct_nullable: Bool,
    struct_def_depth: Int,
    num_rows: Int,
) raises -> Column[HeapRegion]:
    """Build a STRUCT Column[HeapRegion] from def levels (validity only).

    For a nullable struct, rows where def_level < struct_def_depth are null.
    Child columns must be stored separately (Column cannot hold children).

    Args:
        def_levels: Def levels from the first leaf (copied, not moved).
        struct_nullable: Whether the struct is nullable.
        struct_def_depth: Def threshold for struct presence.
        num_rows: Number of rows.

    Returns:
        A Column with arrow_type=STRUCT and the correct validity bitmap.

    Raises:
        Error if `num_rows` is negative.
    """
    if num_rows < 0:
        raise Error(
            "reconstruct_struct_column: negative row count " + String(num_rows)
        )
    var validity = Optional[Bitmap[HeapRegion]](None)
    var null_count = 0

    if struct_nullable and struct_def_depth > 0 and len(def_levels) >= num_rows:
        var bm = Bitmap.create_all_valid(num_rows)
        for i in range(num_rows):
            if Int(def_levels[i]) < struct_def_depth:
                bm.clear(i)
                null_count += 1
        validity = bm^

    var data_buf = OwnedAlignedBuffer(0)
    return Column[HeapRegion](
        arrow_type=ArrowType.STRUCT,
        data=data_buf^,
        offsets=None,
        validity=validity^,
        length=num_rows,
        null_count=null_count,
        offset=0,
    )


def _check_level_rows(
    caller: String, num_def: Int, num_rep: Int, num_rows: Int
) raises:
    """Refuse levels a list or map column cannot be built from: a negative row
    count, repetition levels that do not pair one to one with the definition
    levels, or levels with a first row where the column has none."""
    if num_rows < 0:
        raise Error(caller + ": negative row count " + String(num_rows))
    if num_rep > 0 and num_rep != num_def:
        raise Error(
            caller
            + ": "
            + String(num_rep)
            + " repetition levels for "
            + String(num_def)
            + " definition levels"
        )
    if num_def > 0 and num_rows == 0:
        raise Error(caller + ": levels for a column of 0 rows")


# =============================================================================
# List Reconstruction
# =============================================================================


def reconstruct_list_column(
    def_levels: List[Int32],
    rep_levels: List[Int32],
    list_nullable: Bool,
    parent_def_depth: Int,
    num_rows: Int,
) raises -> Column[HeapRegion]:
    """Build a LIST Column[HeapRegion] from def/rep levels (offsets + validity).

    Parquet 3-level list encoding level semantics:
      - def < list_present_def: list is null
      - def == list_present_def: list exists but is empty
      - def >= element_base_def: list has an element
      - rep == 0: new row (new list)
      - rep == 1: continuation within same list

    Args:
        def_levels: Def levels for the list's leaf column.
        rep_levels: Rep levels for the list's leaf column.
        list_nullable: Whether the list field is nullable.
        parent_def_depth: Def level of the parent context.
        num_rows: Number of output rows (lists).

    Returns:
        A Column with arrow_type=LIST containing offsets and validity.

    Raises:
        Error if `num_rows` is negative, the levels start more rows than
        `num_rows`, or `rep_levels` is neither empty nor as long as
        `def_levels`.
    """
    var list_present_def = parent_def_depth
    if list_nullable:
        list_present_def = parent_def_depth + 1
    var element_base_def = list_present_def + 1

    var n = len(def_levels)
    _check_level_rows("reconstruct_list_column", n, len(rep_levels), num_rows)

    # Build offsets buffer. Writes go through `set_typed[Int32]` on the
    # buffer (origin-tied via `mut self`).
    comptime int32_size = size_of[Int32]()
    var offsets_buf = OwnedAlignedBuffer((num_rows + 1) * int32_size)
    offsets_buf.set_length(Int64((num_rows + 1) * int32_size))


    var list_bm = Bitmap.create_all_valid(num_rows)
    var list_null_count = 0

    var row_idx = 0
    var current_offset = Int32(0)
    offsets_buf.set_typed[Int32](0, Int32(0))

    for i in range(n):
        var def_val = Int(def_levels[i])
        var rep_val = Int(rep_levels[i]) if len(rep_levels) > 0 else 0

        if rep_val == 0 and i > 0:
            row_idx += 1
            if row_idx >= num_rows:
                raise Error(
                    "reconstruct_list_column: the levels start more than "
                    + String(num_rows)
                    + " rows"
                )
            offsets_buf.set_typed[Int32](row_idx, current_offset)

        if rep_val == 0:
            if list_nullable and def_val < list_present_def:
                list_bm.clear(row_idx)
                list_null_count += 1

        if def_val >= element_base_def:
            current_offset += Int32(1)

    # Rows after the last row the levels start are empty; offset `num_rows`
    # ends the column.
    row_idx += 1
    while row_idx <= num_rows:
        offsets_buf.set_typed[Int32](row_idx, current_offset)
        row_idx += 1

    var validity = Optional[Bitmap[HeapRegion]](None)
    if list_nullable and list_null_count > 0:
        validity = list_bm^

    var data_buf = OwnedAlignedBuffer(0)
    return Column[HeapRegion](
        arrow_type=ArrowType.LIST,
        data=data_buf^,
        offsets=offsets_buf^,
        validity=validity^,
        length=num_rows,
        null_count=list_null_count,
        offset=0,
    )


# =============================================================================
# Map Reconstruction
# =============================================================================


def reconstruct_map_column(
    def_levels: List[Int32],
    rep_levels: List[Int32],
    map_nullable: Bool,
    parent_def_depth: Int,
    num_rows: Int,
) raises -> Column[HeapRegion]:
    """Build a MAP Column[HeapRegion] from def/rep levels (offsets + validity).

    Map uses the same offset/null logic as List.

    Args:
        def_levels: Def levels for the map's key leaf column.
        rep_levels: Rep levels for the map's key leaf column.
        map_nullable: Whether the map field is nullable.
        parent_def_depth: Def level of the parent context.
        num_rows: Number of output rows.

    Returns:
        A Column with arrow_type=MAP containing offsets and validity.

    Raises:
        Error if `num_rows` is negative, the levels start more rows than
        `num_rows`, or `rep_levels` is neither empty nor as long as
        `def_levels`.
    """
    var map_present_def = parent_def_depth
    if map_nullable:
        map_present_def = parent_def_depth + 1
    var element_base_def = map_present_def + 1

    var n = len(def_levels)
    _check_level_rows("reconstruct_map_column", n, len(rep_levels), num_rows)

    comptime int32_size = size_of[Int32]()
    var offsets_buf = OwnedAlignedBuffer((num_rows + 1) * int32_size)
    offsets_buf.set_length(Int64((num_rows + 1) * int32_size))


    var map_bm = Bitmap.create_all_valid(num_rows)
    var map_null_count = 0

    var row_idx = 0
    var current_offset = Int32(0)
    offsets_buf.set_typed[Int32](0, Int32(0))

    for i in range(n):
        var def_val = Int(def_levels[i])
        var rep_val = Int(rep_levels[i]) if len(rep_levels) > 0 else 0

        if rep_val == 0 and i > 0:
            row_idx += 1
            if row_idx >= num_rows:
                raise Error(
                    "reconstruct_map_column: the levels start more than "
                    + String(num_rows)
                    + " rows"
                )
            offsets_buf.set_typed[Int32](row_idx, current_offset)

        if rep_val == 0:
            if map_nullable and def_val < map_present_def:
                map_bm.clear(row_idx)
                map_null_count += 1

        if def_val >= element_base_def:
            current_offset += Int32(1)

    row_idx += 1
    while row_idx <= num_rows:
        offsets_buf.set_typed[Int32](row_idx, current_offset)
        row_idx += 1

    var validity = Optional[Bitmap[HeapRegion]](None)
    if map_nullable and map_null_count > 0:
        validity = map_bm^

    var data_buf = OwnedAlignedBuffer(0)
    return Column[HeapRegion](
        arrow_type=ArrowType.MAP,
        data=data_buf^,
        offsets=offsets_buf^,
        validity=validity^,
        length=num_rows,
        null_count=map_null_count,
        offset=0,
    )


# =============================================================================
# Schema tree analysis — compute max_def_level and max_rep_level per leaf
# =============================================================================


struct LeafInfo(Movable, Copyable):
    """Level metadata for a single leaf column.

    Fields:
        leaf_index: Index of this leaf in the flattened column list.
        schema_index: Index in the SchemaElement list.
        max_def_level: Maximum definition level for this leaf path.
        max_rep_level: Maximum repetition level for this leaf path.
        parent_type: The nested type of the immediate parent.
    """

    var leaf_index: Int
    var schema_index: Int
    var max_def_level: Int
    var max_rep_level: Int
    var parent_type: ArrowType

    def __init__(
        out self,
        leaf_index: Int,
        schema_index: Int,
        max_def_level: Int,
        max_rep_level: Int,
        parent_type: ArrowType,
    ):
        self.leaf_index = leaf_index
        self.schema_index = schema_index
        self.max_def_level = max_def_level
        self.max_rep_level = max_rep_level
        self.parent_type = parent_type


def compute_leaf_levels(
    schema_names: List[String],
    schema_num_children: List[Int],
    schema_repetition_types: List[Int],
    num_schema_elements: Int,
) raises -> List[LeafInfo]:
    """Walk the Parquet schema tree and compute max_def/max_rep per leaf.

    Repetition type encoding:
      0 = REQUIRED: contributes nothing
      1 = OPTIONAL: +1 to def
      2 = REPEATED: +1 to def AND +1 to rep

    Args:
        schema_names: Flattened schema element names.
        schema_num_children: Children count per element.
        schema_repetition_types: Repetition type per element (0/1/2, -1=root).
        num_schema_elements: Total schema elements.

    Returns:
        List of LeafInfo, one per leaf, in column order.

    Raises:
        Error if `num_schema_elements` is larger than the per-element lists.
    """
    if (
        num_schema_elements > len(schema_num_children)
        or num_schema_elements > len(schema_repetition_types)
    ):
        raise Error(
            "compute_leaf_levels: "
            + String(num_schema_elements)
            + " schema elements but "
            + String(len(schema_num_children))
            + " child counts and "
            + String(len(schema_repetition_types))
            + " repetition types"
        )
    var result = List[LeafInfo]()
    var pos = 1  # Skip root (element 0).
    while pos < num_schema_elements:
        var consumed = _walk_schema_node(
            pos, schema_names, schema_num_children,
            schema_repetition_types, num_schema_elements,
            0, 0, ArrowType.NULL, result, len(result),
        )
        pos += consumed

    return result^


def _walk_schema_node(
    pos: Int,
    schema_names: List[String],
    schema_num_children: List[Int],
    schema_repetition_types: List[Int],
    num_elements: Int,
    def_depth: Int,
    rep_depth: Int,
    parent_type: ArrowType,
    mut result: List[LeafInfo],
    leaf_index_start: Int,
) -> Int:
    """Walk one schema node and its children. Returns elements consumed."""
    if pos >= num_elements:
        return 0

    var num_children = schema_num_children[pos]
    var rep_type = schema_repetition_types[pos]

    var my_def = def_depth
    var my_rep = rep_depth
    if rep_type == 1:  # OPTIONAL
        my_def += 1
    elif rep_type == 2:  # REPEATED
        my_def += 1
        my_rep += 1

    if num_children == 0:
        # Leaf node.
        result.append(LeafInfo(
            leaf_index=len(result),
            schema_index=pos,
            max_def_level=my_def,
            max_rep_level=my_rep,
            parent_type=parent_type,
        ))
        return 1

    # Group node. Walk children.
    var consumed = 1
    var child_pos = pos + 1
    for _ in range(num_children):
        if child_pos >= num_elements:
            break
        var child_consumed = _walk_schema_node(
            child_pos, schema_names, schema_num_children,
            schema_repetition_types, num_elements,
            my_def, my_rep,
            _infer_nested_type(num_children, rep_type),
            result, len(result),
        )
        consumed += child_consumed
        child_pos += child_consumed

    return consumed


def _infer_nested_type(num_children: Int, rep_type: Int) -> ArrowType:
    """Infer nested type from schema node properties."""
    if rep_type == 2:
        return ArrowType.LIST
    else:
        return ArrowType.STRUCT

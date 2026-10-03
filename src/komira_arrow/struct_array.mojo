# =============================================================================
# StructArray — Arrow-compatible struct (row of named fields) columnar array
# =============================================================================
#
# Arrow format for struct:
#   validity bitmap: optional, 1 bit per row (1=valid, 0=null).
#   children: N child arrays (one Column per field), all the same length.
#
# A StructArray is like a RecordBatch but can be nested inside other arrays
# (e.g., List<Struct>). Each child Column is type-erased and can hold any
# Arrow array type.
#
# Children are stored in a Slab[Column] — same pattern used by
# RecordBatch. Slab provides a safe, owning, fixed-capacity container
# for Movable-only types (Column is Movable but not Copyable).
# =============================================================================

# =============================================================================
# Children are reached through the safe
# `child_at(index) -> ref [_children._bytes] Column` accessor. This file
# contains zero wildcard-origin sites.
# =============================================================================

from komira_collections.slab import Slab

from komira_buffer.heap_region import HeapRegion
from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer


struct StructArray(Movable, Sized):
    """Arrow Struct array — rows of named fields.

    Like a RecordBatch but can be nested inside other arrays (e.g.,
    List<Struct>). All child columns must have the same length.

    Children are stored in a Slab[Column], which owns the heap
    allocation and provides safe indexed access. Slab is the
    right collection because (a) the number of fields is known at
    construction time, and (b) Column is Movable-only which rules out
    List[Column].

    Fields:
        _children: Owning array of child columns, one per field.
        field_names: Field names matching children (parallel list).
        validity: Optional validity bitmap (Arrow convention: bit=1 means
            valid, bit=0 means null). None means "no nulls" (fast path).
        length: Number of rows (same as each child column's length).
        null_count: Number of null (invalid) rows. 0 when validity is None.
    """

    var _children: Slab[Column[HeapRegion]]
    var field_names: List[String]
    var validity: Optional[Bitmap[HeapRegion]]
    var length: Int
    var null_count: Int

    # --- Constructors ---

    def __init__(out self):
        """Create an empty StructArray with 0 fields and 0 rows."""
        self._children = Slab[Column[HeapRegion]]()
        self.field_names = List[String]()
        self.validity = Optional[Bitmap[HeapRegion]](None)
        self.length = 0
        self.null_count = 0

    # NOTE: No __del__. Slab handles destruction of the child Columns
    # and the backing allocation. Auto-synth destructor drops _children.

    # --- Builder-style construction ---

    @staticmethod
    def _build(
        names: List[String],
        num_fields: Int,
        row_count: Int,
        var children: Slab[Column[HeapRegion]],
        var validity: Optional[Bitmap[HeapRegion]],
        null_count: Int,
    ) -> StructArray:
        """Internal: assemble a StructArray from validated components.

        Args:
            names: Field names.
            num_fields: Number of fields.
            row_count: Number of rows.
            children: Owning Slab of child columns. Moved in.
            validity: Optional validity bitmap.
            null_count: Number of null rows.

        Returns:
            A new StructArray.
        """
        var field_names = List[String]()
        for i in range(num_fields):
            field_names.append(names[i])

        var sa = StructArray()
        sa._children = children^
        sa.field_names = field_names^
        sa.validity = validity^
        sa.length = row_count
        sa.null_count = null_count
        return sa^

    @staticmethod
    def from_columns_2(
        names: List[String],
        var col0: Column[HeapRegion],
        var col1: Column[HeapRegion],
    ) raises -> StructArray:
        """Create a non-nullable StructArray from 2 named columns.

        Args:
            names: Two field names.
            col0: First column. Ownership transferred.
            col1: Second column. Ownership transferred.

        Returns:
            A new StructArray with no nulls.

        Raises:
            Error if names count is not 2 or column lengths differ.
        """
        if len(names) != 2:
            raise Error(
                "StructArray.from_columns_2: expected 2 names, got "
                + String(len(names))
            )
        if col0._length != col1._length:
            raise Error(
                "StructArray.from_columns_2: column lengths differ: "
                + String(col0._length)
                + " vs "
                + String(col1._length)
            )
        var row_count = col0._length
        var children = Slab[Column[HeapRegion]].create(2)
        children.append(col0^)
        children.append(col1^)
        return StructArray._build(
            names, 2, row_count, children^, None, 0
        )

    @staticmethod
    def from_columns_3(
        names: List[String],
        var col0: Column[HeapRegion],
        var col1: Column[HeapRegion],
        var col2: Column[HeapRegion],
    ) raises -> StructArray:
        """Create a non-nullable StructArray from 3 named columns.

        Args:
            names: Three field names.
            col0: First column. Ownership transferred.
            col1: Second column. Ownership transferred.
            col2: Third column. Ownership transferred.

        Returns:
            A new StructArray with no nulls.

        Raises:
            Error if names count is not 3 or column lengths differ.
        """
        if len(names) != 3:
            raise Error(
                "StructArray.from_columns_3: expected 3 names, got "
                + String(len(names))
            )
        var row_count = col0._length
        if col1._length != row_count:
            raise Error(
                "StructArray.from_columns_3: column 1 has length "
                + String(col1._length)
                + ", expected "
                + String(row_count)
            )
        if col2._length != row_count:
            raise Error(
                "StructArray.from_columns_3: column 2 has length "
                + String(col2._length)
                + ", expected "
                + String(row_count)
            )
        var children = Slab[Column[HeapRegion]].create(3)
        children.append(col0^)
        children.append(col1^)
        children.append(col2^)
        return StructArray._build(
            names, 3, row_count, children^, None, 0
        )

    @staticmethod
    def from_columns_1(
        names: List[String],
        var col0: Column[HeapRegion],
    ) raises -> StructArray:
        """Create a non-nullable StructArray from 1 named column.

        Args:
            names: One field name.
            col0: The column. Ownership transferred.

        Returns:
            A new StructArray with no nulls.

        Raises:
            Error if names count is not 1.
        """
        if len(names) != 1:
            raise Error(
                "StructArray.from_columns_1: expected 1 name, got "
                + String(len(names))
            )
        var row_count = col0._length
        var children = Slab[Column[HeapRegion]].create(1)
        children.append(col0^)
        return StructArray._build(
            names, 1, row_count, children^, None, 0
        )

    @staticmethod
    def from_columns_1_nullable(
        names: List[String],
        var col0: Column[HeapRegion],
        valid_mask: List[Bool],
    ) raises -> StructArray:
        """Create a nullable StructArray from 1 named column.

        Args:
            names: One field name.
            col0: The column. Ownership transferred.
            valid_mask: Parallel booleans. True = valid, False = null.

        Returns:
            A new StructArray with a validity bitmap.

        Raises:
            Error if names count is not 1.
        """
        if len(names) != 1:
            raise Error(
                "StructArray.from_columns_1_nullable: expected 1 name, got "
                + String(len(names))
            )
        var row_count = col0._length
        var children = Slab[Column[HeapRegion]].create(1)
        children.append(col0^)

        var null_count = 0
        var bm = Bitmap.create_all_valid(row_count)
        for i in range(row_count):
            if i < len(valid_mask) and not valid_mask[i]:
                bm.clear(i)
                null_count += 1

        return StructArray._build(
            names, 1, row_count, children^, bm^, null_count
        )

    @staticmethod
    def from_columns_2_nullable(
        names: List[String],
        var col0: Column[HeapRegion],
        var col1: Column[HeapRegion],
        valid_mask: List[Bool],
    ) raises -> StructArray:
        """Create a nullable StructArray from 2 named columns.

        Args:
            names: Two field names.
            col0: First column. Ownership transferred.
            col1: Second column. Ownership transferred.
            valid_mask: Parallel booleans. True = valid, False = null.

        Returns:
            A new StructArray with a validity bitmap.

        Raises:
            Error if names count is not 2 or column lengths differ.
        """
        if len(names) != 2:
            raise Error(
                "StructArray.from_columns_2_nullable: expected 2 names, got "
                + String(len(names))
            )
        if col0._length != col1._length:
            raise Error(
                "StructArray.from_columns_2_nullable: column lengths differ: "
                + String(col0._length)
                + " vs "
                + String(col1._length)
            )
        var row_count = col0._length
        var children = Slab[Column[HeapRegion]].create(2)
        children.append(col0^)
        children.append(col1^)

        var null_count = 0
        var bm = Bitmap.create_all_valid(row_count)
        for i in range(row_count):
            if i < len(valid_mask) and not valid_mask[i]:
                bm.clear(i)
                null_count += 1

        return StructArray._build(
            names, 2, row_count, children^, bm^, null_count
        )

    # --- Element Access ---

    @always_inline
    def __len__(self) -> Int:
        """Return the number of rows in the struct array."""
        return self.length

    @always_inline
    def num_fields(self) -> Int:
        """Return the number of fields (child columns).

        Returns:
            The number of named fields in this struct.
        """
        return len(self._children)

    @always_inline
    def field_name(self, index: Int) -> String:
        """Return the name of the field at the given index.

        Args:
            index: Zero-based field index.

        Returns:
            The field name.
        """
        return self.field_names[index]

    @always_inline
    def child_at(self, index: Int) -> ref [self._children._bytes] Column[HeapRegion]:
        """Return a safe reference to the child Column[HeapRegion] at `index`.

        The reference's lifetime is tied to this StructArray's child
        storage. Preferred over `_child_ref()` for all new code.

        Args:
            index: Zero-based field index.

        Returns:
            A reference to the Column.
        """
        return self._children[index]

    # --- Null Handling ---

    @always_inline
    def is_null(self, index: Int) -> Bool:
        """Check if the row at index is null.

        Returns False if no validity bitmap (all rows are valid).

        Args:
            index: Zero-based row index.

        Returns:
            True if the row is null, False if valid.
        """
        if not self.validity:
            return False
        return not self.validity.value().test(index)

    # --- Column round-trip (StructArray <-> type-erased Column) ---
    #
    # Mirrors ListArray's `to_column` /
    # `from_column` pair.  Layout on the Column:
    #   _children    : Slab[Column] holding the N child Columns
    #   _field_names : List[String] of N parallel names
    #   _validity    : the struct-level validity bitmap
    #   arrow_type   : ArrowType.STRUCT
    # The Column's `_data` / `_offsets` are unused (STRUCT has no buffer
    # of its own besides validity).

    def to_column(self) raises -> Column[HeapRegion]:
        """Pack this StructArray into a type-erased Column[HeapRegion] with
        `arrow_type == ArrowType.STRUCT`.  Reversible via `from_column`.
        """
        # validity (struct-level)
        var validity = Optional[Bitmap[HeapRegion]](None)
        if self.validity:
            var bm_len = self.validity.value().length
            var bm = Bitmap.create(bm_len)
            var bm_bytes = (bm_len + 7) >> 3
            if bm_bytes > 0:
                bm.buffer.copy_from_view(
                    self.validity.value().buffer.view_range_ro(0, bm_bytes)
                )
                bm.buffer.set_length(bm_bytes)

            validity = bm^

        # zero-length data buffer (STRUCT has only validity at this level)
        var data_buf = OwnedAlignedBuffer(1)
        data_buf.set_length(0)


        var col = Column[HeapRegion](
            arrow_type=ArrowType.STRUCT,
            data=data_buf^,
            offsets=None,
            validity=validity^,
            length=self.length,
            null_count=self.null_count,
            offset=0,
        )
        # Deep-copy children.
        var nfields = self.num_fields()
        var kids = Slab[Column[HeapRegion]].create(nfields)
        for i in range(nfields):
            kids.append(self.child_at(i).deep_copy())
        col._children = kids^
        # Copy field names.
        for i in range(nfields):
            col._field_names.append(self.field_names[i])
        return col^

    @staticmethod
    def from_column(col: Column[HeapRegion]) raises -> StructArray:
        """Unpack a `Column[HeapRegion]` (built by `to_column`) back into a
        StructArray.  """
        if col.arrow_type != ArrowType.STRUCT:
            raise Error(
                "StructArray.from_column: arrow_type is "
                + String(col.arrow_type)
                + ", expected struct"
            )
        var nfields = len(col._children)
        if len(col._field_names) != nfields:
            raise Error(
                "StructArray.from_column: field_names length ("
                + String(len(col._field_names))
                + ") != children length ("
                + String(nfields)
                + ")"
            )
        # Deep-copy children into a fresh Slab.
        var kids = Slab[Column[HeapRegion]].create(max(nfields, 1))
        for i in range(nfields):
            kids.append(col._children[i].deep_copy())
        # validity (struct-level)
        var validity = Optional[Bitmap[HeapRegion]](None)
        if col._validity:
            var bm_len = col._validity.value().length
            var bm = Bitmap.create(bm_len)
            var bm_bytes = (bm_len + 7) >> 3
            if bm_bytes > 0:
                bm.buffer.copy_from_view(
                    col._validity.value().buffer.view_range_ro(0, bm_bytes)
                )
                bm.buffer.set_length(bm_bytes)

            validity = bm^
        var names = List[String]()
        for i in range(nfields):
            names.append(col._field_names[i])
        return StructArray._build(
            names, nfields, col._length, kids^, validity^, col._null_count
        )

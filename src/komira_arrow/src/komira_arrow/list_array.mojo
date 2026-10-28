# =============================================================================
# ListArray — Arrow-compatible variable-length list columnar array
# =============================================================================
#
# Arrow format for variable-length lists:
#   offsets buffer: N+1 Int32 values — offsets[i] is the start index of list i
#       in the child array, offsets[N] is the total number of child elements.
#       List i spans child elements from offsets[i] to offsets[i+1].
#   child: a Column holding the flat array of all child values.
#   validity bitmap: optional, 1 bit per element (1=valid, 0=null).
#
# Memory is managed by MmapAlignedBuffer (offsets), Column (child), and Bitmap
# (validity). No manual free needed.
# =============================================================================

from std.memory import unsafe_memcpy
from std.sys import size_of

from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import (
    SharedAlignedBuffer,
    bridge_oab_to_sab,
)
from komira_arrow.arrow_types import ArrowType
from komira_buffer.heap_region import HeapRegion
from komira_buffer.memory_region import MemoryRegion
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray


struct ListArray[K: MemoryRegion = HeapRegion](Movable, Sized):
    """Arrow List array — variable-length lists of values.

    Layout: Int32 offsets (N+1) + child Column (flat array of all values).
    List element i contains child values from offsets[i] to offsets[i+1].

    Fields:
        offsets: Aligned buffer holding N+1 Int32 offset values.
        child: Column holding the flat array of all child values across all
            lists. Type-erased so any Arrow type can be the child.
        validity: Optional validity bitmap (Arrow convention: bit=1 means
            valid, bit=0 means null). None means "no nulls" (fast path).
        length: Number of logical list elements.
        null_count: Number of null (invalid) elements. 0 when validity is None.
    """

    # Holder field is SharedAlignedBuffer.
    var offsets: SharedAlignedBuffer[Self.K]
    var child: Column[HeapRegion]
    var validity: Optional[Bitmap[Self.K]]
    var length: Int
    var null_count: Int

    # --- Constructors ---

    def __init__(
        out self,
        var offsets: SharedAlignedBuffer[Self.K],
        var child: Column[HeapRegion],
        var validity: Optional[Bitmap[Self.K]],
        length: Int,
        null_count: Int,
    ):
        """Construct a ListArray directly from SharedAlignedBuffer offsets.

        SAB-accepting overload (the canonical shape).
        """
        self.offsets = offsets^
        self.child = child^
        self.validity = validity^
        self.length = length
        self.null_count = null_count

    def __init__(
        out self,
        var offsets: OwnedAlignedBuffer,
        var child: Column[HeapRegion],
        var validity: Optional[Bitmap[Self.K]],
        length: Int,
        null_count: Int,
    ):
        """Construct a ListArray directly from an OwnedAlignedBuffer offsets.

        OAB-accepting overload. The OAB is
        promoted to SAB[HeapRegion] via `from_owned`. Constrained to
        `Self.K == HeapRegion` (OAB is heap-only).
        """
        comptime assert (Self.K == HeapRegion), ( "ListArray.__init__(OwnedAlignedBuffer...): OAB ctor" " requires K=HeapRegion (OAB is heap-only); borrowed-K" " arrays must use the SAB-accepting overload above." )
        self.offsets = bridge_oab_to_sab[Self.K](offsets^)
        self.child = child^
        self.validity = validity^
        self.length = length
        self.null_count = null_count

    @staticmethod
    def from_int_lists(lists: List[List[Int]]) -> ListArray[HeapRegion]:
        """Create a non-nullable ListArray from nested lists of integers.

        Each inner list becomes one list element. The child array is a
        PrimitiveArray[DType.int64] wrapped in a Column.

        Args:
            lists: Nested lists of Int values. All treated as valid (non-null).

        Returns:
            A new ListArray with Int64 child values.
        """
        var num_lists = len(lists)

        # First pass: count total child elements
        var total_values = 0
        for i in range(num_lists):
            total_values += len(lists[i])

        # Build offsets buffer (N+1 entries of Int32)
        # Migrated `_unsafe_data_ptr().bitcast[Int32]()` + init_pointee_copy
        # onto `MmapAlignedBuffer.set_typed[Int32]` — unchanged codegen at
        # @always_inline. `init_pointee_copy` on UInt32 was equivalent to
        # a store since Int32 is Movable+TrivialRegisterPassable.
        comptime int32_size = size_of[Int32]()
        var offsets_buf = OwnedAlignedBuffer((num_lists + 1) * int32_size)
        offsets_buf.set_typed[Int32](0, Int32(0))

        var offset = 0
        for i in range(num_lists):
            offset += len(lists[i])
            offsets_buf.set_typed[Int32](i + 1, Int32(offset))
        offsets_buf.set_length(Int64((num_lists + 1) * int32_size))


        # Build child PrimitiveArray[int64] from all values
        var child_values = List[Scalar[DType.int64]]()
        for i in range(num_lists):
            for j in range(len(lists[i])):
                child_values.append(Scalar[DType.int64](lists[i][j]))
        var child_arr = PrimitiveArray[DType.int64].from_list(child_values)
        var child_col = Column.from_primitive[DType.int64](child_arr)

        return ListArray[HeapRegion](
            offsets=offsets_buf^,
            child=child_col^,
            validity=None,
            length=num_lists,
            null_count=0,
        )

    @staticmethod
    def from_int_lists_nullable(
        lists: List[List[Int]], valid_mask: List[Bool]
    ) -> ListArray[HeapRegion]:
        """Create a nullable ListArray from nested lists of integers.

        Elements where valid_mask[i] is False are marked null. The
        corresponding inner list is still stored (Arrow convention: null
        lists may have arbitrary offset spans) but the validity bit is 0.

        Args:
            lists: Nested lists of Int values.
            valid_mask: Parallel list of booleans. True = valid, False = null.

        Returns:
            A new ListArray with a validity bitmap.
        """
        var num_lists = len(lists)

        # First pass: count total child elements
        var total_values = 0
        for i in range(num_lists):
            total_values += len(lists[i])

        # Build offsets buffer (N+1 entries of Int32)
        # See from_int_lists above for migration rationale.
        comptime int32_size = size_of[Int32]()
        var offsets_buf = OwnedAlignedBuffer((num_lists + 1) * int32_size)
        offsets_buf.set_typed[Int32](0, Int32(0))

        var offset = 0
        for i in range(num_lists):
            offset += len(lists[i])
            offsets_buf.set_typed[Int32](i + 1, Int32(offset))
        offsets_buf.set_length(Int64((num_lists + 1) * int32_size))


        # Build child PrimitiveArray[int64] from all values
        var child_values = List[Scalar[DType.int64]]()
        for i in range(num_lists):
            for j in range(len(lists[i])):
                child_values.append(Scalar[DType.int64](lists[i][j]))
        var child_arr = PrimitiveArray[DType.int64].from_list(child_values)
        var child_col = Column.from_primitive[DType.int64](child_arr)

        # Build validity bitmap
        var null_count = 0
        var bm = Bitmap.create_all_valid(num_lists)
        for i in range(num_lists):
            if i < len(valid_mask) and not valid_mask[i]:
                bm.clear(i)
                null_count += 1

        return ListArray[HeapRegion](
            offsets=offsets_buf^,
            child=child_col^,
            validity=bm^,
            length=num_lists,
            null_count=null_count,
        )

    @staticmethod
    def from_string_lists(
        lists: List[List[String]], valid_mask: List[Bool]
    ) raises -> ListArray[HeapRegion]:
        """Create a (possibly nullable) ListArray of Utf8 from nested string
        lists.  `valid_mask[i] == False` marks list i null (its child slot is
        still stored as an empty span — Arrow allows null lists to have any
        offset span; here we make them zero-length).  The child is a
        StringArray wrapped in a Column.

        The materialization target for
        `regexp_match` / `regexp_split_to_array` / `regexp_extract_all`.

        Args:
            lists: One inner List[String] per row.  For a null row, pass `[]`
                (and set `valid_mask[i] = False`).
            valid_mask: Parallel list of booleans.  True = valid, False = null.
                If shorter than `lists`, missing entries are treated valid.

        Returns:
            A new ListArray with a STRING child Column and (if any nulls) a
            list-level validity bitmap.
        """
        var num_lists = len(lists)

        comptime int32_size = size_of[Int32]()
        var offsets_buf = OwnedAlignedBuffer((num_lists + 1) * int32_size)
        offsets_buf.set_typed[Int32](0, Int32(0))

        # Flatten all child strings (skipping the contents of null rows so the
        # child array stays tight).
        var flat = List[String]()
        var offset = 0
        for i in range(num_lists):
            var is_valid = True
            if i < len(valid_mask) and not valid_mask[i]:
                is_valid = False
            if is_valid:
                for j in range(len(lists[i])):
                    flat.append(lists[i][j].copy())
                offset += len(lists[i])
            offsets_buf.set_typed[Int32](i + 1, Int32(offset))
        offsets_buf.set_length(Int64((num_lists + 1) * int32_size))


        var child_arr = StringArray.from_strings(flat)
        var child_col = Column.from_string(child_arr^)

        var has_nulls = False
        for i in range(len(valid_mask)):
            if not valid_mask[i]:
                has_nulls = True
                break
        if not has_nulls:
            return ListArray[HeapRegion](
                offsets=offsets_buf^,
                child=child_col^,
                validity=None,
                length=num_lists,
                null_count=0,
            )
        var null_count = 0
        var bm = Bitmap.create_all_valid(num_lists)
        for i in range(num_lists):
            if i < len(valid_mask) and not valid_mask[i]:
                bm.clear(i)
                null_count += 1
        return ListArray[HeapRegion](
            offsets=offsets_buf^,
            child=child_col^,
            validity=bm^,
            length=num_lists,
            null_count=null_count,
        )

    # --- Destructor ---
    # MmapAlignedBuffer, Column, and Bitmap handle their own cleanup.

    # --- Element Access ---

    @always_inline
    def __len__(self) -> Int:
        """Return the number of lists in the array."""
        return self.length

    @always_inline
    def get_offset(self, index: Int) -> Int:
        """Return the start offset of list i in the child array.

        This is the index into the child Column where list element `index`
        begins. No bounds checking for performance.

        Args:
            index: Zero-based list element index.

        Returns:
            The starting child index for this list element.
        """
        # Migrated `_unsafe_data_ptr().bitcast[Int32]()` load onto
        # `MmapAlignedBuffer.get_typed[Int32]` — @always_inline preserves
        # codegen (one unaligned load).
        return Int(self.offsets.get_typed[Int32](index))

    @always_inline
    def get_length(self, index: Int) -> Int:
        """Return the number of child elements in list i.

        Computed as offsets[i+1] - offsets[i]. No bounds checking for
        performance.

        Args:
            index: Zero-based list element index.

        Returns:
            Number of child elements in this list.
        """
        # See get_offset above.
        var start = Int(self.offsets.get_typed[Int32](index))
        var end = Int(self.offsets.get_typed[Int32](index + 1))
        return end - start

    def total_values(self) -> Int:
        """Return the total number of child values across all lists.

        This is the value of offsets[length] — the last offset entry.

        Returns:
            Total number of elements in the child array.
        """
        if self.length == 0:
            return 0
        # See get_offset above.
        return Int(self.offsets.get_typed[Int32](self.length))

    def child_as_string(self) raises -> StringArray[HeapRegion]:
        """Reconstruct the child as a StringArray (the child Column[HeapRegion] must be
        STRING-typed).  Helper for tests / the Column round-trip."""
        return self.child.as_string()

    # --- Column round-trip (ListArray <-> type-erased Column) ---
    #
    # The type-erased `Column` does not have a
    # dedicated nested-storage shape, so we pack a STRING-child ListArray into
    # the three buffer slots it already has:
    #   _offsets   : the (N+1) Int32 list offsets
    #   _data      : the child StringArray's UTF-8 byte data
    #   _dict_data : the child StringArray's (M+1) Int32 offsets, where
    #                M == total_values() (the # of child strings)
    #   _dict_size : M
    #   _validity  : the list-level validity bitmap
    #   arrow_type : ArrowType.LIST
    # This is reversible via `from_column`.  `Column.from_list` /
    # `Column.as_list_of_string` are thin forwards to these (added on Column
    # for discoverability; the real logic lives here, alongside ListArray, to
    # keep `column.mojo` free of a back-edge import).

    def to_column(self) raises -> Column[HeapRegion]:
        """Pack this ListArray into a type-erased Column[HeapRegion] with
        `arrow_type == ArrowType.LIST`.  Generalized past the Utf8-child
        specialization — the child Column
        rides in the new `_children` slot, supporting LIST<Int32>,
        LIST<Decimal128>, LIST<Struct>, etc.

        Reversible via `from_column`.  Layout on the Column:
          _offsets  : the (N+1) Int32 list offsets
          _validity : the list-level validity bitmap
          _children : Slab[Column] holding exactly one Column (the item)
          arrow_type: ArrowType.LIST
        """
        comptime int32_size = size_of[Int32]()

        # _offsets <- copy of list offsets (N+1 int32)
        var list_off_bytes = (self.length + 1) * int32_size
        var list_off_buf = OwnedAlignedBuffer(max(list_off_bytes, 1))
        if list_off_bytes > 0:
            list_off_buf.copy_from_view(self.offsets.view_range_ro(0, list_off_bytes))
        list_off_buf.set_length(Int64(list_off_bytes))


        # validity (list-level)
        var validity = Optional[Bitmap[HeapRegion]](None)
        if self.validity:
            var bm_len = self.validity.value().length
            var bm = Bitmap.create(bm_len)
            var bm_bytes = (bm_len + 7) >> 3
            if bm_bytes > 0:
                bm.buffer.copy_from_view(self.validity.value().buffer.view_range_ro(0, bm_bytes))
                bm.buffer.set_length(bm_bytes)

            validity = bm^

        # Make a deep copy of the child Column (caller still owns `self`).
        var child_copy = self.child.deep_copy()

        # Data buffer is zero-length (the child carries its own
        # values); offsets are the only Column-level buffer.
        var data_buf = OwnedAlignedBuffer(1)
        data_buf.set_length(0)


        var col = Column[HeapRegion](
            arrow_type=ArrowType.LIST,
            data=data_buf^,
            offsets=list_off_buf^,
            validity=validity^,
            length=self.length,
            null_count=self.null_count,
            offset=0,
        )
        col._children.append(child_copy^)
        return col^

    @staticmethod
    def from_column(col: Column[HeapRegion]) raises -> ListArray[HeapRegion]:
        """Unpack a `Column[HeapRegion]` (built by `to_column` / `Column.from_list`) back
        into a ListArray with first-class `child: Column`.

        Reads the child from the Column's
        `_children` slot; supports any child arrow_type (the legacy Utf8
        special case is now a thin pass-through to `_children[0]`)."""
        if col.arrow_type != ArrowType.LIST:
            raise Error(
                "ListArray.from_column: arrow_type is "
                + String(col.arrow_type)
                + ", expected list"
            )
        if not col._offsets:
            raise Error("ListArray.from_column: missing list offsets buffer")
        if len(col._children) != 1:
            raise Error(
                "ListArray.from_column: LIST column must have exactly 1 child,"
                " got " + String(len(col._children))
            )
        comptime int32_size = size_of[Int32]()
        var n = col._length

        # list offsets
        var list_off_bytes = (n + 1) * int32_size
        var list_off_buf = OwnedAlignedBuffer(max(list_off_bytes, 1))
        list_off_buf.copy_from_view(col._offsets.value().view_range_ro(0, list_off_bytes))
        list_off_buf.set_length(Int64(list_off_bytes))


        # Deep-copy the child Column.
        var child_copy = col._children[0].deep_copy()

        # validity (list-level)
        var validity = Optional[Bitmap[HeapRegion]](None)
        if col._validity:
            var bm_len = col._validity.value().length
            var bm = Bitmap.create(bm_len)
            var bm_bytes = (bm_len + 7) >> 3
            if bm_bytes > 0:
                bm.buffer.copy_from_view(col._validity.value().buffer.view_range_ro(0, bm_bytes))
                bm.buffer.set_length(bm_bytes)

            validity = bm^

        return ListArray[HeapRegion](
            offsets=list_off_buf^,
            child=child_copy^,
            validity=validity^,
            length=n,
            null_count=col._null_count,
        )

    def list_strings(self, index: Int) raises -> List[String]:
        """Return the j-th .. (j+len-1)-th child strings of list `index` as a
        List[String].  Returns `[]` if the list element is null.  Convenience
        for tests / consumers — not a perf path."""
        if self.is_null(index):
            return List[String]()
        var start = self.get_offset(index)
        var ln = self.get_length(index)
        var child_str = self.child.as_string()
        var out = List[String]()
        for j in range(start, start + ln):
            out.append(child_str.get(j))
        return out^

    # --- Null Handling ---

    @always_inline
    def is_null(self, index: Int) -> Bool:
        """Check if the list element at index is null.

        Returns False if no validity bitmap (all values are valid).

        Args:
            index: Zero-based element index.

        Returns:
            True if the element is null, False if valid.
        """
        if not self.validity:
            return False
        return not self.validity.value().test(index)

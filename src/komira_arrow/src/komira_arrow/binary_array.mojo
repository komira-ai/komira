# =============================================================================
# BinaryArray -- Arrow-compatible variable-length binary columnar array
# =============================================================================
#
# Same physical layout as StringArray (offsets buffer + data buffer + optional
# validity bitmap) but without the UTF-8 guarantee. Suitable for raw bytes,
# serialized protobuf, encrypted payloads, etc.
#
# Arrow format for variable-length binary:
#   offsets buffer: N+1 Int32 values -- offsets[i] is the start byte of
#       element i, offsets[N] is the total data length.
#   data buffer: contiguous raw bytes.
#   validity bitmap: optional, 1 bit per element (1=valid, 0=null).
# =============================================================================

from std.memory import alloc, unsafe_memcpy
from std.sys import size_of

from komira_buffer.byte_view import ByteView

from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import (
    SharedAlignedBuffer,
    bridge_oab_to_sab,
)
from komira_buffer.heap_region import HeapRegion
from komira_buffer.memory_region import MemoryRegion
from komira_arrow.bitmap import Bitmap
from komira_arrow.offset_overflow import check_int32_offsets


struct BinaryArray[K: MemoryRegion = HeapRegion](Movable, Sized):
    """A column of variable-length binary values with optional null bitmap.

    Arrow-compatible layout: offsets buffer (Int32, N+1 entries) + data buffer
    (UInt8, contiguous raw bytes) + optional validity bitmap.

    Fields:
        offsets: Aligned buffer holding N+1 Int32 offset values.
        data: Aligned buffer holding contiguous raw bytes.
        validity: Optional validity bitmap (Arrow convention: bit=1 means
            valid, bit=0 means null). None means "no nulls" (fast path).
        length: Number of logical binary elements.
        data_length: Total bytes in the data buffer.
        null_count: Number of null (invalid) elements. 0 when validity is None.
    """

    # Holder fields are SharedAlignedBuffer.
    var offsets: SharedAlignedBuffer[Self.K]
    var data: SharedAlignedBuffer[Self.K]
    var validity: Optional[Bitmap[Self.K]]
    var length: Int
    var data_length: Int
    var null_count: Int

    # --- Constructors ---

    def __init__(
        out self,
        var offsets: SharedAlignedBuffer[Self.K],
        var data: SharedAlignedBuffer[Self.K],
        var validity: Optional[Bitmap[Self.K]],
        length: Int,
        data_length: Int,
        null_count: Int,
    ):
        """Construct a BinaryArray directly from SharedAlignedBuffers.

        SAB-accepting overload (the eventual canonical ctor).
        """
        self.offsets = offsets^
        self.data = data^
        self.validity = validity^
        self.length = length
        self.data_length = data_length
        self.null_count = null_count

    def __init__(
        out self,
        var offsets: OwnedAlignedBuffer,
        var data: OwnedAlignedBuffer,
        var validity: Optional[Bitmap[Self.K]],
        length: Int,
        data_length: Int,
        null_count: Int,
    ):
        """Construct a BinaryArray directly from OwnedAlignedBuffers.

        OAB-accepting overload. Both OAB inputs
        are promoted to SAB[HeapRegion] via `from_owned` before field
        assignment. Constrained to `Self.K == HeapRegion` (OAB is heap-only).
        """
        comptime assert (Self.K == HeapRegion), ( "BinaryArray.__init__(OwnedAlignedBuffer...): OAB ctor" " requires K=HeapRegion (OAB is heap-only); borrowed-K" " arrays must use the SAB-accepting overload above." )
        self.offsets = bridge_oab_to_sab[Self.K](offsets^)
        self.data = bridge_oab_to_sab[Self.K](data^)
        self.validity = validity^
        self.length = length
        self.data_length = data_length
        self.null_count = null_count

    @staticmethod
    def from_bytes_list(values: List[List[UInt8]]) raises -> BinaryArray[HeapRegion]:
        """Create a non-nullable BinaryArray from a list of byte lists.

        Args:
            values: List of List[UInt8] values. All are treated as valid.

        Returns:
            A new BinaryArray containing all the byte sequences.
        """
        var num_elements = len(values)

        # First pass: compute total data length
        var total_bytes = 0
        for i in range(num_elements):
            total_bytes += len(values[i])

        # Int32-offset ceiling: raise BEFORE allocating anything.
        check_int32_offsets(
            "BinaryArray.from_bytes_list", total_bytes, num_elements
        )

        # Allocate offsets buffer (N+1 entries of Int32)
        # Migrated `_unsafe_data_ptr().bitcast[Int32]()` +
        # init_pointee_copy onto `MmapAlignedBuffer.set_typed[Int32]`.
        comptime int32_size = size_of[Int32]()
        var offsets_buf = OwnedAlignedBuffer((num_elements + 1) * int32_size)
        offsets_buf.set_typed[Int32](0, Int32(0))

        # Allocate data buffer
        var data_buf = OwnedAlignedBuffer(max(total_bytes, 1))

        # Second pass: copy bytes and fill offsets (memcpy per element)
        # Migrated `memcpy(dest=data_buf._unsafe_data_ptr() + offset,
        # src=elem.unsafe_ptr(), count=elem_len)` onto
        # `data_buf.view_range_mut(offset, elem_len).copy_from_view_at(
        # 0, src_view)`. Origin tracking: `src_view` is a read-only view
        # over `elem` (a borrow of `values[i]`) -- both stay alive through
        # this loop body. `copy_from_view_at` is memcpy-backed.
        var offset = 0
        for i in range(num_elements):
            ref elem = values[i]
            var elem_len = len(elem)
            if elem_len > 0:
                var src_view = ByteView(elem.unsafe_ptr(), elem_len)
                data_buf.view_range_mut(offset, elem_len).copy_from_view_at(
                    0, src_view
                )
            offset += elem_len
            offsets_buf.set_typed[Int32](i + 1, Int32(offset))

        offsets_buf.set_length(Int64((num_elements + 1) * int32_size))

        data_buf.set_length(Int64(total_bytes))


        return BinaryArray[HeapRegion](
            offsets=offsets_buf^,
            data=data_buf^,
            validity=None,
            length=num_elements,
            data_length=total_bytes,
            null_count=0,
        )

    @staticmethod
    def from_buffers(
        offsets: List[Int32],
        data: List[UInt8],
        var validity: Optional[Bitmap[HeapRegion]],
        null_count: Int,
    ) raises -> BinaryArray[HeapRegion]:
        """Adopt an Arrow-native (offsets, data) pair into a BinaryArray.

        Zero-re-serialize finalize for `ArrowBinaryBuilder` (the byte-buffer
        accumulator shared with the string path): the decoder streams raw value
        bytes into `data` and pushes one cumulative `Int32` per value into
        `offsets` (N+1 entries, `offsets[0] == 0`). At finalize there is NO
        per-value `List[UInt8]` intermediate and NO per-value re-serialize pass
        (the cost `from_bytes_list` paid) -- just ONE bulk memcpy of `offsets`
        and ONE of `data` into the two AlignedBuffers.

        Identical shape to `StringArray.from_buffers`; the only difference is
        that binary carries no UTF-8 guarantee. The two memcpys are an alignment
        requirement (MmapAlignedBuffer over-allocates + 64-byte aligns +
        SIMD-tail-pads), not a re-serialize. The copies are O(total_bytes) once,
        vs. the prior O(rows) `List[UInt8]` allocs + O(rows) drops + O(total)
        re-serialize.

        Args:
            offsets: N+1 cumulative byte offsets (`offsets[0]==0`,
                `offsets[N]==len(data)`). `len(offsets) >= 1`.
            data: Contiguous raw bytes for all N values.
            validity: Optional validity bitmap (None == all valid).
            null_count: Number of null elements (0 when validity is None).

        Returns:
            A BinaryArray adopting `(offsets, data)`.
        """
        comptime int32_size = size_of[Int32]()
        var num_elements = len(offsets) - 1
        var total_bytes = len(data)

        # `offsets` may already have wrapped upstream; `len(data)` is the
        # 64-bit truth, so this catches the wrap regardless.
        check_int32_offsets(
            "BinaryArray.from_buffers", total_bytes, num_elements
        )

        var offsets_buf = OwnedAlignedBuffer((num_elements + 1) * int32_size)
        # ONE memcpy of the cumulative-offset List[Int32] into the Arrow
        # offsets buffer (no per-element set_typed loop).
        offsets_buf.copy_from_int32_list(offsets)
        offsets_buf.set_length(Int64((num_elements + 1) * int32_size))


        var data_buf = OwnedAlignedBuffer(max(total_bytes, 1))
        # ONE memcpy from the streamed byte List into the Arrow data buffer.
        data_buf.copy_from_bytes_list(data)
        data_buf.set_length(Int64(total_bytes))


        return BinaryArray[HeapRegion](
            offsets=offsets_buf^,
            data=data_buf^,
            validity=validity^,
            length=num_elements,
            data_length=total_bytes,
            null_count=null_count,
        )

    # --- Destructor ---
    # MmapAlignedBuffer and Bitmap handle their own cleanup -- no manual free needed.

    # --- Element Access ---

    @always_inline
    def __len__(self) -> Int:
        """Return the number of binary elements in the array."""
        return self.length

    @always_inline
    def get_length(self, index: Int) -> Int:
        """Return the byte length of the element at the given index.

        This is a fast O(1) operation using the offsets buffer.
        No bounds checking for performance -- caller must ensure valid index.

        Args:
            index: Zero-based element index.

        Returns:
            Number of bytes in the element at `index`.
        """
        # Migrated offset lookups to `MmapAlignedBuffer.get_typed[Int32]`.
        var start = Int(self.offsets.get_typed[Int32](index))
        var end = Int(self.offsets.get_typed[Int32](index + 1))
        return end - start

    def get(self, index: Int) raises -> List[UInt8]:
        """Return the bytes at the given index as a List[UInt8].

        Args:
            index: Zero-based element index.

        Returns:
            A new List[UInt8] containing the bytes for element `index`.

        Raises:
            Error if index is out of bounds.
        """
        if index < 0 or index >= self.length:
            raise Error(
                "BinaryArray.get: index "
                + String(index)
                + " out of range [0, "
                + String(self.length)
                + ")"
            )
        # Migrated offset lookups + memcpy-from-data_buffer to
        # `MmapAlignedBuffer.get_typed[Int32]` + `ByteView.copy_to`.
        # `copy_to` appends byte-by-byte into the List; we start from
        # an empty List and let copy_to grow it to exact length.
        var start = Int(self.offsets.get_typed[Int32](index))
        var end = Int(self.offsets.get_typed[Int32](index + 1))
        var byte_len = end - start

        var result = List[UInt8](capacity=byte_len)
        if byte_len > 0:
            self.data.view_ro().copy_to(result, start, byte_len)
        return result^

    def get_byte(self, element_index: Int, byte_index: Int) raises -> UInt8:
        """Return a single byte from an element.

        Args:
            element_index: Zero-based element index.
            byte_index: Zero-based byte offset within the element.

        Returns:
            The byte value.

        Raises:
            Error if either index is out of bounds.
        """
        if element_index < 0 or element_index >= self.length:
            raise Error(
                "BinaryArray.get_byte: element_index "
                + String(element_index)
                + " out of range [0, "
                + String(self.length)
                + ")"
            )
        # Migrated offset + byte lookup onto typed accessors.
        var start = Int(self.offsets.get_typed[Int32](element_index))
        var end = Int(self.offsets.get_typed[Int32](element_index + 1))
        var byte_len = end - start
        if byte_index < 0 or byte_index >= byte_len:
            raise Error(
                "BinaryArray.get_byte: byte_index "
                + String(byte_index)
                + " out of range [0, "
                + String(byte_len)
                + ")"
            )
        return self.data.read_u8_at(start + byte_index)

    # --- Null Handling ---

    @always_inline
    def is_null(self, index: Int) -> Bool:
        """Check if element at index is null.

        Returns False if no validity bitmap (all values are valid).

        Args:
            index: Zero-based element index.

        Returns:
            True if the element is null, False if valid.
        """
        if not self.validity:
            return False
        return not self.validity.value().test(index)

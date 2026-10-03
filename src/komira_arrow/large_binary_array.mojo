# =============================================================================
# LargeBinaryArray -- Arrow-compatible variable-length binary columnar array
#                     with Int64 offsets (supports >2 GB of binary data)
# =============================================================================
#
# Identical layout to BinaryArray but with Int64 offsets instead of Int32,
# allowing columns with more than 2 GB of total binary data.
#
# Arrow format for LargeBinary:
#   offsets buffer: N+1 Int64 values -- offsets[i] is the start byte of
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


struct LargeBinaryArray[K: MemoryRegion = HeapRegion](Movable, Sized):
    """A column of variable-length binary values with Int64 offsets.

    Arrow-compatible layout: offsets buffer (Int64, N+1 entries) + data buffer
    (UInt8, contiguous raw bytes) + optional validity bitmap.

    The Int64 offsets allow addressing more than 2 GB of total binary data
    per column, unlike BinaryArray which uses Int32 offsets.

    Fields:
        offsets: Aligned buffer holding N+1 Int64 offset values.
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
        """Construct a LargeBinaryArray directly from SharedAlignedBuffers.

        SAB-accepting overload (the canonical shape).
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
        """Construct a LargeBinaryArray directly from OwnedAlignedBuffers.

        OAB-accepting overload. Both OAB inputs
        are promoted to SAB[HeapRegion] via `from_owned`. Constrained to
        `Self.K == HeapRegion` (OAB is heap-only).
        """
        comptime assert (Self.K == HeapRegion), ( "LargeBinaryArray.__init__(OwnedAlignedBuffer...): OAB ctor" " requires K=HeapRegion (OAB is heap-only); borrowed-K" " arrays must use the SAB-accepting overload above." )
        self.offsets = bridge_oab_to_sab[Self.K](offsets^)
        self.data = bridge_oab_to_sab[Self.K](data^)
        self.validity = validity^
        self.length = length
        self.data_length = data_length
        self.null_count = null_count

    @staticmethod
    def from_bytes_list(values: List[List[UInt8]]) -> LargeBinaryArray[HeapRegion]:
        """Create a non-nullable LargeBinaryArray from a list of byte lists.

        Args:
            values: List of List[UInt8] values. All are treated as valid.

        Returns:
            A new LargeBinaryArray containing all the byte sequences.
        """
        var num_elements = len(values)

        # First pass: compute total data length
        var total_bytes = 0
        for i in range(num_elements):
            total_bytes += len(values[i])

        # Allocate offsets buffer (N+1 entries of Int64)
        # Migrated onto `set_typed[Int64]` / `get_typed[Int64]` +
        # `view_range_mut(..., ...).copy_from_view_at(0, src_view)`.
        comptime int64_size = size_of[Int64]()
        var offsets_buf = OwnedAlignedBuffer((num_elements + 1) * int64_size)
        offsets_buf.set_typed[Int64](0, Int64(0))

        # Allocate data buffer
        var data_buf = OwnedAlignedBuffer(max(total_bytes, 1))

        # Second pass: copy bytes and fill offsets (memcpy per element).
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
            offsets_buf.set_typed[Int64](i + 1, Int64(offset))

        offsets_buf.set_length(Int64((num_elements + 1) * int64_size))

        data_buf.set_length(Int64(total_bytes))


        return LargeBinaryArray[HeapRegion](
            offsets=offsets_buf^,
            data=data_buf^,
            validity=None,
            length=num_elements,
            data_length=total_bytes,
            null_count=0,
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
        # Migrated offset lookup to `get_typed[Int64]`.
        var start = Int(self.offsets.get_typed[Int64](index))
        var end = Int(self.offsets.get_typed[Int64](index + 1))
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
                "LargeBinaryArray.get: index "
                + String(index)
                + " out of range [0, "
                + String(self.length)
                + ")"
            )
        # Migrated to `get_typed[Int64]` + `ByteView.copy_to`.
        var start = Int(self.offsets.get_typed[Int64](index))
        var end = Int(self.offsets.get_typed[Int64](index + 1))
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
                "LargeBinaryArray.get_byte: element_index "
                + String(element_index)
                + " out of range [0, "
                + String(self.length)
                + ")"
            )
        # Migrated to typed accessors.
        var start = Int(self.offsets.get_typed[Int64](element_index))
        var end = Int(self.offsets.get_typed[Int64](element_index + 1))
        var byte_len = end - start
        if byte_index < 0 or byte_index >= byte_len:
            raise Error(
                "LargeBinaryArray.get_byte: byte_index "
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

# =============================================================================
# DECIMAL256 ARRAY — Arrow Decimal256 fixed-point column
# =============================================================================
#
# Mirrors `Decimal128Array` at 32-byte
# (256-bit) width. Mojo 1.0.0b1 has native `SIMD[DType.int256, 1]` (used
# internally by Decimal128's rescale intermediate), so each element is
# read/written as one int256.
#
# Arrow Decimal256 stores each value as a 256-bit (32-byte) signed integer
# with a fixed precision and scale. The logical value is:
#
#   logical_value = physical_int256 / 10^scale
#
# Physical storage: each element is 32 bytes — little-endian two's-complement.
# This matches the Arrow memory layout (matches both Arrow spec and PyArrow).
#
# Precision: total number of decimal digits (1-76 — Arrow spec bound).
# Scale: number of digits after the decimal point (0 <= scale <= precision).
# =============================================================================

from std.sys import size_of

from std.memory import ArcPointer

from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import (
    SharedAlignedBuffer,
    bridge_oab_to_sab,
)
from komira_buffer.heap_region import HeapRegion
from komira_buffer.memory_region import MemoryRegion
from komira_arrow.bitmap import Bitmap


# Bytes per Decimal256 element — 256 bits.
comptime DECIMAL256_BYTE_WIDTH = 32


struct Decimal256Array[K: MemoryRegion = HeapRegion](Movable, Sized):
    """Arrow Decimal256 column — fixed-point numbers as 256-bit integers.

    Physical storage: each value is 32 bytes (little-endian
    two's-complement) within the MmapAlignedBuffer.

    Logical value = physical_int256 / 10^scale.

    Fields:
        data:       Aligned byte buffer holding N x 32 bytes.
        validity:   Optional null bitmap (None = no nulls).
        length:     Number of Decimal256 elements.
        null_count: Number of null elements (0 when validity is None).
        precision:  Total decimal digits (1-76).
        scale:      Digits after decimal point (0 <= scale <= precision).
    """

    # Holder field is SharedAlignedBuffer.
    var data: SharedAlignedBuffer[Self.K]
    var validity: Optional[Bitmap[HeapRegion]]
    var length: Int
    var null_count: Int
    var precision: Int
    var scale: Int

    # --- LIFECYCLE ---

    @staticmethod
    def allocate(length: Int, precision: Int, scale: Int) -> Decimal256Array[HeapRegion]:
        """Allocate a non-nullable Decimal256 array, zero-initialized."""
        var buf = OwnedAlignedBuffer(max(length, 1) * DECIMAL256_BYTE_WIDTH)
        buf.zero()
        buf.set_length(Int64(length * DECIMAL256_BYTE_WIDTH))

        var arr = Decimal256Array[HeapRegion]()
        arr.data = bridge_oab_to_sab[HeapRegion](buf^)
        arr.validity = Optional[Bitmap[HeapRegion]](None)
        arr.length = length
        arr.null_count = 0
        arr.precision = precision
        arr.scale = scale
        return arr^

    @staticmethod
    def allocate_nullable(length: Int, precision: Int, scale: Int) -> Decimal256Array[HeapRegion]:
        """Allocate a nullable Decimal256 array with all values valid."""
        var buf = OwnedAlignedBuffer(max(length, 1) * DECIMAL256_BYTE_WIDTH)
        buf.zero()
        buf.set_length(Int64(length * DECIMAL256_BYTE_WIDTH))

        var bm = Bitmap.create_all_valid(length)
        var arr = Decimal256Array[HeapRegion]()
        arr.data = bridge_oab_to_sab[HeapRegion](buf^)
        arr.validity = bm^
        arr.length = length
        arr.null_count = 0
        arr.precision = precision
        arr.scale = scale
        return arr^

    def __init__(out self):
        """Internal: create an empty Decimal256Array.

        Constrained to K=HeapRegion because
        `MmapAlignedBuffer[64](0)` produces a HeapRegion-backed empty buffer.
        """
        comptime assert (Self.K == HeapRegion), ( "Decimal256Array.__init__(): no-arg empty ctor requires" " K=HeapRegion (MmapAlignedBuffer[64](0) is HeapRegion-backed)." )
        # Build SAB[Self.K] empty placeholder (Self.K =
        # HeapRegion per constrained). See decimal_array no-arg ctor.
        var empty_region = HeapRegion(List[UInt8]())
        var arc_heap = ArcPointer[HeapRegion](empty_region^)
        var arc_self_k = rebind[ArcPointer[Self.K]](arc_heap^)
        self.data = SharedAlignedBuffer[Self.K](
            region=arc_self_k^, offset=0, length=0
        )
        self.validity = Optional[Bitmap[HeapRegion]](None)
        self.length = 0
        self.null_count = 0
        self.precision = 0
        self.scale = 0

    # --- ELEMENT ACCESS ---

    def get_i256(self, index: Int) raises -> SIMD[DType.int256, 1]:
        """Read the Decimal256 unscaled value at `index` as a native int256.

        Args:
            index: Element index (0-based).

        Returns:
            The 256-bit unscaled value (logical value = result / 10^scale).
        """
        if index < 0 or index >= self.length:
            raise Error(
                "Decimal256Array.get_i256: index "
                + String(index)
                + " out of range [0, "
                + String(self.length)
                + ")"
            )
        return self.data.read_i256_le_at(index * DECIMAL256_BYTE_WIDTH)

    def set_i256(mut self, index: Int, value: SIMD[DType.int256, 1]) raises:
        """Write a native int256 unscaled value at `index`.

        If the array is nullable, marks the position as valid.
        """
        if index < 0 or index >= self.length:
            raise Error(
                "Decimal256Array.set_i256: index "
                + String(index)
                + " out of range [0, "
                + String(self.length)
                + ")"
            )
        self.data.write_i256_le_at(index * DECIMAL256_BYTE_WIDTH, value)
        if self.validity:
            if not self.validity.value().test(index):
                self.null_count -= 1
            self.validity.value().set(index)

    @staticmethod
    def from_i256_list(
        values: List[SIMD[DType.int256, 1]], precision: Int, scale: Int
    ) raises -> Decimal256Array[HeapRegion]:
        """Build a non-nullable Decimal256Array from a list of unscaled int256s."""
        var arr = Decimal256Array[HeapRegion].allocate(len(values), precision, scale)
        for i in range(len(values)):
            arr.data.write_i256_le_at(i * DECIMAL256_BYTE_WIDTH, values[i])
        return arr^

    # --- CONVENIENCE: Integer set/get ---

    def set_from_int(mut self, index: Int, value: Int) raises:
        """Store an integer value (sign-extended into the 256-bit unscaled slot).

        The physical stored value = value. The logical value = value / 10^scale.
        """
        self.set_i256(index, SIMD[DType.int256, 1](value))

    def get_as_int(self, index: Int) raises -> Int:
        """Read the value as an Int (only valid when the high bits are
        sign-extension of the low 64 bits — common case for small values).
        """
        var v = self.get_i256(index)
        return Int(v.cast[DType.int64]())

    # --- NULLABILITY ---

    def is_null(self, index: Int) raises -> Bool:
        """Check if element at index is null."""
        if index < 0 or index >= self.length:
            raise Error(
                "Decimal256Array.is_null: index "
                + String(index)
                + " out of range [0, "
                + String(self.length)
                + ")"
            )
        if not self.validity:
            return False
        return not self.validity.value().test(index)

    def set_null(mut self, index: Int) raises:
        """Mark element at index as null."""
        if index < 0 or index >= self.length:
            raise Error(
                "Decimal256Array.set_null: index "
                + String(index)
                + " out of range [0, "
                + String(self.length)
                + ")"
            )
        if not self.validity:
            # Validity is Bitmap[HeapRegion] (driver-owned), even
            # for borrowed-K data. Mutation lazy-allocates a heap bitmap.
            self.validity = Bitmap.create_all_valid(self.length)
        if self.validity.value().test(index):
            self.null_count += 1
        self.validity.value().clear(index)

    # --- SIZED ---

    @always_inline
    def __len__(self) -> Int:
        """Return the number of Decimal256 elements."""
        return self.length

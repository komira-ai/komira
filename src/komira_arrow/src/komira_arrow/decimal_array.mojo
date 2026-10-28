# =============================================================================
# DECIMAL128 ARRAY — Arrow Decimal128 fixed-point column
# =============================================================================
#
# Arrow Decimal128 stores each value as a 128-bit (16-byte) signed integer
# with a fixed precision and scale. The logical value is:
#
#   logical_value = physical_int128 / 10^scale
#
# Physical storage: each element is 16 bytes — two Int64 words in
# little-endian order (low word at offset 0, high word at offset 8).
# This matches the Arrow memory layout.
#
# Example: $123.45 with precision=10, scale=2 is stored as int128(12345).
#
# Precision: total number of decimal digits (1-38).
# Scale: number of digits after the decimal point (0 <= scale <= precision).
# =============================================================================

# =============================================================================
# WILDCARD-ORIGIN SITES: pending migration
# =============================================================================
# Each remaining MutExternalOrigin in this file is either (a) a load-bearing
# interior pointer awaiting redesign onto a tight origin, or (b) a temporary
# shim into a primitive that will be removed (e.g. Slab /
# Slab / Slab / AtomicSlab _mut_ptr / _unsafe_base_ptr helpers
# preserved for migration source callers).
#
# Remediation: replace each wildcard with one of
#   * a typed `ref [origin] T` return / parameter,
#   * a private `UnsafePointer[T, concrete_origin]` field + `# SAFETY:`
#     comment (inside a single struct only),
#   * a byte-view (`ByteView` / `ByteViewMut`) + typed scalar reads/writes.
#
# Do NOT add new wildcard sites to this file.
# =============================================================================

from std.sys import size_of
from std.memory import unsafe_memset


from std.memory import ArcPointer

from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import (
    SharedAlignedBuffer,
    bridge_oab_to_sab,
)
from komira_buffer.heap_region import HeapRegion
from komira_buffer.memory_region import MemoryRegion
from komira_arrow.bitmap import Bitmap


# Bytes per Decimal128 element — two Int64 words.
comptime DECIMAL128_BYTE_WIDTH = 16


struct Decimal128Array[K: MemoryRegion = HeapRegion](Movable, Sized):
    """Arrow Decimal128 column — fixed-point numbers as 128-bit integers.

    Physical storage: each value is 16 bytes (two Int64s: low + high),
    stored in little-endian order within the MmapAlignedBuffer.

    Logical value = physical_int128 / 10^scale.

    Fields:
        data:       Aligned byte buffer holding N x 16 bytes.
        validity:   Optional null bitmap (None = no nulls).
        length:     Number of Decimal128 elements.
        null_count: Number of null elements (0 when validity is None).
        precision:  Total decimal digits (1-38).
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
    def allocate(length: Int, precision: Int, scale: Int) -> Decimal128Array[HeapRegion]:
        """Allocate a non-nullable Decimal128 array, zero-initialized.

        Args:
            length:    Number of Decimal128 elements.
            precision: Total decimal digits (1-38).
            scale:     Digits after decimal point.

        Returns:
            A new Decimal128Array with all values set to zero.
        """
        var buf = OwnedAlignedBuffer(max(length, 1) * DECIMAL128_BYTE_WIDTH)
        buf.zero()
        buf.set_length(Int64(length * DECIMAL128_BYTE_WIDTH))

        var arr = Decimal128Array[HeapRegion]()
        # OAB -> SAB bridge (replacing OLD-AB bridge).
        arr.data = bridge_oab_to_sab[HeapRegion](buf^)
        arr.validity = Optional[Bitmap[HeapRegion]](None)
        arr.length = length
        arr.null_count = 0
        arr.precision = precision
        arr.scale = scale
        return arr^

    @staticmethod
    def allocate_nullable(length: Int, precision: Int, scale: Int) -> Decimal128Array[HeapRegion]:
        """Allocate a nullable Decimal128 array with all values valid.

        Args:
            length:    Number of Decimal128 elements.
            precision: Total decimal digits (1-38).
            scale:     Digits after decimal point.

        Returns:
            A new Decimal128Array with all values set to zero and all valid.
        """
        var buf = OwnedAlignedBuffer(max(length, 1) * DECIMAL128_BYTE_WIDTH)
        buf.zero()
        buf.set_length(Int64(length * DECIMAL128_BYTE_WIDTH))

        var bm = Bitmap.create_all_valid(length)
        var arr = Decimal128Array[HeapRegion]()
        # OAB -> SAB bridge (replacing OLD-AB bridge).
        arr.data = bridge_oab_to_sab[HeapRegion](buf^)
        arr.validity = bm^
        arr.length = length
        arr.null_count = 0
        arr.precision = precision
        arr.scale = scale
        return arr^

    def __init__(out self):
        """Internal: create an empty Decimal128Array.

        Constrained to K=HeapRegion because
        `MmapAlignedBuffer[64](0)` produces a HeapRegion-backed empty buffer.
        Borrowed-K Decimal128Arrays must be constructed via the typed
        component constructor.
        """
        comptime assert (Self.K == HeapRegion), ( "Decimal128Array.__init__(): no-arg empty ctor requires" " K=HeapRegion (MmapAlignedBuffer[64](0) is HeapRegion-backed)." )
        # Build SAB[Self.K] empty placeholder. Self.K =
        # HeapRegion per the constrained block; ArcPointer rebind narrows
        # the type assignment for the typechecker (mirror of MmapAlignedBuffer
        # size-ctor).
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

    def __init__(
        out self,
        var data: OwnedAlignedBuffer,
        var validity: Optional[Bitmap[HeapRegion]],
        length: Int,
        null_count: Int,
        precision: Int,
        scale: Int,
    ):
        """Construct a Decimal128Array directly from an OwnedAlignedBuffer.

        OAB-accepting overload. The OAB is
        promoted to SAB[HeapRegion] via `from_owned`. Constrained to
        `Self.K == HeapRegion` (OAB is heap-only by construction). Mirrors
        the OAB ctor pattern on Column / PrimitiveArray / BinaryArray etc.
        The `allocate()` and `allocate_nullable()` factories are separate
        entry points.

        Args:
            data: Aligned byte buffer of length * DECIMAL128_BYTE_WIDTH bytes.
            validity: Optional null bitmap.
            length: Number of Decimal128 elements.
            null_count: Number of null elements.
            precision: Total decimal digits (1-38).
            scale: Digits after decimal point (0 <= scale <= precision).
        """
        comptime assert (Self.K == HeapRegion), ( "Decimal128Array.__init__(OwnedAlignedBuffer...): OAB ctor" " requires K=HeapRegion (OAB is heap-only)." )
        self.data = bridge_oab_to_sab[Self.K](data^)
        self.validity = validity^
        self.length = length
        self.null_count = null_count
        self.precision = precision
        self.scale = scale

    # --- ELEMENT ACCESS (low/high word) ---
    #
    # Migrated from `_low_ptr` / `_high_ptr` helpers (which returned
    # `UnsafePointer[Int64, MutExternalOrigin]`) onto `MmapAlignedBuffer.
    # read_i64_le_at` / `write_i64_le_at`. Each Decimal128 is two packed
    # Int64 words at (index * DECIMAL128_BYTE_WIDTH) and (+8).

    def get_low(self, index: Int) raises -> Int64:
        """Read the low 64 bits of the Decimal128 value at `index`.

        Args:
            index: Element index (0-based).

        Returns:
            The low 64-bit word.

        Raises:
            Error if index is out of bounds.
        """
        if index < 0 or index >= self.length:
            raise Error(
                "Decimal128Array.get_low: index "
                + String(index)
                + " out of range [0, "
                + String(self.length)
                + ")"
            )
        return self.data.read_i64_le_at(index * DECIMAL128_BYTE_WIDTH)

    def get_high(self, index: Int) raises -> Int64:
        """Read the high 64 bits of the Decimal128 value at `index`.

        Args:
            index: Element index (0-based).

        Returns:
            The high 64-bit word.

        Raises:
            Error if index is out of bounds.
        """
        if index < 0 or index >= self.length:
            raise Error(
                "Decimal128Array.get_high: index "
                + String(index)
                + " out of range [0, "
                + String(self.length)
                + ")"
            )
        return self.data.read_i64_le_at(index * DECIMAL128_BYTE_WIDTH + 8)

    def set_raw(mut self, index: Int, low: Int64, high: Int64) raises:
        """Write the raw 128-bit value at `index` as low + high words.

        If the array is nullable, marks the position as valid.

        Args:
            index: Element index (0-based).
            low:   Low 64 bits of the int128 value.
            high:  High 64 bits of the int128 value.

        Raises:
            Error if index is out of bounds.
        """
        if index < 0 or index >= self.length:
            raise Error(
                "Decimal128Array.set_raw: index "
                + String(index)
                + " out of range [0, "
                + String(self.length)
                + ")"
            )
        self.data.write_i64_le_at(index * DECIMAL128_BYTE_WIDTH, low)
        self.data.write_i64_le_at(index * DECIMAL128_BYTE_WIDTH + 8, high)
        if self.validity:
            if not self.validity.value().test(index):
                self.null_count -= 1
            self.validity.value().set(index)

    # --- NATIVE int128 ACCESS ---
    #
    # Mojo 1.0.0b1 has native
    # SIMD[DType.int128, 1]. Each element is the 16-byte LE two's-complement
    # unscaled value — read/write it as one int128 instead of two i64 halves.

    def get_i128(self, index: Int) raises -> SIMD[DType.int128, 1]:
        """Read the Decimal128 unscaled value at `index` as a native int128.

        Args:
            index: Element index (0-based).

        Returns:
            The 128-bit unscaled value (logical value = result / 10^scale).

        Raises:
            Error if index is out of bounds.
        """
        if index < 0 or index >= self.length:
            raise Error(
                "Decimal128Array.get_i128: index "
                + String(index)
                + " out of range [0, "
                + String(self.length)
                + ")"
            )
        return self.data.read_i128_le_at(index * DECIMAL128_BYTE_WIDTH)

    def set_i128(mut self, index: Int, value: SIMD[DType.int128, 1]) raises:
        """Write a native int128 unscaled value at `index`.

        If the array is nullable, marks the position as valid.

        Args:
            index: Element index (0-based).
            value: The 128-bit unscaled value to store.

        Raises:
            Error if index is out of bounds.
        """
        if index < 0 or index >= self.length:
            raise Error(
                "Decimal128Array.set_i128: index "
                + String(index)
                + " out of range [0, "
                + String(self.length)
                + ")"
            )
        self.data.write_i128_le_at(index * DECIMAL128_BYTE_WIDTH, value)
        if self.validity:
            if not self.validity.value().test(index):
                self.null_count -= 1
            self.validity.value().set(index)

    @staticmethod
    def from_i128_list(values: List[SIMD[DType.int128, 1]], precision: Int, scale: Int) raises -> Decimal128Array[HeapRegion]:
        """Build a non-nullable Decimal128Array from a list of unscaled int128s."""
        var arr = Decimal128Array[HeapRegion].allocate(len(values), precision, scale)
        for i in range(len(values)):
            arr.data.write_i128_le_at(i * DECIMAL128_BYTE_WIDTH, values[i])
        return arr^

    # --- CONVENIENCE: Integer set/get ---

    def set_from_int(mut self, index: Int, value: Int) raises:
        """Store an integer value, automatically shifted by scale.

        The physical stored value = value. The logical value = value / 10^scale.
        For example, to store $123.45 with scale=2, pass value=12345.

        For values that fit in 64 bits (the common case for monetary
        columns), high word is set to 0 for positive values or -1 for negative.

        Args:
            index: Element index (0-based).
            value: The integer to store (already scaled).

        Raises:
            Error if index is out of bounds.
        """
        var low = Int64(value)
        # Sign extension: for negative values, high word is all 1s (-1).
        var high = Int64(-1) if value < 0 else Int64(0)
        self.set_raw(index, low, high)

    def get_as_int(self, index: Int) raises -> Int:
        """Read the value as an integer (only valid when high word is 0 or -1).

        For values that fit in 64 bits (the common case), this returns the
        exact stored integer. The caller should divide by 10^scale to get
        the logical value.

        Args:
            index: Element index (0-based).

        Returns:
            The stored int128 value truncated to Int (platform-width integer).

        Raises:
            Error if index is out of bounds.
        """
        return Int(self.get_low(index))

    def get_as_float(self, index: Int) raises -> Float64:
        """Read the value as Float64 (lossy for large values).

        Divides the stored integer by 10^scale to produce the logical
        floating-point value. This is lossy for values that exceed Float64
        precision (~15 significant digits).

        Args:
            index: Element index (0-based).

        Returns:
            The logical decimal value as Float64.

        Raises:
            Error if index is out of bounds.
        """
        var low = self.get_low(index)
        var high = self.get_high(index)
        # For values that fit in 64 bits (high == 0 or high == -1 for negative):
        var int_val = Float64(Int(low))
        # Compute 10^scale divisor
        var divisor = Float64(1.0)
        for _ in range(self.scale):
            divisor *= 10.0
        return int_val / divisor

    # --- NULLABILITY ---

    def is_null(self, index: Int) raises -> Bool:
        """Check if element at index is null.

        Returns False if no validity bitmap (all values are valid).

        Args:
            index: Element index (0-based).

        Returns:
            True if the element is null.

        Raises:
            Error if index is out of bounds.
        """
        if index < 0 or index >= self.length:
            raise Error(
                "Decimal128Array.is_null: index "
                + String(index)
                + " out of range [0, "
                + String(self.length)
                + ")"
            )
        if not self.validity:
            return False
        return not self.validity.value().test(index)

    def set_null(mut self, index: Int) raises:
        """Mark element at index as null.

        If no validity bitmap exists, one is created with all elements valid
        before marking the given index as null.

        Args:
            index: Element index (0-based).

        Raises:
            Error if index is out of bounds.
        """
        if index < 0 or index >= self.length:
            raise Error(
                "Decimal128Array.set_null: index "
                + String(index)
                + " out of range [0, "
                + String(self.length)
                + ")"
            )
        if not self.validity:
            # Validity is always Bitmap[HeapRegion] (driver-owned
            # null bitmap), even for borrowed-K data. set_null is mutation,
            # so the lazy-allocated bitmap is heap-owned.
            self.validity = Bitmap.create_all_valid(self.length)
        if self.validity.value().test(index):
            self.null_count += 1
        self.validity.value().clear(index)

    # --- SIZED ---

    @always_inline
    def __len__(self) -> Int:
        """Return the number of Decimal128 elements."""
        return self.length

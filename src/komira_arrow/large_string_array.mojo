# =============================================================================
# LargeStringArray -- Arrow-compatible variable-length string columnar array
#                     with Int64 offsets (supports >2 GB of string data)
# =============================================================================
#
# Identical layout to StringArray but with Int64 offsets instead of Int32,
# allowing columns with more than 2 GB of total string data.
#
# Arrow format for LargeUtf8:
#   offsets buffer: N+1 Int64 values -- offsets[i] is the start byte of
#       string i, offsets[N] is the total data length.
#   data buffer: contiguous UTF-8 bytes.
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


struct LargeStringArray[K: MemoryRegion = HeapRegion](Movable, Sized):
    """A column of variable-length UTF-8 strings with Int64 offsets.

    Arrow-compatible layout: offsets buffer (Int64, N+1 entries) + data buffer
    (UInt8, contiguous UTF-8 bytes) + optional validity bitmap.

    The Int64 offsets allow addressing more than 2 GB of total string data
    per column, unlike StringArray which uses Int32 offsets.

    Fields:
        offsets: Aligned buffer holding N+1 Int64 offset values.
        data: Aligned buffer holding contiguous UTF-8 bytes.
        validity: Optional validity bitmap (Arrow convention: bit=1 means
            valid, bit=0 means null). None means "no nulls" (fast path).
        length: Number of logical string elements.
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
        """Construct a LargeStringArray directly from SharedAlignedBuffers.

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
        """Construct a LargeStringArray directly from OwnedAlignedBuffers.

        OAB-accepting overload. Both OAB inputs
        are promoted to SAB[HeapRegion] via `from_owned`. Constrained to
        `Self.K == HeapRegion` (OAB is heap-only).
        """
        comptime assert (Self.K == HeapRegion), ( "LargeStringArray.__init__(OwnedAlignedBuffer...): OAB ctor" " requires K=HeapRegion (OAB is heap-only); borrowed-K" " arrays must use the SAB-accepting overload above." )
        self.offsets = bridge_oab_to_sab[Self.K](offsets^)
        self.data = bridge_oab_to_sab[Self.K](data^)
        self.validity = validity^
        self.length = length
        self.data_length = data_length
        self.null_count = null_count

    @staticmethod
    def from_strings(values: List[String]) -> LargeStringArray[HeapRegion]:
        """Create a non-nullable LargeStringArray from a list of strings.

        Args:
            values: List of String values. All are treated as valid (non-null).

        Returns:
            A new LargeStringArray containing all the strings.
        """
        var num_strings = len(values)

        # First pass: compute total data length
        var total_bytes = 0
        for i in range(num_strings):
            total_bytes += values[i].byte_length()

        # Allocate offsets buffer (N+1 entries of Int64)
        # Migrated to `set_typed[Int64]` + `view_range_mut` +
        # `copy_from_view_at`.
        comptime int64_size = size_of[Int64]()
        var offsets_buf = OwnedAlignedBuffer((num_strings + 1) * int64_size)
        offsets_buf.set_typed[Int64](0, Int64(0))

        # Allocate data buffer
        var data_buf = OwnedAlignedBuffer(max(total_bytes, 1))

        # Second pass: copy string bytes and fill offsets.
        var offset = 0
        for i in range(num_strings):
            var s = values[i]
            var s_len = s.byte_length()
            if s_len > 0:
                var src_view = ByteView(
                    s.unsafe_ptr().bitcast[UInt8](), s_len
                )
                data_buf.view_range_mut(offset, s_len).copy_from_view_at(
                    0, src_view
                )
            offset += s_len
            offsets_buf.set_typed[Int64](i + 1, Int64(offset))

        offsets_buf.set_length(Int64((num_strings + 1) * int64_size))

        data_buf.set_length(Int64(total_bytes))


        return LargeStringArray[HeapRegion](
            offsets=offsets_buf^,
            data=data_buf^,
            validity=None,
            length=num_strings,
            data_length=total_bytes,
            null_count=0,
        )

    @staticmethod
    def from_strings_with_validity(
        values: List[String],
        valid: List[Bool],
    ) raises -> LargeStringArray[HeapRegion]:
        """The int64-offset twin of `StringArray.from_strings_with_validity`.

        `valid[i] == True` means row i carries `values[i]`. `valid[i] ==
        False` means row i is NULL — the row still occupies an
        (offset, length=0) slot per Arrow's contract and its validity bit is
        cleared. All-True (or empty) `valid` takes the `from_strings` fast
        path, i.e. `validity=None`.

        The layout carries a validity bitmap (the promoting producers copy
        one through); this is the constructor that BUILDS a nullable
        `large_string` column directly, so every null-handling arm of every
        sink that names LARGE_STRING is testable. There is
        deliberately NO `check_int32_offsets` call here: refusing at the int32
        ceiling is the narrow twin's whole job, and this type exists to be the
        answer when that refusal fires.

        Args:
            values: Per-row string content (placeholder for null rows).
            valid: Per-row validity flags; `len(valid) == len(values)`.

        Returns:
            A LargeStringArray whose validity bitmap reflects `valid`.
        """
        var num_strings = len(values)

        var null_count = 0
        for i in range(len(valid)):
            if not valid[i]:
                null_count += 1
        if null_count == 0:
            return LargeStringArray.from_strings(values)

        comptime int64_size = size_of[Int64]()
        var total_bytes = 0
        for i in range(num_strings):
            if i < len(valid) and not valid[i]:
                continue
            total_bytes += values[i].byte_length()

        var offsets_buf = OwnedAlignedBuffer((num_strings + 1) * int64_size)
        offsets_buf.set_typed[Int64](0, Int64(0))
        var data_buf = OwnedAlignedBuffer(max(total_bytes, 1))

        var bm = Bitmap.create(num_strings)
        var offset = 0
        for i in range(num_strings):
            var is_null = (i < len(valid)) and (not valid[i])
            if is_null:
                bm.clear(i)
            else:
                bm.set(i)
                var s = values[i]
                var s_len = s.byte_length()
                if s_len > 0:
                    var src_view = ByteView(
                        s.unsafe_ptr().bitcast[UInt8](), s_len
                    )
                    data_buf.view_range_mut(offset, s_len).copy_from_view_at(
                        0, src_view
                    )
                offset += s_len
            offsets_buf.set_typed[Int64](i + 1, Int64(offset))

        offsets_buf.set_length(Int64((num_strings + 1) * int64_size))
        data_buf.set_length(Int64(total_bytes))

        return LargeStringArray[HeapRegion](
            offsets=offsets_buf^,
            data=data_buf^,
            validity=Optional[Bitmap[HeapRegion]](bm^),
            length=num_strings,
            data_length=total_bytes,
            null_count=null_count,
        )

    # --- Destructor ---
    # MmapAlignedBuffer and Bitmap handle their own cleanup -- no manual free needed.

    # --- Element Access ---

    @always_inline
    def __len__(self) -> Int:
        """Return the number of strings in the array."""
        return self.length

    def get(self, index: Int) raises -> String:
        """Return the string at the given index (bounds-checked, copies data).

        Args:
            index: Zero-based element index.

        Returns:
            A new String containing the UTF-8 bytes for element `index`.

        Raises:
            Error if index is out of bounds.
        """
        if index < 0 or index >= self.length:
            raise Error(
                "LargeStringArray.get: index "
                + String(index)
                + " out of range [0, "
                + String(self.length)
                + ")"
            )
        # Migrated to typed offset lookup + `ByteView.copy_to` into
        # a null-terminated scratch List.
        var start = Int(self.offsets.get_typed[Int64](index))
        var end = Int(self.offsets.get_typed[Int64](index + 1))
        var str_len = end - start

        if str_len == 0:
            return String("")

        var scratch = List[UInt8](capacity=str_len + 1)
        self.data.view_ro().copy_to(scratch, start, str_len)
        scratch.append(UInt8(0))
        # SAFETY: `scratch` is alive through this call; pointer is a
        # null-terminated UTF-8 C buffer copied by the String ctor.
        var result = String(unsafe_from_utf8_ptr=scratch.unsafe_ptr())
        return result

    @always_inline
    def get_length(self, index: Int) -> Int:
        """Return the byte length of the string at the given index.

        This is a fast O(1) operation using the offsets buffer.
        No bounds checking for performance -- caller must ensure valid index.

        Args:
            index: Zero-based element index.

        Returns:
            Number of bytes in the string at `index`.
        """
        # Migrated offset lookup to `get_typed[Int64]`.
        var start = Int(self.offsets.get_typed[Int64](index))
        var end = Int(self.offsets.get_typed[Int64](index + 1))
        return end - start

    @always_inline
    def get_span(
        ref self, index: Int
    ) -> Span[UInt8, origin_of(self.data)]:
        """Return a ZERO-COPY `Span[UInt8]` over element `index`'s UTF-8 bytes.

        The Int64-offset twin of `StringArray.get_span`, and the only way to
        walk a `large_string` column without a heap allocation per row.

        ⚠ THE ALLOCATION IS NOT A MICRO-OPTIMISATION HERE — IT IS THE
        DIFFERENCE BETWEEN A WORKING CONSUMER AND ONE THAT DIES. A
        `large_string` column exists in this tree precisely because it passed
        2 GiB, i.e. it has tens of millions of rows, so a consumer restricted
        to `get()` pays an owned `String` per row. That is what aborted the
        corpus value oracle's `--sig` arm on c5/c5hc, and it is why any fold
        over a promoted column must come through here. `get()` stays and is
        still correct; it is simply not usable at the scale this type is for.

        No bounds check (the caller iterates `0..len`), matching the narrow
        twin exactly.

        Args:
            index: Zero-based element index.

        Returns:
            A borrowed byte span over `data[offsets[i]..offsets[i+1]]`.
        """
        var start = Int(self.offsets.get_typed[Int64](index))
        var end = Int(self.offsets.get_typed[Int64](index + 1))
        # SAFETY: bounds-checked against the data buffer by `view_range_ro`;
        # the ByteView (and thus the Span) carries the data buffer's origin so
        # the borrow is compiler-tracked. No raw pointer escapes this module.
        return self.data.view_range_ro(start, end - start).into_span()

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

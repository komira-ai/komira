# =============================================================================
# StringArray — Arrow-compatible variable-length string columnar array
# =============================================================================
#
# Arrow format for variable-length binary/string:
#   offsets buffer: N+1 Int32 values — offsets[i] is the start byte of string i,
#       offsets[N] is the total data length. String i spans
#       data[offsets[i]..offsets[i+1]].
#   data buffer: contiguous UTF-8 bytes.
#   validity bitmap: optional, 1 bit per element (1=valid, 0=null).
#
# Memory is managed by MmapAlignedBuffer (offsets, data) and Bitmap (validity).
# UnsafePointer usage is contained in those primitives.
# =============================================================================

from std.memory import alloc, unsafe_memcpy
from std.sys import size_of

from ..collections.byte_view import ByteView

from .owned_aligned_buffer import OwnedAlignedBuffer
from .shared_aligned_buffer import (
    SharedAlignedBuffer,
    bridge_oab_to_sab,
)
from ..io.heap_region import HeapRegion
from ..io.memory_region import MemoryRegion
from .bitmap import Bitmap
from .offset_overflow import (
    check_int32_offsets,
    check_int32_offsets_attributed,
)

# STRDRAIN COUNTER: the ONE place every `List[String]` staging drain must
# route through. See `komira_core/helpers/strdrain_counter.mojo` for why the
# counter lives here rather than at every call site.
from ..helpers.strdrain_counter import strdrain_note_from_strings


struct StringArray[K: MemoryRegion = HeapRegion](Movable, Sized):
    """A column of variable-length UTF-8 strings with optional null bitmap.

    Arrow-compatible layout: offsets buffer (Int32, N+1 entries) + data buffer
    (UInt8, contiguous UTF-8 bytes) + optional validity bitmap.

    Parameters:
        K: The MemoryRegion type backing the buffers. Defaults to
           HeapRegion (owning). K=MmapRegion is the zero-copy IPC path.
           The K parameter carries the buffer region type through the
           holder. Default K=HeapRegion means `StringArray` sites need no
           annotation.

    Fields:
        offsets: Aligned buffer holding N+1 Int32 offset values.
        data: Aligned buffer holding contiguous UTF-8 bytes.
        validity: Optional validity bitmap (Arrow convention: bit=1 means
            valid, bit=0 means null). None means "no nulls" (fast path).
        length: Number of logical string elements.
        data_length: Total bytes in the data buffer.
        null_count: Number of null (invalid) elements. 0 when validity is None.
    """

    # Holder fields flipped
    # `MmapAlignedBuffer[64, Self.K]` -> `SharedAlignedBuffer[Self.K]`.
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
        """Construct a StringArray directly from SharedAlignedBuffers.

        SAB-accepting overload (the canonical shape). Callers construct
        the SAB via `SharedAlignedBuffer.from_owned(OwnedAlignedBuffer(size)^)`.
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
        """Construct a StringArray directly from OwnedAlignedBuffers.

        OAB-accepting overload. Both OAB inputs
        are promoted to SAB[HeapRegion] via `from_owned`. Constrained to
        `Self.K == HeapRegion` (OAB is heap-only).
        """
        comptime assert (Self.K == HeapRegion), ( "StringArray.__init__(OwnedAlignedBuffer...): OAB ctor" " requires K=HeapRegion (OAB is heap-only); borrowed-K" " arrays must use the SAB-accepting overload above." )
        self.offsets = bridge_oab_to_sab[Self.K](offsets^)
        self.data = bridge_oab_to_sab[Self.K](data^)
        self.validity = validity^
        self.length = length
        self.data_length = data_length
        self.null_count = null_count

    @staticmethod
    def from_strings(
        values: List[String],
        producer: StaticString = "",
    ) raises -> StringArray[HeapRegion]:
        """Create a non-nullable StringArray from a list of strings.

        ⚠ `producer` IS THE ONLY THING THAT MAKES AN OVERFLOW HERE ACTIONABLE.
        This constructor has many callers, so `ArrowOffsetOverflow: ...
        at StringArray.from_strings` names the one participant that does not
        know why it was called. A caller that stages a potentially large column
        MUST pass its own identity; see `offset_overflow.mojo`'s attribution
        section.

        Args:
            values: List of String values. All are treated as valid (non-null).
            producer: Identity of the CALLING producer, for the overflow
                message. Empty means unattributed, and the message says so.

        Returns:
            A new StringArray containing all the strings.
        """
        var num_strings = len(values)

        # First pass: compute total data length
        var total_bytes = 0
        for i in range(num_strings):
            total_bytes += values[i].byte_length()

        # Int32-offset ceiling: raise BEFORE allocating anything, so a >2 GiB
        # column fails loudly instead of wrapping `Int32(offset)` negative.
        check_int32_offsets_attributed(
            "StringArray.from_strings", producer, total_bytes, num_strings
        )

        # STRDRAIN COUNTER: one call, one value count, one byte count. Per
        # CALL (per column per batch), never per value — the loop below already
        # memcpys every value, so three relaxed adds in front of it are not
        # measurable. UNCONDITIONAL on purpose: a counter that only ran in one
        # configuration could not compare configurations.
        strdrain_note_from_strings(num_strings, total_bytes)

        # Allocate offsets buffer (N+1 entries of Int32)
        # Migrated `_unsafe_data_ptr().bitcast[Int32]()` writes to
        # `set_typed[Int32]` and per-string memcpy to
        # `view_range_mut(..).copy_from_view_at(0, src_view)`.
        comptime int32_size = size_of[Int32]()
        var offsets_buf = OwnedAlignedBuffer((num_strings + 1) * int32_size)
        offsets_buf.set_typed[Int32](0, Int32(0))

        # Allocate data buffer
        var data_buf = OwnedAlignedBuffer(max(total_bytes, 1))

        # Second pass: copy string bytes and fill offsets (memcpy per string).
        var offset = 0
        for i in range(num_strings):
            var s = values[i]
            var s_len = s.byte_length()
            if s_len > 0:
                # `s` is alive through this loop iteration; view is tied
                # to its origin via the UnsafePointer bitcast source.
                var src_view = ByteView(
                    s.unsafe_ptr().bitcast[UInt8](), s_len
                )
                data_buf.view_range_mut(offset, s_len).copy_from_view_at(
                    0, src_view
                )
            offset += s_len
            offsets_buf.set_typed[Int32](i + 1, Int32(offset))

        offsets_buf.set_length(Int64((num_strings + 1) * int32_size))

        data_buf.set_length(Int64(total_bytes))


        return StringArray[HeapRegion](
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
        producer: StaticString = (
            "StringArray.from_strings_with_validity (all-valid fast path)"
        ),
    ) raises -> StringArray[HeapRegion]:
        """Create a NULLABLE StringArray from values + a per-row valid mask.

        `valid[i] == True` means row i is a real value (`values[i]` is the
        content). `valid[i] == False` means row i is NULL — the row still
        occupies an (offset, length=0) slot in the offsets buffer per Arrow's
        contract, and the corresponding validity bit is cleared.

        When `valid` is all-True (or empty), the resulting array has
        `validity=None` (the all-valid fast path) — byte-identical to
        `from_strings`. Used by the column-untyped join drain to propagate a
        build-side STRING column's null bitmap through the gather
.

        Args:
            values: Per-row string content (placeholder for null rows).
            valid: Per-row validity flags; `len(valid) == len(values)`.
            producer: Identity of the CALLING producer, for the overflow
                message. Defaults to this constructor's own name so that the
                all-valid delegation below never reports a call the caller did
                not make.

        Returns:
            A StringArray whose validity bitmap reflects `valid`.
        """
        var num_strings = len(values)

        # Detect any nulls; if none, take the all-valid fast path.
        var null_count = 0
        for i in range(len(valid)):
            if not valid[i]:
                null_count += 1
        if null_count == 0:
            # ⛔ THE PRODUCER MUST TRAVEL ACROSS THIS DELEGATION. Otherwise a
            # grouped-key drain that called the NULLABLE constructor is
            # reported as `at StringArray.from_strings`, i.e. as a call it
            # never made. A reader grepping for the reported site
            # cannot find this call site at all.
            # The producer parameter DEFAULTS to this constructor's own
            # name, so an unconverted caller still produces a message naming
            # the constructor it actually invoked, and a converted one
            # overrides it with something better. No emptiness test, and no
            # per-call allocation on the hot path.
            return StringArray.from_strings(values, producer)

        comptime int32_size = size_of[Int32]()
        # Null rows contribute zero bytes (Arrow stores an empty slot).
        var total_bytes = 0
        for i in range(num_strings):
            if i < len(valid) and not valid[i]:
                continue
            total_bytes += values[i].byte_length()

        check_int32_offsets_attributed(
            "StringArray.from_strings_with_validity",
            producer,
            total_bytes,
            num_strings,
        )

        # STRDRAIN COUNTER — see `from_strings`. `total_bytes` here already
        # excludes null slots, which is the honest figure: a null stages an
        # empty `String` that owns no bytes.
        strdrain_note_from_strings(num_strings, total_bytes)

        var offsets_buf = OwnedAlignedBuffer((num_strings + 1) * int32_size)
        offsets_buf.set_typed[Int32](0, Int32(0))
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
            offsets_buf.set_typed[Int32](i + 1, Int32(offset))

        offsets_buf.set_length(Int64((num_strings + 1) * int32_size))
        data_buf.set_length(Int64(total_bytes))

        return StringArray[HeapRegion](
            offsets=offsets_buf^,
            data=data_buf^,
            validity=Optional[Bitmap[HeapRegion]](bm^),
            length=num_strings,
            data_length=total_bytes,
            null_count=null_count,
        )

    @staticmethod
    def from_byte_lists(
        values: List[List[UInt8]],
    ) raises -> StringArray[HeapRegion]:
        """Create a non-nullable StringArray from a list of RAW byte sequences,
        copied VERBATIM (NO UTF-8 round-trip, NO `chr()` String mangling).

        This is the binary-faithful companion of `from_strings`. `from_strings`
        routes each value through a `String`, which mangles TRUE binary data two
        ways: an embedded `0x00` truncates the String (`as_bytes()` stops at the
        null, dropping every trailing byte) and a `>= 0x80` byte expands into a
        multi-byte UTF-8 sequence. `from_byte_lists` copies the raw bytes
        straight into the Arrow data buffer, so a composite secondary-index key
        carrying `0x00` separators / high bytes survives byte-for-byte. The
        resulting array length and per-element byte length equal the input
        verbatim. Pair it with a Parquet BYTE_ARRAY column WITHOUT a UTF8
        ConvertedType (raw BINARY) for a true binary column.

        Args:
            values: List of raw byte sequences. All are treated as valid (non-null).

        Returns:
            A StringArray whose data buffer is the verbatim concatenation of
            `values` with the matching N+1 cumulative offsets.
        """
        var num = len(values)
        comptime int32_size = size_of[Int32]()

        var total_bytes = 0
        for i in range(num):
            total_bytes += len(values[i])

        check_int32_offsets("StringArray.from_byte_lists", total_bytes, num)

        var offsets_buf = OwnedAlignedBuffer((num + 1) * int32_size)
        offsets_buf.set_typed[Int32](0, Int32(0))
        var data_buf = OwnedAlignedBuffer(max(total_bytes, 1))

        var offset = 0
        for i in range(num):
            ref v = values[i]
            var v_len = len(v)
            if v_len > 0:
                # SAFETY: `v` is alive through this iteration; the ByteView
                # carries its origin so the borrow is compiler-tracked. No raw
                # pointer escapes this module.
                var src_view = ByteView(v.unsafe_ptr(), v_len)
                data_buf.view_range_mut(offset, v_len).copy_from_view_at(
                    0, src_view
                )
            offset += v_len
            offsets_buf.set_typed[Int32](i + 1, Int32(offset))

        offsets_buf.set_length(Int64((num + 1) * int32_size))
        data_buf.set_length(Int64(total_bytes))

        return StringArray[HeapRegion](
            offsets=offsets_buf^,
            data=data_buf^,
            validity=None,
            length=num,
            data_length=total_bytes,
            null_count=0,
        )

    @staticmethod
    def from_buffers(
        offsets: List[Int32],
        data: List[UInt8],
        var validity: Optional[Bitmap[HeapRegion]],
        null_count: Int,
    ) raises -> StringArray[HeapRegion]:
        """Adopt an Arrow-native (offsets, data) pair into a StringArray.

        This is the zero-re-serialize finalize for `ArrowStringBuilder`: the
        decoder streams raw UTF-8 bytes into `data` and pushes one cumulative
        `Int32` per value into `offsets` (N+1 entries, `offsets[0] == 0`). At
        finalize there is NO per-value `List[String]` intermediate and NO
        per-string re-serialize pass (the cost `from_strings` paid) — just ONE
        bulk memcpy of `offsets` and ONE of `data` into the two AlignedBuffers.

        The two memcpys are an alignment requirement, not a re-serialize:
        MmapAlignedBuffer over-allocates + 64-byte aligns + SIMD-tail-pads, so the
        builder's plain `List` backing store cannot itself be the Arrow buffer.
        The copies are O(total_bytes) once, vs. the prior O(rows) String allocs
        + O(rows) String drops + O(total_bytes) re-serialize.

        Args:
            offsets: N+1 cumulative byte offsets (`offsets[0]==0`,
                `offsets[N]==len(data)`). `len(offsets) >= 1`.
            data: Contiguous UTF-8 bytes for all N values.
            validity: Optional validity bitmap (None == all valid).
            null_count: Number of null elements (0 when validity is None).

        Returns:
            A StringArray adopting `(offsets, data)`.
        """
        comptime int32_size = size_of[Int32]()
        var num_strings = len(offsets) - 1
        var total_bytes = len(data)

        # The caller's `offsets` List[Int32] may ALREADY have wrapped (the
        # builder narrows per push). `len(data)` is the 64-bit truth, so this
        # check catches the wrap even though the offsets arrive pre-narrowed.
        check_int32_offsets(
            "StringArray.from_buffers", total_bytes, num_strings
        )

        var offsets_buf = OwnedAlignedBuffer((num_strings + 1) * int32_size)
        # ONE memcpy of the cumulative-offset List[Int32] into the Arrow
        # offsets buffer (no per-element set_typed loop).
        offsets_buf.copy_from_int32_list(offsets)
        offsets_buf.set_length(Int64((num_strings + 1) * int32_size))


        var data_buf = OwnedAlignedBuffer(max(total_bytes, 1))
        # ONE memcpy from the streamed byte List into the Arrow data buffer.
        data_buf.copy_from_bytes_list(data)
        data_buf.set_length(Int64(total_bytes))


        return StringArray[HeapRegion](
            offsets=offsets_buf^,
            data=data_buf^,
            validity=validity^,
            length=num_strings,
            data_length=total_bytes,
            null_count=null_count,
        )

    # --- Destructor ---
    # MmapAlignedBuffer and Bitmap handle their own cleanup — no manual free needed.

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
                "StringArray.get: index "
                + String(index)
                + " out of range [0, "
                + String(self.length)
                + ")"
            )
        # Migrated offset lookup to `get_typed[Int32]`; per-string
        # memcpy into a null-terminated scratch List + String ctor.
        var start = Int(self.offsets.get_typed[Int32](index))
        var end = Int(self.offsets.get_typed[Int32](index + 1))
        var str_len = end - start

        if str_len == 0:
            return String("")

        # `copy_to` appends each byte; we then append the null terminator.
        var scratch = List[UInt8](capacity=str_len + 1)
        self.data.view_ro().copy_to(scratch, start, str_len)
        scratch.append(UInt8(0))
        # SAFETY: `scratch` is alive through this call; its pointer is a
        # null-terminated UTF-8 C buffer that the String ctor copies out.
        var result = String(unsafe_from_utf8_ptr=scratch.unsafe_ptr())
        return result

    @always_inline
    def get_length(self, index: Int) -> Int:
        """Return the byte length of the string at the given index.

        This is a fast O(1) operation using the offsets buffer.
        No bounds checking for performance — caller must ensure valid index.

        Args:
            index: Zero-based element index.

        Returns:
            Number of bytes in the string at `index`.
        """
        # Migrated offset lookup to `get_typed[Int32]`.
        var start = Int(self.offsets.get_typed[Int32](index))
        var end = Int(self.offsets.get_typed[Int32](index + 1))
        return end - start

    @always_inline
    def get_span(
        ref self, index: Int
    ) -> Span[UInt8, origin_of(self.data)]:
        """Return a ZERO-COPY `Span[UInt8]` over element `index`'s raw UTF-8
        bytes — a borrowed view into the data buffer, NO heap alloc.

        This is the write-path companion of `get` (which allocates an owned
        `String` per call). The Avro writer (`_encode_one_cell`) and any encoder
        that consumes the bytes directly should use this to avoid one heap
        allocation + copy per string row (~30M allocs on a lineitem write).

        Mirrors arrow-avro's `StringArray::value(idx) -> &str` (a zero-copy
        slice into the offset buffer). The returned span's lifetime is tied to
        the data buffer; the compiler forbids retaining it past a mutation of
        the array. No bounds check (caller iterates `0..len`).

        Args:
            index: Zero-based element index.

        Returns:
            A borrowed byte span over `data[offsets[i]..offsets[i+1]]`.
        """
        var start = Int(self.offsets.get_typed[Int32](index))
        var end = Int(self.offsets.get_typed[Int32](index + 1))
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

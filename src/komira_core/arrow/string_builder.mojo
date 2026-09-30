# =============================================================================
# string_builder.mojo — Arrow-native streaming string/binary accumulator.
# =============================================================================
#
# `ArrowStringBuilder` is a raw byte-buffer + Int32-offsets accumulator. It
# serves BOTH the Arrow string (UTF-8) and binary (raw-bytes) columns: the
# push machinery never validates or interprets the bytes, so binary is just
# "string without the UTF-8 guarantee". `build()` finalizes into a string
# Column; `build_binary()` finalizes into a binary Column. ONE builder, two
# finalizers — no near-duplicate `ArrowBinaryBuilder` struct. The Avro
# `_BinaryAcc` adopts it via `build_binary()`.
# =============================================================================
#
# Shared primitive (the Avro `_StringAcc` shape). BOTH the ORC column decoder
# and the Avro action-table interpreter build Arrow string columns; the naive
# shape materializes a `List[String]` (one heap String per
# value, millions per column) and then RE-SERIALIZED that list into the Arrow
# `offsets + data` buffers via `StringArray.from_strings`. That is two full
# passes + one small heap allocation per value + one drop per value.
#
# This builder streams DIRECTLY into Arrow's variable-length layout:
#   - `data: List[UInt8]`   — contiguous UTF-8 bytes (amortized O(1) append).
#   - `offsets: List[Int32]` — N+1 cumulative byte offsets (offsets[0]==0).
#   - `_null_count` inline + a LAZY `nulls: List[Bool]` only allocated on the
#     first null (the all-non-null hot path never touches it).
#
# `push_bytes(span)` copies the raw value bytes once with NO intermediate
# String allocation. At finalize, `StringArray.from_buffers` adopts the two
# Lists with ONE bulk memcpy each (the memcpy is an MmapAlignedBuffer
# alignment/SIMD-tail-pad requirement, not a re-serialize).
#
# Encapsulation: this struct holds only owned `List` fields and exposes a
# value-typed API (push spans / build a Column). No UnsafePointer crosses the
# module boundary.
# =============================================================================


from ..simd.validity_pack import pack_validity_from_null_flags

from .owned_aligned_buffer import OwnedAlignedBuffer
from .shared_aligned_buffer import SharedAlignedBuffer
from .binary_array import BinaryArray
from ..io.heap_region import HeapRegion
from .bitmap import Bitmap, bytes_for_bits
from .column import Column
from .string_array import StringArray


struct ArrowStringBuilder(Copyable, Movable):
    """Streaming accumulator for an Arrow string (UTF-8) column.

    Decode raw value bytes straight into Arrow's `(offsets, data)` layout with
    no per-value `String` allocation and no re-serialize pass at finalize.
    """

    var data: List[UInt8]
    var offsets: List[Int32]
    var nulls: List[Bool]  # lazy: empty until first null
    var _null_count: Int
    var _has_validity: Bool

    def __init__(out self):
        self.data = List[UInt8]()
        self.offsets = List[Int32]()
        self.offsets.append(Int32(0))  # offsets[0] == 0
        self.nulls = List[Bool]()
        self._null_count = 0
        self._has_validity = False

    @always_inline
    def n_values(self) -> Int:
        """Number of values pushed so far (N, not the N+1 offset count)."""
        return len(self.offsets) - 1

    @always_inline
    def data_len(self) -> Int:
        """Total accumulated value bytes.

        Exposed so a format reader can enforce the Arrow-32 offset ceiling
        (2^31-1) ONCE at column-build time rather than re-deriving it. The
        offsets this builder appends are narrowed with a bare `Int32(...)`
        at `_append_offset`, so past 2 GiB they wrap NEGATIVE while `data`
        stays correctly large — an ASSERT-independent corruption (no stdlib
        bounds check is involved in the narrowing).
        """
        return len(self.data)

    def reserve_rows(mut self, n_rows: Int):
        """Pre-size the offsets list for `n_rows` total values.

        `data` is intentionally NOT reserved here — its size depends on the
        average value byte-length which the caller does not know up front;
        `List.append`'s doubling growth gives amortized O(1) without an
        O(n^2) re-reserve trap. Pre-reserving offsets avoids the geometric
        realloc cascade on the N+1 Int32 offset list across many stripes/blocks.
        """
        self.offsets.reserve(n_rows + 1)

    def reserve_bytes(mut self, n_bytes: Int):
        """Pre-size the `data` byte buffer for `n_bytes` total value bytes.

        ⚠ THE SIBLING `reserve_rows` DELIBERATELY DOES NOT DO THIS, and its
        reason is stated there: a FORMAT READER does not know the average value
        byte-length up front, so reserving from a guess risks an O(n^2)
        re-reserve cascade. That reason does not reach a DRAIN, which is
        finalizing an ALREADY-MATERIALIZED set of values and can compute the
        exact total in one cheap pass over their lengths (`String.byte_length`
        reads a header field; it does not touch the bytes).

        This method exists so a drain conversion can be argued as pure work
        REMOVAL. Without it, replacing `StringArray.from_strings` — which
        computes `total_bytes` exactly in its first pass and allocates ONCE —
        with a doubling `List` would DELETE N per-value String allocations
        while ADDING amortized realloc byte traffic the incumbent never paid.
        That is a trade, not a deletion, and it would have to be authorised by
        a benchmark rather than by correctness. With an exact reserve the byte
        traffic is matched and only the allocations are removed.
        """
        self.data.reserve(n_bytes)

    @always_inline
    def _append_offset(mut self):
        self.offsets.append(Int32(len(self.data)))

    @always_inline
    def _mark_present(mut self):
        if self._has_validity:
            self.nulls.append(False)

    @always_inline
    def push_bytes(mut self, v: Span[UInt8, _]):
        """Append one value: bulk-extend the byte buffer + push its end offset.

        `List.extend(Span)` routes through a single grow + memcpy (NOT a
        per-byte append loop), so a wide string column costs one memcpy/value.
        """
        self.data.extend(v)
        self._append_offset()
        self._mark_present()

    @always_inline
    def push_bytes_partial(mut self, v: Span[UInt8, _]):
        """Append bytes to the value currently being ASSEMBLED, without closing
        it.  Pair with `end_value()`.

        ⭐ WHY THIS EXISTS.  A producer that builds one value from SEVERAL
        pieces (a `regexp_replace` output is `gap | substitution | gap | tail`)
        otherwise has to concatenate those pieces into a scratch `List[UInt8]`
        or a `String` first, purely so it can hand `push_bytes` one contiguous
        span — reintroducing exactly the per-value heap allocation + extra byte
        pass this builder exists to delete.  With this pair the pieces are
        `extend`ed straight into the Arrow data buffer and the offset is pushed
        once, at the end.

        ⛔ `end_value()` IS NOT OPTIONAL.  Between `push_bytes_partial` and
        `end_value` the builder is MID-VALUE: `n_values()` has not advanced and
        the bytes written belong to no value yet.  Finalizing there would drop
        them (they sit past the last offset).  Never interleave a
        `push_bytes`/`push_null` into an open value.
        """
        self.data.extend(v)

    @always_inline
    def end_value(mut self):
        """Close the value assembled by zero or more `push_bytes_partial`
        calls.  Zero calls is legal and yields the empty string."""
        self._append_offset()
        self._mark_present()

    def push_contiguous_block(
        mut self, data: Span[UInt8, _], lengths: Span[Int64, _], total: Int
    ):
        """Append a run of `len(lengths)` non-null values whose bytes are
        ALREADY contiguous in `data` (data[0:total], total == sum(lengths)).

        This is the ORC / Avro no-null DIRECT string fast path: instead of one
        `data.extend(span)` + one `offsets.append` PER value (N grow-checks + N
        memcpy calls + N bounds-checked offset appends), it does:
          * ONE bulk `data.extend(data[0:total])` — a single memcpy of the
            whole block (the bytes are physically contiguous in the DATA
            stream, so per-value slicing/copying was redundant), and
          * a tight prefix-sum that writes N Int32 offsets via a hoisted
            raw-pointer cursor (the offset list is pre-grown ONCE, so there is
            no per-value capacity-check branch).

        Validity is untouched (these are all present); if a prior null already
        flipped `_has_validity`, the caller must instead use per-value
        `push_bytes`/`push_null` (the nullable slow path) — this fast path
        asserts no validity tracking via `_has_validity == False` semantics by
        only being called on the no-present path.
        """
        var n = len(lengths)
        if n == 0:
            return
        # ONE bulk byte copy of the whole block (caller passes the precomputed
        # total == sum(lengths), already used for its bounds check).
        self.data.extend(data[0:total])
        # Tight offset prefix-sum: grow the offset list once, then write N
        # cumulative Int32 offsets through a raw cursor (no per-elem grow check).
        var base = Int(self.offsets[len(self.offsets) - 1])
        var old_len = len(self.offsets)
        self.offsets.resize(unsafe_uninit_length=old_len + n)
        # SAFETY: `offsets` was just resized to old_len+n; the cursor writes
        # exactly indices [old_len, old_len+n). Pointer is module-internal
        # (never escapes) with the List's concrete origin. base+running stays
        # within the value-byte budget validated by the caller's total check.
        var dst = self.offsets.unsafe_ptr() + old_len
        var running = base
        for i in range(n):
            running += Int(lengths[i])
            dst[i] = Int32(running)
        if self._has_validity:
            self.nulls.reserve(len(self.nulls) + n)
            for _i in range(n):
                self.nulls.append(False)

    def push_null(mut self):
        """Append a null value (zero-length, validity bit cleared)."""
        if not self._has_validity:
            # First null: back-fill the nulls list to all-present for prior rows.
            self._has_validity = True
            var prior = len(self.offsets) - 1
            self.nulls.reserve(prior + 1)
            for _i in range(prior):
                self.nulls.append(False)
        self._append_offset()  # zero-length value
        self.nulls.append(True)
        self._null_count += 1

    def build(var self) raises -> Column[HeapRegion]:
        """Finalize into an Arrow string Column[HeapRegion] (zero re-serialize)."""
        var validity: Optional[Bitmap[HeapRegion]] = None
        var nc = 0
        if self._has_validity:
            var bm = _bitmap_from_nulls(self.nulls)
            if bm:
                validity = bm^
                nc = self._null_count
        var arr = StringArray.from_buffers(
            self.offsets, self.data, validity^, nc
        )
        return Column.from_string(arr)

    def build_string_array(var self) raises -> StringArray[HeapRegion]:
        """Finalize into a bare `StringArray[HeapRegion]` (zero re-serialize).

        The same finalize as `build()`, stopping one step short of the `Column`
        wrapper — for the kernels whose signature is `-> StringArray` and whose
        caller does its own `Column.from_string`.

        ⚠ THIS DOES NOT SHARE A BODY with `build` / `build_binary` — the
        validity-pack block is written out three times (`build`,
        `build_binary`, this). There is no drift guarantee; the three must be
        edited together until one of them is refactored to delegate.
        """
        var validity: Optional[Bitmap[HeapRegion]] = None
        var nc = 0
        if self._has_validity:
            var bm = _bitmap_from_nulls(self.nulls)
            if bm:
                validity = bm^
                nc = self._null_count
        return StringArray.from_buffers(self.offsets, self.data, validity^, nc)

    def build_binary(var self) raises -> Column[HeapRegion]:
        """Finalize into an Arrow binary Column[HeapRegion] (zero re-serialize).

        Sibling of `build()`: the byte-buffer + offsets + validity machinery
        is identical (binary is string without the UTF-8 guarantee — and this
        builder never validates UTF-8 on push, it just `extend`s raw bytes), so
        the SAME accumulator serves both columns. Only the finalize differs:
        `BinaryArray.from_buffers` + `Column.from_binary` instead of the string
        twins. This is why there is one builder, not two near-duplicates.
        """
        var validity: Optional[Bitmap[HeapRegion]] = None
        var nc = 0
        if self._has_validity:
            var bm = _bitmap_from_nulls(self.nulls)
            if bm:
                validity = bm^
                nc = self._null_count
        var arr = BinaryArray.from_buffers(
            self.offsets, self.data, validity^, nc
        )
        return Column.from_binary(arr)


def _bitmap_from_nulls(nulls: List[Bool]) raises -> Optional[Bitmap[HeapRegion]]:
    """Build an Arrow validity bitmap (bit i == 1 iff row i is VALID).

    `nulls[i] == True` means row i is NULL. Returns None if `nulls` is empty
    or no row is null. Uses the shared SIMD movemask validity packer
    (16 rows/iteration) — bit-for-bit identical to the scalar
    `create_all_valid + per-null clear` pack.
    """
    var n = len(nulls)
    if n == 0:
        return None
    var any_null = False
    for i in range(n):
        if nulls[i]:
            any_null = True
            break
    if not any_null:
        return None
    var num_bytes = bytes_for_bits(n)
    var bm = Bitmap[HeapRegion]()
    # Bitmap.buffer is SharedAlignedBuffer; bridge OAB via from_owned.
    bm.buffer = SharedAlignedBuffer.from_owned(
        OwnedAlignedBuffer(num_bytes)
    )
    var dst = bm.buffer.into_span_capacity()
    _ = pack_validity_from_null_flags(Span(nulls), dst)
    bm.buffer.set_length(num_bytes)

    bm.length = n
    return Optional[Bitmap[HeapRegion]](bm^)

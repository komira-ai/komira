# =============================================================================
# PLAIN Encoding Decoder — Parquet's simplest encoding
# =============================================================================
#
# PLAIN encoding stores values back-to-back in their native little-endian
# binary representation. For fixed-width types on little-endian platforms
# (all modern x86-64 and ARM), PLAIN-encoded data IS the Arrow in-memory
# format — decode is just a memcpy.
#
# Every public decoder takes the encoded page as a `Span[UInt8]`; the Span's
# length is the page extent each decoder checks before it reads. The private
# cores take the Span's pointer and length.
#
# The FIXED_LEN_BYTE_ARRAY decoders are in `plain_flba`; the PLAIN encoders
# belong to the writer.
#
# SAFETY: the cores read the page through a concrete-origin pointer taken
# from the caller's Span, only after the extent check that bounds the read.
# =============================================================================

from std.memory import unsafe_memcpy, unsafe_memset
from std.sys import size_of

from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.string_array import StringArray
from komira_arrow.bitmap import Bitmap
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_buffer.heap_region import HeapRegion
# The PLAIN BYTE_ARRAY copy is a PER-STRING copy. Stdlib `memcpy`'s inline
# expansion ends in a ONE-BYTE-PER-ITERATION remainder loop for `len mod 32`,
# which on typical string payloads runs on nearly every value — and for
# 17..31 B values the vector loop is skipped entirely so the WHOLE copy is
# byte-at-a-time. `fast_copy_bytes` has no byte-at-a-time tail.
from komira_simd.fast_copy import fast_copy_bytes

# The arm gate and the paired per-page fire counters of the two BYTE_ARRAY
# walks. `scan_copy_trace` imports only std, `komira_atomic_alias` and the
# package's other trace modules, so this edge is acyclic.
from .scan_copy_trace import (
    add_plain_ba_fused_alloc,
    add_plain_ba_slack,
    incr_plain_ba_fused,
    incr_plain_ba_two_pass,
    plain_ba_fused_enabled,
)


# =============================================================================
# Fixed-width numeric decoders — memcpy into an aligned buffer
# =============================================================================
# =============================================================================
# THE EXTENT IS A PARAMETER, NOT A COMMENT.
#
# Every decoder below takes the page as a Span, so a caller cannot make the
# call without stating how many bytes it actually has, and every decoder
# checks the declared value count against those bytes before it reads.
#
# COST: ONE compare per PAGE (per call), not per value. It rejects nothing a
# conforming writer emits — PLAIN fixed-width IS exactly `num_values *
# elem_size` bytes.
# =============================================================================


@always_inline
def _require_plain_extent(
    what: StaticString,
    num_values: Int,
    bytes_per_value: Int,
    data_len: Int,
) raises:
    """Reject a PLAIN page that cannot hold the values it declares.

    The single boundary check behind every fixed-width PLAIN decoder. It
    names the encoding, the declared count, the implied byte demand and the
    bytes actually present, so a corrupt page produces a diagnosis rather
    than an overread.

    Args:
        what: Human-readable name of the decode being attempted.
        num_values: Value count declared by the (attacker-controlled) header.
        bytes_per_value: Encoded width of one value.
        data_len: Bytes actually present in the page.

    Raises:
        Error naming the shortfall, if the declared extent does not fit.
    """
    if num_values < 0:
        raise Error(
            "parquet: corrupt "
            + String(what)
            + " page: negative value count "
            + String(num_values)
        )
    if data_len < 0:
        raise Error(
            "parquet: corrupt "
            + String(what)
            + " page: negative body length "
            + String(data_len)
        )
    # The count is compared with `data_len // bytes_per_value`, never the
    # product with `data_len`: `num_values * bytes_per_value` wraps for a
    # header-supplied count (2^62 INT96 values is 0 bytes after the wrap),
    # and a wrapped product would pass a page that holds none of them. A
    # zero-width value reads nothing, so any count fits.
    if bytes_per_value > 0 and num_values > data_len // bytes_per_value:
        raise Error(
            "parquet: corrupt "
            + String(what)
            + " page: declares "
            + String(num_values)
            + " values ("
            + String(num_values * bytes_per_value)
            + " bytes at "
            + String(bytes_per_value)
            + " bytes/value) but the page body holds only "
            + String(data_len)
            + " bytes"
        )


@always_inline
def _decode_plain_fixed[
    dtype: DType, o: Origin
](
    data: UnsafePointer[UInt8, o], data_len: Int, num_values: Int
) raises -> PrimitiveArray[dtype]:
    """Decode PLAIN-encoded fixed-width values via memcpy.

    On little-endian platforms (all modern CPUs), PLAIN encoding for fixed-width
    numeric types is byte-identical to the Arrow in-memory layout. Decoding is
    a single memcpy into an aligned buffer.

    Parameters:
        dtype: The Arrow data type of the output array.

    Args:
        data: Pointer to the PLAIN-encoded page data.
        data_len: Number of bytes actually present at `data`. REQUIRED — the
            memcpy below reads `num_values * elem_size` bytes and nothing
            else stands between the header's count and that read.
        num_values: Number of values to decode.

    Returns:
        A non-nullable PrimitiveArray containing the decoded values.

    Raises:
        Error if the page body cannot hold `num_values` encoded values.
    """
    if num_values == 0:
        return PrimitiveArray[dtype].allocate(0)

    comptime elem_size = size_of[Scalar[dtype]]()
    _require_plain_extent(
        "PLAIN fixed-width", num_values, elem_size, data_len
    )
    var byte_count = num_values * elem_size

    # Allocate 64-byte aligned output buffer (Arrow spec + AVX-512 friendly).
    # Dest via origin-tied `view_range_mut` on the buffer.
    var buf = OwnedAlignedBuffer(byte_count)
    var dst_view = buf.view_range_mut(0, byte_count)
    unsafe_memcpy(dest=dst_view._unsafe_ptr(), src=data, count=byte_count)
    buf.set_length(Int64(byte_count))


    return PrimitiveArray[dtype](buf^, num_values, None, 0, 0)


@always_inline
def decode_plain_int32(
    data: Span[UInt8, _], num_values: Int
) raises -> PrimitiveArray[DType.int32]:
    """Decode PLAIN-encoded Int32 values. Zero-copy-equivalent on little-endian.

    Args:
        data: The page: packed 4-byte little-endian values. The decode
            reads `num_values * 4` bytes and refuses a shorter page.
        num_values: Number of Int32 values to decode.

    Returns:
        A non-nullable PrimitiveArray[DType.int32].
    """
    return _decode_plain_fixed[DType.int32](
        data.unsafe_ptr(), len(data), num_values
    )


@always_inline
def decode_plain_int64(
    data: Span[UInt8, _], num_values: Int
) raises -> PrimitiveArray[DType.int64]:
    """Decode PLAIN-encoded Int64 values. Zero-copy-equivalent on little-endian.

    Args:
        data: The page: packed 8-byte little-endian values. The decode
            reads `num_values * 8` bytes and refuses a shorter page.
        num_values: Number of Int64 values to decode.

    Returns:
        A non-nullable PrimitiveArray[DType.int64].
    """
    return _decode_plain_fixed[DType.int64](
        data.unsafe_ptr(), len(data), num_values
    )


@always_inline
def decode_plain_float32(
    data: Span[UInt8, _], num_values: Int
) raises -> PrimitiveArray[DType.float32]:
    """Decode PLAIN-encoded Float32 values. Zero-copy-equivalent on little-endian.

    Args:
        data: The page: packed 4-byte little-endian values. The decode
            reads `num_values * 4` bytes and refuses a shorter page.
        num_values: Number of Float32 values to decode.

    Returns:
        A non-nullable PrimitiveArray[DType.float32].
    """
    return _decode_plain_fixed[DType.float32](
        data.unsafe_ptr(), len(data), num_values
    )


@always_inline
def decode_plain_float64(
    data: Span[UInt8, _], num_values: Int
) raises -> PrimitiveArray[DType.float64]:
    """Decode PLAIN-encoded Float64 values. Zero-copy-equivalent on little-endian.

    Args:
        data: The page: packed 8-byte little-endian values. The decode
            reads `num_values * 8` bytes and refuses a shorter page.
        num_values: Number of Float64 values to decode.

    Returns:
        A non-nullable PrimitiveArray[DType.float64].
    """
    return _decode_plain_fixed[DType.float64](
        data.unsafe_ptr(), len(data), num_values
    )


# =============================================================================
# Zero-copy numeric decoders — alias the input buffer as the Arrow array
# =============================================================================
#
# On little-endian platforms (all modern x86-64 and ARM), PLAIN-encoded
# fixed-width numeric data IS the Arrow in-memory representation. When the
# input buffer is already 64-byte aligned (as SharedAlignedBuffer guarantees),
# we can transfer ownership of the buffer directly to the PrimitiveArray
# without any memcpy.
#
# These functions take OWNERSHIP of the input SharedAlignedBuffer via `var` parameter
# and transfer it into the PrimitiveArray. The buffer pointer does not change.
#
# Requirements:
#   - Little-endian platform (all modern CPUs)
#   - Non-nullable column
#   - PLAIN encoding
#   - Fixed-width type (int32, int64, float32, float64)
# =============================================================================


@always_inline
def _decode_plain_fixed_zero_copy[
    dtype: DType
](var data: SharedAlignedBuffer[HeapRegion], num_values: Int) raises -> PrimitiveArray[dtype]:
    """Zero-copy decode: reuses the input buffer as the Arrow data buffer.

    The input SharedAlignedBuffer IS the output PrimitiveArray's data buffer.
    No memcpy. Ownership transfers from caller to the PrimitiveArray.

    Parameters:
        dtype: The Arrow data type of the output array.

    Args:
        data: The aligned buffer containing PLAIN-encoded data. Ownership
            is transferred -- the caller must not use it after this call.
        num_values: Number of values to decode.

    Returns:
        A non-nullable PrimitiveArray aliasing the input buffer.
    """
    if num_values == 0:
        return PrimitiveArray[dtype].allocate(0)

    comptime elem_size = size_of[Scalar[dtype]]()
    var byte_count = num_values * elem_size

    # ROBUSTNESS. `num_values` is the page/chunk header's DECLARED count and
    # `data` is the page buffer that was actually read; nothing before this
    # related the two. The `set_length` below does not check the capacity:
    # growing the length past the allocation does not fault here, it mints a
    # PrimitiveArray whose `length` LIES, and the out-of-bounds read happens
    # later, in whatever operator consumes the column. The count is compared
    # with `data.len() // elem_size`, so a count whose byte size wraps cannot
    # pass. ONE compare per zero-copy decode, not per value.
    if num_values < 0 or num_values > data.len() // elem_size:
        raise Error(
            "parquet: PLAIN zero-copy decode declares "
            + String(num_values)
            + " values ("
            + String(byte_count)
            + " bytes) but the page buffer holds only "
            + String(data.len())
            + " bytes"
        )

    # Set the length on the buffer so PrimitiveArray knows how many bytes
    # are valid. The buffer already contains the decoded data.
    data.set_length(byte_count)


    # Transfer ownership: data^ moves the buffer into PrimitiveArray.
    # No copy -- the pointer stays the same.
    return PrimitiveArray[dtype](data^, num_values, None, 0, 0)


@always_inline
def decode_plain_int32_zero_copy(
    var data: SharedAlignedBuffer[HeapRegion],
    num_values: Int,
) raises -> PrimitiveArray[DType.int32]:
    """Zero-copy decode: reuses the input buffer as the Arrow data buffer.

    The input SharedAlignedBuffer IS the output PrimitiveArray's data buffer.
    No memcpy. Only works for:
    - Little-endian platforms (all modern CPUs)
    - Non-nullable columns
    - PLAIN encoding
    - Fixed-width types (int32, int64, float32, float64)

    Args:
        data: The aligned buffer with PLAIN-encoded Int32 values. Ownership
            is transferred.
        num_values: Number of Int32 values.

    Returns:
        A non-nullable PrimitiveArray[DType.int32] aliasing the buffer.
    """
    return _decode_plain_fixed_zero_copy[DType.int32](data^, num_values)


@always_inline
def decode_plain_int64_zero_copy(
    var data: SharedAlignedBuffer[HeapRegion],
    num_values: Int,
) raises -> PrimitiveArray[DType.int64]:
    """Zero-copy decode: reuses the input buffer as the Arrow data buffer.

    See decode_plain_int32_zero_copy for details.

    Args:
        data: The aligned buffer with PLAIN-encoded Int64 values. Ownership
            is transferred.
        num_values: Number of Int64 values.

    Returns:
        A non-nullable PrimitiveArray[DType.int64] aliasing the buffer.
    """
    return _decode_plain_fixed_zero_copy[DType.int64](data^, num_values)


@always_inline
def decode_plain_float32_zero_copy(
    var data: SharedAlignedBuffer[HeapRegion],
    num_values: Int,
) raises -> PrimitiveArray[DType.float32]:
    """Zero-copy decode: reuses the input buffer as the Arrow data buffer.

    See decode_plain_int32_zero_copy for details.

    Args:
        data: The aligned buffer with PLAIN-encoded Float32 values. Ownership
            is transferred.
        num_values: Number of Float32 values.

    Returns:
        A non-nullable PrimitiveArray[DType.float32] aliasing the buffer.
    """
    return _decode_plain_fixed_zero_copy[DType.float32](data^, num_values)


@always_inline
def decode_plain_float64_zero_copy(
    var data: SharedAlignedBuffer[HeapRegion],
    num_values: Int,
) raises -> PrimitiveArray[DType.float64]:
    """Zero-copy decode: reuses the input buffer as the Arrow data buffer.

    See decode_plain_int32_zero_copy for details.

    Args:
        data: The aligned buffer with PLAIN-encoded Float64 values. Ownership
            is transferred.
        num_values: Number of Float64 values.

    Returns:
        A non-nullable PrimitiveArray[DType.float64] aliasing the buffer.
    """
    return _decode_plain_fixed_zero_copy[DType.float64](data^, num_values)


# =============================================================================
# Boolean decoder — unpack bit-packed booleans
# =============================================================================


def decode_plain_boolean(
    data: Span[UInt8, _], num_values: Int
) raises -> BooleanArray:
    """Decode PLAIN-encoded boolean values.

    Parquet PLAIN booleans are bit-packed, LSB-first within each byte —
    identical to Arrow's BooleanArray layout. This is a direct memcpy of the
    packed bits.

    Args:
        data: The page: bit-packed booleans (1 bit per value, LSB-first). The
            memcpy below reads `(num_values + 7) / 8` bytes and refuses a
            shorter page.
        num_values: Number of boolean values to decode.

    Returns:
        A non-nullable BooleanArray.

    Raises:
        Error if `num_values` is negative or the page body cannot hold
        `num_values` packed bits.
    """
    if num_values == 0:
        return BooleanArray.allocate(0)
    # A negative count would round to zero bytes below and pass the extent
    # check; it is refused here, before a Bitmap of negative length exists.
    _require_plain_extent("PLAIN BOOLEAN", num_values, 0, len(data))

    var num_bytes = (num_values + 7) >> 3
    # ⭐ THE OVERREAD THAT DOES NOT CRASH. A 2^22-bit decode out of a 4-byte
    # page can return successfully when the allocator has the adjacent heap
    # mapped: it copies that heap and hands it back as a well-formed
    # BooleanArray. On a query engine that adjacent heap can be another
    # tenant's rows. Whether an overread segfaults is a fact about arena
    # layout that day; this gate is about whether the input was ACCEPTED.
    _require_plain_extent("PLAIN BOOLEAN", num_bytes, 1, len(data))

    # Create a Bitmap by allocating and copying the packed bits.
    # Dest via origin-tied `view_range_mut`.
    var bm = Bitmap.create(num_values)
    var bm_view = bm.buffer.view_range_mut(0, num_bytes)
    unsafe_memcpy(
        dest=bm_view._unsafe_ptr(), src=data.unsafe_ptr(), count=num_bytes
    )
    bm.buffer.set_length(num_bytes)


    # Clear trailing bits beyond num_values in the last byte to avoid
    # spurious True values.
    var trailing = num_values & 7
    if trailing > 0:
        var mask = UInt8((1 << trailing) - 1)
        var last = bm.buffer.read_u8_at(num_bytes - 1)
        bm.buffer.write_u8_at(num_bytes - 1, last & mask)

    return BooleanArray.from_bitmap(bm^)


# =============================================================================
# Variable-length byte array / string decoder
# =============================================================================


def decode_plain_byte_array(
    data: Span[UInt8, _], num_values: Int
) raises -> StringArray[HeapRegion]:
    """Decode PLAIN-encoded BYTE_ARRAY values into a StringArray.

    Parquet PLAIN BYTE_ARRAY format: for each value, a 4-byte little-endian
    length followed by that many bytes of data.

    Layout: [len0: u32_le][bytes0][len1: u32_le][bytes1]...

    ROBUSTNESS. The length prefix is read as a SIGNED Int32 straight from
    the page, so an unchecked walk lets the page choose the memcpy count,
    the source offset, the destination offset AND the destination
    allocation size independently — a write-what-where. Every length prefix
    is checked in the walk that reads it, on BOTH arms below.

    TWO ARMS, ONE OUTPUT. This function is the argument gate and the arm
    dispatch; the walk itself is `_decode_plain_ba_fused` (the default) or
    `_decode_plain_ba_two_pass` (`set_plain_ba_fused_enabled(False)`).
    They accept exactly the same pages and return byte-identical buffers —
    the fused arm derives the destination size from the page length instead
    of from a first traversal, so it walks the page once. Each arm's
    docstring carries its own bound proof.

    Args:
        data: The page. Every length prefix and every value body must lie
            within it.
        num_values: Number of byte array values to decode.

    Returns:
        A non-nullable StringArray with offsets and contiguous data.

    Raises:
        Error if `num_values` is negative, if the page is longer than the
        Int32 offsets can address, if a length prefix is negative or if a
        value would extend past the page.
    """
    var data_len = len(data)
    # The offsets are Int32 and every offset is at most the page length, so a
    # page past 2^31 - 1 bytes is refused before either walk writes one that
    # wraps negative. A Parquet page size is an Int32, so no page reaches it.
    if data_len > 2147483647:
        raise Error(
            "parquet: decode_plain_byte_array: a page of "
            + String(data_len)
            + " bytes is past the 2147483647 bytes Int32 offsets can address"
        )
    if num_values < 0:
        raise Error(
            "parquet: decode_plain_byte_array: negative num_values "
            + String(num_values)
        )
    if num_values == 0:
        # Empty array: single zero offset, no data.
        # Write via `set_typed[Int32]`.
        comptime int32_size = size_of[Int32]()
        var offsets_buf = OwnedAlignedBuffer(int32_size)
        offsets_buf.set_typed[Int32](0, Int32(0))
        offsets_buf.set_length(Int64(int32_size))

        var data_buf = OwnedAlignedBuffer(1)
        data_buf.set_length(Int64(0))

        return StringArray(offsets_buf^, data_buf^, None, 0, 0, 0)

    # The arm gate (`set_plain_ba_fused_enabled`, DEFAULT ON). One relaxed
    # atomic load per page; never per value.
    if plain_ba_fused_enabled():
        incr_plain_ba_fused()
        return _decode_plain_ba_fused(data.unsafe_ptr(), data_len, num_values)
    incr_plain_ba_two_pass()
    return _decode_plain_ba_two_pass(data.unsafe_ptr(), data_len, num_values)


# =============================================================================
# THE PER-VALUE REFUSALS OF BOTH BYTE_ARRAY WALKS, AND THE `@no_inline` THAT
# KEEPS THEIR SENTENCES OUT OF THE PER-VALUE LOOP.
# =============================================================================
#
# ★ WHY THESE EXIST. Both walks below refuse a malformed page from INSIDE
#   `for i in range(num_values)` — once per VALUE. Every refusal spelled at the
#   call site costs, in the loop body, whether or not the branch is ever taken:
#   a `String(Int)` itoa per interpolated number (three or four of them), a
#   `String::_add` per join, an sret return slot, an atomic String-refcount
#   destructor (`lock decq` + `KGEN_CompilerRT_AlignedFree`) and an opaque
#   `StackTrace::collect_if_enabled` call. The compiler cannot hoist any of it
#   out, because it cannot prove the branch never fires.
#
# ⚠ MEASURED, NOT REASONED ABOUT. In an x86-64 disassembly of an optimized
#   build, `decode_plain_byte_array` carried 532 never-taken raise-path
#   instructions INSIDE its hot loop's own address range out of 1,775 — 30.0%
#   — at ZERO perf samples.
#
# ★ THE PREDICATE STAYS AT THE CALL SITE. Each `if` below is two compares on
#   values already in registers, and that is exactly where a bounds check
#   belongs — the walk's whole safety argument (see `decode_plain_byte_array`'s
#   docstring) rests on it. ONLY THE SENTENCE MOVES.
#
# ⛔ DO NOT INLINE THESE BACK, AND DO NOT REWORD THEM. The messages are part of
#   the contract: `test_plain_ba_fused_byte_equiv` asserts on the TEXT (a
#   mutation that drops a bound still raises, one value later, so "it raised"
#   is not a falsifier), and `test_plain_ba_raise_outlined` asserts every one
#   of these sentences BYTE FOR BYTE against a copy composed in the test.
#
# ⚠ TWO OF THE FOUR ARE SHARED BY BOTH ARMS ON PURPOSE. The truncated-prefix
#   and negative-length refusals were byte-identical copies in the two walks;
#   they are now one function each, which is also what makes the arms'
#   byte-equivalence claim checkable rather than a coincidence of two literals.
#   The third refusal is NOT shared: the two-pass arm proves
#   `str_len <= data_len - pos` and the fused arm the strictly stronger
#   prefix-reserve bound, and their sentences differ because the BOUNDS differ.
#   Collapsing them would erase the distinction a test of those bounds draws.
# =============================================================================


@no_inline
def _raise_plain_ba_truncated_prefix(
    i: Int, pos: Int, data_len: Int
) raises:
    """The page ends before value `i`'s 4-byte length prefix. Shared by BOTH
    walks — the bound is the same on each."""
    raise Error(
        "parquet: truncated PLAIN BYTE_ARRAY: length prefix for"
        " value "
        + String(i)
        + " starts at byte "
        + String(pos)
        + " but the page holds only "
        + String(data_len)
        + " bytes"
    )


@no_inline
def _raise_plain_ba_negative_length(i: Int, str_len: Int) raises:
    """Value `i`'s length prefix is negative (it is read as a SIGNED Int32
    straight from the page). Shared by BOTH walks."""
    raise Error(
        "parquet: corrupt PLAIN BYTE_ARRAY: value "
        + String(i)
        + " declares a negative length "
        + String(str_len)
    )


@no_inline
def _raise_plain_ba_overruns_page(i: Int, str_len: Int, remaining: Int) raises:
    """TWO-PASS ARM ONLY: value `i`'s body runs past the end of the page.
    `remaining` is `data_len - pos`, the bytes left after its own prefix."""
    raise Error(
        "parquet: corrupt PLAIN BYTE_ARRAY: value "
        + String(i)
        + " declares length "
        + String(str_len)
        + " but only "
        + String(remaining)
        + " bytes remain in the page"
    )


@no_inline
def _raise_plain_ba_overruns_reserve(
    i: Int, str_len: Int, remaining: Int, later_values: Int
) raises:
    """FUSED ARM ONLY: value `i`'s body runs past the end of the page ONCE the
    later values' length prefixes are reserved — the strictly stronger bound
    the exact-capacity allocation needs. `remaining` is
    `data_len - pos - prefix_reserve` and `later_values` is
    `num_values - 1 - i`."""
    raise Error(
        "parquet: corrupt PLAIN BYTE_ARRAY: value "
        + String(i)
        + " declares length "
        + String(str_len)
        + " but only "
        + String(remaining)
        + " bytes remain in the page once the "
        + String(later_values)
        + " later length prefixes are reserved"
    )


def _decode_plain_ba_two_pass[
    o: Origin
](
    data: UnsafePointer[UInt8, o], data_len: Int, num_values: Int
) raises -> StringArray[HeapRegion]:
    """TWO-PASS arm: walk the page TWICE — pass 1 validates + sizes, pass 2
    copies.

    ⛔ THE CONTROL ARM OF THE A/B. An A/B whose OFF arm has drifted measures
    two changes. Do not "tidy" it, and in particular do NOT add the fused
    arm's prefix-reserve bound here — that bound is what makes the fused arm's
    exact allocation safe, and adding it to the control changes the control.

    WHY TWO PASSES. `total_data_bytes` — the destination allocation size — is
    not known until every length prefix has been read, so pass 1 must complete
    before the data buffer can exist. That is the ONLY reason: the second pass
    buys no lifetime, no alignment and no ownership. `_decode_plain_ba_fused`
    removes it by deriving an EXACT bound from `data_len` instead.

    Args:
        data: Pointer to the PLAIN-encoded byte array data.
        data_len: Number of readable bytes at `data`.
        num_values: Number of byte array values to decode. Must be > 0.

    Returns:
        A non-nullable StringArray with offsets and contiguous data.

    Raises:
        Error if a length prefix is negative or a value would extend past
        `data_len`.
    """
    # --- PASS 1: scan lengths, validate, compute offsets ---
    # Offsets writes via `set_typed[Int32]` on the buffer.
    comptime int32_size = size_of[Int32]()
    # The walk below writes offset `i + 1` only after value `i`'s prefix fit,
    # so it writes at most `data_len // 4` offsets past the first: the buffer
    # is sized by that, not by the header's count, whose `(num_values + 1) *
    # 4` wraps (2^62 values is a 4-byte buffer). The walk's own refusal of a
    # page too short for the count is unchanged.
    var offsets_buf = OwnedAlignedBuffer(
        (min(num_values, data_len >> 2) + 1) * int32_size
    )
    offsets_buf.set_typed[Int32](0, Int32(0))

    # NOT-VECTORIZABLE: Offset accumulation is a prefix sum (serial dependency).
    # String lengths are interleaved with data, so even the read is non-contiguous.
    var pos = 0
    var total_data_bytes = 0
    for i in range(num_values):
        # ROBUSTNESS: two compares per value against values already in
        # registers (`pos` is the induction variable, `str_len` is the
        # word we just had to load anyway). This is the ONLY place the
        # walk can be made safe — the second pass replays the same
        # lengths, so it inherits this pass's proof.
        if pos + 4 > data_len:
            _raise_plain_ba_truncated_prefix(i, pos, data_len)
        var str_len = Int((data + pos).bitcast[Int32]()[])
        pos += 4
        if str_len < 0:
            _raise_plain_ba_negative_length(i, str_len)
        if str_len > data_len - pos:
            _raise_plain_ba_overruns_page(i, str_len, data_len - pos)
        total_data_bytes += str_len
        offsets_buf.set_typed[Int32](i + 1, Int32(total_data_bytes))
        pos += str_len

    offsets_buf.set_length(Int64((num_values + 1) * int32_size))


    # Second pass: copy data. Since strings are interspersed with 4-byte
    # lengths in the source, we memcpy each string individually.
    # Dest pointer obtained via origin-tied `view_mut`; the
    # view holds the borrow across the per-string memcpy loop.
    var data_buf = OwnedAlignedBuffer(max(total_data_bytes, 1))
    var data_dst_view = data_buf.view_mut()
    var data_dst_ptr = data_dst_view._unsafe_ptr()
    var dest_pos = 0
    var src_pos = 0
    for _ in range(num_values):
        var str_len = Int((data + src_pos).bitcast[Int32]()[])
        src_pos += 4
        if str_len > 0:
            # `fast_copy_bytes`, NOT stdlib `memcpy`: the per-string byte
            # tail (see the import). In a variable-width gather of the same
            # shape it measured 2.86 -> 0.75 instructions per byte.
            #
            # Non-overlap holds by construction: the destination is a
            # freshly-allocated buffer sized to the pass-1 total; the source is
            # the read-only page. Both lengths were proven in-bounds by pass 1,
            # which this pass replays exactly. No arm of `fast_copy_bytes` ever
            # touches a byte outside [0, str_len) — the trailing block is
            # anchored at `n - width`, never at a rounded-UP multiple — so this
            # cannot over-read the final value of a page.
            fast_copy_bytes(
                Span[UInt8, data_dst_view.origin](
                    unsafe_ptr=data_dst_ptr + dest_pos, length=str_len
                ),
                Span[UInt8, o](unsafe_ptr=data + src_pos, length=str_len),
            )
        dest_pos += str_len
        src_pos += str_len

    data_buf.set_length(Int64(total_data_bytes))


    return StringArray(
        offsets_buf^, data_buf^, None, num_values, total_data_bytes, 0
    )


def _decode_plain_ba_fused[
    o: Origin
](
    data: UnsafePointer[UInt8, o], data_len: Int, num_values: Int
) raises -> StringArray[HeapRegion]:
    """FUSED arm: ONE walk that validates, writes offsets AND copies bodies.

    Byte-for-byte the same `StringArray` as `_decode_plain_ba_two_pass`, for
    exactly the same set of accepted pages, with the second traversal of the
    page — and the `num_values` redundant re-loads of the length prefixes it
    performs — deleted.

    ⭐ THE ALLOCATION BOUND. A PLAIN BYTE_ARRAY values section is
    `[u32 len][body]` repeated, so any page the walk completes satisfies
    `4*num_values + total_data_bytes <= data_len`. Hence
    `cap = data_len - 4*num_values` is an upper bound on `total_data_bytes`,
    and for a conforming exactly-packed section it is EQUAL to it — which is
    why this deletion adds no allocation. `add_plain_ba_slack` reports the
    difference in bytes so that claim is a reading, not an argument.

    ⚠ THE PREFIX RESERVE IS LOAD-BEARING, AND IT IS THE ONE THING THIS ARM
    ADDS. The legacy per-value check proves only `str_len <= data_len - pos`,
    which for an EARLY value permits `dest_pos + str_len` to reach
    `data_len - 4` — past `cap` whenever `num_values > 1`. Witness:
    `data_len = 104, num_values = 2`, value 0 declaring length 100. The legacy
    walk accepts value 0 and raises only on value 1; a fused walk with the
    legacy bound would have written 100 bytes into a 96-byte buffer FIRST.
    Reserving the later values' prefixes — `str_len <= data_len - pos -
    4*(n-1-i)` — closes that, and provably rejects nothing the legacy arm
    accepts: a page the legacy walk completes has `4*n + total <= data_len`,
    so for every `i`, `pos_i + str_len_i + 4*(n-1-i) <= 4*n + total <=
    data_len`. The two arms therefore accept exactly the same pages; only the
    error TEXT of a rejected page differs.

    ⚠ THE SLACK TAIL IS ZEROED, not left as fresh-allocation garbage.
    `OwnedAlignedBuffer` zeroes only its 64-byte SIMD pad, so a `cap > total`
    page would otherwise hand a `StringArray` whose bytes `[total, cap)` are
    uninitialised heap. No Arrow consumer addresses them (values are reached
    through the offsets), but "no consumer reads it" is a claim about every
    present and future consumer and this is a memset of, measurably, zero
    bytes on a conforming page.

    Args:
        data: Pointer to the PLAIN-encoded byte array data.
        data_len: Number of readable bytes at `data`.
        num_values: Number of byte array values to decode. Must be > 0.

    Returns:
        A non-nullable StringArray with offsets and contiguous data.

    Raises:
        Error if the page cannot hold one length prefix per declared value, if
        a length prefix is negative, or if a value would extend past the bytes
        left once the later values' length prefixes are reserved.
    """
    comptime int32_size = size_of[Int32]()

    # The bound has to hold BEFORE the walk, because the walk writes into the
    # buffer it sizes. `num_values > data_len // 4` is exactly
    # `4*num_values > data_len`, and it also keeps `4 * num_values` from
    # overflowing on a header-supplied `num_values`. It rejects only pages the
    # legacy walk would also reject (that walk needs 4 bytes per value too),
    # so acceptance is unchanged.
    if num_values > (data_len >> 2):
        raise Error(
            "parquet: truncated PLAIN BYTE_ARRAY: the page holds "
            + String(data_len)
            + " bytes, too few for the 4-byte length prefix of each of the "
            + String(num_values)
            + " declared values"
        )
    var cap = data_len - 4 * num_values

    var offsets_buf = OwnedAlignedBuffer((num_values + 1) * int32_size)
    offsets_buf.set_typed[Int32](0, Int32(0))

    # Dest pointer obtained via origin-tied `view_mut`; the view
    # holds the borrow across the whole walk.
    var data_buf = OwnedAlignedBuffer(max(cap, 1))
    var data_dst_view = data_buf.view_mut()
    var data_dst_ptr = data_dst_view._unsafe_ptr()

    # NOT-VECTORIZABLE: offset accumulation is a prefix sum (serial
    # dependency) and the lengths are interleaved with the bodies, so even the
    # read is non-contiguous.
    var pos = 0
    var total_data_bytes = 0
    # Bytes the not-yet-visited values' length prefixes must still fit in.
    var prefix_reserve = 4 * (num_values - 1)
    for i in range(num_values):
        if pos + 4 > data_len:
            _raise_plain_ba_truncated_prefix(i, pos, data_len)  # cov: unreachable the up-front check and the prefix reserve leave 4 bytes for every prefix
        var str_len = Int((data + pos).bitcast[Int32]()[])
        pos += 4
        if str_len < 0:
            _raise_plain_ba_negative_length(i, str_len)
        if str_len > data_len - pos - prefix_reserve:
            _raise_plain_ba_overruns_reserve(
                i,
                str_len,
                data_len - pos - prefix_reserve,
                num_values - 1 - i,
            )
        if str_len > 0:
            # `fast_copy_bytes`, NOT stdlib `memcpy` — see
            # `_decode_plain_ba_two_pass`. Same
            # copy, same non-overlap argument: the destination is a
            # freshly-allocated buffer and the source is the read-only page.
            # `dest_pos + str_len <= cap` is the prefix-reserve invariant
            # proved in this function's docstring.
            fast_copy_bytes(
                Span[UInt8, data_dst_view.origin](
                    unsafe_ptr=data_dst_ptr + total_data_bytes, length=str_len
                ),
                Span[UInt8, o](unsafe_ptr=data + pos, length=str_len),
            )
        pos += str_len
        total_data_bytes += str_len
        offsets_buf.set_typed[Int32](i + 1, Int32(total_data_bytes))
        prefix_reserve -= 4

    offsets_buf.set_length(Int64((num_values + 1) * int32_size))

    if cap > total_data_bytes:
        var slack = cap - total_data_bytes
        add_plain_ba_slack(slack)
        # SAFETY: `data_dst_ptr` is the origin-tied interior pointer of
        # `data_buf`, whose usable extent is `max(cap, 1) >= cap`, and
        # `total_data_bytes + slack == cap`. `_ = data_dst_view` below keeps
        # the borrow live across the store.
        unsafe_memset(data_dst_ptr + total_data_bytes, UInt8(0), slack)
    _ = data_dst_view

    data_buf.set_length(Int64(total_data_bytes))
    # ⭐ READ BACK FROM THE BUFFER, NOT FROM `cap`. A counter derived from the
    # bound is a MODEL of the allocation and cannot see a mutation that changes
    # the allocation alone (it leaves "allocate `data_len` instead of the
    # exact bound" GREEN). `capacity()` is the padded byte count the
    # allocator actually handed out.
    add_plain_ba_fused_alloc(data_buf.capacity())

    return StringArray(
        offsets_buf^, data_buf^, None, num_values, total_data_bytes, 0
    )


# =============================================================================
# INT96 timestamp decode — legacy Spark/Hive format
# =============================================================================
#
# INT96 stores timestamps as 12 bytes per value:
#   bytes [0:8]  — nanos within the Julian day (Int64 LE)
#   bytes [8:12] — Julian day number (Int32 LE)
#
# Conversion to nanoseconds since the Unix epoch:
#   unix_day = julian_day - 2440588
#   result_ns = unix_day * 86_400_000_000_000 + nanos_within_day
# =============================================================================


def decode_plain_int96_to_int64(
    data: Span[UInt8, _],
    num_values: Int,
) raises -> PrimitiveArray[DType.int64]:
    """Decode INT96 PLAIN data to Int64 nanoseconds since Unix epoch.

    Each INT96 value is 12 bytes: 8 bytes LE nanos-within-day followed by
    4 bytes LE Julian day number. Converted to nanoseconds since the Unix epoch.

    Args:
        data: The page: raw INT96 PLAIN-encoded bytes. The loop below reads
            `num_values * 12` bytes by raw offset and refuses a shorter page.
        num_values: Number of INT96 values to decode.

    Returns:
        A PrimitiveArray[DType.int64] with nanosecond timestamps.

    Raises:
        Error if the page body cannot hold `num_values` INT96 values.
    """
    if num_values == 0:
        return PrimitiveArray[DType.int64].allocate(0)

    # The "num_values * 12 bytes" in the Args block above is enforced here.
    _require_plain_extent("PLAIN INT96", num_values, 12, len(data))
    var src = data.unsafe_ptr()

    # Julian day of the Unix epoch.
    comptime JULIAN_UNIX_EPOCH = Int64(2440588)
    # Nanoseconds per day: 86400 * 1_000_000_000.
    comptime NANOS_PER_DAY = Int64(86400000000000)

    comptime int64_size = size_of[Scalar[DType.int64]]()
    var byte_count = num_values * int64_size
    var buf = OwnedAlignedBuffer(byte_count)

    # Per-element writes via `set_typed[Int64]` on the buffer.
    for i in range(num_values):
        var offset = i * 12
        # Read nanos_within_day as Int64 LE from bytes [0:8].
        var nanos_within_day = (src + offset).bitcast[Int64]()[]
        # Read julian_day as Int32 LE from bytes [8:12].
        var julian_day = Int64((src + offset + 8).bitcast[Int32]()[])
        # Convert to nanoseconds since Unix epoch.
        var result_ns = (julian_day - JULIAN_UNIX_EPOCH) * NANOS_PER_DAY + nanos_within_day
        buf.set_typed[Int64](i, result_ns)

    buf.set_length(Int64(byte_count))

    return PrimitiveArray[DType.int64](buf^, num_values, None, 0, 0)

# =============================================================================
# DELTA_LENGTH_BYTE_ARRAY / DELTA_BYTE_ARRAY decoders
# =============================================================================
#
# Kept apart from `delta.mojo`, which the RESUMABLE DELTA_BINARY_PACKED path
# (`DeltaDecoder.begin_resumable` + `resume_fill_*`) would otherwise push past
# the 1000-line ceiling. The two functions stay together because
# DELTA_BYTE_ARRAY is defined in terms of
# DELTA_LENGTH_BYTE_ARRAY, and both are pure BYTE_ARRAY-side consumers of the
# integer `DeltaDecoder` that remains in `delta.mojo`.
#
# Format (DELTA_LENGTH_BYTE_ARRAY):
#   [DELTA_BINARY_PACKED encoded lengths as i32]
#   [concatenated byte data]
#
# Format (DELTA_BYTE_ARRAY):
#   [DELTA_BINARY_PACKED prefix_lengths]
#   [DELTA_LENGTH_BYTE_ARRAY suffixes]
#   Each value = prev_value[:prefix_len] + suffix
#
# Used for sorted/similar strings (URLs, dict keys) by Spark, Impala, etc.
#
# Reference: parquet-format Encodings.md, DELTA_LENGTH_BYTE_ARRAY (6) /
# DELTA_BYTE_ARRAY (7).
# =============================================================================

from std.sys import size_of

from komira_arrow.string_array import StringArray
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.heap_region import HeapRegion

from .delta import DeltaDecoder, delta_binary_packed_byte_count


# =============================================================================
# DELTA_LENGTH_BYTE_ARRAY decoder
# =============================================================================


def decode_delta_length_byte_array[
    _mut: Bool, o: Origin[mut=_mut], //
](
    data: Span[UInt8, o],
    num_values: Int,
) raises -> StringArray[HeapRegion]:
    """Decode DELTA_LENGTH_BYTE_ARRAY encoded byte arrays into a StringArray.

    Format:
        [DELTA_BINARY_PACKED encoded lengths (as i32)]
        [concatenated byte data]

    The lengths are first decoded using DELTA_BINARY_PACKED, then raw bytes
    are read sequentially using those lengths.

    Args:
        data: The encoded byte stream.
        num_values: Number of byte array values to decode.

    Returns:
        A non-nullable StringArray with the decoded byte arrays.

    Raises:
        Error if the encoded data is malformed or truncated.
    """
    from std.memory import unsafe_memcpy, unsafe_memset

    var data_len = len(data)
    if num_values == 0:
        # Write via `set_typed[Int32]`.
        comptime int32_size = size_of[Int32]()
        var offsets_buf = OwnedAlignedBuffer(int32_size)
        offsets_buf.set_typed[Int32](0, Int32(0))
        offsets_buf.set_length(Int64(int32_size))

        var data_buf = OwnedAlignedBuffer(1)
        data_buf.set_length(Int64(0))

        return StringArray(offsets_buf^, data_buf^, None, 0, 0, 0)
    _require_value_count(num_values, "DELTA_LENGTH_BYTE_ARRAY")

    # Step 1: Decode lengths via DELTA_BINARY_PACKED.
    var lengths_buf = List[Int64](capacity=num_values)
    lengths_buf.resize(num_values, Int64(0))
    var dec = DeltaDecoder(data)
    var decoded = dec.decode_int64(num_values, Span(lengths_buf))

    # Calculate how many bytes the delta-encoded lengths consumed.
    var consumed_bytes = delta_binary_packed_byte_count(data, num_values)

    # Step 2: Build offsets array and compute total data length.
    # Writes via `set_typed[Int32]` on the buffer.
    comptime int32_size = size_of[Int32]()
    var offsets_buf = OwnedAlignedBuffer((num_values + 1) * int32_size)
    offsets_buf.set_typed[Int32](0, Int32(0))

    # =====================================================================
    # The length bound.
    #
    # THE LENGTHS ARE ATTACKER BYTES AND NOTHING BOUNDED THEM. Every `l`
    # below is a zigzag-decoded Int64 lifted straight out of the page's
    # DELTA_BINARY_PACKED header — a 4-byte hostile page whose
    # `miniblock_count` is 0 makes `decode_int64` return exactly one value,
    # `first_value`, chosen freely by the file. The old loop then did
    # `total_data_len += l` with NO check and used the sum three ways, each
    # of which trusts it completely:
    #
    #   * `Int32(total_data_len)` — a SILENT narrowing cast into the
    #     offsets array. 2^31 becomes a negative offset that every
    #     downstream StringArray consumer indexes with.
    #   * `OwnedAlignedBuffer(max(total_data_len, 1))` — the destination
    #     allocation is sized from it. A 10-byte page can demand gigabytes.
    #   * `data_buf.set_length(Int64(total_data_len))` — a NEGATIVE
    #     `first_value` (e.g. -4096) yields a 1-byte allocation carrying a
    #     declared length of -4096 and offsets [0, -4096]; `available` goes
    #     negative so both the memcpy and the zero-fill are skipped, and
    #     the array is returned looking well-formed.
    #
    # WHERE THE CHECK GOES AND WHY IT IS PER-VALUE. Each length is an
    # independent hostile value, so there is no single header field to
    # validate instead — but the check is ONE compare against a
    # pre-computed remainder, in a loop that already does a load, an add
    # and an Int32 store per value. `cap` folds the two ceilings (the
    # page's own byte count, and the Int32 offset ceiling the offsets
    # array is made of) so the loop body itself stays one comparison.
    #
    # ⚠ THE BOUND IS THE WHOLE PAGE, NOT `data_len - consumed_bytes`, on
    # purpose. `delta_binary_packed_byte_count` is a SECOND, independent
    # re-parse of the same header, and the pre-existing contract when it
    # disagrees with the decoder is to zero-fill the shortfall (see
    # `available` below) — not to reject the file. Bounding by the page
    # keeps that tolerance intact while still making the sum non-negative,
    # smaller than the bytes that exist, and exactly representable as the
    # Int32 it is about to be stored as. Every one of those is what the
    # three consumers below already assumed.
    # =====================================================================
    comptime _INT32_CEIL = 2147483647
    var body_avail = max(data_len - consumed_bytes, 0)
    var cap = min(data_len, _INT32_CEIL)

    var total_data_len = 0
    var bad_index = -1
    var bad_length = 0
    for i in range(decoded):
        var l = Int(lengths_buf[i])
        if l < 0 or l > cap - total_data_len:
            bad_index = i
            bad_length = l
            break
        total_data_len += l
        offsets_buf.set_typed[Int32](i + 1, Int32(total_data_len))

    if bad_index >= 0:
        var remaining = cap - total_data_len
        raise Error(
            "parquet: corrupt DELTA_LENGTH_BYTE_ARRAY page: value "
            + String(bad_index)
            + " declares a length of "
            + String(bad_length)
            + " but only "
            + String(remaining)
            + " byte(s) of the "
            + String(data_len)
            + "-byte page remain ("
            + String(body_avail)
            + " after its length block; bound also capped at the Int32"
            " offset ceiling)"
        )

    # Fill remaining offsets if decoded < num_values (shouldn't happen).
    for i in range(decoded, num_values):
        offsets_buf.set_typed[Int32](i + 1, Int32(total_data_len))

    offsets_buf.set_length(Int64((num_values + 1) * int32_size))

    # Step 3: Copy contiguous byte data.
    # Dest pointer obtained via origin-tied `view_mut` so the
    # subsequent memcpy + memset both go through the same borrow.
    # SAFETY: `consumed_bytes <= data_len`, and only `available <= data_len -
    # consumed_bytes` bytes are read from `data_start`.
    var data_start = data.unsafe_ptr() + consumed_bytes
    var available = min(data_len - consumed_bytes, total_data_len)
    var data_buf = OwnedAlignedBuffer(max(total_data_len, 1))
    var data_dst_view = data_buf.view_mut()
    var data_dst_ptr = data_dst_view._unsafe_ptr()
    if available > 0:
        unsafe_memcpy(dest=data_dst_ptr, src=data_start, count=available)
    # Zero-fill if data is short (shouldn't happen with valid files).
    if available < total_data_len:
        unsafe_memset(data_dst_ptr + available, 0, total_data_len - available)
    data_buf.set_length(Int64(total_data_len))


    return StringArray(
        offsets_buf^,
        data_buf^,
        None,
        num_values,
        total_data_len,
        0,
    )


# =============================================================================
# DELTA_BYTE_ARRAY decoder
# =============================================================================


comptime _DBA_INT32_CEIL = 2147483647
"""The largest end offset a DELTA_BYTE_ARRAY StringArray can hold (Int32)."""


def decode_delta_byte_array[
    _mut: Bool, o: Origin[mut=_mut], //
](
    data: Span[UInt8, o],
    num_values: Int,
) raises -> StringArray[HeapRegion]:
    """Decode DELTA_BYTE_ARRAY encoded byte arrays into a StringArray.

    Format:
        [DELTA_BINARY_PACKED prefix_lengths]
        [DELTA_LENGTH_BYTE_ARRAY suffixes]

    Each value is reconstructed incrementally:
        value[i] = value[i-1][:prefix_len[i]] + suffix[i]

    This encoding is efficient for sorted strings with shared prefixes
    (dictionary keys, URLs, file paths).

    Args:
        data: The encoded byte stream.
        num_values: Number of byte array values to decode.

    Returns:
        A non-nullable StringArray with the decoded byte arrays.

    Raises:
        Error if the encoded data is malformed or truncated, a prefix
        length is negative, or the values reconstruct to more than the
        Int32 offset ceiling (2147483647 bytes).
    """
    from std.memory import alloc, unsafe_memcpy

    if num_values == 0:
        # Write via `set_typed[Int32]`.
        comptime int32_size = size_of[Int32]()
        var offsets_buf = OwnedAlignedBuffer(int32_size)
        offsets_buf.set_typed[Int32](0, Int32(0))
        offsets_buf.set_length(Int64(int32_size))

        var data_buf = OwnedAlignedBuffer(1)
        data_buf.set_length(Int64(0))

        return StringArray(offsets_buf^, data_buf^, None, 0, 0, 0)
    _require_value_count(num_values, "DELTA_BYTE_ARRAY")

    # Step 1: Decode prefix lengths via DELTA_BINARY_PACKED.
    var prefix_buf = List[Int64](capacity=num_values)
    prefix_buf.resize(num_values, Int64(0))
    var dec = DeltaDecoder(data)
    var prefix_decoded = dec.decode_int64(num_values, Span(prefix_buf))

    var prefix_consumed = delta_binary_packed_byte_count(data, num_values)

    # Step 2: Decode suffixes via DELTA_LENGTH_BYTE_ARRAY.
    var suffix_arr = decode_delta_length_byte_array(
        data[prefix_consumed:], num_values
    )

    # Step 3: Reconstruct values using prefix from previous value + suffix.
    # First pass: compute total output data length.
    # Suffix offsets/data via origin-tied views.
    var suffix_offsets_view = suffix_arr.offsets.view_ro()
    var suffix_data_view = suffix_arr.data.view_ro()
    var total_out_len = 0
    var prev_len = 0
    for i in range(num_values):
        var prefix_len = Int(prefix_buf[i]) if i < prefix_decoded else 0
        # A prefix length is a count of bytes shared with the previous value:
        # a negative one would place the suffix before the value's start, so
        # it is refused here, before anything is written.
        if prefix_len < 0:
            raise Error(
                "parquet: corrupt DELTA_BYTE_ARRAY page: value "
                + String(i)
                + " declares a negative prefix length "
                + String(prefix_len)
            )
        # Clamp prefix_len to previous value length.
        if prefix_len > prev_len:
            prefix_len = prev_len
        var suffix_start = Int(suffix_offsets_view.get_typed[Int32](i))
        var suffix_end = Int(suffix_offsets_view.get_typed[Int32](i + 1))
        var suffix_len = suffix_end - suffix_start
        var val_len = prefix_len + suffix_len
        # The reconstructed values are bounded by nothing on the page: each
        # can repeat the whole previous value as its prefix, so a page of N
        # values over an L-byte suffix rebuilds N * L bytes. Their running
        # end is stored as an Int32 offset, so a total past the Int32
        # ceiling is refused here, before the allocation sized from it and
        # before an offset is narrowed. `val_len` is >= 0: the prefix was
        # checked above and the suffix offsets are a running sum.
        if val_len > _DBA_INT32_CEIL - total_out_len:
            raise Error(
                "parquet: corrupt DELTA_BYTE_ARRAY page: value "
                + String(i)
                + " takes the reconstructed values past "
                + String(_DBA_INT32_CEIL)
                + " bytes, the Int32 offset ceiling"
            )
        total_out_len += val_len
        prev_len = val_len

    # Second pass: build offsets and data.
    # Offsets writes via `set_typed[Int32]`; data dest pointer
    # via `view_mut` so memcpy + read-back share a single borrow.
    comptime int32_size = size_of[Int32]()
    var offsets_buf = OwnedAlignedBuffer((num_values + 1) * int32_size)
    offsets_buf.set_typed[Int32](0, Int32(0))

    var data_buf = OwnedAlignedBuffer(max(total_out_len, 1))
    var data_dst_view = data_buf.view_mut()
    var data_dst_ptr = data_dst_view._unsafe_ptr()
    var suffix_data_ptr = suffix_data_view._unsafe_ptr()
    var out_pos = 0

    # SAFETY: prev_value tracks the most recently reconstructed string
    # for prefix reuse. We use a UnsafePointer-based growable buffer to
    # avoid List[UInt8] Copyable constraint overhead. Freed at end.
    var prev_value_cap = 256
    var prev_value = alloc[UInt8](prev_value_cap)
    var prev_value_len = 0

    for i in range(num_values):
        var prefix_len = Int(prefix_buf[i]) if i < prefix_decoded else 0
        # Clamp prefix_len to previous value length.
        if prefix_len > prev_value_len:
            prefix_len = prev_value_len

        var suffix_start = Int(suffix_offsets_view.get_typed[Int32](i))
        var suffix_end = Int(suffix_offsets_view.get_typed[Int32](i + 1))
        var suffix_len = suffix_end - suffix_start
        var val_len = prefix_len + suffix_len

        # Copy prefix from prev_value into output.
        if prefix_len > 0:
            unsafe_memcpy(
                dest=data_dst_ptr + out_pos,
                src=prev_value,
                count=prefix_len,
            )

        # Copy suffix from suffix_arr.data into output.
        if suffix_len > 0:
            unsafe_memcpy(
                dest=data_dst_ptr + out_pos + prefix_len,
                src=suffix_data_ptr + suffix_start,
                count=suffix_len,
            )

        # Update prev_value for next iteration.
        if val_len > prev_value_cap:
            prev_value.free()
            prev_value_cap = val_len * 2
            prev_value = alloc[UInt8](prev_value_cap)
        # Copy the reconstructed value into prev_value.
        if val_len > 0:
            unsafe_memcpy(
                dest=prev_value,
                src=data_dst_ptr + out_pos,
                count=val_len,
            )
        prev_value_len = val_len

        out_pos += val_len
        offsets_buf.set_typed[Int32](i + 1, Int32(out_pos))

    offsets_buf.set_length(Int64((num_values + 1) * int32_size))

    data_buf.set_length(Int64(total_out_len))


    prev_value.free()
    # keepalive: suffix_arr must stay alive until after we've read its data.
    _ = suffix_arr

    return StringArray(
        offsets_buf^,
        data_buf^,
        None,
        num_values,
        total_out_len,
        0,
    )


def _require_value_count(num_values: Int, encoding: StaticString) raises:
    """Refuse a negative value count, which a page header can carry."""
    if num_values < 0:
        raise Error(
            "parquet: corrupt "
            + String(encoding)
            + " page: negative value count "
            + String(num_values)
        )

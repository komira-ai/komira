# =============================================================================
# ocf_block_scan.mojo — OCF block-boundary discovery via sync-marker walk.
# =============================================================================
#
# OCF block byte layout (Avro spec "Object Container Files"):
#
#   block  := long object_count                // # records, zigzag varint
#             long byte_count                  // post-compression payload size
#             bytes payload                    // (de)compressed records
#             sync_marker                      // same 16 bytes as header sync
#
# This module discovers block boundaries so the decoders (scalar decode;
# block-parallel decode) can carve work units. Two strategies:
#
#   1. CHAINED-WALK (primary, all file sizes): read each block header
#      (object_count varint + byte_count varint), skip `byte_count` payload
#      bytes, assert the 16-byte sync marker matches the header's marker,
#      advance. Deterministic + exact for well-formed files. O(num_blocks),
#      independent of file size.
#
#   2. SIMD memmem-scan (recovery/resync): `find_sync_marker_from` finds the
#      next sync marker with a SIMD memmem when the chained walk fails
#      (corrupt/truncated block), or for parallel range partitioning without
#      a full forward walk.
#
# Encapsulation: blocks are discovered out of a borrowed `Span[UInt8]` view;
# the result is an owned List[OcfBlock] of pointer-free (offset, len, count)
# records.
# =============================================================================

from komira_core.simd.byte_class.byte_memmem import find_needle

from .ocf_header import OcfHeader, OCF_SYNC_LEN, decode_ocf_header, VarintRead


# =============================================================================
# OcfBlock — one discovered block's coordinates (pointer-free).
# =============================================================================

@fieldwise_init
struct OcfBlock(Copyable, Movable):
    # Number of records in the block (decoded object_count).
    var object_count: Int64
    # Byte offset of the payload (post the two block-header varints).
    var payload_offset: Int
    # Payload byte length (decoded byte_count; post-compression size).
    var payload_len: Int


# =============================================================================
# Block scan (chained-walk, primary path).
# =============================================================================

def scan_ocf_blocks(bytes: Span[UInt8, _]) raises -> List[OcfBlock]:
    """Decode the header then chained-walk every block to discover boundaries.

    Returns the list of blocks in file order. Raises on a sync-marker
    mismatch (corrupt/truncated block) or a malformed block header.
    """
    var header = decode_ocf_header(bytes)
    return scan_ocf_blocks_after_header(bytes, header)


def scan_ocf_blocks_after_header(
    bytes: Span[UInt8, _], header: OcfHeader
) raises -> List[OcfBlock]:
    """Chained-walk blocks starting at `header.header_len`, validating each
    block's trailing sync marker against the header's marker."""
    var blocks = List[OcfBlock]()
    var pos = header.header_len
    var n = len(bytes)

    while pos < n:
        # ---- object_count (zigzag varint long) ----
        var oc_read = _read_long(bytes, pos)
        var object_count = oc_read.value
        pos = oc_read.new_pos
        # ---- byte_count (zigzag varint long) ----
        var bc_read = _read_long(bytes, pos)
        var byte_count = Int(bc_read.value)
        pos = bc_read.new_pos
        # UNTRUSTED INPUT. `object_count` is carried on the OcfBlock and becomes an
        # ALLOCATION SIZE downstream (`_I64Acc.reserve(cur + object_count)`,
        # and the comptime path's `total_rows` sum), where an unchecked
        # `length * elem_size` multiply can wrap a 2^61 request into a 64-byte
        # buffer. A positive upper bound cannot be decided here — the payload
        # is still compressed, so its record capacity is unknown — so the sign
        # is rejected here and the magnitude is handled where the allocation
        # actually happens (`ActionTableInterpreter.decode_block` clamps the
        # pre-reserve hint; the accumulators cap the element count).
        if object_count < 0:
            raise Error(
                String(
                    "AvroOcfError.MALFORMED_BLOCK: negative block object_count "
                )
                + String(object_count)
            )
        # UNTRUSTED INPUT: `pos + byte_count + OCF_SYNC_LEN` is signed Int and
        # WRAPS for a byte_count near 2^63 (10 well-formed varint bytes reach
        # Int64.MAX), so an additive guard passes the hostile value; the cursor
        # then goes hugely NEGATIVE, `_sync_matches`'s own
        # `pos + OCF_SYNC_LEN > len(bytes)` test is also negative and passes,
        # and `bytes[pos + i]` reads at an index of about -2^63 — at
        # ASSERT=none an effectively arbitrary-address read.
        #
        # Subtraction-first form: `pos <= n` and `OCF_SYNC_LEN` is 16, so the
        # right-hand side is computed entirely in small numbers and cannot
        # overflow. It goes negative when the block header itself already ran
        # past the sync region, in which case any byte_count >= 0 is rejected —
        # which is correct.
        if byte_count < 0 or byte_count > n - pos - OCF_SYNC_LEN:
            raise Error(
                String(
                    "AvroOcfError.TRUNCATED_BLOCK: block at offset "
                )
                + String(pos)
                + " declares a "
                + String(byte_count)
                + "-byte payload but only "
                + String(n - pos - OCF_SYNC_LEN)
                + " bytes remain before the file's trailing sync marker"
            )
        var payload_offset = pos
        blocks.append(
            OcfBlock(
                object_count=object_count,
                payload_offset=payload_offset,
                payload_len=byte_count,
            )
        )
        pos += byte_count
        # ---- trailing sync marker must match header's ----
        if not _sync_matches(bytes, pos, header.sync_marker):
            raise Error(
                "AvroOcfError.SYNC_MISMATCH: block trailing sync marker "
                "does not match header marker"
            )
        pos += OCF_SYNC_LEN

    return blocks^


@always_inline
def _sync_matches(
    bytes: Span[UInt8, _], pos: Int, marker: Array[UInt8, OCF_SYNC_LEN]
) -> Bool:
    if pos + OCF_SYNC_LEN > len(bytes):
        return False
    for i in range(OCF_SYNC_LEN):
        if bytes[pos + i] != marker[i]:
            return False
    return True


# =============================================================================
# Scalar sync-marker resync (recovery / parallel-range partition helper).
# =============================================================================
#
# Scans forward from `start` for the next occurrence of the 16-byte sync
# marker; returns the byte offset of the FIRST byte AFTER the marker (i.e. the
# start of the next block), or -1 if not found. Used for (a) recovery after a
# corrupt block, and (b) parallel range partitioning where a worker seeks to
# the next block boundary from an arbitrary file offset.
#
# The inner needle-search is the SIMD "first+last byte" memmem primitive
# (`komira_core.simd.byte_class.byte_memmem.find_needle`). It finds the same
# marker positions as a scalar first-byte fast-skip loop — the SIMD path is
# validated bit-identical to a scalar reference by the memmem property test.

def find_sync_marker_from(
    bytes: Span[UInt8, _], start: Int, marker: Array[UInt8, OCF_SYNC_LEN]
) -> Int:
    """Find the next sync marker at or after `start`. Returns the offset of
    the byte AFTER the marker (next-block start), or -1 if not found."""
    var n = len(bytes)
    if OCF_SYNC_LEN == 0 or start < 0 or start > n:
        return -1

    # SIMD memmem over the haystack suffix `bytes[start .. n)`. The needle is
    # the 16-byte marker. `find_needle` returns an offset relative to the
    # suffix start (or -1); translate back to an absolute offset and return
    # the byte AFTER the marker (next-block start).
    var marker_span = Span[UInt8, origin_of(marker)](marker)
    var rel = find_needle(bytes[start:], marker_span)
    if rel < 0:
        return -1
    return start + rel + OCF_SYNC_LEN


# =============================================================================
# Avro long varint — reuses ocf_header._read_long (returns VarintRead).
# =============================================================================


def _read_long(bytes: Span[UInt8, _], pos: Int) raises -> VarintRead:
    """Decode a zigzag varint Avro `long`. Returns VarintRead(value, new_pos)."""
    var p = pos
    var shift: UInt64 = 0
    var acc: UInt64 = 0
    while True:
        if p >= len(bytes):
            raise Error("AvroOcfError.TRUNCATED_BLOCK: varint overrun")
        var b = bytes[p]
        p += 1
        acc |= (UInt64(b & 0x7F) << shift)
        if (b & 0x80) == 0:
            break
        shift += 7
        if shift >= 64:
            raise Error("AvroOcfError.MALFORMED_VARINT: long > 10 bytes")
    var decoded = Int64((acc >> 1) ^ (~(acc & 1) + 1))
    return VarintRead(decoded, p)

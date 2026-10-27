# =============================================================================
# thspill2.mojo: the THSPILL2 encoder, decoder and the `Spillable` trait.
# =============================================================================
#
# The row-grain spill codec. A `Spillable` exposes its row count, its body
# bytes and a schema fingerprint; `THSpill2Encoder` writes them as one chunk
# (a 96-byte header from `thspill2_header.mojo` plus the body) through a
# `SpillStorage`, and `THSpill2Decoder` reads one back. The codec moves bytes;
# the conformer owns the body shape.
#
# Encode: read `row_count`, `nbytes` and `schema_fingerprint`, allocate one
# buffer of `96 + nbytes`, pack the header, copy the body, hand the buffer to
# `storage.write_chunk`.
#
# Decode: `storage.read_chunk`, parse the header, validate every header field
# against the chunk, hand the body to `T.from_bytes`. A chunk read from
# storage is untrusted input: a truncated chunk, a bad magic or version, a
# negative or oversize length or count, unknown flag bits and a compressed
# body all raise before the body is touched.
#
# No pointer type appears on a public surface; the one memcpy into the
# destination buffer is confined to `copy_from_view_at`.
# =============================================================================

from std.memory import unsafe_memcpy

from komira_buffer.byte_view import ByteView
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_buffer.heap_region import HeapRegion

from .spill_storage import ChunkId, SpillStorage
from .thspill2_header import (
    THSPILL2_FLAG_COMPRESSED_LZ4,
    THSPILL2_FLAG_KNOWN_MASK,
    THSPILL2_HEADER_SIZE,
    THSpill2Header,
    pack_header,
    parse_header,
)


# =============================================================================
# Spillable trait
# =============================================================================


trait Spillable(Movable, Deinitable):
    """Anything THSPILL2 can serialize. The body is opaque bytes to the codec.

    Methods:
      * `row_count`: logical rows in the chunk, stored in the header.
      * `nbytes`: body byte length; the encoder allocates exactly
        `THSPILL2_HEADER_SIZE + nbytes`.
      * `schema_fingerprint`: the caller's schema identity.
      * `as_byte_view`: the body bytes the encoder copies, borrowed for the
        duration of the call; the encoder does not retain the view.
      * `from_bytes`: static constructor from decoded body bytes plus the
        header's row count and fingerprint. Ownership of the body buffer
        transfers to the new value.

    `from_bytes` takes a `SharedAlignedBuffer[HeapRegion]`, which is what
    `SpillStorage.read_chunk` returns.
    """

    def row_count(self) -> Int64:
        """Logical rows in this chunk. Written to the header."""
        ...

    def nbytes(self) -> Int64:
        """Body byte length. Determines chunk allocation size."""
        ...

    def schema_fingerprint(self) -> UInt64:
        """The caller's schema identity: a UInt64, canonically the FNV-1a 64
        fold from `komira_engine_runtime.spill.fnv1a`."""
        ...

    def as_byte_view[
        _mut: Bool, origin: Origin[mut=_mut], //,
    ](ref [origin] self) -> ByteView[origin]:
        """Borrow the body bytes for the encoder to memcpy. Lifetime
        tied to the receiver borrow.
        """
        ...

    @staticmethod
    def from_bytes(
        var bytes: SharedAlignedBuffer[HeapRegion],
        row_count: Int64,
        schema_fingerprint: UInt64,
    ) raises -> Self:
        """Rehydrate from decoded body bytes + header metadata.
        Ownership of `bytes` transfers to the new Self.

        A conformer must raise when `schema_fingerprint` does not match its
        own expected schema identity: the codec is body-opaque, has no
        expected fingerprint to compare against, and delivers the header's
        value unchanged. A conformer should also raise when `bytes.length()`
        is inconsistent with its layout for `row_count`, or when the body is
        otherwise malformed.
        """
        ...


# =============================================================================
# THSpill2Encoder — generic over Spillable T.
# =============================================================================


struct THSpill2Encoder[T: Spillable]:
    """Encoder for THSPILL2 chunks holding a Spillable T. It has no state;
    call `THSpill2Encoder[MyRowBlock].encode(storage, src)`."""

    @staticmethod
    def encode[
        S: SpillStorage
    ](mut storage: S, var src: Self.T) raises -> ChunkId:
        """Serialize `src` into a fresh chunk on `storage` and return its
        ChunkId. The chunk is `[0..96)` the header and `[96..96+nbytes)` the
        body, built in one allocation. `src` is consumed and released after
        the body copy, before the write.

        Raises:
            If `src.nbytes()` is negative, or from `storage.write_chunk`
            (budget exceeded, I/O error).
        """
        var body_len = Int(src.nbytes())
        var row_count = src.row_count()
        var fingerprint = src.schema_fingerprint()

        # A negative nbytes() from a misbehaving conformer is refused here.
        if body_len < 0:
            raise Error(
                "THSpill2Encoder.encode: body length is negative ("
                + String(body_len)
                + ") — Spillable.nbytes() returned bogus value"
            )

        var total = THSPILL2_HEADER_SIZE + body_len

        # One buffer sized for header + body.
        var oab = OwnedAlignedBuffer(capacity=total)

        # Pack the header into bytes [0..96). The span is tied to the local
        # `oab`, which stays alive across the call.
        var header = THSpill2Header.for_uncompressed(
            body_length=UInt64(body_len),
            row_count=UInt64(row_count),
            schema_fingerprint=fingerprint,
        )
        var hdr_span = oab.view_mut().into_span()
        pack_header(header, hdr_span)

        # Body memcpy [96..96+body_len). Skipped for empty bodies.
        if body_len > 0:
            # `body_view` borrows `src` and does not escape this block.
            var body_view = src.as_byte_view()
            oab.copy_from_view_at(THSPILL2_HEADER_SIZE, body_view)

        # Release the source before the write to cut peak memory.
        _ = src^

        # Promote to a shared buffer and hand it to storage.
        var sab = SharedAlignedBuffer[HeapRegion].from_owned(oab^)
        return storage.write_chunk(sab^)


# =============================================================================
# THSpill2Decoder — generic over Spillable T.
# =============================================================================


struct THSpill2Decoder[T: Spillable]:
    """Decoder for THSPILL2 chunks holding a Spillable T. It has no state.

    Two restore paths:

      * `decode_copy(storage, chunk_id)` copies the body into a fresh buffer
        and hands it to `T.from_bytes`; the restored T is independent of the
        storage chunk. `decode` is an alias.
      * `decode_zerocopy(storage, chunk_id)` hands `T.from_bytes` a borrowed
        slice of the chunk's buffer: no body copy, and the slice holds a
        reference to the chunk's buffer, so the restored T stays valid after
        the storage releases the chunk or is destroyed.

    Both paths read the chunk, parse the header, validate it against the
    chunk's length (see `_parse_and_validate`), then call `T.from_bytes`.

    The body begins at byte 96 and the chunk's base is 64-byte aligned, so
    the body is at least 16-byte aligned: enough for typed row-field loads. A
    conformer that needs a 64-byte-aligned body uses `decode_copy` or
    `realign_to[64]()` on the body buffer.

    The codec cannot check the fingerprint: it knows the one the encoder
    wrote, not the one the restoring operator expects. It delivers the
    header's `row_count` and `schema_fingerprint` unchanged and the
    conformer's `from_bytes` enforces the fingerprint.
    """

    @staticmethod
    def _parse_and_validate(
        raw: SharedAlignedBuffer[HeapRegion],
    ) raises -> THSpill2Header:
        """Parse the header of `raw` and validate each field against it.

        Raises on: a buffer shorter than a header, a bad magic or version
        (from `parse_header`); a `row_count` or `body_length` of 2^63 or more;
        flag bits this reader does not know; the compressed flag (the codec
        writes and restores uncompressed bodies only); an
        `uncompressed_body_length` that differs from `body_length`; and a
        `96 + body_length` larger than the buffer. Every check precedes any
        allocation or slice of the body.
        """
        var raw_view = raw.as_view()
        var raw_span = raw_view.into_span()
        var header = parse_header(raw_span)

        # The wire fields are UInt64; a value of 2^63 or more reads as a
        # negative Int64 and would pass a `length < declared_total` check.
        var body_length_i64 = Int64(header.body_length)
        if body_length_i64 < 0:
            raise Error(
                "THSpill2Decoder.decode: header.body_length="
                + String(header.body_length)
                + " is absurd (>= 2^63) - corrupt chunk"
            )
        if Int64(header.row_count) < 0:
            raise Error(
                "THSpill2Decoder.decode: header.row_count="
                + String(header.row_count)
                + " is absurd (>= 2^63) - corrupt chunk"
            )
        if (header.flags & ~THSPILL2_FLAG_KNOWN_MASK) != 0:
            raise Error(
                "THSpill2Decoder.decode: header.flags="
                + String(Int(header.flags))
                + " has unknown bits set - corrupt chunk"
            )
        if (header.flags & THSPILL2_FLAG_COMPRESSED_LZ4) != 0:
            raise Error(
                "THSpill2Decoder.decode: compressed bodies are not"
                " supported"
            )
        if header.uncompressed_body_length != header.body_length:
            raise Error(
                "THSpill2Decoder.decode: uncompressed_body_length="
                + String(header.uncompressed_body_length)
                + " differs from body_length="
                + String(header.body_length)
                + " on an uncompressed chunk - corrupt chunk"
            )

        var declared_total = Int64(THSPILL2_HEADER_SIZE) + body_length_i64
        if declared_total < 0 or raw.length() < declared_total:
            raise Error(
                "THSpill2Decoder.decode: storage returned "
                + String(Int(raw.length()))
                + " bytes but header declares "
                + String(Int(declared_total))
                + " (header.body_length="
                + String(Int(body_length_i64))
                + ")"
            )
        return header

    @staticmethod
    def decode_copy[
        S: SpillStorage
    ](storage: S, chunk_id: ChunkId) raises -> Self.T:
        """Read, validate and rehydrate, copying the body into a fresh
        buffer. The restored T is independent of the storage chunk.

        Raises if `storage.read_chunk` raises, if `_parse_and_validate`
        refuses the chunk, or if `T.from_bytes` raises.
        """
        var raw = storage.read_chunk(chunk_id)
        var header = Self._parse_and_validate(raw)
        var body_len = Int(header.body_length)

        var body_oab = OwnedAlignedBuffer(capacity=body_len)
        if body_len > 0:
            # `_parse_and_validate` proved 96 + body_len <= raw.length().
            var body_src_view = raw.view_range_ro(
                THSPILL2_HEADER_SIZE, body_len
            )
            body_oab.copy_from_view(body_src_view)

        _ = raw^

        var body_sab = SharedAlignedBuffer[HeapRegion].from_owned(body_oab^)

        return Self.T.from_bytes(
            body_sab^,
            Int64(header.row_count),
            header.schema_fingerprint,
        )

    @staticmethod
    def decode_zerocopy[
        S: SpillStorage
    ](storage: S, chunk_id: ChunkId) raises -> Self.T:
        """Read, validate and rehydrate with no body copy. `T.from_bytes`
        receives a borrowed slice `[96, 96 + body_length)` of the chunk's
        buffer. The slice holds a reference to the buffer, so the restored T
        remains valid after this call returns, after the storage releases the
        chunk and after the storage is destroyed.

        Raises if `storage.read_chunk` raises, if `_parse_and_validate`
        refuses the chunk, or if `T.from_bytes` raises.
        """
        var raw = storage.read_chunk(chunk_id)
        var header = Self._parse_and_validate(raw)
        var body_len = Int(header.body_length)

        # An empty body is a well-formed zero-length borrow at offset 96.
        var body_sab = SharedAlignedBuffer[HeapRegion].from_borrowed_view(
            raw, Int64(THSPILL2_HEADER_SIZE), Int64(body_len)
        )

        _ = raw^

        return Self.T.from_bytes(
            body_sab^,
            Int64(header.row_count),
            header.schema_fingerprint,
        )

    @staticmethod
    def decode[
        S: SpillStorage
    ](storage: S, chunk_id: ChunkId) raises -> Self.T:
        """Alias for `decode_copy`."""
        return Self.decode_copy(storage, chunk_id)

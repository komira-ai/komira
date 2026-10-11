# =============================================================================
# thspill2.mojo — THSPILL2 engine encoder + decoder + `Spillable` trait.
# =============================================================================
#
# The engine-side substrate every `SpillableOp.spill_to_storage` /
# `SpillableOp.restore_from_storage` call routes through. The header
# format lives in `thspill2_header.mojo` (96-byte fixed header).
#
# # P-1.B substrate
#
# Encoder/decoder + `Spillable` trait. The trait surface lets ANY
# `Movable + Deinitable` body produce/consume opaque bytes
# under the THSPILL2 envelope. v0.4 P-1.D wires HashAggUntyped's
# RowBlock partition as the FIRST production conformer; P-1.E adds
# SortBuffer's external-run blocks + JoinBuildUntyped's build-side
# partitions. The codec moves bytes; the operator owns the body shape.
#
# # Encoder lifecycle (CALLED BY `SpillableOp.spill_to_storage`)
#
#   var encoder = THSpill2Encoder[T]()
#   var chunk_id = encoder.encode(storage, my_row_block)
#
# Internally:
#   1. Read `src.row_count()` + `src.nbytes()` + `src.schema_fingerprint()`.
#   2. Allocate ONE OAB of `(96 + body_len)` bytes.
#   3. Pack header into bytes [0..96) via `pack_header(...)`.
#   4. Memcpy body bytes into [96..) from `src.as_byte_view()`.
#   5. Promote OAB → SAB via `from_owned`.
#   6. Hand SAB to `storage.write_chunk(...)`.
#   7. Return the resulting `ChunkId`.
#
# # Decoder lifecycle (CALLED BY `SpillableOp.restore_from_storage`)
#
#   var t = THSpill2Decoder[T].decode(storage, chunk_id)
#
# Internally:
#   1. `storage.read_chunk(chunk_id)` — returns SAB[HeapRegion].
#   2. Parse 96-byte header via `parse_header(...)`.
#   3. Validate `buf.length() >= 96 + header.body_length`.
#   4. Slice body bytes [96..96+body_length).
#   5. Hand body bytes + row_count + schema_fingerprint to `T.from_bytes`.
#   6. Return the rehydrated T.
#
# # The Spillable trait
#
# Today's contract (v0.4 P-1.B): conformers expose row_count, nbytes,
# schema_fingerprint, and an `as_byte_view()` that yields the bytes the
# encoder copies into the chunk body. `from_bytes` builds a T from
# decoded bytes + the header's row_count + schema_fingerprint.
#
# Two production conformers in P-1.D / P-1.E:
#   * HashAggUntyped's RowBlock (P-1.D).
#   * SortBuffer's RowBlock (P-1.E).
#
# Test conformers ship in `tests/engine/test_thspill2_codec.mojo` —
# `_TestRowBlock` (heap-bytes wrapper just rich enough to exercise
# the round-trip).
#
# # Encapsulation rule
#
# - NO `UnsafePointer` on any public surface of `Spillable`,
#   `THSpill2Encoder`, `THSpill2Decoder`. Bytes flow via
#   `SharedAlignedBuffer[HeapRegion]` and `ByteView[origin]`.
# - NO wildcard origins on any struct field.
# - The internal `memcpy` into the destination OAB is confined to one
#   site with a `# SAFETY:` block.
# =============================================================================

from std.memory import unsafe_memcpy

from komira_buffer.byte_view import ByteView
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_buffer.heap_region import HeapRegion

from .spill_storage import ChunkId, SpillStorage
from .thspill2_header import (
    THSPILL2_HEADER_SIZE,
    THSpill2Header,
    pack_header,
    parse_header,
)


# =============================================================================
# Spillable trait
# =============================================================================


trait Spillable(Movable, Deinitable):
    """Anything THSPILL2 can serialize.

    P-1.B today serializes row blocks; P-2 layers a parallel
    `Spillable` conformance over column batches for THSPLC. The trait
    is identical between row + column conformers — only the body shape
    differs, and the body is opaque from the codec's perspective.

    # Methods
      * `row_count` — logical rows in this chunk. Stored in the header
        for restore-side O(1) capacity sizing.
      * `nbytes` — body byte length. The encoder allocates exactly
        `THSPILL2_HEADER_SIZE + nbytes` bytes for the chunk.
      * `schema_fingerprint` — caller's schema identity. Restore checks
        the fingerprint against the operator's expected shape and
        raises on mismatch (cross-version restore safety).
      * `as_byte_view` — origin-tracked byte view over the body bytes.
        The encoder memcpys these bytes into the chunk body. The view
        is alive for the duration of the call (receiver borrow); the
        encoder must NOT retain it past the memcpy.
      * `from_bytes` — static constructor from decoded body bytes +
        per-header metadata. The body buffer ownership transfers to
        the new T (typically by moving the SAB onto a `var _bytes`
        field, or copying into the operator's own storage and
        dropping the SAB).

    # Lifetime contract for `as_byte_view`
    Receiver `ref [origin] self`. Returned `ByteView[origin]` is alive
    for the receiver's borrow lifetime — the encoder uses the view
    inside `encode(...)` and does NOT retain it. The conformer's body
    bytes MUST be addressable (heap-resident; SAB-backed; List-backed)
    so the view is byte-accurate.

    # `from_bytes` and the K parameter
    `from_bytes` takes `SharedAlignedBuffer[HeapRegion]` (NOT
    K-parametric). There is room for a K-parametric
    decode against an mmap-backed restore (`SharedAlignedBuffer
    [MmapRegion]`), but P-1.A's `SpillStorage.read_chunk` always
    returns `SharedAlignedBuffer[HeapRegion]`. Conformers that want
    zero-copy mmap restore land alongside the K-parametric
    `read_chunk` extension in a follow-up sub-slot.
    """

    def row_count(self) -> Int64:
        """Logical rows in this chunk. Written to the header."""
        ...

    def nbytes(self) -> Int64:
        """Body byte length. Determines chunk allocation size."""
        ...

    def schema_fingerprint(self) -> UInt64:
        """Caller's schema identity. Restore checks for mismatch.

        A UInt64 (header version 0x02), to unify with
        the production FNV-1a-64 fold over the canonical input
        `entry_stride_le_8B || agg_tag_list_bytes`. See
        `komira_engine_runtime.spill.fnv1a.fnv1a_64_partition_fingerprint`
        for the canonical helper.
        """
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

        FINGERPRINT CONTRACT (SPILL-FU-DECODE-ROBUSTNESS): a PRODUCTION
        conformer MUST raise when `schema_fingerprint` does not match its own
        expected schema identity — the codec is body-opaque and cannot
        enforce this (it has no expected fingerprint to compare against; see
        the `THSpill2Decoder` "Fingerprint enforcement" docstring). The codec
        delivers the header's `schema_fingerprint` here unchanged; enforcing
        the match is THIS layer's responsibility.

        Conformers SHOULD also raise if `bytes.length()` is inconsistent with
        the conformer-specific layout for `row_count`, or if the body bytes
        are otherwise malformed.
        """
        ...


# =============================================================================
# THSpill2Encoder — generic over Spillable T.
# =============================================================================


struct THSpill2Encoder[T: Spillable]:
    """Engine-side encoder for THSPILL2 chunks containing a Spillable T.

    The encoder is value-shaped (no fields). The `encode` method is
    `@staticmethod` — callers do NOT instantiate the encoder; they
    write `THSpill2Encoder[MyRowBlock].encode(storage, src)`.

    Why static-not-stateful: the encoder has no inter-call state to retain. The
    method is one allocation + one header pack + one body memcpy +
    one `write_chunk` — keeping it static lets callers avoid the
    init/finalize ceremony.
    """

    @staticmethod
    def encode[
        S: SpillStorage
    ](mut storage: S, var src: Self.T) raises -> ChunkId:
        """Serialize `src` into a fresh chunk on `storage`. Returns the
        ChunkId of the written chunk.

        Body shape: `[0..96): THSPILL2 header; [96..96+body_len): body
        bytes from src.as_byte_view()`.

        Memory: ONE allocation of `(96 + body_len)` bytes. Header is
        written via `pack_header(...)`. Body is memcpy'd from
        `src.as_byte_view()`. The OAB is promoted to SAB and handed to
        `storage.write_chunk` (which consumes the SAB).

        `src` is consumed — after `encode` returns, the source body is
        no longer accessible (the encoder takes ownership and drops
        the source's heap allocation after the body memcpy completes).

        Args:
            storage: The SpillStorage backend to write the chunk to.
            src:     The Spillable body to serialize. Consumed.

        Returns:
            ChunkId of the written chunk on `storage`.

        Raises:
            * From the body's `as_byte_view()` (conformer-specific).
            * From `storage.write_chunk(...)` (e.g. budget exceeded,
              EIO).
            * From `pack_header(...)` (only if `body_length` would
              overflow the allocation — defensive; should not fire in
              practice).
        """
        var body_len = Int(src.nbytes())
        var row_count = src.row_count()
        var fingerprint = src.schema_fingerprint()

        # Defensive check: catch negative nbytes() from a misbehaving
        # conformer at the codec boundary rather than letting it
        # propagate into the OAB ctor.
        if body_len < 0:
            raise Error(
                "THSpill2Encoder.encode: body length is negative ("
                + String(body_len)
                + ") — Spillable.nbytes() returned bogus value"
            )

        var total = THSPILL2_HEADER_SIZE + body_len

        # Allocate ONE OAB sized exactly for header + body. The OAB
        # post-condition is `_length == _capacity == total` (padded up
        # to next 64B boundary internally; `_length == total` for the
        # logical-write window). Subsequent `write_*_le_at` /
        # `copy_from_view_at` calls bound on `_length`/`_capacity`
        # accordingly.
        var oab = OwnedAlignedBuffer(capacity=total)

        # Pack the header into bytes [0..96).
        # SAFETY: `oab.view_range_mut(0, 96)` returns a Span-flavored
        # ByteView whose origin is tied to the local `oab`. The
        # encoder holds `oab` alive across the `pack_header` call;
        # the span does not escape this scope. `into_span()` derives
        # a `Span[Byte, view.origin]` for the helper.
        var header = THSpill2Header.for_uncompressed(
            body_length=UInt64(body_len),
            row_count=UInt64(row_count),
            schema_fingerprint=fingerprint,
        )
        # pack_header writes into the first 96 bytes. We pass a
        # view over the FULL OAB (length=total), not a sub-range, so
        # the destination span starts at offset 0; pack_header
        # bounds-checks `dst.len() >= 96` itself.
        var hdr_span = oab.view_mut().into_span()
        pack_header(header, hdr_span)

        # Body memcpy [96..96+body_len). Skipped for empty bodies.
        if body_len > 0:
            # `src.as_byte_view()` returns a ByteView tied to `src`'s
            # borrow. `src` is held alive across the memcpy by the
            # encoder's stack frame; `body_view` does NOT escape.
            var body_view = src.as_byte_view()
            # OAB's `copy_from_view_at(dst_offset, src_view)` does a
            # bounded memcpy. Bound is `_capacity` (>= total), so
            # offset 96 + body_len fits.
            oab.copy_from_view_at(THSPILL2_HEADER_SIZE, body_view)
            # `body_view` drops here (does NOT escape).

        # `src` is now consumed — drop it explicitly so its bytes are
        # released BEFORE we hand `oab` off (cuts peak memory by 1×
        # body_len).
        _ = src^

        # Promote OAB → SAB and hand to storage.
        var sab = SharedAlignedBuffer[HeapRegion].from_owned(oab^)
        return storage.write_chunk(sab^)


# =============================================================================
# THSpill2Decoder — generic over Spillable T.
# =============================================================================


struct THSpill2Decoder[T: Spillable]:
    """Engine-side decoder for THSPILL2 chunks holding a Spillable T.

    Symmetric to `THSpill2Encoder`: static, no per-call state. Two
    restore paths (mirrors `THSPLCDecoder`'s column-side copy / 0-copy
    split):

      * `decode_copy(storage, chunk_id)` — memcpy the body bytes into a
        fresh `OwnedAlignedBuffer` and hand the owning SAB to
        `T.from_bytes`. The honest baseline: the restored T is fully
        independent of the storage chunk (which drops at end of call).
      * `decode_zerocopy(storage, chunk_id)` — hand `T.from_bytes` a
        `SharedAlignedBuffer.from_borrowed_view(raw, 96, body_len)`
        Arc-clone slice over the storage chunk's bytes. NO body memcpy;
        the restored T keeps the source storage pinned via the cloned
        Arc refcount on `raw`.

    `decode` is retained as an alias for `decode_copy` (the original
    P-1.B contract) so existing call sites do not churn.

    Both paths:
      1. Call `storage.read_chunk(chunk_id)` to fetch the raw bytes.
      2. Parse the 96-byte header.
      3. Validate the SAB's length covers `96 + header.body_length`.
      4. Build the body SAB (fresh OAB-copy for copy; borrowed-view
         slice for 0-copy).
      5. Hand the body SAB + row_count + schema_fingerprint to
         `T.from_bytes(...)`.

    # 0-copy row restore — eligibility (be honest)

    The body starts at byte offset 96 in the chunk. The encoder writes
    the body as a byte-identical copy of `src.as_byte_view()` — i.e. the
    operator's IN-MEMORY row image. So the borrowed-view slice IS the
    in-memory row block, restored with no payload allocation. This is the
    "spill bytes == in-memory bytes, restore = view+cast" thesis applied
    to the row grain.

    ALL THSPILL2 row shapes are 0-copy-eligible at the codec layer,
    because the body is OPAQUE BYTES from the codec's perspective and the
    conformer's `from_bytes` already owns the body shape. There is no
    AoS<->SoA transpose and no per-field value transform.

    Alignment: `THSPILL2_HEADER_SIZE == 96`, and `96 % 16 == 0` (the
    header was sized so the body inherits 16-byte alignment relative to
    the chunk base — see `thspill2_header.mojo` §96-byte layout). The
    chunk's own base pointer is 64-aligned (OAB allocates 64-aligned;
    `from_owned` preserves it), so the body slice base is at least
    16-aligned — enough for any 8/16-byte-wide typed row-field load the
    operator performs (matches THSPLC's column-side eligibility stance:
    element-by-element typed loads, no whole-buffer 64B-SIMD demand at
    the codec layer).

    A conformer that genuinely needs the body 64-byte aligned for a
    whole-block SIMD pass (none in v0.4's row-restore consumers) should
    call `decode_copy` or `realign_to[64]()` on the body SAB itself —
    that is the documented copy-fallback. No row shape forces a copy for
    correctness today.

    # Fingerprint enforcement — WHICH LAYER (SPILL-FU-DECODE-ROBUSTNESS)

    Unlike THSPLC (whose decoder owns the caller's expected `Schema` and so
    can recompute + compare the fingerprint itself), the THSPILL2 codec is
    body-OPAQUE: it knows only the fingerprint the encoder WROTE (carried in
    the header), NOT the fingerprint the restoring operator EXPECTS. The
    expected schema identity lives with the conformer (`T.from_bytes`), so
    fingerprint enforcement MUST happen there — the codec cannot compare
    against a value it does not possess.

    What the codec guarantees: it faithfully DELIVERS `header.row_count` and
    `header.schema_fingerprint` (exactly as written, after release-build
    length/magic/version validation) to `T.from_bytes`. A conforming
    `from_bytes` MUST raise when `schema_fingerprint` does not match its own
    expected shape (the trait docstring's "Conformers MAY raise ... if
    schema_fingerprint does not match" is hereby the REQUIRED contract for any
    production conformer). v0.4 ships no production THSPILL2 row conformer;
    the robustness test suite drives a conformer that enforces the
    fingerprint and proves the codec delivers the (possibly-corrupt) header
    fingerprint through to it unchanged.
    """

    @staticmethod
    def _parse_and_validate(
        raw: SharedAlignedBuffer[HeapRegion],
    ) raises -> THSpill2Header:
        """Shared prologue for both decode paths: parse + validate the
        header against `raw`'s length. Returns the parsed header; the
        caller owns `raw` and decides copy-vs-borrow on the body."""
        # Parse the header from the leading 96 bytes.
        # `raw.as_view()` returns ByteView[origin] over the full SAB
        # bytes. `into_span()` gives a Span we can pass to
        # `parse_header`. parse_header itself bounds-checks `>= 96` and
        # raises on bad magic / unknown version.
        var raw_view = raw.as_view()
        var raw_span = raw_view.into_span()
        var header = parse_header(raw_span)

        # RELEASE-BUILD body-length sanity. `body_length` is UInt64 on the
        # wire; a corrupt chunk can declare an absurd value. Reject anything
        # whose Int64 reinterpretation is negative (>= 2^63) BEFORE it feeds
        # the `declared_total` comparison — otherwise the negative would make
        # `raw.length() < declared_total` falsely pass and the body slice
        # (decode_copy `view_range_ro` / decode_zerocopy `from_borrowed_view`,
        # both debug_assert-only) would read past the chunk in release.
        var body_length_i64 = Int64(header.body_length)
        if body_length_i64 < 0:
            raise Error(
                "THSpill2Decoder.decode: header.body_length="
                + String(header.body_length)
                + " is absurd (>= 2^63) — corrupt chunk"
            )

        # Verify the SAB covers header + body.
        var declared_total = Int64(THSPILL2_HEADER_SIZE) + body_length_i64
        if raw.length() < declared_total:
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
        """Read + parse + rehydrate, memcpy-ing the body into a fresh
        owning OAB. The restored T is fully independent of the storage
        chunk. This is the honest baseline restore path.

        Raises if:
          * `storage.read_chunk` raises (e.g. invalid chunk_id, EIO).
          * `parse_header` raises (bad magic / unknown version).
          * The chunk buffer is shorter than `96 + body_length`
            declared by the header.
          * `T.from_bytes` raises (conformer-specific).

        Args:
            storage:  SpillStorage backend the chunk lives on.
            chunk_id: Handle minted by a prior `THSpill2Encoder.encode`
                      on the same storage.

        Returns:
            Rehydrated T (independent of the storage chunk).
        """
        var raw = storage.read_chunk(chunk_id)
        var header = Self._parse_and_validate(raw)
        var body_len = Int(header.body_length)

        # Copy body bytes into a fresh OAB and promote to SAB.
        var body_oab = OwnedAlignedBuffer(capacity=body_len)
        if body_len > 0:
            # SAFETY: slice off the first 96 bytes via
            # `raw.view_range_ro(96, body_len)` and memcpy into the
            # fresh OAB. Both source + dest pointers carry valid
            # origins; the memcpy is bounded by body_len which is
            # `<= raw.length() - 96` (verified in _read_and_validate).
            var body_src_view = raw.view_range_ro(
                THSPILL2_HEADER_SIZE, body_len
            )
            body_oab.copy_from_view(body_src_view)

        # Drop `raw` here — body bytes now owned by body_oab. The
        # storage's SAB Arc refcount decrements as the caller's scope ends.
        _ = raw^

        var body_sab = SharedAlignedBuffer[HeapRegion].from_owned(
            body_oab^
        )

        return Self.T.from_bytes(
            body_sab^,
            Int64(header.row_count),
            header.schema_fingerprint,
        )

    @staticmethod
    def decode_zerocopy[
        S: SpillStorage
    ](storage: S, chunk_id: ChunkId) raises -> Self.T:
        """Read + parse + rehydrate with NO body memcpy. `T.from_bytes`
        receives a `SharedAlignedBuffer.from_borrowed_view(raw, 96,
        body_len)` Arc-clone slice over the storage chunk's bytes — the
        restored T aliases the in-memory row image and keeps the source
        storage pinned via the cloned Arc refcount.

        SAFETY / lifetime: the borrowed body SAB clones `raw`'s
        ArcPointer (refcount++), so the source chunk's bytes stay alive
        for as long as the restored T (and therefore its body SAB) is
        alive — even after `raw` itself drops at the end of this call.
        This is exactly the THSPLC column 0-copy contract, applied to the
        opaque row body.

        Eligibility: all THSPILL2 row shapes (see the struct docstring's
        "0-copy row restore" section). The body is opaque bytes; the
        16-byte body alignment (96 % 16 == 0; 64-aligned chunk base)
        satisfies the operator's typed row-field loads.

        Raises if:
          * `storage.read_chunk` raises (e.g. invalid chunk_id, EIO).
          * `parse_header` raises (bad magic / unknown version).
          * The chunk buffer is shorter than `96 + body_length`
            declared by the header.
          * `T.from_bytes` raises (conformer-specific).

        Args:
            storage:  SpillStorage backend the chunk lives on.
            chunk_id: Handle minted by a prior `THSpill2Encoder.encode`
                      on the same storage.

        Returns:
            Rehydrated T aliasing the chunk's resident bytes.
        """
        var raw = storage.read_chunk(chunk_id)
        var header = Self._parse_and_validate(raw)
        var body_len = Int(header.body_length)

        # Build a borrowed-view body SAB over [96, 96+body_len) of `raw`.
        # The borrow Arc-clones `raw`'s region (refcount++), so the source
        # bytes stay pinned for the restored T's lifetime — no payload
        # memcpy. For an empty body, an offset-0 zero-length borrow is
        # still well-formed (from_borrowed_view bounds-checks
        # offset+length <= owner._length).
        var body_sab = SharedAlignedBuffer[HeapRegion].from_borrowed_view(
            raw, Int64(THSPILL2_HEADER_SIZE), Int64(body_len)
        )

        # Drop `raw` here — the body SAB holds its own Arc clone of the
        # source region, so the storage bytes remain pinned.
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
        """Back-compat alias for `decode_copy` (the original P-1.B
        contract). Existing call sites keep working unchanged; new
        callers that want the 0-copy restore call `decode_zerocopy`.
        """
        return Self.decode_copy(storage, chunk_id)

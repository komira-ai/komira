# =============================================================================
# Compression — trait for byte-stream codecs
# =============================================================================
#
# `Compression` is a SEPARATE trait at a DIFFERENT abstraction layer than
# `SerdeFormat`:
#   - `SerdeFormat`  describes "what is the on-disk record structure?"
#                    (Parquet, Jsonl, Csv, Arrow IPC, ...)
#   - `Compression` describes "what byte-stream codec wraps the record
#                              structure (or, for Parquet, individual pages)?"
#                    (Uncompressed, Snappy, Zstd, Gzip, Lz4Raw, Lzo, Brotli, Zlib)
#
# The two compose in two distinct positions in the type tree:
#
# 1. **Per-page compression** (Parquet's case):
#    `Parquet[C: Compression = Snappy]` — codec is a typed parameter of the
#    format itself; pages of column chunks are individually compressed; the
#    Parquet Thrift `ColumnChunk.codec` field records `C.PARQUET_CODEC_ID`.
#
# 2. **Whole-file compression** (`.jsonl.gz` / `.csv.gz`):
#    `WholeFileCompressed[Inner: SerdeFormat, C: Compression]` — codec wraps
#    the entire byte stream of the inner format; the inner format's
#    record-level parse/encode runs over the decompressed byte stream.
#
# Parquet does NOT use `WholeFileCompressed` — Parquet has per-page
# compression by spec (each column chunk's codec is independent).
#
# `Compression` conformers are ONE-PER-ALGORITHM, NOT one-per (format ×
# algorithm) — `Snappy` is `Snappy` whether used inside Parquet or inside
# `WholeFileCompressed[Jsonl, Snappy]`. The two positions in the type tree
# are the only point of asymmetry.
#
# Conformers (8 total, see `compression_codecs.mojo`):
#   WORKING (4):
#     - `Uncompressed`   — no-op identity codec; Parquet codec id 0.
#     - `Snappy`         — libsnappy FFI; Parquet codec id 1; DEFAULT for Parquet.
#     - `Zstd[level: Int = 3]` — libzstd FFI; Parquet codec id 6; ".zst".
#     - `Gzip[level: Int = 6]` — libz via komira_zlib (windowBits auto-detect); Parquet codec id 2; ".gz".
#   SCAFFOLD (4) — trait shape lands; bodies raise clear "not yet wired" errors:
#     - `Lzo`            — legacy; Parquet codec id 3.
#     - `Brotli[quality: Int = 11]` — text-friendly; Parquet codec id 4.
#     - `Lz4Raw`         — fast; Parquet codec id 7.
#     - `Zlib[level: Int = 6]` — raw deflate; Parquet codec id 8.
#
# The 4 scaffold conformers are STRUCTURALLY COMPLETE (they satisfy the
# `Compression` trait and have correct `PARQUET_CODEC_ID` / `FILE_EXTENSION` /
# `NAME` so `(F == X)` cascades pick them up); their compress /
# decompress raise `Error("<codec>: not yet wired in trait conformer; use
# komira_parquet.compression for production paths")`. The `komira_parquet.
# compression` FFI handles the production read/write paths.
#
# **Why no Snappy DELEGATION to the native Mojo Snappy port?** Arrow cannot
# depend on `komira_parquet` (cycle direction: parquet -> arrow). The Snappy
# conformer here calls libsnappy via `external_call` (same as the production
# FFI path in `komira_parquet`); the native Mojo Snappy port lives in
# `komira_parquet`. The conformer is a thin FFI shim, NOT a
# re-implementation of Snappy.
# =============================================================================


trait Compression(Copyable, Movable, ImplicitlyCopyable):
    """Byte-stream compression algorithm.

    Used in two positions in the type tree:
      1. As Parquet's per-page compression parameter:
         `Parquet[C: Compression = Snappy]`.
      2. As the codec inside `WholeFileCompressed[Inner, C]` for record-stream
         formats with no built-in compression (e.g.
         `WholeFileCompressed[Jsonl, Gzip]` for `.jsonl.gz`).

    Conformers (8 total):
      WORKING:
        - `Uncompressed`        — no-op identity; Parquet codec id 0.
        - `Snappy`              — fast/decent; Parquet codec id 1; DEFAULT for Parquet.
        - `Gzip[level: Int = 6]` — DEFLATE+gzip wrapper; Parquet id 2; ".gz".
        - `Zstd[level: Int = 3]` — modern fast/dense; Parquet codec id 6; ".zst".
      SCAFFOLD (trait shape only; bodies raise clear "not yet wired" errors):
        - `Lzo`                 — legacy; Parquet codec id 3.
        - `Brotli[quality: Int = 11]` — text-friendly; Parquet codec id 4.
        - `Lz4Raw`              — fast; Parquet codec id 7.
        - `Zlib[level: Int = 6]` — raw deflate; Parquet codec id 8.

    Compression conformers are ONE-PER-ALGORITHM, NOT one-per (format ×
    algorithm) — `Snappy` is `Snappy` whether used inside Parquet or inside
    `WholeFileCompressed[Jsonl, ...]`. The two positions in the type tree
    are the only point of asymmetry.

    The trait API is intentionally minimal:

      - `PARQUET_CODEC_ID: Int8` — Thrift CompressionCodec enum value.
        Read by the Parquet writer / reader for the `ColumnChunk.codec`
        field. Matches `komira_parquet.types.CompressionCodec` UInt8 values.

      - `FILE_EXTENSION: StringLiteral` — file-suffix marker for whole-file
        wrap (`.gz`, `.zst`, etc.). `""` (empty) means "no extension"
        (Uncompressed) and disables `WholeFileCompressed[..., C]` extension
        auto-detect — empty-extension whole-file wrapping is nonsense.

      - `NAME: StringLiteral` — human-readable, for errors + logs.

      - `compress(input: Span[UInt8, _]) raises -> List[UInt8]` — encode
        `input` to a fresh List of bytes. Returned by value (`var out = ...`).

      - `decompress(input: Span[UInt8, _], expected_size: Int) raises -> List[UInt8]`
        — decode `input` to a fresh List of bytes. `expected_size` is the
        uncompressed-length HINT (caller-supplied from Parquet page header
        or whole-file size metadata); used to pre-allocate the output buffer.

    Encapsulation: the trait surface is in terms of `Span[UInt8, _]` (origin-
    polymorphic, safe). Conformer bodies are free to use UnsafePointer
    internally for FFI; see `# FFI-BOUNDARY:` comments in conformer files.
    """

    comptime PARQUET_CODEC_ID: Int8
    comptime FILE_EXTENSION: StaticString
    comptime NAME: StaticString

    @staticmethod
    def compress(input: Span[UInt8, _]) raises -> List[UInt8]:
        ...

    @staticmethod
    def decompress(
        input: Span[UInt8, _], expected_size: Int
    ) raises -> List[UInt8]:
        ...


# =============================================================================
# ArrowIpcCompression — sub-trait for codecs in Arrow IPC's BodyCompression
# =============================================================================
#
# A sub-trait of `Compression` so the
# `Arrow[C: ArrowIpcCompression]` marker can compile-time constrain `C` to
# the subset of codecs that Arrow IPC's `BodyCompression.codec` enum
# actually ships (LZ4_FRAME = 0; ZSTD = 1; Uncompressed = -1 sentinel for
# "no BodyCompression flatbuf emitted").
#
# Compile-time prevents:
#   - `Arrow[Snappy]`, `Arrow[Gzip]`, `Arrow[Lzo]`, `Arrow[Brotli]`,
#     `Arrow[Lz4Raw]`, `Arrow[Zlib]` — none of these are in Arrow IPC's
#     BodyCompression.codec enum.
#   - `Parquet[Lz4Frame]` — Lz4Frame is not in Parquet's CompressionCodec
#     Thrift enum (Parquet uses LZ4-Raw at id 7, not LZ4-Frame).
#
# The 3 conformers (Uncompressed, Lz4Frame, Zstd[level]) live in
# `arrow.compression_codecs`. Each redeclares its full conformance
# list at the struct-decl line (Mojo has no "extend an existing
# struct's conformance" operator). Listing `ArrowIpcCompression(Compression)`
# in the struct's conformance implies `Compression` via the sub-trait
# relationship.
#
# Writer-side behavior:
#   - `C.ARROW_IPC_CODEC_ID == -1`: encoder MUST skip BodyCompression
#     flatbuf field emission. Emitting `BodyCompression{codec: -1}` is
#     invalid Arrow IPC; the spec's "no field" path means "uncompressed
#     body".
#   - `C.ARROW_IPC_CODEC_ID in {0, 1}`: encoder emits
#     `BodyCompression{codec: C.ARROW_IPC_CODEC_ID}` per RecordBatch.
# =============================================================================


trait ArrowIpcCompression(Compression):
    """Subset of `Compression` conformers that ship in Arrow IPC's
    `BodyCompression.codec` enum (Arrow IPC File Format spec).

    Sub-trait of `Compression`. Only `Uncompressed`, `Lz4Frame`, and
    `Zstd[level]` conform. The `Arrow[C: ArrowIpcCompression]` marker
    (in `arrow.formats`) uses this sub-trait to compile-time
    prevent `Arrow[Snappy]` / `Arrow[Gzip]` / `Arrow[Lz4Raw]` / etc.
    (all wire-incorrect — not in the Arrow IPC enum).

    `ARROW_IPC_CODEC_ID` enum values per the Arrow IPC `Message.fbs`
    spec (`org.apache.arrow.flatbuf.CompressionType`):
      - `-1` (sentinel) = Uncompressed body — encoder MUST NOT emit a
        `BodyCompression` flatbuf field for this codec; per spec, the
        absence of the field means "uncompressed body".
      - `0` = LZ4_FRAME (LZ4 frame format; magic `0x184D2204`).
      - `1` = ZSTD.

    Note: Arrow IPC uses LZ4-Frame, NOT LZ4-Raw (the form Parquet uses
    at Parquet codec id 7). The two LZ4 framings are wire-incompatible
    — Arrow IPC's `Lz4Frame` and Parquet's `Lz4Raw` are separate
    conformers.

    The Lz4Frame body calls `liblz4`'s `LZ4F_compressFrame` /
    `LZ4F_decompress` through komira_lz4's frame API.

    `decompress_into[o](src, dst, dst_capacity)` is a zero-extra-copy
    decompress directly into a pre-allocated output region. Saves the
    codec-side `List[UInt8]` alloc + the driver-side memcpy from
    `List → output frame body`. Same FFI calls underneath; just the
    output destination changes. Sub-trait scope: only Arrow IPC codecs
    need this hot-path optimization; Parquet keeps its own runtime-
    dispatched `decompress(...)` direct-FFI surface in komira_parquet.

    The write-side mirror is `compress_into[o](src, dst, dst_capacity) -> Int`.
    The codec FFI writes directly into the output frame's compressed
    body region (pre-sized to `compressBound(raw_len)` per buffer)
    instead of materializing a `List[UInt8]` that the driver then
    memcpys via `copy_from_bytes_list_at`. Same FFI calls underneath
    (`LZ4F_compressFrame` / `ZSTD_compress`); just the output
    destination changes. `compress_bound(src_size) -> Int`
    lets the driver pre-compute the output frame's worst-case body
    size before any compress call (matches the read-side's PASS-1
    prefix scan).

    The cached-dctx decompress path:
      - `create_dctx() -> UnsafePointer[UInt8, MutUntrackedOrigin]`
        creates one decompression context per worker (mirrors
        arrow-cpp's per-thread dctx cache).
      - `free_dctx(dctx)` releases it (called by `_CodecDctxHandle`'s
        destructor at end-of-dispatch).
      - `decompress_into_with_dctx[o](dctx, src, dst, dst_capacity)`
        decompresses with a pre-created dctx; calls the codec's reset
        function between buffers to amortize ctor/dtor cost.
        Lz4Frame: `LZ4F_resetDecompressionContext` + `LZ4F_decompress`
                  (through komira_lz4's `Lz4FrameDecoder`).
        Zstd: `ZSTD_DCtx_reset(ZSTD_reset_session_only)` +
              `ZSTD_decompressDCtx`.
        Uncompressed: memcpy (dctx ignored).

    Once RecordBatches are coalesced, the dominant cost is thousands of
    `LZ4F_createDecompressionContext` + `LZ4F_freeDecompressionContext`
    pairs per file decode. Caching one dctx per worker drops
    that to one per worker + cheap `LZ4F_resetDecompressionContext` calls.

    The dctx opaque-pointer type crosses the trait-method boundary but
    is encapsulated by `_CodecDctxHandle[C]` (declared in
    `compression_codecs.mojo`) — the handle's destructor calls
    `C.free_dctx(...)`, so the raw `UnsafePointer` is never visible to
    the dispatch driver in `ipc_body_compression.mojo`.
    """

    comptime ARROW_IPC_CODEC_ID: Int8

    @staticmethod
    def decompress_into[
        o: Origin[mut=True], //,
    ](
        src: Span[UInt8, _],
        dst: UnsafePointer[UInt8, o],
        dst_capacity: Int,
    ) raises -> Int:
        """Decompress `src` directly into the `dst_capacity` bytes at
        `dst`. Returns the number of bytes actually written. Raises if
        the codec FFI fails or if the decompressed payload does not fit.

        Zero-extra-copy variant of `decompress`: avoids the `List[UInt8]`
        allocation + codec-side internal memcpy that the existing
        `decompress(Span, expected_size) -> List[UInt8]` shape requires.
        Used by `decompress_record_batch_frame` /
        `decompress_dictionary_batch_frame` in `ipc_body_compression.mojo`,
        where the final destination (the output IPC frame's body region)
        is known up-front.

        SAFETY CONTRACT — CALLER:
          - `dst` MUST be valid for `dst_capacity` bytes of mutable
            writes; its origin (`o`) MUST keep the backing buffer alive
            for the duration of the synchronous FFI call.
          - `dst_capacity` MUST be >= the expected uncompressed payload
            size. Codec implementations are free to raise if the actual
            decompressed size differs from the expected size (caller-
            supplied length prefix from Arrow IPC's per-buffer
            uncompressed_length field).
          - The Span `src` and the buffer behind `dst` MUST NOT alias
            (codec FFI may read forward from `src` while writing to
            `dst` — no in-place decompression is permitted).

        SAFETY CONTRACT — IMPLEMENTOR:
          - MUST NOT escape `dst` past the synchronous call.
          - MUST honor `dst_capacity` (do not write past dst+dst_capacity).
          - MUST return the number of bytes actually written.
        """
        ...

    @staticmethod
    def compress_bound(src_size: Int) raises -> Int:
        """Return the worst-case size of the compressed output for a
        `src_size`-byte input. Used by the write-side driver
        (`encode_record_batch_message_compressed` /
        `encode_dictionary_batch_message_from_string_column_compressed`)
        to pre-size the output frame's compressed body region BEFORE
        calling `compress_into`.

        For LZ4-Frame: returns `LZ4F_compressFrameBound(src_size, NULL)`.
        For Zstd: returns `ZSTD_compressBound(src_size)`.
        For Uncompressed (sentinel — not exercised by encoders that emit
          BodyCompression flatbuf): returns `src_size`.

        Synchronous; no FFI side effects beyond a single bound query.
        """
        ...

    @staticmethod
    def compress_into[
        o: Origin[mut=True], //,
    ](
        src: Span[UInt8, _],
        dst: UnsafePointer[UInt8, o],
        dst_capacity: Int,
    ) raises -> Int:
        """Compress `src` directly into the `dst_capacity` bytes at
        `dst`. Returns the number of bytes actually written (the
        compressed payload's length). Raises if the codec FFI fails
        or if the output does not fit in `dst_capacity`.

        Zero-extra-copy WRITE-side variant of `compress`: avoids the
        `List[UInt8]` allocation + driver-side `copy_from_bytes_list_at`
        memcpy that the existing `compress(Span) -> List[UInt8]` shape
        requires. Mirror of `decompress_into`.

        Used by `encode_record_batch_message_compressed[C]` /
        `encode_dictionary_batch_message_from_string_column_compressed[C]`
        in `ipc_body_compression.mojo`. The driver pre-sizes the output
        frame's body region using `compress_bound(raw_len)` and writes
        the i64 length-prefix AFTER the codec returns (so the prefix
        records the actual uncompressed length and the cursor advances
        by `8 + actual_compressed_len`).

        SAFETY CONTRACT — CALLER:
          - `dst` MUST be valid for `dst_capacity` bytes of mutable
            writes; its origin (`o`) MUST keep the backing buffer alive
            for the duration of the synchronous FFI call.
          - `dst_capacity` MUST be >= `compress_bound(len(src))`. The
            codec WILL raise if its FFI's worst-case bound is exceeded
            by the actual output (should be impossible for a well-
            formed codec bound).
          - The Span `src` and the buffer behind `dst` MUST NOT alias
            (codec FFI may read forward from `src` while writing to
            `dst` — no in-place compression is permitted).

        SAFETY CONTRACT — IMPLEMENTOR:
          - MUST NOT escape `dst` past the synchronous call.
          - MUST honor `dst_capacity` (do not write past dst+dst_capacity).
          - MUST return the number of bytes actually written.
        """
        ...

    @staticmethod
    def create_dctx() raises -> UnsafePointer[UInt8, MutUntrackedOrigin]:
        """Allocate one decompression context for use by
        `decompress_into_with_dctx`. Returns an opaque, codec-specific
        pointer that MUST be freed via `free_dctx` exactly once.

        For LZ4-Frame: a heap-boxed `komira_lz4.frame.Lz4FrameDecoder`,
        which owns one `LZ4F_dctx`.
        For Zstd: wraps `ZSTD_createDCtx` returning the ZSTD_DCtx pointer.
        For Uncompressed: returns a null sentinel (memcpy path requires
        no dctx state).

        SAFETY CONTRACT:
          - The returned pointer is opaque; callers MUST NOT dereference
            or pointer-arithmetic on it. Pass it back through
            `decompress_into_with_dctx` / `free_dctx`.
          - Single ownership: each handle MUST be freed exactly once.
            `_CodecDctxHandle[C]`'s destructor in `compression_codecs.mojo`
            is the canonical owner; callers SHOULD NOT call `create_dctx`
            directly — go through `_CodecDctxHandle[C]()`.
        """
        ...

    @staticmethod
    def free_dctx(var dctx: UnsafePointer[UInt8, MutUntrackedOrigin]):
        """Free a decompression context previously returned by
        `create_dctx`. Null sentinel is a no-op.

        For LZ4-Frame: `LZ4F_freeDecompressionContext(dctx)`.
        For Zstd: `ZSTD_freeDCtx(dctx)`.
        For Uncompressed: no-op (sentinel was already null).
        """
        ...

    @staticmethod
    def decompress_into_with_dctx[
        o: Origin[mut=True], //,
    ](
        dctx: UnsafePointer[UInt8, MutUntrackedOrigin],
        src: Span[UInt8, _],
        dst: UnsafePointer[UInt8, o],
        dst_capacity: Int,
    ) raises -> Int:
        """Decompress `src` into `dst` using a caller-supplied dctx.
        Returns the number of bytes written.

        Mirror of `decompress_into` but the codec's decompression context
        is provided by the caller (typically a per-worker cache held by
        `_CodecDctxHandle[C]`). The codec MUST call its reset function
        on `dctx` BEFORE the decompress call so that prior state from a
        previous buffer does not leak through.

        For LZ4-Frame:
          - `LZ4F_resetDecompressionContext(dctx)` (always succeeds),
          - then `LZ4F_decompress(dctx, dst, &dstSize, src, &srcSize, NULL)`.
        For Zstd:
          - `ZSTD_DCtx_reset(dctx, ZSTD_reset_session_only)` (drops the
            in-flight session but keeps any cached dictionaries/parameters),
          - then `ZSTD_decompressDCtx(dctx, dst, dstCapacity, src, srcSize)`.
        For Uncompressed: dctx ignored; memcpy.

        SAFETY CONTRACT — CALLER:
          - `dctx` MUST have been obtained from a prior `create_dctx`
            call on the same codec `C`; MUST NOT have been freed yet.
          - The dctx MUST NOT be shared across concurrent threads. The
            per-worker dispatch model in `ipc_body_compression.mojo`
            guarantees one dctx per worker, accessed only by that worker.
          - All other constraints from `decompress_into` apply (dst
            validity, dst_capacity, non-aliasing with src).

        SAFETY CONTRACT — IMPLEMENTOR:
          - MUST call the codec's reset function on `dctx` before the
            decompress call.
          - MUST NOT escape `dctx`, `src`, or `dst` past the synchronous
            FFI call.
          - MUST return the number of bytes actually written.
        """
        ...

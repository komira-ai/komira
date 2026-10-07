# =============================================================================
# Compression conformers — 8 codec marker structs implementing `Compression`
# =============================================================================
#
# WORKING — call the codec libraries through this package's codec modules:
# snappy through snappy_block.mojo (statically linked), libzstd through the
# handle of codec_libraries.mojo, and libz / liblz4 through the komira_zlib and
# komira_lz4 layers (which own those libraries' handles and FFI):
#   - `Uncompressed`               — no-op (no FFI).
#   - `Snappy`                     — snappy, linked into the binary.
#   - `Zstd[level: Int = 3]`       — libzstd.
#   - `Gzip[level: Int = 6]`       — libz via komira_zlib (auto-detect read).
#   - `Lz4Raw`                     — liblz4 raw block via komira_lz4.
#   - `Lz4Frame`                   — liblz4 frame via komira_lz4.frame.
#
# SCAFFOLD — trait shape lands; bodies raise clear errors:
#   - `Lzo`                        — Parquet codec id 3.
#   - `Brotli[quality: Int = 11]`  — Parquet codec id 4.
#   - `Zlib[level: Int = 6]`       — Parquet codec id 8.
#
# The scaffold bodies raise `Error("<codec>: not yet wired in
# Compression trait conformer (scaffold); ...")` pointing at
# `komira_parquet.compression` for production paths. The trait shape itself is
# COMPLETE and `(F == X)` dispatch picks up scaffold types
# identically to working ones; only the runtime body differs.
#
# FFI-BOUNDARY discipline:
#   - All conformer compress/decompress methods accept `Span[UInt8, _]`
#     (origin-polymorphic, safe surface — encapsulation rule).
#   - The Zstd conformer calls libzstd through `_zstd_handle()`
#     (codec_libraries.mojo) for its decompression contexts and its
#     pointer-taking `*_into` methods; helpers use `.unsafe_ptr()` +
#     `.unsafe_origin_cast[MutUntrackedOrigin]()` ONLY at those call sites,
#     with `# FFI-BOUNDARY:` comments.
#   - The Snappy / Zstd / Uncompressed conformers each build a
#     `List[UInt8](capacity=...)` output, call the C lib into that buffer,
#     then set the final length. Gzip / Lz4Raw / Lz4Frame hand a Span of
#     their output List to the komira_zlib / komira_lz4 Span API.
#
# HANDLES: no library is opened here. libzstd's process-lifetime handle is
# codec_libraries.mojo's; libz and liblz4 are komira_zlib's and komira_lz4's,
# with their own process-lifetime singletons and known-answer tests.
# =============================================================================

from std.memory import OwnedPointer, unsafe_memcpy, alloc

from komira_compression.codec_libraries import _zstd_handle
from komira_compression.compression import ArrowIpcCompression, Compression
from komira_compression.snappy_block import (
    snappy_compress_into,
    snappy_max_compressed_length,
    snappy_uncompress_into,
    snappy_uncompressed_length,
)
from komira_lz4.codec import (
    lz4_compress_bound,
    lz4_compress_into,
    lz4_decompress_into,
)
from komira_lz4.frame import (
    Lz4FrameDecoder,
    lz4_frame_compress_bound,
    lz4_frame_compress_into,
    lz4_frame_decompress_into,
)
from komira_zlib import (
    ZLIB_WINDOW_BITS_AUTO,
    ZLIB_WINDOW_BITS_ZLIB,
    zlib_compress_bound,
    zlib_crc32,
    zlib_deflate_into,
    zlib_inflate_into,
)


@always_inline
def _null_ptr[T: AnyType, o: Origin]() -> UnsafePointer[T, o]:
    """A NULL typed pointer (replaces the b2-removed `UnsafePointer[T, o]()`
    null ctor).

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the
    # bare pointer (the non-null-pointer layout guarantee); `None` is
    # the all-zero (NULL) bit pattern. Replaces the removed null ctor with
    # NO `unsafe_from_address=Int(0)`. Used for FFI NULL sentinels/args
    # (e.g. Arrow C-ABI NULL fields, codec NULL prefs/options); the C side
    # treats NULL as documented (default options / absent field).
    #
    # NOTE: the `MutExternalOrigin` ORIGIN on the C-Data-Interface FFI
    # surface is the documented FFI-boundary carve-out (allowlisted); its
    # migration to a concrete origin is a separate effort, OUT OF SCOPE for
    # the b2 null-ctor unblock.
    """
    var none: Optional[UnsafePointer[T, o]] = None
    return UnsafePointer(to=none).bitcast[UnsafePointer[T, o]]()[]


# =============================================================================
# Span -> FFI-pointer adapter
# =============================================================================
#
# Conformer trait methods accept `Span[UInt8, _]` (origin-poly). At the FFI
# boundary we cast to `UnsafePointer[UInt8, MutUntrackedOrigin]` because the
# C ABI does not speak Mojo origins. The cast is sound because the C call
# is synchronous and the caller proves the buffer outlives the call by
# holding the `Span` in the enclosing scope.


@always_inline
def _span_ptr(s: Span[UInt8, _]) -> UnsafePointer[UInt8, MutUntrackedOrigin]:
    """Coerce a `Span[UInt8, _]` to a `MutUntrackedOrigin`-cast UnsafePointer
    for FFI. FFI-BOUNDARY: synchronous C call; caller owns the buffer.
    """
    # SAFETY: see header. The cast does not extend lifetime; the Span ref
    # remains in scope across the FFI call below.
    return (
        s.unsafe_ptr()
        .unsafe_mut_cast[True]()
        .unsafe_origin_cast[MutUntrackedOrigin]()
    )


@always_inline
def _list_ptr(
    mut buf: List[UInt8],
) -> UnsafePointer[UInt8, MutUntrackedOrigin]:
    """Coerce a `List[UInt8]`'s data pointer to FFI shape."""
    # SAFETY: synchronous FFI; `buf` is not reallocated across the call
    # because the caller pre-reserved capacity (no append happens between
    # this call and consumption of the pointer).
    return buf.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin]()


# =============================================================================
# Uncompressed — no-op identity codec
# =============================================================================


@fieldwise_init
struct Uncompressed(ArrowIpcCompression):
    """No-op identity codec (Parquet codec id 0). `compress` and `decompress`
    are both memcpy passthroughs.

    Zero-byte struct (the `_reserved` field is a Mojo @fieldwise_init
    placeholder; Bool is one byte and ignored at the type-system level).

    Conforms to `ArrowIpcCompression(Compression)`. The
    `ARROW_IPC_CODEC_ID = -1` sentinel means "no
    BodyCompression flatbuf emitted" — the spec's "no field" path means
    "uncompressed body" (Arrow IPC's `CompressionType` enum only ships
    0=LZ4_FRAME and 1=ZSTD; -1 is an internal sentinel).
    """

    var _reserved: Bool

    comptime PARQUET_CODEC_ID: Int8 = 0
    comptime ARROW_IPC_CODEC_ID: Int8 = -1
    comptime FILE_EXTENSION: StaticString = ""
    comptime NAME: StaticString = "uncompressed"

    def __init__(out self):
        self._reserved = False

    @staticmethod
    def compress(input: Span[UInt8, _]) raises -> List[UInt8]:
        var n = len(input)
        var out = List[UInt8](capacity=n)
        # SAFETY: copy `n` bytes from input's underlying buffer into the
        # freshly-reserved List backing storage. List is then size-set to
        # `n` so subsequent reads see the copied content.
        unsafe_memcpy(dest=out.unsafe_ptr(), src=input.unsafe_ptr(), count=n)
        out.resize(unsafe_uninit_length=n)
        return out^

    @staticmethod
    def decompress(
        input: Span[UInt8, _], expected_size: Int
    ) raises -> List[UInt8]:
        var n = len(input)
        if expected_size != 0 and expected_size != n:
            raise Error(
                "Uncompressed.decompress: expected_size="
                + String(expected_size)
                + " does not match input.len()="
                + String(n)
            )
        var out = List[UInt8](capacity=n)
        unsafe_memcpy(dest=out.unsafe_ptr(), src=input.unsafe_ptr(), count=n)
        out.resize(unsafe_uninit_length=n)
        return out^

    @staticmethod
    def decompress_into[
        o: Origin[mut=True], //,
    ](
        src: Span[UInt8, _],
        dst: UnsafePointer[UInt8, o],
        dst_capacity: Int,
    ) raises -> Int:
        """Identity codec: byte-copy `src` directly into `dst`. The
        Arrow IPC compressed-body path with sentinel `uncompressed_length
        == -1` short-circuits in the driver and never reaches this
        method — but it's wired for trait completeness.
        """
        var n = len(src)
        if n > dst_capacity:
            raise Error(
                "Uncompressed.decompress_into: input.len()="
                + String(n) + " > dst_capacity="
                + String(dst_capacity)
            )
        # FFI-BOUNDARY: stdlib memcpy; synchronous; caller owns `dst`.
        unsafe_memcpy(
            dest=dst.unsafe_origin_cast[MutUntrackedOrigin](),
            src=src.unsafe_ptr(),
            count=n,
        )
        return n

    @staticmethod
    def compress_bound(src_size: Int) raises -> Int:
        """Identity codec: compressed size equals uncompressed size."""
        return src_size

    @staticmethod
    def compress_into[
        o: Origin[mut=True], //,
    ](
        src: Span[UInt8, _],
        dst: UnsafePointer[UInt8, o],
        dst_capacity: Int,
    ) raises -> Int:
        """Identity codec: byte-copy `src` directly into `dst`. Trait
        completeness; the Arrow IPC compressed-write path runtime-
        guards against routing Uncompressed through this method (would
        emit BodyCompression{codec:-1} which is invalid Arrow IPC).
        """
        var n = len(src)
        if n > dst_capacity:
            raise Error(
                "Uncompressed.compress_into: input.len()="
                + String(n) + " > dst_capacity="
                + String(dst_capacity)
            )
        # FFI-BOUNDARY: stdlib memcpy; synchronous; caller owns `dst`.
        unsafe_memcpy(
            dest=dst.unsafe_origin_cast[MutUntrackedOrigin](),
            src=src.unsafe_ptr(),
            count=n,
        )
        return n

    @staticmethod
    def create_dctx() raises -> UnsafePointer[UInt8, MutUntrackedOrigin]:
        """Uncompressed has no decompression-context state — return a
        null sentinel. The Arrow IPC sentinel-uncompressed path
        short-circuits in the driver and never reaches
        `decompress_into_with_dctx`; this is for trait completeness.
        """
        return _null_ptr[UInt8, MutUntrackedOrigin]()

    @staticmethod
    def free_dctx(var dctx: UnsafePointer[UInt8, MutUntrackedOrigin]):
        """No-op (sentinel is already null)."""
        pass

    @staticmethod
    def decompress_into_with_dctx[
        o: Origin[mut=True], //,
    ](
        dctx: UnsafePointer[UInt8, MutUntrackedOrigin],
        src: Span[UInt8, _],
        dst: UnsafePointer[UInt8, o],
        dst_capacity: Int,
    ) raises -> Int:
        """Uncompressed dctx-aware path: dctx ignored; memcpy."""
        return Self.decompress_into(src, dst, dst_capacity)


# =============================================================================
# Snappy — the snappy C API, statically linked (Parquet codec id 1)
# =============================================================================
#
# Through snappy_block.mojo, the one module that declares the snappy symbols.
# =============================================================================


@fieldwise_init
struct Snappy(Compression):
    """The snappy compression codec, calling the snappy C API. Parquet codec
    id 1. Default for Parquet (matches DuckDB).

    The snappy library is statically linked into every binary that uses
    this package, so no shared library is needed at run time. A native Mojo
    Snappy decoder lives in `komira_parquet_codec` and is used on the Parquet
    path; this conformer calls the C library through `snappy_block`.
    """

    var _reserved: Bool

    comptime PARQUET_CODEC_ID: Int8 = 1
    comptime FILE_EXTENSION: StaticString = ""
    comptime NAME: StaticString = "snappy"

    def __init__(out self):
        self._reserved = False

    @staticmethod
    def compress(input: Span[UInt8, _]) raises -> List[UInt8]:
        var n = len(input)
        var max_out = snappy_max_compressed_length(n)
        var out = List[UInt8](capacity=max_out)
        # SAFETY: the `max_out` bytes are the List's reserved capacity; snappy
        # writes the block into them and the List is cut to what it wrote.
        out.resize(unsafe_uninit_length=max_out)
        var written: Int
        try:
            written = snappy_compress_into(Span(out), input)
        except e:
            raise Error("Snappy.compress: " + String(e))
        out.resize(unsafe_uninit_length=written)
        return out^

    @staticmethod
    def decompress(
        input: Span[UInt8, _], expected_size: Int
    ) raises -> List[UInt8]:
        var n = len(input)
        if n == 0:
            raise Error("Snappy.decompress: empty input")

        # Compute or accept output size.
        var out_len: Int
        if expected_size > 0:
            out_len = expected_size
        else:
            # Ask snappy for the declared uncompressed length.
            try:
                out_len = snappy_uncompressed_length(input)
            except e:
                raise Error("Snappy.decompress: " + String(e))

        var out = List[UInt8](capacity=out_len)
        # SAFETY: the `out_len` bytes are the List's reserved capacity; snappy
        # writes at most that many and the List is cut to what it wrote.
        out.resize(unsafe_uninit_length=out_len)
        var written: Int
        try:
            written = snappy_uncompress_into(Span(out), input)
        except e:
            raise Error("Snappy.decompress: " + String(e))
        out.resize(unsafe_uninit_length=written)
        return out^


# =============================================================================
# Zstd[level] — libzstd through codec_libraries.mojo's handle (Parquet codec id 6)
# =============================================================================
#
# zstd.h API used:
#   size_t ZSTD_decompress(void* dst, size_t dstCapacity,
#                          const void* src, size_t srcSize);
#   size_t ZSTD_compress(void* dst, size_t dstCapacity,
#                        const void* src, size_t srcSize, int compressionLevel);
#   size_t ZSTD_compressBound(size_t srcSize);
#   unsigned ZSTD_isError(size_t result);
# =============================================================================


@fieldwise_init
struct Zstd[level: Int = 3](ArrowIpcCompression):
    """The libzstd FFI compression codec. Parquet codec id 6.

    `level` is a comptime parameter (typical: 1-19; default 3 matches
    DuckDB / pyarrow / parquet-mr).

    Conforms to `ArrowIpcCompression(Compression)`. `ARROW_IPC_CODEC_ID = 1` matches Arrow IPC `CompressionType.ZSTD`.
    Per-buffer body compression in Arrow IPC RecordBatch messages.
    """

    var _reserved: Bool

    comptime PARQUET_CODEC_ID: Int8 = 6
    comptime ARROW_IPC_CODEC_ID: Int8 = 1
    comptime FILE_EXTENSION: StaticString = ".zst"
    comptime NAME: StaticString = "zstd"

    def __init__(out self):
        self._reserved = False

    @staticmethod
    def compress(input: Span[UInt8, _]) raises -> List[UInt8]:
        var n = len(input)
        var handle_ptr = _zstd_handle()
        var bound = handle_ptr[].call["ZSTD_compressBound", Int](n)
        var out = List[UInt8](capacity=bound)

        # FFI-BOUNDARY:
        var result = handle_ptr[].call["ZSTD_compress", Int](
            _list_ptr(out),
            bound,
            _span_ptr(input),
            n,
            Int32(Self.level),
        )
        var is_err = handle_ptr[].call["ZSTD_isError", Int](result)
        if is_err != 0:
            raise Error(
                "Zstd.compress: ZSTD_compress failed (result="
                + String(result) + ", n=" + String(n) + ")"
            )
        out.resize(unsafe_uninit_length=result)
        return out^

    @staticmethod
    def decompress(
        input: Span[UInt8, _], expected_size: Int
    ) raises -> List[UInt8]:
        var n = len(input)
        if expected_size <= 0:
            raise Error(
                "Zstd.decompress: expected_size must be > 0 (got "
                + String(expected_size) + ")"
            )
        var out = List[UInt8](capacity=expected_size)
        var handle_ptr = _zstd_handle()
        # FFI-BOUNDARY:
        var result = handle_ptr[].call["ZSTD_decompress", Int](
            _list_ptr(out),
            expected_size,
            _span_ptr(input),
            n,
        )
        var is_err = handle_ptr[].call["ZSTD_isError", Int](result)
        if is_err != 0:
            raise Error(
                "Zstd.decompress: ZSTD_decompress failed (result="
                + String(result) + ", n=" + String(n) + ")"
            )
        out.resize(unsafe_uninit_length=result)
        return out^

    @staticmethod
    def create_dctx() raises -> UnsafePointer[UInt8, MutUntrackedOrigin]:
        """Create a `ZSTD_DCtx*` via `ZSTD_createDCtx()`. The returned
        pointer is opaque to the caller; pass through `free_dctx` /
        `decompress_into_with_dctx`. Raises on alloc failure (null
        return from libzstd, indicates OOM).
        """
        var handle_ptr = _zstd_handle()
        # FFI-BOUNDARY: ZSTD_createDCtx() returns a ZSTD_DCtx* (opaque);
        # we hold it as UInt8* for cross-codec uniformity. NULL = OOM.
        var dctx = handle_ptr[].call[
            "ZSTD_createDCtx",
            UnsafePointer[UInt8, MutUntrackedOrigin],
        ]()
        if Int(dctx) == 0:
            raise Error(
                "Zstd.create_dctx: ZSTD_createDCtx returned null (OOM)"
            )
        return dctx

    @staticmethod
    def free_dctx(var dctx: UnsafePointer[UInt8, MutUntrackedOrigin]):
        """Release a `ZSTD_DCtx*` via `ZSTD_freeDCtx(dctx)`. Null-safe."""
        if Int(dctx) == 0:
            return
        try:
            var handle_ptr = _zstd_handle()
            # FFI-BOUNDARY: ZSTD_freeDCtx returns a size_t result; for
            # the well-formed pointer case it returns 0, but we don't
            # check (destructor path, can't raise).
            var _rc = handle_ptr[].call["ZSTD_freeDCtx", Int](dctx)
        except:
            # Destructor swallows handle-lookup errors (process-lifetime
            # singleton; failure here implies a deeper system issue
            # we can't recover from in a __deinit__ path).
            pass

    @staticmethod
    def decompress_into_with_dctx[
        o: Origin[mut=True], //,
    ](
        dctx: UnsafePointer[UInt8, MutUntrackedOrigin],
        src: Span[UInt8, _],
        dst: UnsafePointer[UInt8, o],
        dst_capacity: Int,
    ) raises -> Int:
        """ZSTD decompress into `dst` using the caller-supplied `dctx`.
        Calls `ZSTD_DCtx_reset(dctx, ZSTD_reset_session_only)` BEFORE
        each decompress so prior in-flight state does not leak through.

        A per-worker cache removes one ZSTD_createDCtx + ZSTD_freeDCtx
        pair per compressed buffer. arrow-cpp uses this pattern in
        `arrow/util/compression_zstd.cc` (one DCtx per thread).
        """
        var n = len(src)
        if dst_capacity <= 0:
            raise Error(
                "Zstd.decompress_into_with_dctx: dst_capacity must be > 0 "
                "(got " + String(dst_capacity) + ")"
            )
        if Int(dctx) == 0:
            raise Error(
                "Zstd.decompress_into_with_dctx: null dctx (call "
                "create_dctx first)"
            )
        var handle_ptr = _zstd_handle()
        # FFI-BOUNDARY: ZSTD_DCtx_reset(dctx, 1) where
        # ZSTD_reset_session_only = 1 per zstd.h `ZSTD_ResetDirective`
        # enum. Resets the streaming session but preserves any cached
        # parameters/dictionaries (which we don't use; the call is
        # cheap regardless).
        var _reset_rc = handle_ptr[].call["ZSTD_DCtx_reset", Int](
            dctx, Int32(1)
        )
        # FFI-BOUNDARY: ZSTD_decompressDCtx is the dctx-using variant of
        # ZSTD_decompress; same semantics, but reuses the passed context
        # instead of allocating a fresh one.
        var result = handle_ptr[].call["ZSTD_decompressDCtx", Int](
            dctx,
            dst.unsafe_origin_cast[MutUntrackedOrigin](),
            dst_capacity,
            _span_ptr(src),
            n,
        )
        var is_err = handle_ptr[].call["ZSTD_isError", Int](result)
        if is_err != 0:
            raise Error(
                "Zstd.decompress_into_with_dctx: ZSTD_decompressDCtx"
                " failed (result=" + String(result) + ", n=" + String(n)
                + ", dst_capacity=" + String(dst_capacity) + ")"
            )
        return result

    @staticmethod
    def decompress_into[
        o: Origin[mut=True], //,
    ](
        src: Span[UInt8, _],
        dst: UnsafePointer[UInt8, o],
        dst_capacity: Int,
    ) raises -> Int:
        """ZSTD decompress directly into `dst`. Zero-extra-copy variant
        of `decompress`: the FFI writes its output into `dst` (the
        Arrow IPC output frame's body region) instead of into an
        intermediate `List[UInt8]` that the driver then memcpys.

        Avoids the `List` alloc + per-buffer memcpy on the LZ4/Zstd read
        arms.
        """
        var n = len(src)
        if dst_capacity <= 0:
            raise Error(
                "Zstd.decompress_into: dst_capacity must be > 0 (got "
                + String(dst_capacity) + ")"
            )
        var handle_ptr = _zstd_handle()
        # FFI-BOUNDARY: `dst` lifetime guaranteed by caller per
        # SAFETY contract on the trait method (synchronous FFI).
        var result = handle_ptr[].call["ZSTD_decompress", Int](
            dst.unsafe_origin_cast[MutUntrackedOrigin](),
            dst_capacity,
            _span_ptr(src),
            n,
        )
        var is_err = handle_ptr[].call["ZSTD_isError", Int](result)
        if is_err != 0:
            raise Error(
                "Zstd.decompress_into: ZSTD_decompress failed (result="
                + String(result) + ", n=" + String(n)
                + ", dst_capacity=" + String(dst_capacity) + ")"
            )
        return result

    @staticmethod
    def compress_bound(src_size: Int) raises -> Int:
        """Worst-case ZSTD compressed size via `ZSTD_compressBound`."""
        var handle_ptr = _zstd_handle()
        return handle_ptr[].call["ZSTD_compressBound", Int](src_size)

    @staticmethod
    def compress_into[
        o: Origin[mut=True], //,
    ](
        src: Span[UInt8, _],
        dst: UnsafePointer[UInt8, o],
        dst_capacity: Int,
    ) raises -> Int:
        """ZSTD compress directly into `dst`. Zero-extra-copy WRITE-side
        variant of `compress`: the FFI writes its output into `dst`
        (the Arrow IPC output frame's compressed body region) instead
        of into an intermediate `List[UInt8]` that the driver then
        memcpys via `copy_from_bytes_list_at`.

        Write-side mirror of the read-side `decompress_into`. Caller pre-sizes the
        output region using `compress_bound(len(src))`.
        """
        var n = len(src)
        if dst_capacity <= 0:
            raise Error(
                "Zstd.compress_into: dst_capacity must be > 0 (got "
                + String(dst_capacity) + ")"
            )
        var handle_ptr = _zstd_handle()
        # FFI-BOUNDARY: `dst` lifetime guaranteed by caller per
        # SAFETY contract on the trait method (synchronous FFI).
        var result = handle_ptr[].call["ZSTD_compress", Int](
            dst.unsafe_origin_cast[MutUntrackedOrigin](),
            dst_capacity,
            _span_ptr(src),
            n,
            Int32(Self.level),
        )
        var is_err = handle_ptr[].call["ZSTD_isError", Int](result)
        if is_err != 0:
            raise Error(
                "Zstd.compress_into: ZSTD_compress failed (result="
                + String(result) + ", n=" + String(n)
                + ", dst_capacity=" + String(dst_capacity) + ")"
            )
        return result


# =============================================================================
# Gzip[level] — libz through komira_zlib (Parquet codec id 2)
# =============================================================================
#
# Write: one zlib-framed deflate stream (`zlib_deflate_into` with
# `ZLIB_WINDOW_BITS_ZLIB`, memLevel 8, default strategy: the same stream libz's
# `compress2` writes) — accepted by all major Parquet readers with auto-detect.
# Read: `zlib_inflate_into` with `ZLIB_WINDOW_BITS_AUTO` (15 + 32), which
# auto-detects gzip / zlib framing (load-bearing for interop with pyarrow /
# parquet-mr / DuckDB / Spark).
#
# ⚠ ZLIB FRAMING IS NOT GZIP FILE FRAMING, and a `.gz` FILE must be the latter.
# The zlib stream is RFC 1950 (2-byte header + deflate + adler32); a gzip FILE
# is RFC 1952 (10-byte header starting `1f 8b` + raw deflate + crc32 + isize).
# Inside a Parquet page the distinction is invisible — every major reader
# auto-detects, which is why the write path above is fine there and has been for
# its whole life. On DISK it is the difference between a file `gunzip`, `zcat`
# and DuckDB can open and one they refuse. `compress_gzip_file` below is the
# file-framing entry; use it for any whole-file `.gz` sink.
#
# libz itself is loaded, once per process, by komira_zlib; this file holds no
# libz handle and declares no libz symbol.
# =============================================================================


@fieldwise_init
struct Gzip[level: Int = 6](Compression):
    """The libz compression codec (through komira_zlib). Parquet codec id 2.

    `level` is a comptime parameter (1-9; default 6 matches DuckDB /
    pyarrow / parquet-mr).

    Write path: `compress` (zlib framing) — for a Parquet PAGE.
    File path:  `compress_gzip_file` (RFC 1952 gzip framing) — for a `.gz` FILE.
    Both take an input of any length, over 4 GiB included (komira_zlib feeds
    libz in 32-bit slices, as `compress2` did; ISIZE is the length mod 2^32).
    Read path: `decompress`, auto-detecting gzip / zlib framing, so both
    framings read back here. The stream must end inside the input and decode
    to at most `expected_size` bytes; a truncated, oversized or corrupt stream
    is refused.
    """

    var _reserved: Bool

    comptime PARQUET_CODEC_ID: Int8 = 2
    comptime FILE_EXTENSION: StaticString = ".gz"
    comptime NAME: StaticString = "gzip"

    def __init__(out self):
        self._reserved = False

    @staticmethod
    def _deflate_zlib(input: Span[UInt8, _], lead: Int) raises -> List[UInt8]:
        """`[lead bytes, uninitialised][zlib stream of input]`, with room for 8
        more bytes after the stream (capacity only)."""
        var n = len(input)
        var bound = zlib_compress_bound(n, ZLIB_WINDOW_BITS_ZLIB)
        var out = List[UInt8](capacity=lead + bound + 8)
        out.resize(unsafe_uninit_length=lead + bound)
        var zlen = zlib_deflate_into(
            Span(out)[lead : lead + bound],
            input,
            Int32(Self.level),
            ZLIB_WINDOW_BITS_ZLIB,
        )
        out.resize(lead + zlen, UInt8(0))
        return out^

    @staticmethod
    def compress(input: Span[UInt8, _]) raises -> List[UInt8]:
        try:
            return Self._deflate_zlib(input, 0)
        except e:
            raise Error("Gzip.compress: " + String(e))

    @staticmethod
    def compress_gzip_file(input: Span[UInt8, _]) raises -> List[UInt8]:
        """Compress to a GZIP FILE (RFC 1952) — the framing a `.gz` file needs.

        `compress` above emits RFC 1950 zlib framing, which is right for a
        Parquet page and WRONG for a file: a `.gz` written that way starts `78 …`
        instead of `1f 8b`, and `gunzip` / `zcat` / DuckDB all refuse it. Our own
        readers auto-detect, so a self round-trip test cannot see the difference
        — only another tool can.

        ZERO-COPY REFRAME. A zlib stream is `[2-byte header][deflate][4-byte
        adler32]`; a gzip file is `[10-byte header][the SAME deflate][4-byte
        crc32][4-byte isize]`. So the zlib stream is written at offset 8, the
        10-byte gzip header then overwrites exactly the two zlib header bytes it
        left at [8,10), and the 8-byte trailer overwrites the 4 adler bytes in
        place. The deflate payload — all of it — is never moved.
        """
        var n = len(input)
        var out: List[UInt8]
        var crc: UInt32
        try:
            # 8 leading bytes, so the deflate body lands at 10.
            out = Self._deflate_zlib(input, 8)
            crc = zlib_crc32(input)
        except e:
            raise Error("Gzip.compress_gzip_file: " + String(e))
        var zlen = len(out) - 8
        if zlen < 6:
            raise Error(
                "Gzip.compress_gzip_file: zlib stream too short to reframe"
                " (zlen=" + String(zlen) + ")"
            )

        # RFC 1952 §2.3 header: magic, CM=8 (deflate), FLG=0 (no name/extra),
        # MTIME=0 (no timestamp — keeps the output BYTE-DETERMINISTIC, which a
        # write-parity corpus depends on), XFL by level, OS=255 (unknown).
        out[0] = UInt8(0x1F)
        out[1] = UInt8(0x8B)
        out[2] = UInt8(8)
        out[3] = UInt8(0)
        out[4] = UInt8(0)
        out[5] = UInt8(0)
        out[6] = UInt8(0)
        out[7] = UInt8(0)
        comptime xfl = 2 if Self.level == 9 else (4 if Self.level == 1 else 0)
        out[8] = UInt8(xfl)
        out[9] = UInt8(255)

        # Trailer, little-endian, starting where the adler32 sat.
        var isize = UInt32(n & 0xFFFFFFFF)
        out.resize(8 + zlen - 4, UInt8(0))
        out.append(UInt8(Int(crc) & 0xFF))
        out.append(UInt8((Int(crc) >> 8) & 0xFF))
        out.append(UInt8((Int(crc) >> 16) & 0xFF))
        out.append(UInt8((Int(crc) >> 24) & 0xFF))
        out.append(UInt8(Int(isize) & 0xFF))
        out.append(UInt8((Int(isize) >> 8) & 0xFF))
        out.append(UInt8((Int(isize) >> 16) & 0xFF))
        out.append(UInt8((Int(isize) >> 24) & 0xFF))
        return out^

    @staticmethod
    def decompress(
        input: Span[UInt8, _], expected_size: Int
    ) raises -> List[UInt8]:
        if expected_size <= 0:
            raise Error(
                "Gzip.decompress: expected_size must be > 0 (got "
                + String(expected_size) + ")"
            )
        var out = List[UInt8](capacity=expected_size)
        out.resize(unsafe_uninit_length=expected_size)
        var written: Int
        try:
            written = zlib_inflate_into(
                Span(out), input, ZLIB_WINDOW_BITS_AUTO
            )
        except e:
            raise Error("Gzip.decompress: " + String(e))
        out.resize(written, UInt8(0))
        return out^


# =============================================================================
# SCAFFOLD codecs — trait shape lands; bodies raise clear errors
# =============================================================================
#
# Each scaffold conformer is structurally complete: it satisfies the
# `Compression` trait, has correct `PARQUET_CODEC_ID` / `FILE_EXTENSION` /
# `NAME`, and so `(F == X)` cascades pick it up. Only the
# runtime body differs — they raise a clear error pointing at
# `komira_parquet.compression` for production paths.


@fieldwise_init
struct Lzo(Compression):
    """LZO compression codec (Parquet codec id 3) — LEGACY scaffold.

    LZO is extremely rare in modern Parquet files; even `komira_parquet.
    compression.decompress` raises a clear "re-write with Snappy or Zstd"
    error for this codec (it has never been wired). This trait conformer
    inherits the same boundary.
    """

    var _reserved: Bool

    comptime PARQUET_CODEC_ID: Int8 = 3
    comptime FILE_EXTENSION: StaticString = ""
    comptime NAME: StaticString = "lzo"

    def __init__(out self):
        self._reserved = False

    @staticmethod
    def compress(input: Span[UInt8, _]) raises -> List[UInt8]:
        raise Error(
            "Lzo.compress: not supported. LZO is a legacy Parquet codec; "
            + "re-write with Snappy or Zstd."
        )

    @staticmethod
    def decompress(
        input: Span[UInt8, _], expected_size: Int
    ) raises -> List[UInt8]:
        raise Error(
            "Lzo.decompress: not supported. LZO is a legacy Parquet codec; "
            + "re-write with Snappy or Zstd."
        )


@fieldwise_init
struct Brotli[quality: Int = 11](Compression):
    """Brotli compression codec (Parquet codec id 4) — SCAFFOLD.

    Brotli is rare in Parquet but common in HTTP / web payloads. This
    conformer carries the trait shape; libbrotli FFI is not wired.
    """

    var _reserved: Bool

    comptime PARQUET_CODEC_ID: Int8 = 4
    comptime FILE_EXTENSION: StaticString = ".br"
    comptime NAME: StaticString = "brotli"

    def __init__(out self):
        self._reserved = False

    @staticmethod
    def compress(input: Span[UInt8, _]) raises -> List[UInt8]:
        raise Error(
            "Brotli.compress: not yet wired in Compression trait conformer "
            + "(scaffold; libbrotli FFI is not wired)."
        )

    @staticmethod
    def decompress(
        input: Span[UInt8, _], expected_size: Int
    ) raises -> List[UInt8]:
        raise Error(
            "Brotli.decompress: not yet wired in Compression trait conformer "
            + "(scaffold; libbrotli FFI is not wired)."
        )


@fieldwise_init
struct Lz4Raw(Compression):
    """LZ4 raw-block compression codec (Parquet codec id 7).

    Delegates to komira_lz4's raw-block API (`lz4_compress_bound` /
    `lz4_compress_into` / `lz4_decompress_into`, over liblz4's
    `LZ4_compressBound` / `LZ4_compress_default` / `LZ4_decompress_safe`).
    This is the raw LZ4 BLOCK format (no frame magic, no block list, no end
    mark); distinct on-wire from `Lz4Frame` (Arrow IPC, magic 0x184D2204). The
    two LZ4 framings are NOT interchangeable.
    """

    var _reserved: Bool

    comptime PARQUET_CODEC_ID: Int8 = 7
    comptime FILE_EXTENSION: StaticString = ".lz4"
    comptime NAME: StaticString = "lz4_raw"

    def __init__(out self):
        self._reserved = False

    @staticmethod
    def compress(input: Span[UInt8, _]) raises -> List[UInt8]:
        # The block format carries NO length/frame prefix — the caller stores
        # the uncompressed size out-of-band (Parquet page header carries it).
        # An empty input is the one-byte empty block 0x00.
        var out: List[UInt8]
        try:
            var bound = lz4_compress_bound(len(input))
            out = List[UInt8](capacity=bound)
            out.resize(unsafe_uninit_length=bound)
            var written = lz4_compress_into(Span(out), input)
            out.resize(written, UInt8(0))
        except e:
            raise Error("Lz4Raw.compress: " + String(e))
        return out^

    @staticmethod
    def decompress(
        input: Span[UInt8, _], expected_size: Int
    ) raises -> List[UInt8]:
        # The raw block carries no uncompressed-size prefix, so `expected_size`
        # (the decoded size the caller knows out-of-band) IS the destination
        # capacity.
        if expected_size <= 0:
            raise Error(
                "Lz4Raw.decompress: expected_size must be > 0 (got "
                + String(expected_size) + ")"
            )
        var out = List[UInt8](capacity=expected_size)
        out.resize(unsafe_uninit_length=expected_size)
        var written: Int
        try:
            written = lz4_decompress_into(Span(out), input)
        except e:
            raise Error("Lz4Raw.decompress: " + String(e))
        out.resize(written, UInt8(0))
        return out^


# =============================================================================
# Lz4Frame — LZ4-Frame codec for Arrow IPC
# =============================================================================
#
# Arrow IPC uses the LZ4-Frame format (frame magic `0x184D2204` + frame
# descriptor + block list + end mark) for `BodyCompression.codec == 0`.
# Distinct from `Lz4Raw` (Parquet codec id 7) which is the raw-block form —
# the two LZ4 framings are wire-incompatible.
#
# Delegates to komira_lz4's frame API (`komira_lz4.frame`: liblz4's
# `LZ4F_compressFrame` with default preferences, and one-shot
# `LZ4F_decompress`). The trait's opaque dctx pointer is a heap-boxed
# `Lz4FrameDecoder` (which owns the `LZ4F_dctx`); only this struct makes or
# opens the box.
#
# `PARQUET_CODEC_ID = -1` sentinel: Lz4Frame is wire-incorrect for
# Parquet (Parquet uses Lz4Raw at id 7, NOT Lz4Frame). The -1 sentinel
# is defense-in-depth if a future Parquet writer constrains its codec
# parameter to a Parquet-shaped sub-trait. Today the constraint
# lives in the marker types: `Arrow[C: ArrowIpcCompression]` accepts
# Lz4Frame; `Parquet[C: Compression]` accepts it too (no Parquet sub-
# trait yet), but the Parquet write path will runtime-raise on
# `CompressionCodec(UInt8(255))` (the wrap of Int8(-1)).
# =============================================================================


@fieldwise_init
struct Lz4Frame(ArrowIpcCompression):
    """LZ4-Frame codec for Arrow IPC (Arrow IPC `CompressionType.LZ4_FRAME = 0`).

    Distinct from `Lz4Raw` (Parquet codec id 7 raw-block form): LZ4-Frame
    is the streaming-friendly wrapper format with magic `0x184D2204`.

    Delegates to komira_lz4's frame API. A decode is one-shot: one
    `LZ4F_decompress` call over the whole input, refused on a liblz4 error or
    when any input is left unconsumed.
    """

    var _reserved: Bool

    comptime PARQUET_CODEC_ID: Int8 = -1
    comptime ARROW_IPC_CODEC_ID: Int8 = 0
    comptime FILE_EXTENSION: StaticString = ".lz4"
    comptime NAME: StaticString = "lz4_frame"

    def __init__(out self):
        self._reserved = False

    @staticmethod
    def compress(input: Span[UInt8, _]) raises -> List[UInt8]:
        # Default preferences (liblz4's NULL prefs), so the bytes are the ones
        # `compress_into` writes.
        var out: List[UInt8]
        try:
            var bound = lz4_frame_compress_bound(len(input))
            out = List[UInt8](capacity=bound)
            out.resize(unsafe_uninit_length=bound)
            var written = lz4_frame_compress_into(Span(out), input)
            out.resize(written, UInt8(0))
        except e:
            raise Error("Lz4Frame.compress: " + String(e))
        return out^

    @staticmethod
    def decompress(
        input: Span[UInt8, _], expected_size: Int
    ) raises -> List[UInt8]:
        if expected_size <= 0:
            raise Error(
                "Lz4Frame.decompress: expected_size must be > 0 (got "
                + String(expected_size) + ")"
            )
        var out = List[UInt8](capacity=expected_size)
        out.resize(unsafe_uninit_length=expected_size)
        var written: Int
        try:
            written = lz4_frame_decompress_into(Span(out), input)
        except e:
            raise Error("Lz4Frame.decompress: " + String(e))
        out.resize(written, UInt8(0))
        return out^

    @staticmethod
    def decompress_into[
        o: Origin[mut=True], //,
    ](
        src: Span[UInt8, _],
        dst: UnsafePointer[UInt8, o],
        dst_capacity: Int,
    ) raises -> Int:
        """LZ4-Frame decompress directly into `dst`. Zero-extra-copy
        variant of `decompress`: the FFI writes its output into `dst`
        (the Arrow IPC output frame's body region) instead of into an
        intermediate `List[UInt8]` that the driver then memcpys.

        Avoids the `List` alloc + per-buffer memcpy on the LZ4 read arm.
        """
        if dst_capacity <= 0:
            raise Error(
                "Lz4Frame.decompress_into: dst_capacity must be > 0 (got "
                + String(dst_capacity) + ")"
            )
        # SAFETY: the trait contract: `dst` holds `dst_capacity` writable
        # bytes for the duration of this synchronous call.
        var out = Span[UInt8, o](unsafe_ptr=dst, length=dst_capacity)
        try:
            return lz4_frame_decompress_into(out, src)
        except e:
            raise Error("Lz4Frame.decompress_into: " + String(e))

    @staticmethod
    def create_dctx() raises -> UnsafePointer[UInt8, MutUntrackedOrigin]:
        """A reusable decompression context, as the trait's opaque pointer:
        a heap-boxed `Lz4FrameDecoder`. Pass it to
        `decompress_into_with_dctx` and release it with `free_dctx`.

        A per-worker cache removes one LZ4F_createDecompressionContext
        + LZ4F_freeDecompressionContext pair per compressed buffer.
        Same pattern as arrow-cpp's per-thread dctx cache.
        """
        var decoder: Lz4FrameDecoder
        try:
            decoder = Lz4FrameDecoder()
        except e:
            raise Error("Lz4Frame.create_dctx: " + String(e))
        # SAFETY: a fresh one-element allocation, move-initialised on the next
        # line before any read. Its single owner is the returned pointer until
        # `free_dctx` reclaims it.
        var box = alloc[Lz4FrameDecoder](1)
        box.unsafe_write(decoder^)
        return box.bitcast[UInt8]().unsafe_origin_cast[MutUntrackedOrigin]()

    @staticmethod
    def free_dctx(var dctx: UnsafePointer[UInt8, MutUntrackedOrigin]):
        """Release a context from `create_dctx` (destroys the boxed
        `Lz4FrameDecoder`, which frees its `LZ4F_dctx`, then frees the box).
        Null-safe.
        """
        if Int(dctx) == 0:
            return
        # SAFETY: `dctx` is the byte view of the `alloc[Lz4FrameDecoder](1)`
        # box `create_dctx` filled, released here exactly once (the trait
        # contract), so this `OwnedPointer` is its single owner: dropping it
        # runs the decoder's destructor and frees the box.
        var owned = OwnedPointer[Lz4FrameDecoder](
            unsafe_from_raw_pointer=dctx.bitcast[Lz4FrameDecoder]()
        )
        _ = owned^

    @staticmethod
    def decompress_into_with_dctx[
        o: Origin[mut=True], //,
    ](
        dctx: UnsafePointer[UInt8, MutUntrackedOrigin],
        src: Span[UInt8, _],
        dst: UnsafePointer[UInt8, o],
        dst_capacity: Int,
    ) raises -> Int:
        """LZ4-Frame decompress into `dst` using the caller-supplied
        context from `create_dctx`. The context is reset before the
        decompress (`LZ4F_resetDecompressionContext`), so a frame that failed
        before leaves no state behind.

        Same decode as `decompress_into` but with a caller-cached context,
        so no context is created or freed per buffer.
        """
        if dst_capacity <= 0:
            raise Error(
                "Lz4Frame.decompress_into_with_dctx: dst_capacity must"
                " be > 0 (got " + String(dst_capacity) + ")"
            )
        if Int(dctx) == 0:
            raise Error(
                "Lz4Frame.decompress_into_with_dctx: null dctx (call"
                " create_dctx first)"
            )
        # SAFETY: the trait contract: `dctx` came from `create_dctx` (a boxed
        # `Lz4FrameDecoder`, live until `free_dctx`) and is used by one worker
        # at a time; `dst` holds `dst_capacity` writable bytes for the duration
        # of this synchronous call.
        var decoder = dctx.bitcast[Lz4FrameDecoder]()
        var out = Span[UInt8, o](unsafe_ptr=dst, length=dst_capacity)
        try:
            return decoder[].decompress_into(out, src)
        except e:
            raise Error("Lz4Frame.decompress_into_with_dctx: " + String(e))

    @staticmethod
    def compress_bound(src_size: Int) raises -> Int:
        """Worst-case LZ4-Frame compressed size with default preferences
        (`LZ4F_compressFrameBound(srcSize, prefs=NULL)`), matching
        `compress` / `compress_into`.
        """
        return lz4_frame_compress_bound(src_size)

    @staticmethod
    def compress_into[
        o: Origin[mut=True], //,
    ](
        src: Span[UInt8, _],
        dst: UnsafePointer[UInt8, o],
        dst_capacity: Int,
    ) raises -> Int:
        """LZ4-Frame compress directly into `dst`. Zero-extra-copy
        WRITE-side variant of `compress`: the output goes into `dst`
        (the Arrow IPC output frame's compressed body region) instead of
        into an intermediate `List[UInt8]` that the driver then memcpys
        via `copy_from_bytes_list_at`.

        Write-side mirror of the read-side `decompress_into`. Caller pre-sizes
        the output region using `compress_bound(len(src))` (a smaller one is
        refused). Default preferences, matching `compress` byte for byte.
        """
        if dst_capacity <= 0:
            raise Error(
                "Lz4Frame.compress_into: dst_capacity must be > 0 (got "
                + String(dst_capacity) + ")"
            )
        # SAFETY: the trait contract: `dst` holds `dst_capacity` writable
        # bytes for the duration of this synchronous call.
        var out = Span[UInt8, o](unsafe_ptr=dst, length=dst_capacity)
        try:
            return lz4_frame_compress_into(out, src)
        except e:
            raise Error("Lz4Frame.compress_into: " + String(e))


@fieldwise_init
struct Zlib[level: Int = 6](Compression):
    """Raw zlib/deflate compression codec (Parquet codec id 8) — SCAFFOLD.

    Distinct from `Gzip` in that `Zlib` uses raw deflate framing (no
    gzip magic header). The Parquet "GZIP" codec id 2 covers both gzip
    and zlib framing via auto-detect; this slot reserves codec id 8 for
    explicit raw-deflate write paths. Raw deflate (`deflateInit2` with
    `windowBits = -15`) is not wired.
    """

    var _reserved: Bool

    comptime PARQUET_CODEC_ID: Int8 = 8
    comptime FILE_EXTENSION: StaticString = ".zz"
    comptime NAME: StaticString = "zlib"

    def __init__(out self):
        self._reserved = False

    @staticmethod
    def compress(input: Span[UInt8, _]) raises -> List[UInt8]:
        raise Error(
            "Zlib.compress: not yet wired in Compression trait conformer "
            + "(scaffold; production uses komira_parquet.compression GZIP)."
        )

    @staticmethod
    def decompress(
        input: Span[UInt8, _], expected_size: Int
    ) raises -> List[UInt8]:
        raise Error(
            "Zlib.decompress: not yet wired in Compression trait conformer "
            + "(scaffold; production uses komira_parquet.compression GZIP)."
        )


# =============================================================================
# _CodecDctxHandle[C] — typed RAII wrapper for a per-worker dctx
# =============================================================================
#
# Movable + Deinitable wrapper around one codec-specific
# decompression context. Owns the opaque dctx pointer; on __deinit__ calls
# `C.free_dctx(...)` to release it.
#
# Stored in `Slab[_CodecDctxHandle[C]]` inside `_CoalescedState[C]` in
# `ipc_body_compression.mojo`; one slot per worker. The slab is
# pre-sized to n_workers at PASS B entry; each worker is the sole
# owner / reader / writer of its slot.
#
# ENCAPSULATION: the raw
# `UnsafePointer[UInt8, MutUntrackedOrigin]` is held in a PRIVATE field
# `_raw`. The handle exposes a single `decompress_into_with_dctx[o]`
# method that forwards to `C.decompress_into_with_dctx`. The driver in
# `ipc_body_compression.mojo` only ever sees the handle by reference;
# the raw dctx pointer never crosses a module boundary.
#
# Movable semantics: the synthesized move copies `_raw` into the destination
# and ends the source's lifetime WITHOUT running its `__deinit__`, so a move
# transfers ownership of the dctx and nothing frees it twice. The null check
# in `__deinit__` covers the default-constructed handle (no dctx created yet).
#
# SAFETY:
#   - One handle owns ONE dctx; the destructor calls free_dctx exactly
#     once (modulo the null-sentinel guard).
#   - Per-worker disjointness: the dispatch driver guarantees that
#     handle slot `tid` is touched only by worker `tid`. No cross-thread
#     access to one handle.
#   - The `_raw` pointer is opaque (a boxed `Lz4FrameDecoder` or a
#     `ZSTD_DCtx*`);
#     the FFI side is the SOLE site that dereferences it. The handle
#     does not pointer-arithmetic on it.
# =============================================================================


struct _CodecDctxHandle[C: ArrowIpcCompression](
    Movable, Deinitable
):
    """Per-worker RAII handle for a codec decompression context.

    Owns ONE `C`-codec dctx pointer; destructor calls `C.free_dctx`.
    Used by `_CoalescedState[C]`'s per-worker dctx slab in
    `ipc_body_compression.mojo`.

    Field set:
      var _raw: UnsafePointer[UInt8, MutUntrackedOrigin]
        # SAFETY: opaque codec-specific dctx pointer from `C.create_dctx`
        # (a heap-boxed `komira_lz4.frame.Lz4FrameDecoder` for Lz4Frame,
        # ZSTD_DCtx* for Zstd, null for Uncompressed). Null = no dctx
        # created yet (default-constructed, `acquire` not called); the
        # destructor skips `free_dctx` then. A moved-from handle is never
        # destroyed, so it needs no null.
    """

    # SAFETY: opaque codec-specific dctx pointer; never dereferenced
    # outside the codec FFI body (`compression_codecs.mojo`). Wildcard
    # origin is the FFI carve-out — same shape as the LZ4/ZSTD FFI
    # callsites in this file.
    var _raw: UnsafePointer[UInt8, MutUntrackedOrigin]

    def __init__(out self):
        """Empty handle (null sentinel). Use `acquire()` to lazily
        create the dctx on first use, or call `Self.create()` for an
        eager-create constructor."""
        self._raw = _null_ptr[UInt8, MutUntrackedOrigin]()

    @staticmethod
    def create() raises -> _CodecDctxHandle[Self.C]:
        """Eagerly create a dctx via `C.create_dctx()`. Returns a handle
        that owns it.
        """
        var h = _CodecDctxHandle[Self.C]()
        h._raw = Self.C.create_dctx()
        return h^

    def acquire(mut self) raises:
        """Lazily create the dctx if not yet created. Idempotent —
        safe to call multiple times per worker; only the first call
        does work. The per-worker dispatch model in
        `ipc_body_compression.mojo` calls this on first use within
        each worker's `execute()`.
        """
        if Int(self._raw) == 0:
            self._raw = Self.C.create_dctx()

    def __deinit__(deinit self):
        """Release the dctx if non-null. Null-safe (handles moved-from
        and default-constructed instances).
        """
        if Int(self._raw) != 0:
            Self.C.free_dctx(self._raw)
            # NO post-free null-out: `deinit self` destroys this value, so
            # the store is dead. The `!= 0` guard above is what makes the
            # free idempotent for moved-from / default-constructed handles.

    def decompress_into_with_dctx[
        o: Origin[mut=True], //,
    ](
        mut self,
        src: Span[UInt8, _],
        dst: UnsafePointer[UInt8, o],
        dst_capacity: Int,
    ) raises -> Int:
        """Decompress `src` into `dst` using this handle's dctx.
        Lazily acquires the dctx on first call (per-worker idiom — the
        first buffer this worker handles triggers create_dctx, all
        subsequent ones reuse via the codec's reset function).
        """
        if Int(self._raw) == 0:
            self._raw = Self.C.create_dctx()
        return Self.C.decompress_into_with_dctx(
            self._raw, src, dst, dst_capacity
        )

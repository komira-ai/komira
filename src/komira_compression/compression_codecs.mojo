# =============================================================================
# Compression conformers — 8 codec marker structs implementing `Compression`
# =============================================================================
#
# WORKING (4) — call the snappy C API (statically linked) and libzstd / libz
# (via OwnedDLHandle FFI):
#   - `Uncompressed`               — no-op (no FFI).
#   - `Snappy`                     — snappy, linked into the binary.
#   - `Zstd[level: Int = 3]`       — libzstd.
#   - `Gzip[level: Int = 6]`       — libz (inflateInit2_ with auto-detect).
#
# SCAFFOLD (4) — trait shape lands; bodies raise clear errors:
#   - `Lzo`                        — Parquet codec id 3.
#   - `Brotli[quality: Int = 11]`  — Parquet codec id 4.
#   - `Lz4Raw`                     — Parquet codec id 7.
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
#   - Internally, helpers use `.unsafe_ptr()` + `.unsafe_origin_cast[
#     MutExternalOrigin]()` ONLY at the `external_call` boundary, with
#     `# FFI-BOUNDARY:` comments. This mirrors
#     `komira_parquet/compression.mojo` patterns.
#   - The Snappy / Zstd / Gzip / Uncompressed conformers each build a
#     `List[UInt8](capacity=...)` output, call the C lib into that buffer,
#     then call `_unsafe_set_size_unchecked(...)` to set the final length.
#
# DEDUPLICATION NOTE: this module duplicates the OwnedDLHandle singleton
# pattern from `komira_parquet/compression.mojo` (~80 LOC). The duplication
# is INTENTIONAL: arrow cannot depend on `komira_parquet` (cycle
# direction). The OwnedDLHandle ctor costs ~220us per construction on
# Darwin, so a process-lifetime singleton (a `_Global`, below) is the only
# way to amortize the cost without an explicit EngineContext-owned handle.
# If EngineContext comes to own codec handles, this module can drop its
# singletons and accept `ref` handles in by parameter.
# =============================================================================

from std.memory import unsafe_memcpy, alloc
from std.ffi import OwnedDLHandle, _Global, external_call
from std.os import abort

from std.sys.info import CompilationTarget

from komira_compression.compression import ArrowIpcCompression, Compression


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
# Library sonames — per-OS dylib/so basename
# =============================================================================

comptime _LIBZSTD: StaticString = "libzstd.dylib" if CompilationTarget.is_macos() else "libzstd.so.1"
comptime _LIBZ: StaticString = "libz.dylib" if CompilationTarget.is_macos() else "libz.so.1"
comptime _LIBLZ4: StaticString = "liblz4.dylib" if CompilationTarget.is_macos() else "liblz4.so.1"


# =============================================================================
# Per-codec OwnedDLHandle singletons (process-lifetime dlopen cache)
# =============================================================================
#
# Each codec gets a process-lifetime `_Global` runtime slot (dlopen'd once,
# init-once, cross-compile-unit-coherent, KGEN-managed) — no environment
# variable and no `unsafe_from_address=Int`. Distinct `_Global` names keep the arrow handles
# independent of the parquet / orc / avro singletons for the same dylibs.

# LZ4F_VERSION constant from liblz4 (lz4frame.h `#define LZ4F_VERSION 100`).
# Passed to LZ4F_createDecompressionContext for ABI version-mismatch detection.
comptime _LZ4F_VERSION: UInt32 = 100


def _init_arrow_zstd_handle() -> OwnedDLHandle:
    """`_Global` init_fn: dlopen libzstd once per process (KGEN-serialized).

    SAFETY: init_fn must be non-raising; the OwnedDLHandle ctor raises only on
    an unresolvable pinned dylib (fatal provisioning error), so we `abort` —
    matching a raise that aborts the query.
    """
    try:
        return OwnedDLHandle(_LIBZSTD)
    except e:
        abort("libzstd dlopen failed (arrow codec handle init)")


def _init_arrow_z_handle() -> OwnedDLHandle:
    """`_Global` init_fn: dlopen libz once per process (KGEN-serialized)."""
    try:
        return OwnedDLHandle(_LIBZ)
    except e:
        abort("libz dlopen failed (arrow codec handle init)")


def _init_arrow_lz4_handle() -> OwnedDLHandle:
    """`_Global` init_fn: dlopen liblz4 once per process (KGEN-serialized)."""
    try:
        return OwnedDLHandle(_LIBLZ4)
    except e:
        abort("liblz4 dlopen failed (arrow codec handle init)")


comptime _ZSTD_GLOBAL = _Global[
    "komira_arrow_zstd_handle", _init_arrow_zstd_handle
]
comptime _Z_GLOBAL = _Global["komira_arrow_z_handle", _init_arrow_z_handle]
comptime _LZ4_GLOBAL = _Global["komira_arrow_lz4_handle", _init_arrow_lz4_handle]


# Per-codec accessors — return the process-lifetime handle slot (init-once via
# `_Global`). SAFETY: FFI carve-out; `MutUntrackedOrigin` is the stdlib
# `_Global` return type (runtime-managed static storage). No env var, no
# `unsafe_from_address`.
@always_inline
def _zstd_handle() raises -> UnsafePointer[OwnedDLHandle, MutUntrackedOrigin]:
    return _ZSTD_GLOBAL.get_or_create_ptr()


@always_inline
def _z_handle() raises -> UnsafePointer[OwnedDLHandle, MutUntrackedOrigin]:
    return _Z_GLOBAL.get_or_create_ptr()


@always_inline
def _lz4_handle() raises -> UnsafePointer[OwnedDLHandle, MutUntrackedOrigin]:
    return _LZ4_GLOBAL.get_or_create_ptr()


# =============================================================================
# Span -> FFI-pointer adapter
# =============================================================================
#
# Conformer trait methods accept `Span[UInt8, _]` (origin-poly). At the FFI
# boundary we cast to `UnsafePointer[UInt8, MutExternalOrigin]` because the
# C ABI does not speak Mojo origins. The cast is sound because the C call
# is synchronous and the caller proves the buffer outlives the call by
# holding the `Span` in the enclosing scope.


@always_inline
def _span_ptr(s: Span[UInt8, _]) -> UnsafePointer[UInt8, MutUntrackedOrigin]:
    """Coerce a `Span[UInt8, _]` to a `MutExternalOrigin`-cast UnsafePointer
    for FFI. FFI-BOUNDARY: synchronous C call; caller owns the buffer.
    """
    # SAFETY: see header. The cast does not extend lifetime; the Span ref
    # remains in scope across the external_call below.
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
# snappy-c.h API used:
#   snappy_status snappy_compress(const char* input, size_t input_length,
#                                 char* compressed, size_t* compressed_length);
#   snappy_status snappy_uncompress(const char* compressed, size_t compressed_length,
#                                   char* uncompressed, size_t* uncompressed_length);
#   snappy_status snappy_uncompressed_length(const char* compressed,
#                                            size_t compressed_length,
#                                            size_t* result);
#
# `snappy_status` is a C enum where 0 == SNAPPY_OK.
#
# Snappy guarantees `compressed_size <= 32 + input_len + input_len/6` (same
# formula snappy reports via `snappy_max_compressed_length`).
# =============================================================================


@always_inline
def _snappy_max_compressed_length(input_len: Int) -> Int:
    """Snappy guarantees compressed_size <= 32 + n + n/6."""
    return 32 + input_len + input_len // 6


@fieldwise_init
struct Snappy(Compression):
    """The snappy compression codec, calling the snappy C API. Parquet codec
    id 1. Default for Parquet (matches DuckDB).

    The snappy library is statically linked into every binary that uses
    komira_core, so no shared library is needed at run time. A native Mojo
    Snappy port lives in `komira_parquet` and is used on the Parquet path;
    this conformer calls the C library directly.
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
        var max_out = _snappy_max_compressed_length(n)
        var out = List[UInt8](capacity=max_out)

        # SAFETY: see _span_ptr / _list_ptr; synchronous FFI.
        var size_buf = alloc[Int64](1)
        size_buf[0] = Int64(max_out)
        # FFI-BOUNDARY:
        var status = external_call["snappy_compress", Int32](
            _span_ptr(input),
            Int64(n),
            _list_ptr(out),
            size_buf,
        )
        var written = Int(size_buf[0])
        size_buf.free()
        if Int(status) != 0:
            raise Error(
                "Snappy.compress: snappy_compress failed (status="
                + String(Int(status)) + ", n=" + String(n) + ")"
            )
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
            var sz = alloc[Int64](1)
            sz[0] = Int64(0)
            var status = external_call["snappy_uncompressed_length", Int32](
                _span_ptr(input),
                Int64(n),
                sz,
            )
            var sz_val = Int(sz[0])
            sz.free()
            if Int(status) != 0:
                raise Error(
                    "Snappy.decompress: snappy_uncompressed_length failed "
                    + "(status=" + String(Int(status)) + ")"
                )
            out_len = sz_val

        var out = List[UInt8](capacity=out_len)
        var size_buf = alloc[Int64](1)
        size_buf[0] = Int64(out_len)
        # FFI-BOUNDARY:
        var status2 = external_call["snappy_uncompress", Int32](
            _span_ptr(input),
            Int64(n),
            _list_ptr(out),
            size_buf,
        )
        var written = Int(size_buf[0])
        size_buf.free()
        if Int(status2) != 0:
            raise Error(
                "Snappy.decompress: snappy_uncompress failed (status="
                + String(Int(status2)) + ", n=" + String(n) + ")"
            )
        out.resize(unsafe_uninit_length=written)
        return out^


# =============================================================================
# Zstd[level] — libzstd via OwnedDLHandle (Parquet codec id 6)
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
# Gzip[level] — libz via OwnedDLHandle (Parquet codec id 2)
# =============================================================================
#
# Uses one-shot `compress2` for write (zlib framing — accepted by all major
# Parquet readers with auto-detect). For read, uses `inflateInit2_` with
# `windowBits = 15 + 32` for auto-detect of gzip / zlib / raw-deflate framing
# (load-bearing for interop with pyarrow / parquet-mr / DuckDB / Spark).
#
# ⚠ ZLIB FRAMING IS NOT GZIP FILE FRAMING, and a `.gz` FILE must be the latter.
# `compress2` emits RFC 1950 (2-byte header + deflate + adler32); a gzip FILE is
# RFC 1952 (10-byte header starting `1f 8b` + raw deflate + crc32 + isize).
# Inside a Parquet page the distinction is invisible — every major reader
# auto-detects, which is why the write path above is fine there and has been for
# its whole life. On DISK it is the difference between a file `gunzip`, `zcat`
# and DuckDB can open and one they refuse. `compress_gzip_file` below is the
# file-framing entry; use it for any whole-file `.gz` sink.
#
# z_stream struct is 112 bytes on LP64.
# =============================================================================

comptime _Z_STREAM_SIZE: Int = 112
comptime _Z_OK: Int = 0
comptime _Z_STREAM_END: Int = 1
comptime _Z_NO_FLUSH: Int = 0
comptime _Z_WINDOWBITS_AUTO: Int32 = 15 + 32

# zlib's `crc32(uLong, const Bytef*, uInt)` takes a 32-BIT length. Feed it in
# chunks so a >4 GiB buffer (a whole-file CSV/JSONL sink is exactly that shape)
# cannot silently wrap and produce a valid-looking file with a wrong CRC.
comptime _Z_CRC_CHUNK: Int = 1 << 30


@fieldwise_init
struct Gzip[level: Int = 6](Compression):
    """The libz FFI compression codec. Parquet codec id 2.

    `level` is a comptime parameter (1-9; default 6 matches DuckDB /
    pyarrow / parquet-mr).

    Write path: `compress2` (zlib framing) — for a Parquet PAGE.
    File path:  `compress_gzip_file` (RFC 1952 gzip framing) — for a `.gz` FILE.
    Read path: `inflateInit2_` with `windowBits = 15 + 32` (auto-detect
    gzip / zlib / raw-deflate framing), so both framings read back here.
    """

    var _reserved: Bool

    comptime PARQUET_CODEC_ID: Int8 = 2
    comptime FILE_EXTENSION: StaticString = ".gz"
    comptime NAME: StaticString = "gzip"

    def __init__(out self):
        self._reserved = False

    @staticmethod
    def compress(input: Span[UInt8, _]) raises -> List[UInt8]:
        var n = len(input)
        var handle_ptr = _z_handle()
        var bound = Int(
            handle_ptr[].call["compressBound", Int64](Int64(n))
        )
        var out = List[UInt8](capacity=bound)

        var size_buf = alloc[Int64](1)
        size_buf[0] = Int64(bound)
        # FFI-BOUNDARY:
        var status = handle_ptr[].call["compress2", Int32](
            _list_ptr(out),
            size_buf,
            _span_ptr(input),
            Int64(n),
            Int32(Self.level),
        )
        var written = Int(size_buf[0])
        size_buf.free()
        if Int(status) != 0:
            raise Error(
                "Gzip.compress: zlib compress2 failed (status="
                + String(Int(status)) + ", n=" + String(n) + ")"
            )
        out.resize(unsafe_uninit_length=written)
        return out^

    @staticmethod
    def _crc32(input: Span[UInt8, _]) raises -> UInt32:
        """zlib `crc32` over the whole span, fed in <=1 GiB chunks.

        The chunking is not an optimization: zlib's `len` parameter is `uInt`
        (32-bit), and a whole-file sink buffer is routinely larger than that.
        `crc32` is incremental by construction, so chunking is exact."""
        var handle_ptr = _z_handle()
        var crc = Int64(0)
        var off = 0
        var n = len(input)
        while off < n:
            var take = min(_Z_CRC_CHUNK, n - off)
            # FFI-BOUNDARY: synchronous call; `input` outlives it.
            crc = handle_ptr[].call["crc32", Int64](
                crc,
                _span_ptr(input) + off,
                Int32(take),
            )
            off += take
        return UInt32(Int(crc) & 0xFFFFFFFF)

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
        crc32][4-byte isize]`. So `compress2` writes at offset 8, the 10-byte
        gzip header then overwrites exactly the two zlib header bytes it left at
        [8,10), and the 8-byte trailer overwrites the 4 adler bytes in place. The
        deflate payload — all of it — is never moved.
        """
        var n = len(input)
        var handle_ptr = _z_handle()
        var bound = Int(handle_ptr[].call["compressBound", Int64](Int64(n)))
        # 8 leading (so the deflate body lands at 10) + 8 trailing (crc + isize,
        # of which 4 overwrite the adler32).
        var out = List[UInt8](capacity=8 + bound + 8)
        var base = _list_ptr(out)

        var size_buf = alloc[Int64](1)
        size_buf[0] = Int64(bound)
        # FFI-BOUNDARY:
        var status = handle_ptr[].call["compress2", Int32](
            base + 8,
            size_buf,
            _span_ptr(input),
            Int64(n),
            Int32(Self.level),
        )
        var zlen = Int(size_buf[0])
        size_buf.free()
        if Int(status) != 0:
            raise Error(
                "Gzip.compress_gzip_file: zlib compress2 failed (status="
                + String(Int(status)) + ", n=" + String(n) + ")"
            )
        if zlen < 6:
            raise Error(
                "Gzip.compress_gzip_file: zlib stream too short to reframe"
                " (zlen=" + String(zlen) + ")"
            )

        # RFC 1952 §2.3 header: magic, CM=8 (deflate), FLG=0 (no name/extra),
        # MTIME=0 (no timestamp — keeps the output BYTE-DETERMINISTIC, which a
        # write-parity corpus depends on), XFL by level, OS=255 (unknown).
        base[0] = UInt8(0x1F)
        base[1] = UInt8(0x8B)
        base[2] = UInt8(8)
        base[3] = UInt8(0)
        base[4] = UInt8(0)
        base[5] = UInt8(0)
        base[6] = UInt8(0)
        base[7] = UInt8(0)
        comptime xfl = 2 if Self.level == 9 else (4 if Self.level == 1 else 0)
        base[8] = UInt8(xfl)
        base[9] = UInt8(255)

        # Trailer, little-endian, starting where the adler32 sat.
        var crc = Self._crc32(input)
        var isize = UInt32(n & 0xFFFFFFFF)
        var t = 8 + zlen - 4
        base[t + 0] = UInt8(Int(crc) & 0xFF)
        base[t + 1] = UInt8((Int(crc) >> 8) & 0xFF)
        base[t + 2] = UInt8((Int(crc) >> 16) & 0xFF)
        base[t + 3] = UInt8((Int(crc) >> 24) & 0xFF)
        base[t + 4] = UInt8(Int(isize) & 0xFF)
        base[t + 5] = UInt8((Int(isize) >> 8) & 0xFF)
        base[t + 6] = UInt8((Int(isize) >> 16) & 0xFF)
        base[t + 7] = UInt8((Int(isize) >> 24) & 0xFF)

        out.resize(unsafe_uninit_length=zlen + 12)
        return out^

    @staticmethod
    def decompress(
        input: Span[UInt8, _], expected_size: Int
    ) raises -> List[UInt8]:
        var n = len(input)
        if expected_size <= 0:
            raise Error(
                "Gzip.decompress: expected_size must be > 0 (got "
                + String(expected_size) + ")"
            )
        var out = List[UInt8](capacity=expected_size)

        var handle_ptr = _z_handle()
        var version = handle_ptr[].call[
            "zlibVersion", UnsafePointer[UInt8, MutUntrackedOrigin]
        ]()

        # SAFETY: opaque z_stream scratch buffer, freed via inflateEnd +
        # alloc.free() before return.
        var strm = alloc[UInt8](_Z_STREAM_SIZE)
        # zero-init the 112-byte struct
        var zi: Int = 0
        while zi < _Z_STREAM_SIZE:
            strm[zi] = UInt8(0)
            zi += 1

        # z_stream layout on LP64 (verified in komira_parquet/compression.mojo):
        #   off  0, size 8: next_in   (const unsigned char*)
        #   off  8, size 4: avail_in  (unsigned int)
        #   off 12, size 4: _pad1
        #   off 16, size 8: total_in
        #   off 24, size 8: next_out
        #   off 32, size 4: avail_out
        #   off 40, size 8: total_out
        var src_ptr = _span_ptr(input)
        var dst_ptr = _list_ptr(out)
        (strm.bitcast[UInt64]() + 0)[] = UInt64(Int(src_ptr))
        (strm.bitcast[UInt32]() + 2)[] = UInt32(n)
        (strm.bitcast[UInt64]() + 3)[] = UInt64(Int(dst_ptr))
        (strm.bitcast[UInt32]() + 8)[] = UInt32(expected_size)

        var init_rc = handle_ptr[].call["inflateInit2_", Int32](
            strm, _Z_WINDOWBITS_AUTO, version, Int32(_Z_STREAM_SIZE)
        )
        if Int(init_rc) != _Z_OK:
            strm.free()
            raise Error(
                "Gzip.decompress: inflateInit2_ failed (rc="
                + String(Int(init_rc)) + ")"
            )

        var rc = handle_ptr[].call["inflate", Int32](
            strm, Int32(_Z_NO_FLUSH)
        )
        var total_out = Int((strm.bitcast[UInt64]() + 5)[])
        _ = handle_ptr[].call["inflateEnd", Int32](strm)
        strm.free()

        if Int(rc) != _Z_OK and Int(rc) != _Z_STREAM_END:
            raise Error(
                "Gzip.decompress: inflate failed (rc=" + String(Int(rc))
                + ", n=" + String(n) + ")"
            )
        out.resize(unsafe_uninit_length=total_out)
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

    Wires liblz4's raw-block API (`LZ4_compressBound` / `LZ4_compress_default`
    / `LZ4_decompress_safe`) via the shared `OwnedDLHandle` singleton — the
    SAME C entry points used by `komira_parquet.compression`'s
    `_compress_lz4_raw` / `_decompress_lz4_raw` page-codec path. This is the
    raw LZ4 BLOCK format (no frame magic, no block list, no end mark);
    distinct on-wire from `Lz4Frame` (Arrow IPC, magic 0x184D2204). The two
    LZ4 framings are NOT interchangeable.
    """

    var _reserved: Bool

    comptime PARQUET_CODEC_ID: Int8 = 7
    comptime FILE_EXTENSION: StaticString = ".lz4"
    comptime NAME: StaticString = "lz4_raw"

    def __init__(out self):
        self._reserved = False

    @staticmethod
    def compress(input: Span[UInt8, _]) raises -> List[UInt8]:
        # liblz4 raw-block compress. lz4.h:
        #   int LZ4_compress_default(const char* src, char* dst,
        #                            int srcSize, int dstCapacity);
        # Returns bytes written (0 on insufficient dstCapacity). The block
        # format carries NO length/frame prefix — the caller stores the
        # uncompressed size out-of-band (Parquet page header carries it),
        # mirroring `komira_parquet.compression._compress_lz4_raw`.
        var n = len(input)
        var handle_ptr = _lz4_handle()
        # LZ4_compressBound(inputSize) — worst-case compressed size.
        var bound = Int(
            handle_ptr[].call["LZ4_compressBound", Int32](Int32(n))
        )
        var out = List[UInt8](capacity=bound)
        # FFI-BOUNDARY: arg order is (src, dst, srcSize, dstCapacity).
        var written = handle_ptr[].call["LZ4_compress_default", Int32](
            _span_ptr(input),
            _list_ptr(out),
            Int32(n),
            Int32(bound),
        )
        if Int(written) <= 0:
            raise Error(
                "Lz4Raw.compress: LZ4_compress_default failed (result="
                + String(Int(written)) + ", n=" + String(n)
                + ", bound=" + String(bound) + ")"
            )
        out.resize(unsafe_uninit_length=Int(written))
        return out^

    @staticmethod
    def decompress(
        input: Span[UInt8, _], expected_size: Int
    ) raises -> List[UInt8]:
        # liblz4 raw-block decompress. lz4.h:
        #   int LZ4_decompress_safe(const char* src, char* dst,
        #                           int compressedSize, int dstCapacity);
        # Returns bytes written (negative on error). The raw block carries
        # no uncompressed-size prefix, so `expected_size` (the decoded size
        # the caller knows out-of-band) IS the destination capacity.
        var n = len(input)
        if expected_size <= 0:
            raise Error(
                "Lz4Raw.decompress: expected_size must be > 0 (got "
                + String(expected_size) + ")"
            )
        var handle_ptr = _lz4_handle()
        var out = List[UInt8](capacity=expected_size)
        # FFI-BOUNDARY: arg order is (src, dst, compressedSize, dstCapacity).
        var written = handle_ptr[].call["LZ4_decompress_safe", Int32](
            _span_ptr(input),
            _list_ptr(out),
            Int32(n),
            Int32(expected_size),
        )
        if Int(written) < 0:
            raise Error(
                "Lz4Raw.decompress: LZ4_decompress_safe failed (result="
                + String(Int(written)) + ", n=" + String(n)
                + ", expected_size=" + String(expected_size) + ")"
            )
        out.resize(unsafe_uninit_length=Int(written))
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
# Wired to liblz4's `LZ4F_compressFrame` / `LZ4F_decompress` FFI entry
# points (the same shape as `Zstd[level]` / `Snappy`).
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

    Wired to `liblz4`'s `LZ4F_compressFrame` / `LZ4F_decompress` FFI entry
    points (the streaming Arrow IPC per-buffer compression surface; mirror
    of the `Zstd[level]` / `Snappy` FFI pattern in this file).
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
        # Calls liblz4 `LZ4F_compressFrame` via
        # OwnedDLHandle singleton (mirrors the Zstd / Gzip shape).
        # The frame format wraps the LZ4 raw block in a frame magic
        # (0x184D2204) + frame descriptor + block list + end mark — the
        # streaming-friendly LZ4 variant that Arrow IPC ships as
        # `BodyCompression.codec = LZ4_FRAME (0)`. Distinct on-wire from
        # `Lz4Raw` (Parquet codec id 7); the two are NOT interchangeable.
        var n = len(input)
        var handle_ptr = _lz4_handle()
        # LZ4F_compressFrameBound(srcSize, prefs=NULL): returns max
        # compressed size for srcSize input with default preferences.
        # Pass NULL prefs (LZ4F_INIT_PREFERENCES default — compressionLevel
        # 0 = LZ4F_CLEVEL_DEFAULT, no checksums, autoFlush off).
        var null_prefs = _null_ptr[UInt8, MutUntrackedOrigin]()
        var bound = handle_ptr[].call["LZ4F_compressFrameBound", Int](
            n, null_prefs
        )
        var out = List[UInt8](capacity=bound)
        # FFI-BOUNDARY:
        var written = handle_ptr[].call["LZ4F_compressFrame", Int](
            _list_ptr(out),
            bound,
            _span_ptr(input),
            n,
            null_prefs,
        )
        # LZ4F_isError(result) — nonzero on error. The encoding API uses
        # the same "is_error" tagged return as the decode API.
        var is_err = handle_ptr[].call["LZ4F_isError", Int32](written)
        if Int(is_err) != 0:
            raise Error(
                "Lz4Frame.compress: LZ4F_compressFrame failed (result="
                + String(written) + ", n=" + String(n) + ")"
            )
        out.resize(unsafe_uninit_length=written)
        return out^

    @staticmethod
    def decompress(
        input: Span[UInt8, _], expected_size: Int
    ) raises -> List[UInt8]:
        # Calls liblz4 `LZ4F_decompress` via
        # OwnedDLHandle singleton. Requires a decompression context
        # (LZ4F_dctx); create + free per-call. The dctx is a few KB and
        # per-call alloc is fine for the Arrow IPC per-buffer model
        # (the alternative is a thread-local cache).
        var n = len(input)
        if expected_size <= 0:
            raise Error(
                "Lz4Frame.decompress: expected_size must be > 0 (got "
                + String(expected_size) + ")"
            )
        var handle_ptr = _lz4_handle()

        # SAFETY: dctx_ptr is a heap-allocated pointer slot for the
        # LZ4F_dctx*. We OWN the alloc; the create/free pair zips
        # allocate+release the dctx itself (separately from this slot).
        var dctx_ptr = alloc[UnsafePointer[UInt8, MutUntrackedOrigin]](1)
        dctx_ptr[0] = _null_ptr[UInt8, MutUntrackedOrigin]()
        var create_rc = handle_ptr[].call[
            "LZ4F_createDecompressionContext", Int
        ](dctx_ptr, _LZ4F_VERSION)
        var create_err = handle_ptr[].call["LZ4F_isError", Int32](create_rc)
        if Int(create_err) != 0:
            dctx_ptr.free()
            raise Error(
                "Lz4Frame.decompress: LZ4F_createDecompressionContext failed"
                " (rc=" + String(create_rc) + ")"
            )
        var dctx = dctx_ptr[0]

        var out = List[UInt8](capacity=expected_size)

        # LZ4F_decompress takes pointers to dstSize + srcSize that are
        # ALSO outputs (read+write). Allocate transient u64 slots for
        # them (Mojo `Int64` and `Int` are wire-compat with size_t on
        # LP64 — same 8-byte width).
        var dst_size_slot = alloc[Int64](1)
        dst_size_slot[0] = Int64(expected_size)
        var src_size_slot = alloc[Int64](1)
        src_size_slot[0] = Int64(n)
        # opts pointer can be NULL — defaults.
        var null_opts = _null_ptr[UInt8, MutUntrackedOrigin]()
        # FFI-BOUNDARY:
        var result = handle_ptr[].call["LZ4F_decompress", Int](
            dctx,
            _list_ptr(out),
            dst_size_slot,
            _span_ptr(input),
            src_size_slot,
            null_opts,
        )
        var written = Int(dst_size_slot[0])
        var consumed = Int(src_size_slot[0])
        dst_size_slot.free()
        src_size_slot.free()
        var _free_rc = handle_ptr[].call[
            "LZ4F_freeDecompressionContext", Int
        ](dctx)
        dctx_ptr.free()

        var is_err = handle_ptr[].call["LZ4F_isError", Int](result)
        if is_err != 0:
            raise Error(
                "Lz4Frame.decompress: LZ4F_decompress failed (result="
                + String(result) + ", n=" + String(n)
                + ", written=" + String(written) + ")"
            )
        # Successful one-shot decode returns 0 (nothing left in src) or
        # the size of next expected input chunk (multi-call streaming).
        # For one-shot full-frame decode, `consumed` must equal `n` and
        # `written` must equal `expected_size`.
        if consumed != n:
            raise Error(
                "Lz4Frame.decompress: incomplete decode (consumed="
                + String(consumed) + " of " + String(n) + " bytes;"
                + " only one-shot decode is supported, not multi-call streaming)"
            )
        out.resize(unsafe_uninit_length=written)
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
        var n = len(src)
        if dst_capacity <= 0:
            raise Error(
                "Lz4Frame.decompress_into: dst_capacity must be > 0 (got "
                + String(dst_capacity) + ")"
            )
        var handle_ptr = _lz4_handle()

        # SAFETY: dctx_ptr is a heap-allocated pointer slot for the
        # LZ4F_dctx*. We OWN the alloc; the create/free pair zips
        # allocate+release the dctx itself (separately from this slot).
        var dctx_ptr = alloc[UnsafePointer[UInt8, MutUntrackedOrigin]](1)
        dctx_ptr[0] = _null_ptr[UInt8, MutUntrackedOrigin]()
        var create_rc = handle_ptr[].call[
            "LZ4F_createDecompressionContext", Int
        ](dctx_ptr, _LZ4F_VERSION)
        var create_err = handle_ptr[].call["LZ4F_isError", Int32](create_rc)
        if Int(create_err) != 0:
            dctx_ptr.free()
            raise Error(
                "Lz4Frame.decompress_into: LZ4F_createDecompressionContext"
                " failed (rc=" + String(create_rc) + ")"
            )
        var dctx = dctx_ptr[0]

        # LZ4F_decompress takes pointers to dstSize + srcSize that are
        # ALSO outputs (read+write). Allocate transient u64 slots.
        var dst_size_slot = alloc[Int64](1)
        dst_size_slot[0] = Int64(dst_capacity)
        var src_size_slot = alloc[Int64](1)
        src_size_slot[0] = Int64(n)
        var null_opts = _null_ptr[UInt8, MutUntrackedOrigin]()
        # FFI-BOUNDARY: `dst` lifetime guaranteed by caller per
        # SAFETY contract on the trait method (synchronous FFI).
        var result = handle_ptr[].call["LZ4F_decompress", Int](
            dctx,
            dst.unsafe_origin_cast[MutUntrackedOrigin](),
            dst_size_slot,
            _span_ptr(src),
            src_size_slot,
            null_opts,
        )
        var written = Int(dst_size_slot[0])
        var consumed = Int(src_size_slot[0])
        dst_size_slot.free()
        src_size_slot.free()
        var _free_rc = handle_ptr[].call[
            "LZ4F_freeDecompressionContext", Int
        ](dctx)
        dctx_ptr.free()

        var is_err = handle_ptr[].call["LZ4F_isError", Int](result)
        if is_err != 0:
            raise Error(
                "Lz4Frame.decompress_into: LZ4F_decompress failed (result="
                + String(result) + ", n=" + String(n)
                + ", written=" + String(written) + ")"
            )
        if consumed != n:
            raise Error(
                "Lz4Frame.decompress_into: incomplete decode (consumed="
                + String(consumed) + " of " + String(n) + " bytes;"
                + " only one-shot decode is supported, not multi-call streaming)"
            )
        return written

    @staticmethod
    def create_dctx() raises -> UnsafePointer[UInt8, MutUntrackedOrigin]:
        """Create one `LZ4F_dctx*` via `LZ4F_createDecompressionContext`.
        The returned pointer is opaque; pass through `free_dctx` /
        `decompress_into_with_dctx`.

        A per-worker cache removes one LZ4F_createDecompressionContext
        + LZ4F_freeDecompressionContext pair per compressed buffer.
        Same pattern as arrow-cpp's per-thread dctx cache.
        """
        var handle_ptr = _lz4_handle()
        # SAFETY: dctx_ptr is a heap-allocated pointer slot for the
        # LZ4F_dctx*. We OWN the alloc; free it BEFORE returning. The
        # caller owns only the inner dctx pointer (returned by-value).
        var dctx_ptr = alloc[UnsafePointer[UInt8, MutUntrackedOrigin]](1)
        dctx_ptr[0] = _null_ptr[UInt8, MutUntrackedOrigin]()
        # FFI-BOUNDARY:
        var create_rc = handle_ptr[].call[
            "LZ4F_createDecompressionContext", Int
        ](dctx_ptr, _LZ4F_VERSION)
        var create_err = handle_ptr[].call["LZ4F_isError", Int32](create_rc)
        var dctx = dctx_ptr[0]
        dctx_ptr.free()
        if Int(create_err) != 0:
            raise Error(
                "Lz4Frame.create_dctx: LZ4F_createDecompressionContext"
                " failed (rc=" + String(create_rc) + ")"
            )
        return dctx

    @staticmethod
    def free_dctx(var dctx: UnsafePointer[UInt8, MutUntrackedOrigin]):
        """Release an `LZ4F_dctx*` via `LZ4F_freeDecompressionContext`.
        Null-safe.
        """
        if Int(dctx) == 0:
            return
        try:
            var handle_ptr = _lz4_handle()
            # FFI-BOUNDARY: LZ4F_freeDecompressionContext returns size_t;
            # for the well-formed-pointer case it returns 0. Ignored in
            # the destructor path.
            var _rc = handle_ptr[].call[
                "LZ4F_freeDecompressionContext", Int
            ](dctx)
        except:
            # Same swallow rationale as Zstd.free_dctx: destructor path.
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
        """LZ4-Frame decompress into `dst` using the caller-supplied
        `dctx`. Calls `LZ4F_resetDecompressionContext(dctx)` BEFORE the
        decompress to clear any prior streaming state (per `lz4frame.h`
        l.497: "Use LZ4F_resetDecompressionContext() to return to clean
        state").

        Same FFI call as `decompress_into` but with a caller-cached dctx,
        so no context is created or freed per buffer.
        """
        var n = len(src)
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
        var handle_ptr = _lz4_handle()

        # FFI-BOUNDARY: LZ4F_resetDecompressionContext returns void per
        # lz4frame.h l.513 ("always successful"). external_call requires
        # a return type; declare Int for ABI compat and discard.
        var _reset_rc = handle_ptr[].call[
            "LZ4F_resetDecompressionContext", Int
        ](dctx)

        # LZ4F_decompress takes pointers to dstSize + srcSize that are
        # ALSO outputs (read+write). Allocate transient u64 slots.
        var dst_size_slot = alloc[Int64](1)
        dst_size_slot[0] = Int64(dst_capacity)
        var src_size_slot = alloc[Int64](1)
        src_size_slot[0] = Int64(n)
        var null_opts = _null_ptr[UInt8, MutUntrackedOrigin]()
        # FFI-BOUNDARY: `dst` lifetime guaranteed by caller per SAFETY
        # contract on the trait method (synchronous FFI).
        var result = handle_ptr[].call["LZ4F_decompress", Int](
            dctx,
            dst.unsafe_origin_cast[MutUntrackedOrigin](),
            dst_size_slot,
            _span_ptr(src),
            src_size_slot,
            null_opts,
        )
        var written = Int(dst_size_slot[0])
        var consumed = Int(src_size_slot[0])
        dst_size_slot.free()
        src_size_slot.free()

        var is_err = handle_ptr[].call["LZ4F_isError", Int](result)
        if is_err != 0:
            raise Error(
                "Lz4Frame.decompress_into_with_dctx: LZ4F_decompress"
                " failed (result=" + String(result) + ", n=" + String(n)
                + ", written=" + String(written) + ")"
            )
        if consumed != n:
            raise Error(
                "Lz4Frame.decompress_into_with_dctx: incomplete decode"
                " (consumed=" + String(consumed) + " of " + String(n)
                + " bytes; only one-shot decode is supported, not multi-call"
                " streaming)"
            )
        return written

    @staticmethod
    def compress_bound(src_size: Int) raises -> Int:
        """Worst-case LZ4-Frame compressed size via
        `LZ4F_compressFrameBound(srcSize, prefs=NULL)`. NULL prefs
        matches the `compress_into` shape below (default preferences,
        same as the existing `compress` body).
        """
        var handle_ptr = _lz4_handle()
        var null_prefs = _null_ptr[UInt8, MutUntrackedOrigin]()
        return handle_ptr[].call["LZ4F_compressFrameBound", Int](
            src_size, null_prefs
        )

    @staticmethod
    def compress_into[
        o: Origin[mut=True], //,
    ](
        src: Span[UInt8, _],
        dst: UnsafePointer[UInt8, o],
        dst_capacity: Int,
    ) raises -> Int:
        """LZ4-Frame compress directly into `dst`. Zero-extra-copy
        WRITE-side variant of `compress`: the FFI writes its output
        into `dst` (the Arrow IPC output frame's compressed body
        region) instead of into an intermediate `List[UInt8]` that
        the driver then memcpys via `copy_from_bytes_list_at`.

        Write-side mirror of the read-side `decompress_into`. Caller pre-sizes the
        output region using `compress_bound(len(src))`. Uses NULL
        prefs (LZ4F_INIT_PREFERENCES default — clevel 0, no
        checksums, autoFlush off) matching the existing `compress`
        body to keep on-wire byte-identity.
        """
        var n = len(src)
        if dst_capacity <= 0:
            raise Error(
                "Lz4Frame.compress_into: dst_capacity must be > 0 (got "
                + String(dst_capacity) + ")"
            )
        var handle_ptr = _lz4_handle()
        var null_prefs = _null_ptr[UInt8, MutUntrackedOrigin]()
        # FFI-BOUNDARY: `dst` lifetime guaranteed by caller per
        # SAFETY contract on the trait method (synchronous FFI).
        var written = handle_ptr[].call["LZ4F_compressFrame", Int](
            dst.unsafe_origin_cast[MutUntrackedOrigin](),
            dst_capacity,
            _span_ptr(src),
            n,
            null_prefs,
        )
        var is_err = handle_ptr[].call["LZ4F_isError", Int32](written)
        if Int(is_err) != 0:
            raise Error(
                "Lz4Frame.compress_into: LZ4F_compressFrame failed (result="
                + String(written) + ", n=" + String(n)
                + ", dst_capacity=" + String(dst_capacity) + ")"
            )
        return written


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
# `UnsafePointer[UInt8, MutExternalOrigin]` is held in a PRIVATE field
# `_raw`. The handle exposes a single `decompress_into_with_dctx[o]`
# method that forwards to `C.decompress_into_with_dctx`. The driver in
# `ipc_body_compression.mojo` only ever sees the handle by reference;
# the raw dctx pointer never crosses a module boundary.
#
# Movable semantics: handle moves transfer ownership of `_raw`; the
# source's `_raw` becomes null (so __deinit__ is a no-op on the moved-from
# instance). @fieldwise_init synthesizes the move correctly (UInt8*
# field is trivially copyable; the moved-from value is dropped without
# calling free_dctx because we manually null it out — see init / take).
#
# SAFETY:
#   - One handle owns ONE dctx; the destructor calls free_dctx exactly
#     once (modulo the null-sentinel guard).
#   - Per-worker disjointness: the dispatch driver guarantees that
#     handle slot `tid` is touched only by worker `tid`. No cross-thread
#     access to one handle.
#   - The `_raw` pointer is opaque (a `LZ4F_dctx*` or `ZSTD_DCtx*`);
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
      var _raw: UnsafePointer[UInt8, MutExternalOrigin]
        # SAFETY: opaque codec-specific dctx pointer
        # (LZ4F_dctx* for Lz4Frame, ZSTD_DCtx* for Zstd, null for
        # Uncompressed). Null sentinel = no live dctx (already freed,
        # or moved-from, or default-constructed before first use). The
        # destructor's null-guard ensures double-free safety on the
        # moved-from instance.
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

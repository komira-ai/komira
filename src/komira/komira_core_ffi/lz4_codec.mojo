# =============================================================================
# komira_core_ffi.lz4_codec
# =============================================================================
#
# The SHARED LZ4 RAW-BLOCK codec leaf. Page-level Parquet codec dispatch and
# document-store `_source` compression both need LZ4 raw blocks, and neither
# may import the other, so the raw-block compress/decompress lives here, in a
# leaf both already depend on.
#
# The LZ4 FRAME entries (`LZ4F_*`, the interoperable Kafka/Arrow-IPC framing)
# are a distinct codec (frame vs raw block) with a distinct consumer set, and
# are not here.
#
# # Approach: runtime dlopen via OwnedDLHandle, singleton via stdlib `_Global`
#
# RUNTIME dlopen via OwnedDLHandle of the system liblz4, cached in a
# process-lifetime `_Global` runtime slot (init-once, cross-compile-unit-
# coherent). No env var and no `unsafe_from_address`. A distinct `_Global`
# name keeps this raw-block handle independent of any frame-codec singleton.
#
# # Encapsulation (FFI boundary)
#
# PUBLIC SAFE API (the surface general callers use):
#   * `lz4_compress(Span[UInt8]) -> List[UInt8]`
#   * `lz4_decompress(Span[UInt8], uncompressed_len: Int) -> List[UInt8]`
#   * `lz4_compress_bound(Int) -> Int`
#   No UnsafePointer in ANY of these signatures; the FFI raw pointers are
#   confined to the `lz4_*_ffi` entries + the output-buffer alloc/free inside
#   the safe wrappers. Nothing crosses a module boundary except Span/List/Int.
# RAW-POINTER FFI API (the FFI-BOUNDARY surface a page-level codec dispatch
# consumes, which itself operates on raw page buffers):
#   * `lz4_compress_ffi`   / `lz4_decompress_ffi`  (caller-chosen origins,
#     NOT wildcards; cast to an untracked origin ONLY at the handle.call site)
#   * `lz4_compress_bound_ffi`
# INTERNAL FFI (private):
#   * The OwnedDLHandle singleton is a stdlib `_Global` runtime slot; its
#     `get_or_create_ptr()` returns an untracked-origin pointer into
#     process-lifetime static storage (NO env var, NO `unsafe_from_address`).
#   * Every `handle.call` site carries a `# SAFETY:` comment.
# =============================================================================

from std.ffi import OwnedDLHandle, _Global
from std.memory import alloc
from std.os import abort
from std.sys.info import CompilationTarget


# -----------------------------------------------------------------------------
# Per-OS soname.
# -----------------------------------------------------------------------------

comptime _LIBLZ4: StaticString = (
    "liblz4.dylib" if CompilationTarget.is_macos() else "liblz4.so.1"
)

# -----------------------------------------------------------------------------
# Process-lifetime OwnedDLHandle singleton via the stdlib `_Global` runtime slot.
#
# `_Global[name, init_fn]` provides a name-keyed, process-global, init-once,
# cross-compile-unit-coherent slot managed by the KGEN runtime: no env var, no
# address laundering. The distinct `_Global` name keeps this liblz4 RAW-BLOCK
# handle independent of any other codec's singleton.
# -----------------------------------------------------------------------------


def _init_lz4_codec_handle() -> OwnedDLHandle:
    """`_Global` init_fn: dlopen liblz4 exactly once per process (KGEN-serialized).

    SAFETY: `_Global`'s init_fn must be non-raising. The OwnedDLHandle ctor
    raises only when the pinned dylib is unresolvable (a fatal provisioning
    error), so we `abort`: without the library no LZ4 block can be read.
    """
    try:
        return OwnedDLHandle(_LIBLZ4)
    except e:
        abort("liblz4 dlopen failed (komira_core_ffi lz4 raw-block handle init)")


comptime _LZ4_CODEC_GLOBAL = _Global[
    "komira_core_ffi_lz4_codec_handle", _init_lz4_codec_handle
]


@always_inline
def _default_lz4_codec_handle() raises -> UnsafePointer[
    OwnedDLHandle, MutUntrackedOrigin
]:
    """Return the process-lifetime liblz4 handle slot (init-once via `_Global`).

    SAFETY: FFI boundary. Targets KGEN-runtime-managed static storage
    (process-lifetime); `MutUntrackedOrigin` is the stdlib `_Global` API's own
    return type, confined to this FFI helper. No env var, no `unsafe_from_address`.
    """
    return _LZ4_CODEC_GLOBAL.get_or_create_ptr()


# -----------------------------------------------------------------------------
# Raw-pointer FFI wrappers — caller-chosen origins, cast at the call site only.
# These are the FFI-BOUNDARY surface for a page-level codec dispatch that
# operates on raw page buffers. General callers use the SAFE Span/List API at
# the bottom of the file.
# -----------------------------------------------------------------------------


def lz4_decompress_ffi[
    sori: Origin, dori: MutOrigin
](
    dst: UnsafePointer[UInt8, dori],
    dst_capacity: Int,
    src: UnsafePointer[UInt8, sori],
    src_size: Int,
) raises -> Int:
    """LZ4 raw block decompression via liblz4's `LZ4_decompress_safe`.

    lz4.h API:
        int LZ4_decompress_safe(const char* src, char* dst,
                                int compressedSize, int dstCapacity);

    Returns bytes written. liblz4 returns negative on error.

    SAFETY: liblz4 reads exactly `src_size` bytes from `src` and writes up to
    `dst_capacity` bytes to `dst`. Both buffers are caller-owned for the
    synchronous call; liblz4 retains no pointer past the call. The handle is a
    process-lifetime singleton. Origins are cast to an untracked origin ONLY at
    the call site. The raw pointers reach only a page-codec dispatch and this
    file's safe wrappers.
    """
    var handle_ptr = _default_lz4_codec_handle()
    var result = handle_ptr[].call["LZ4_decompress_safe", Int32](
        src.unsafe_mut_cast[True]().unsafe_origin_cast[MutUntrackedOrigin](),
        dst.unsafe_origin_cast[MutUntrackedOrigin](),
        Int32(src_size),
        Int32(dst_capacity),
    )
    if Int(result) < 0:
        raise Error(
            "LZ4_decompress_safe failed (result=" + String(Int(result))
            + ", input_len=" + String(src_size)
            + ", output_cap=" + String(dst_capacity) + ")"
        )
    return Int(result)


def lz4_compress_ffi[
    sori: Origin, dori: MutOrigin
](
    dst: UnsafePointer[UInt8, dori],
    dst_capacity: Int,
    src: UnsafePointer[UInt8, sori],
    src_size: Int,
) raises -> Int:
    """LZ4 raw block compression via liblz4's `LZ4_compress_default`.

    lz4.h API:
        int LZ4_compress_default(const char* src, char* dst,
                                 int srcSize, int dstCapacity);

    Returns bytes written. liblz4 returns 0 on insufficient dstCapacity.

    SAFETY: identical contract to `lz4_decompress_ffi`.
    """
    var handle_ptr = _default_lz4_codec_handle()
    var result = handle_ptr[].call["LZ4_compress_default", Int32](
        src.unsafe_mut_cast[True]().unsafe_origin_cast[MutUntrackedOrigin](),
        dst.unsafe_origin_cast[MutUntrackedOrigin](),
        Int32(src_size),
        Int32(dst_capacity),
    )
    if Int(result) <= 0:
        raise Error(
            "LZ4_compress_default failed (result=" + String(Int(result))
            + ", input_len=" + String(src_size)
            + ", output_cap=" + String(dst_capacity) + ")"
        )
    return Int(result)


def lz4_compress_bound_ffi(src_size: Int) raises -> Int:
    """LZ4 maximum compressed size via liblz4's `LZ4_compressBound`.

    lz4.h API:
        int LZ4_compressBound(int inputSize);

    Pure-arithmetic on the C side (`(inputSize) + ((inputSize)/255) + 16`), but
    we keep the FFI shape for parity with the lz4 ABI's bound contract.
    """
    var handle_ptr = _default_lz4_codec_handle()
    return Int(
        handle_ptr[].call["LZ4_compressBound", Int32](Int32(src_size))
    )


# =============================================================================
# PUBLIC API — SAFE (Span in / List out; ZERO raw pointer in any signature).
# =============================================================================


def lz4_compress_bound(input_len: Int) raises -> Int:
    """The maximum compressed size for `input_len` source bytes (liblz4's
    `LZ4_compressBound`). For `input_len == 0` returns a small positive bound
    (the raw-block API never asks to compress an empty buffer — callers should
    handle empty inputs without calling `lz4_compress`)."""
    if input_len < 0:
        raise Error(
            "lz4_compress_bound: negative input_len " + String(input_len)
        )
    if input_len == 0:
        return 16  # LZ4_compressBound(0) == 16; keep the math local for 0.
    return lz4_compress_bound_ffi(input_len)


def lz4_compress(input: Span[UInt8, _]) raises -> List[UInt8]:
    """Compress `input` with LZ4 raw block; return the OWNED compressed bytes.

    Empty input returns an empty `List[UInt8]` (LZ4 raw block has no canonical
    empty-block encoding; the caller stores the uncompressed_len == 0 alongside
    and decompress mirrors it). The output buffer is sized to
    `LZ4_compressBound(len(input))` and truncated to the actual compressed
    length the FFI returns.

    SAFETY: the only raw pointer is the scratch output `alloc`, whose lifetime
    is wholly contained in this function (allocated, handed to the FFI for a
    synchronous call, copied into the returned List, then freed). No pointer
    escapes.
    """
    var n = len(input)
    if n == 0:
        return List[UInt8]()

    var cap = lz4_compress_bound_ffi(n)
    var out_buf = alloc[UInt8](cap)
    # SAFETY: `input.unsafe_ptr()` is borrowed for the synchronous FFI call only
    # (the Span's origin keeps the source alive across the call); `out_buf` is
    # this function's local heap scratch. liblz4 retains neither past the call.
    var written: Int
    try:
        written = lz4_compress_ffi(out_buf, cap, input.unsafe_ptr(), n)
    except e:
        out_buf.free()
        raise e^

    var out = List[UInt8](capacity=written)
    for i in range(written):
        out.append(out_buf[i])
    out_buf.free()
    return out^


def lz4_decompress(
    compressed: Span[UInt8, _], uncompressed_len: Int
) raises -> List[UInt8]:
    """Decompress an LZ4 raw block; return the OWNED `uncompressed_len`-byte
    result. `uncompressed_len` is the exact original size (the caller stored it
    alongside the compressed bytes — LZ4 raw block does NOT self-describe the
    decoded size).

    `uncompressed_len == 0` returns an empty `List[UInt8]` (mirrors
    `lz4_compress`'s empty-input convention; the compressed bytes are also
    empty by that convention).

    SAFETY: the only raw pointer is the scratch output `alloc`, fully contained
    in this function (allocated, handed to the FFI synchronously, copied into
    the returned List, then freed). No pointer escapes.
    """
    if uncompressed_len < 0:
        raise Error(
            "lz4_decompress: negative uncompressed_len "
            + String(uncompressed_len)
        )
    if uncompressed_len == 0:
        return List[UInt8]()
    var n = len(compressed)
    if n == 0:
        raise Error(
            "lz4_decompress: empty compressed input but uncompressed_len="
            + String(uncompressed_len)
        )

    var out_buf = alloc[UInt8](uncompressed_len)
    # SAFETY: `compressed.unsafe_ptr()` borrowed for the synchronous FFI call
    # only; `out_buf` is local heap scratch. liblz4 retains neither.
    var written: Int
    try:
        written = lz4_decompress_ffi(
            out_buf, uncompressed_len, compressed.unsafe_ptr(), n
        )
    except e:
        out_buf.free()
        raise e^
    if written != uncompressed_len:
        out_buf.free()
        raise Error(
            "lz4_decompress: produced " + String(written)
            + " bytes, expected " + String(uncompressed_len)
            + " (corrupt or wrong uncompressed_len)"
        )

    var out = List[UInt8](capacity=uncompressed_len)
    for i in range(uncompressed_len):
        out.append(out_buf[i])
    out_buf.free()
    return out^

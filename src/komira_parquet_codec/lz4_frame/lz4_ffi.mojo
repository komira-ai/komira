# =============================================================================
# lz4_frame/lz4_ffi.mojo
# =============================================================================
#
# LZ4 FRAME compression / decompression — FFI wrapper around liblz4's frame
# API (`LZ4F_*`, lz4frame.h).
#
# # Approach: runtime dlopen via OwnedDLHandle
#
# liblz4 is opened by name (`liblz4.so.1` / `liblz4.dylib`) at first use and
# kept in a process-lifetime handle, so nothing is linked.
#
# # API (package-private: `compression.mojo` is the caller)
#
#   fn _lz4_frame_decompress_into(dst: Span[mut UInt8], src: Span[UInt8]) -> Int
#   fn _lz4_frame_compress_into(dst: Span[mut UInt8], src: Span[UInt8]) -> Int
#   fn _lz4_frame_compress_bound(src_size: Int) -> Int
#
# # OwnedDLHandle singleton
#
# Process-lifetime liblz4 FRAME handle via the stdlib `_Global` runtime slot
# (dlopen'd once, init-once, cross-compile-unit-coherent, KGEN-managed).
#
# # Encapsulation
#
#   * No signature holds a raw pointer: the entries take Spans, and the
#     pointers taken from them are cast to an untracked origin ONLY at the
#     `handle.call[...]` sites.
#   * The decompression context is a typed pointer local created and freed
#     inside one call; no address is ever rebuilt from an integer.
#   * The handle singleton is a stdlib `_Global` slot; `get_or_create_ptr()`
#     returns `MutUntrackedOrigin` into process-lifetime static storage (no env
#     var, no address rebuilt from an integer).
#   * Every `handle.call` site carries a `# SAFETY:` comment.
# =============================================================================

from std.ffi import OwnedDLHandle, _Global
from std.os import abort
from std.sys.info import CompilationTarget


@always_inline
def _lz4_null_byte() -> UnsafePointer[UInt8, MutUntrackedOrigin]:
    """A NULL `UnsafePointer[UInt8, MutUntrackedOrigin]` (the pointer type has
    no null constructor) for liblz4 NULL-prefs / NULL-options FFI args.

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the bare
    # pointer (the stdlib non-null-pointer design); `None` is the
    # all-zero NULL bit pattern. The untracked origin is the type of every
    # `handle.call[...]` FFI pointer arg here. liblz4 never dereferences the NULL
    # (it requests the default prefs/options).
    """
    var none: Optional[UnsafePointer[UInt8, MutUntrackedOrigin]] = None
    return UnsafePointer(to=none).bitcast[
        UnsafePointer[UInt8, MutUntrackedOrigin]
    ]()[]


# -----------------------------------------------------------------------------
# Per-OS soname.
# -----------------------------------------------------------------------------

comptime _LIBLZ4: StaticString = (
    "liblz4.dylib" if CompilationTarget.is_macos() else "liblz4.so.1"
)

# -----------------------------------------------------------------------------
# Process-lifetime OwnedDLHandle singleton via the stdlib `_Global` runtime slot.
#
# `_Global[name, init_fn]` provides a
# name-keyed, process-global, init-once, cross-compile-unit-coherent slot managed
# by the KGEN runtime — no env var, no address laundering. The distinct `_Global`
# name keeps this liblz4 FRAME handle independent of the raw-block
# (komira_lz4) handle and any other package's liblz4 handle.
# -----------------------------------------------------------------------------


def _init_lz4_ffi_handle() -> OwnedDLHandle:
    """`_Global` init_fn: dlopen liblz4 exactly once per process (KGEN-serialized).

    SAFETY: `_Global`'s init_fn must be non-raising. The OwnedDLHandle ctor
    raises only when the library cannot be loaded (a fatal provisioning
    error), so we `abort`: without the library no LZ4 frame can be read.
    """
    try:
        return OwnedDLHandle(_LIBLZ4)
    except e:
        abort("liblz4 dlopen failed (parquet lz4-frame FFI handle init)")


comptime _LZ4_FFI_GLOBAL = _Global[
    "komira_parquet_codec_lz4_frame_handle", _init_lz4_ffi_handle
]


@always_inline
def _default_lz4_ffi_handle() raises -> UnsafePointer[
    OwnedDLHandle, MutUntrackedOrigin
]:
    """Return the process-lifetime liblz4 FRAME handle slot (init-once via `_Global`).

    SAFETY: FFI boundary. Targets KGEN-runtime-managed static storage
    (process-lifetime); `MutUntrackedOrigin` is the stdlib `_Global` API's own
    return type, confined to this FFI helper. No env var, no address rebuilt from an integer.
    """
    return _LZ4_FFI_GLOBAL.get_or_create_ptr()


# -----------------------------------------------------------------------------
# The LZ4 RAW-BLOCK entries live in the shared komira_lz4 library; only the
# LZ4 FRAME entries (a distinct codec) are in this file.
# -----------------------------------------------------------------------------
# LZ4 FRAME (LZ4F_*) decompression — the interoperable framing per the LZ4
# Frame Format spec. Kafka's LZ4 producer compression (KIP-57, since Kafka
# 0.10) emits LZ4-FRAME bytes (magic 0x184D2204 + frame descriptor + block
# headers), NOT raw blocks. A raw-block decoder CANNOT decode these; the
# liblz4 frame API (`LZ4F_decompress`) is required.
#
# liblz4 frame API (lz4frame.h):
#   typedef ... LZ4F_dctx;
#   LZ4F_errorCode_t LZ4F_createDecompressionContext(LZ4F_dctx** dctxPtr,
#                                                    unsigned version);
#   size_t LZ4F_decompress(LZ4F_dctx* dctx,
#                          void* dstBuffer, size_t* dstSizePtr,
#                          const void* srcBuffer, size_t* srcSizePtr,
#                          const LZ4F_decompressOptions_t* dOptPtr);
#   LZ4F_errorCode_t LZ4F_freeDecompressionContext(LZ4F_dctx* dctx);
#   unsigned LZ4F_isError(LZ4F_errorCode_t code);
#   #define LZ4F_VERSION 100
# -----------------------------------------------------------------------------

comptime _LZ4F_VERSION: Int32 = 100


def _lz4_frame_decompress_into[
    dori: MutOrigin
](dst: Span[UInt8, dori], src: Span[UInt8, _]) raises -> Int:
    """LZ4 FRAME decompression via liblz4's `LZ4F_decompress`.

    Decodes one complete in-memory LZ4 frame (`src`) into `dst` (capacity
    `len(dst)`). Drives `LZ4F_decompress` in a loop until the whole frame is
    consumed; liblz4 returns a hint of 0 once the frame is fully decoded.
    Returns the number of decompressed bytes written.

    Raises with the literal "LZ4F dst buffer too small" marker substring when
    the output buffer filled before the frame ended (a caller's grow-and-retry
    loop matches on that substring); raises "LZ4F frame truncated" when the
    input ends before the frame does (a missing end mark, a cut block); raises
    a distinct error on any `LZ4F_isError`-flagged failure.

    SAFETY: liblz4's frame decoder reads only `src` and writes only `dst`
    across the synchronous call sequence; it retains no pointer past each
    `LZ4F_decompress` call. The decompression context is created and freed
    within this function (no leak). The context handle and the two `size_t`
    in/out counters are stack locals whose addresses are handed to liblz4
    only for the duration of each call. Origins are cast to an untracked
    origin ONLY at the `handle.call[...]` sites.
    """
    var src_size = len(src)
    var dst_capacity = len(dst)
    var src_ptr = src.unsafe_ptr()
    var dst_ptr = dst.unsafe_ptr()
    var handle_ptr = _default_lz4_ffi_handle()

    # The decompression context: an opaque LZ4F_dctx* that liblz4 allocates
    # and this function frees. It is held as a typed pointer local and never
    # dereferenced on the Mojo side; liblz4 writes it through the address of
    # this local.
    var dctx = _lz4_null_byte()
    # SAFETY: `UnsafePointer(to=dctx)` addresses the stack local above (a
    # concrete origin); liblz4 writes the allocated context pointer into it
    # and does not retain the address. Cast to an untracked origin at the FFI
    # call only.
    var create_rc = handle_ptr[].call["LZ4F_createDecompressionContext", UInt64](
        UnsafePointer(to=dctx)
        .bitcast[UInt8]()
        .unsafe_origin_cast[MutUntrackedOrigin](),
        UInt32(Int(_LZ4F_VERSION)),
    )
    var is_err_create = handle_ptr[].call["LZ4F_isError", UInt32](create_rc)
    if Int(is_err_create) != 0:
        raise Error(
            "LZ4F_createDecompressionContext failed (code="
            + String(Int(create_rc)) + ")"
        )
    if dctx == _lz4_null_byte():
        raise Error("LZ4F_createDecompressionContext returned null dctx")

    var total_out = 0
    var src_pos = 0
    var raised_msg = String("")
    var failed = False

    # Drive the frame decoder until it reports the frame done (a hint of 0).
    # Each call tells us how many src bytes it ate and how many dst bytes it
    # produced. Once the input is used up, a call with no input left lets
    # liblz4 flush what it buffered; a call that then makes no progress
    # means the frame ended early (input used up) or the output is full.
    while True:
        var dst_avail = dst_capacity - total_out
        # In/out size counters (size_t == UInt64 on LP64).
        var dst_sz = Array[UInt64, 1](fill=UInt64(dst_avail))
        var src_sz = Array[UInt64, 1](fill=UInt64(src_size - src_pos))
        var dst_sz_ptr = dst_sz.unsafe_ptr()
        var src_sz_ptr = src_sz.unsafe_ptr()
        # SAFETY: the context handle, the dst and src windows (inside the
        # Spans, which keep their buffers alive) and the two stack size
        # counters all outlive this synchronous call; liblz4 retains none of
        # them. Origins cast to an untracked origin only here.
        var hint = handle_ptr[].call["LZ4F_decompress", UInt64](
            dctx,
            (dst_ptr + total_out).unsafe_origin_cast[MutUntrackedOrigin](),
            dst_sz_ptr.bitcast[UInt8]().unsafe_origin_cast[MutUntrackedOrigin](),
            (src_ptr + src_pos).unsafe_mut_cast[True]().unsafe_origin_cast[
                MutUntrackedOrigin
            ](),
            src_sz_ptr.bitcast[UInt8]().unsafe_origin_cast[MutUntrackedOrigin](),
            _lz4_null_byte(),  # default options (NULL)
        )
        var is_err = handle_ptr[].call["LZ4F_isError", UInt32](hint)
        if Int(is_err) != 0:
            failed = True
            raised_msg = "LZ4F_decompress failed (code=" + String(Int(hint)) + ")"
            break
        var produced = Int(dst_sz[0])
        var consumed = Int(src_sz[0])
        total_out += produced
        src_pos += consumed
        if Int(hint) == 0:
            # Frame fully decoded.
            break
        if consumed == 0 and produced == 0:
            # No progress and the frame is not done.
            failed = True
            if src_pos >= src_size and total_out < dst_capacity:
                raised_msg = (
                    "LZ4F frame truncated: the " + String(src_size)
                    + "-byte input ends before the frame does"
                )
            else:
                raised_msg = "LZ4F dst buffer too small"
            break

    # SAFETY (FFI): `dctx` is the LZ4F_dctx handle returned by
    # LZ4F_createDecompressionContext above; we own it and free it exactly
    # once here on teardown. liblz4 owns the context's heap, and the pointer
    # is never used after this call.
    var _free_rc = handle_ptr[].call["LZ4F_freeDecompressionContext", UInt64](
        dctx
    )

    if failed:
        raise Error(raised_msg)
    return total_out


def _lz4_frame_compress_bound(src_size: Int) raises -> Int:
    """Max LZ4-frame compressed size via liblz4 `LZ4F_compressFrameBound`.

    lz4frame.h API:
        size_t LZ4F_compressFrameBound(size_t srcSize,
                                       const LZ4F_preferences_t* prefsPtr);
    We pass NULL prefs (defaults).
    """
    var handle_ptr = _default_lz4_ffi_handle()
    # SAFETY (FFI): NULL prefs requests the default/worst-case frame bound.
    # This is a pure stateless size query — liblz4 does not dereference or
    # retain the NULL pointer, so no lifetime or origin is involved.
    return Int(
        handle_ptr[].call["LZ4F_compressFrameBound", UInt64](
            UInt64(src_size),
            _lz4_null_byte(),  # NULL prefs
        )
    )


def _lz4_frame_compress_into[
    dori: MutOrigin
](dst: Span[UInt8, dori], src: Span[UInt8, _]) raises -> Int:
    """LZ4 FRAME compression (one-shot) via liblz4 `LZ4F_compressFrame`.

    Produces a complete interoperable LZ4 frame (the format Kafka's `lz4`
    producer emits). `len(dst)` must be >= `_lz4_frame_compress_bound`.
    Returns the frame byte count.

    SAFETY: stateless one-shot; liblz4 reads only `src`, writes only `dst`,
    and retains nothing past the call; the Spans keep both buffers alive.
    Origins cast to an untracked origin only at the call site.
    """
    var handle_ptr = _default_lz4_ffi_handle()
    var result = handle_ptr[].call["LZ4F_compressFrame", UInt64](
        dst.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin](),
        UInt64(len(dst)),
        src.unsafe_ptr()
        .unsafe_mut_cast[True]()
        .unsafe_origin_cast[MutUntrackedOrigin](),
        UInt64(len(src)),
        _lz4_null_byte(),  # NULL prefs (defaults)
    )
    var is_err = handle_ptr[].call["LZ4F_isError", UInt32](result)
    if Int(is_err) != 0:
        raise Error(
            "LZ4F_compressFrame failed (code=" + String(Int(result)) + ")"
        )
    return Int(result)

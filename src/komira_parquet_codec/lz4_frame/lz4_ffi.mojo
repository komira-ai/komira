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
# # API
#
#   fn lz4_frame_decompress_ffi(dst, dst_capacity, src, src_size) raises -> Int
#   fn lz4_frame_compress_ffi(dst, dst_capacity, src, src_size) raises -> Int
#   fn lz4_frame_compress_bound_ffi(src_size) raises -> Int
#
# # OwnedDLHandle singleton
#
# Process-lifetime liblz4 FRAME handle via the stdlib `_Global` runtime slot
# (dlopen'd once, init-once, cross-compile-unit-coherent, KGEN-managed).
#
# # Encapsulation
#
# Public API:
#   * `lz4_frame_*_ffi` entries accept UnsafePointer with CALLER-CHOSEN origins
#     (Origin / MutOrigin generic params), NOT wildcards.
# Internal FFI:
#   * The handle singleton is a stdlib `_Global` slot; `get_or_create_ptr()`
#     returns `MutUntrackedOrigin` into process-lifetime static storage (no env
#     var, no `unsafe_from_address`).
#   * Public entries cast caller pointers to an untracked origin ONLY at the
#     `handle.call[...]` site.
#   * Every `handle.call` site carries a `# SAFETY:` comment.
# =============================================================================

from std.ffi import OwnedDLHandle, _Global
from std.memory import alloc, UnsafePointer
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
    raises only when the pinned dylib is unresolvable (a fatal provisioning
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
    return type, confined to this FFI helper. No env var, no `unsafe_from_address`.
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


def lz4_frame_decompress_ffi[
    sori: Origin, dori: MutOrigin
](
    dst: UnsafePointer[UInt8, dori],
    dst_capacity: Int,
    src: UnsafePointer[UInt8, sori],
    src_size: Int,
) raises -> Int:
    """LZ4 FRAME decompression via liblz4's `LZ4F_decompress`.

    Decodes a complete in-memory LZ4-frame (`src[0:src_size]`) into `dst`
    (capacity `dst_capacity`). Drives `LZ4F_decompress` in a loop until the
    whole frame is consumed; the function returns 0 (a hint of 0) once the
    frame is fully decoded. Returns the number of decompressed bytes written.

    Raises with the literal "LZ4F dst buffer too small" marker substring when
    the input is consumed but the output buffer filled before the frame ended
    (the caller's grow-and-retry loop matches on that substring); raises a
    distinct error on any `LZ4F_isError`-flagged failure.

    SAFETY: liblz4's frame decoder reads only `src[0:src_size]` and writes
    only `dst[0:dst_capacity]` across the synchronous call sequence; it
    retains no pointer past each `LZ4F_decompress` call. The decompression
    context is created and freed within this function (no leak). The two
    `size_t` in/out counters live on the stack as InlineArray slots whose
    addresses we hand to liblz4 only for the duration of each call. Origins
    are cast to an untracked origin ONLY at the `handle.call[...]` sites.
    """
    var handle_ptr = _default_lz4_ffi_handle()

    # Create the decompression context (dctx is an opaque pointer liblz4
    # allocates; we own freeing it).
    var dctx_slot = Array[UInt64, 1](fill=UInt64(0))
    var dctx_slot_ptr = dctx_slot.unsafe_ptr()
    # SAFETY: `dctx_slot_ptr` addresses a 1-element stack InlineArray; liblz4
    # writes the allocated dctx pointer into it and does not retain the
    # address. Cast to an untracked origin at the FFI call only.
    var create_rc = handle_ptr[].call["LZ4F_createDecompressionContext", UInt64](
        dctx_slot_ptr.bitcast[UInt8]().unsafe_origin_cast[MutUntrackedOrigin](),
        UInt32(Int(_LZ4F_VERSION)),
    )
    var is_err_create = handle_ptr[].call["LZ4F_isError", UInt32](create_rc)
    if Int(is_err_create) != 0:
        raise Error(
            "LZ4F_createDecompressionContext failed (code="
            + String(Int(create_rc)) + ")"
        )
    var dctx = dctx_slot[0]
    if dctx == UInt64(0):
        raise Error("LZ4F_createDecompressionContext returned null dctx")
    # TODO(safety): `dctx` is a C-owned LZ4F_dctx* opaque handle (liblz4 owns
    # its heap), created here and freed on teardown below within this SAME
    # synchronous scope. It is stored as UInt64 and rematerialized via
    # `unsafe_from_address=Int(dctx)` at the decompress + free call sites. The
    # clean fix: read the dctx slot as a typed
    # `UnsafePointer[UInt8, <concrete>]` and thread it through decompress/free
    # instead of round-tripping through Int.

    var total_out = 0
    var src_pos = 0
    var raised_msg = String("")
    var failed = False

    # Drive the frame decoder until the whole input is consumed. Each call
    # tells us how many src bytes it ate and how many dst bytes it produced.
    while src_pos < src_size:
        var dst_avail = dst_capacity - total_out
        # In/out size counters (size_t == UInt64 on LP64).
        var dst_sz = Array[UInt64, 1](fill=UInt64(dst_avail))
        var src_sz = Array[UInt64, 1](fill=UInt64(src_size - src_pos))
        var dst_sz_ptr = dst_sz.unsafe_ptr()
        var src_sz_ptr = src_sz.unsafe_ptr()
        # SAFETY: all four buffers (dctx handle, dst slice, src slice, the two
        # size counters) are caller-/stack-owned for the duration of this
        # synchronous call; liblz4 retains none of them. Origins cast to
        # an untracked origin only here.
        var hint = handle_ptr[].call["LZ4F_decompress", UInt64](
            UnsafePointer[UInt8, MutUntrackedOrigin](
                unsafe_from_address=Int(dctx)
            ),
            (dst + total_out).unsafe_origin_cast[MutUntrackedOrigin](),
            dst_sz_ptr.bitcast[UInt8]().unsafe_origin_cast[MutUntrackedOrigin](),
            (src + src_pos).unsafe_mut_cast[True]().unsafe_origin_cast[
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
            # No progress and the frame is not done — the dst buffer is full.
            failed = True
            raised_msg = "LZ4F dst buffer too small"
            break

    # SAFETY (FFI): `dctx` is the LZ4F_dctx handle
    # returned by LZ4F_createDecompressionContext above; we own it and free
    # it exactly once here on teardown. liblz4 owns the dctx's heap; the
    # address is rematerialized for the free call (no Mojo-side lifetime is
    # tracked through it) and is never dereferenced after this call.
    var _free_rc = handle_ptr[].call["LZ4F_freeDecompressionContext", UInt64](
        UnsafePointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(dctx))
    )

    if failed:
        raise Error(raised_msg)
    return total_out


def lz4_frame_compress_bound_ffi(src_size: Int) raises -> Int:
    """Max LZ4-frame compressed size via liblz4 `LZ4F_compressFrameBound`.

    lz4frame.h API:
        size_t LZ4F_compressFrameBound(size_t srcSize,
                                       const LZ4F_preferences_t* prefsPtr);
    We pass NULL prefs (defaults).
    """
    var handle_ptr = _default_lz4_ffi_handle()
    # SAFETY (FFI): NULL prefs requests the
    # default/worst-case frame bound. This is a pure stateless size query —
    # liblz4 does not dereference or retain the NULL pointer, so no lifetime
    # or origin is involved.
    return Int(
        handle_ptr[].call["LZ4F_compressFrameBound", UInt64](
            UInt64(src_size),
            _lz4_null_byte(),  # NULL prefs
        )
    )


def lz4_frame_compress_ffi[
    sori: Origin, dori: MutOrigin
](
    dst: UnsafePointer[UInt8, dori],
    dst_capacity: Int,
    src: UnsafePointer[UInt8, sori],
    src_size: Int,
) raises -> Int:
    """LZ4 FRAME compression (one-shot) via liblz4 `LZ4F_compressFrame`.

    Produces a complete interoperable LZ4 frame (the format Kafka's `lz4`
    producer emits). `dst_capacity` must be >= `lz4_frame_compress_bound_ffi`.
    Returns the frame byte count.

    SAFETY: stateless one-shot; liblz4 reads only `src[0:src_size]`, writes
    only `dst[0:dst_capacity]`, retains nothing past the call. Origins cast to
    an untracked origin only at the call site.
    """
    var handle_ptr = _default_lz4_ffi_handle()
    var result = handle_ptr[].call["LZ4F_compressFrame", UInt64](
        dst.unsafe_origin_cast[MutUntrackedOrigin](),
        UInt64(dst_capacity),
        src.unsafe_mut_cast[True]().unsafe_origin_cast[MutUntrackedOrigin](),
        UInt64(src_size),
        _lz4_null_byte(),  # NULL prefs (defaults)
    )
    var is_err = handle_ptr[].call["LZ4F_isError", UInt32](result)
    if Int(is_err) != 0:
        raise Error(
            "LZ4F_compressFrame failed (code=" + String(Int(result)) + ")"
        )
    return Int(result)

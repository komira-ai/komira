# =============================================================================
# zstd/zstd_ffi.mojo
# =============================================================================
#
# Zstandard — FFI wrapper to libzstd's `ZSTD_decompress` / `ZSTD_compress` /
# `ZSTD_compressBound` / `ZSTD_isError` symbols.
#
# # Approach: runtime dlopen via OwnedDLHandle
#
# libzstd is opened by name (`libzstd.so.1` / `libzstd.dylib`) at first use
# and kept in a process-lifetime handle, so the system's libzstd is used and
# nothing is linked.
#
# # API
#
# Stateless single-call FFI — no opaque context handle, no per-call alloc
# (libzstd takes raw byte buffers).
#
#   fn zstd_decompress_ffi(
#       dst: UnsafePointer[UInt8, dori],
#       dst_capacity: Int,
#       src: UnsafePointer[UInt8, sori],
#       src_size: Int,
#   ) raises -> Int
#
#   fn zstd_compress_ffi(
#       dst: UnsafePointer[UInt8, dori],
#       dst_capacity: Int,
#       src: UnsafePointer[UInt8, sori],
#       src_size: Int,
#       compression_level: Int32,
#   ) raises -> Int
#
#   fn zstd_compress_bound_ffi(src_size: Int) raises -> Int
#
# # OwnedDLHandle singleton
#
# Process-lifetime libzstd handle via the stdlib `_Global` runtime slot
# (dlopen once on first use, init-once, cross-compile-unit-coherent,
# KGEN-managed). First call: one dlopen. Every later call: slot fetch + dlsym
# + indirect call.
#
# # Encapsulation
#
# Public API:
#   * `zstd_decompress_ffi` / `zstd_compress_ffi` / `zstd_compress_bound_ffi`
#     accept UnsafePointer with CALLER-CHOSEN origins (Origin / MutOrigin
#     generic params), NOT wildcards.
# Internal FFI:
#   * The handle singleton is a stdlib `_Global` slot; `get_or_create_ptr()`
#     returns `MutUntrackedOrigin` into process-lifetime static storage (no env
#     var, no `unsafe_from_address`).
#   * Caller pointers are cast to an untracked origin ONLY at the
#     `handle.call[...]` site.
#   * Every `handle.call` site carries a `# SAFETY:` comment.
# =============================================================================

from std.ffi import OwnedDLHandle, _Global

from std.memory import alloc
from std.os import abort
from std.sys.info import CompilationTarget


# -----------------------------------------------------------------------------
# Per-OS soname. Both branches type-check on every host; comptime if elides
# the non-host branch at codegen.
# -----------------------------------------------------------------------------

comptime _LIBZSTD: StaticString = (
    "libzstd.dylib" if CompilationTarget.is_macos() else "libzstd.so.1"
)

# -----------------------------------------------------------------------------
# Process-lifetime OwnedDLHandle singleton via the stdlib `_Global` runtime slot.
#
# `_Global[name, init_fn]` provides a name-keyed, process-global, init-once,
# cross-compile-unit-coherent slot managed by the KGEN runtime — no env var,
# no address laundering. The distinct `_Global` name keeps this libzstd handle
# independent of any other package's libzstd handle.
# -----------------------------------------------------------------------------


def _init_zstd_ffi_handle() -> OwnedDLHandle:
    """`_Global` init_fn: dlopen libzstd exactly once per process (KGEN-serialized).

    SAFETY: `_Global`'s init_fn must be non-raising. The OwnedDLHandle ctor
    raises only when the pinned dylib is unresolvable (a fatal provisioning
    error), so we `abort`: without the library no zstd page can be read.
    """
    try:
        return OwnedDLHandle(_LIBZSTD)
    except e:
        abort("libzstd dlopen failed (parquet zstd FFI handle init)")


comptime _ZSTD_FFI_GLOBAL = _Global[
    "komira_parquet_codec_zstd_handle", _init_zstd_ffi_handle
]


@always_inline
def _default_zstd_ffi_handle() raises -> UnsafePointer[
    OwnedDLHandle, MutUntrackedOrigin
]:
    """Return the process-lifetime libzstd handle slot (init-once via `_Global`).

    SAFETY: FFI boundary. Targets KGEN-runtime-managed static storage
    (process-lifetime); `MutUntrackedOrigin` is the stdlib `_Global` API's own
    return type, confined to this FFI helper. No env var, no `unsafe_from_address`.
    """
    return _ZSTD_FFI_GLOBAL.get_or_create_ptr()


# -----------------------------------------------------------------------------
# Public FFI wrappers — the (dst, dst_capacity, src, src_size) shape the
# codec dispatch in compression.mojo calls.
# -----------------------------------------------------------------------------


def zstd_decompress_ffi[
    sori: Origin, dori: MutOrigin
](
    dst: UnsafePointer[UInt8, dori],
    dst_capacity: Int,
    src: UnsafePointer[UInt8, sori],
    src_size: Int,
) raises -> Int:
    """Decompress one or more concatenated zstd frames via libzstd's
    `ZSTD_decompress`. Returns total bytes written to dst.

    SAFETY: libzstd's ZSTD_decompress reads exactly `src_size` bytes from
    `src` and writes up to `dst_capacity` bytes to `dst`. Both buffers
    are caller-owned for the duration of this synchronous call; libzstd
    retains no pointer past the call. The handle is a process-lifetime
    singleton (never freed). Origins are cast to an untracked origin ONLY
    at the call site.
    """
    var handle_ptr = _default_zstd_ffi_handle()
    var result = handle_ptr[].call["ZSTD_decompress", Int](
        dst.unsafe_origin_cast[MutUntrackedOrigin](),
        dst_capacity,
        src.unsafe_mut_cast[True]().unsafe_origin_cast[MutUntrackedOrigin](),
        src_size,
    )
    var is_err = handle_ptr[].call["ZSTD_isError", Int](result)
    if is_err != 0:
        raise Error(
            "ZSTD_decompress failed (result=" + String(result)
            + ", input_len=" + String(src_size)
            + ", output_cap=" + String(dst_capacity) + ")"
        )
    return result


def zstd_compress_ffi[
    sori: Origin, dori: MutOrigin
](
    dst: UnsafePointer[UInt8, dori],
    dst_capacity: Int,
    src: UnsafePointer[UInt8, sori],
    src_size: Int,
    compression_level: Int32,
) raises -> Int:
    """Compress src into dst via libzstd's `ZSTD_compress` at `compression_level`.
    Returns bytes written.

    SAFETY: identical contract to zstd_decompress_ffi — buffers are
    caller-owned, libzstd retains no pointer past the call.
    """
    var handle_ptr = _default_zstd_ffi_handle()
    var result = handle_ptr[].call["ZSTD_compress", Int](
        dst.unsafe_origin_cast[MutUntrackedOrigin](),
        dst_capacity,
        src.unsafe_mut_cast[True]().unsafe_origin_cast[MutUntrackedOrigin](),
        src_size,
        compression_level,
    )
    var is_err = handle_ptr[].call["ZSTD_isError", Int](result)
    if is_err != 0:
        raise Error(
            "ZSTD_compress failed (result=" + String(result)
            + ", input_len=" + String(src_size)
            + ", output_cap=" + String(dst_capacity) + ")"
        )
    return result


def zstd_compress_bound_ffi(src_size: Int) raises -> Int:
    """ZSTD_compressBound(srcSize) — maximum possible compressed size.

    Stateless, pure arithmetic on the C side; equivalent to the
    `ZSTD_COMPRESSBOUND` macro in zstd.h (srcSize + (srcSize >> 8) + 512).
    The FFI shape is preserved for parity with the C library's bound
    contract (vs computing the macro in-Mojo).
    """
    var handle_ptr = _default_zstd_ffi_handle()
    return handle_ptr[].call["ZSTD_compressBound", Int](src_size)

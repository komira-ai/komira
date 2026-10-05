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
# # API (package-private: `compression.mojo` is the caller)
#
# Stateless single-call FFI — no opaque context handle, no per-call alloc.
#
#   fn _zstd_decompress_into(dst: Span[mut UInt8], src: Span[UInt8]) -> Int
#   fn _zstd_compress_into(dst: Span[mut UInt8], src: Span[UInt8],
#                          compression_level: Int32) -> Int
#   fn _zstd_compress_bound(src_size: Int) -> Int
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
#   * No signature holds a raw pointer: the entries take Spans, and the
#     pointers are taken from them for the one synchronous call and cast to an
#     untracked origin ONLY at the `handle.call[...]` site.
#   * The handle singleton is a stdlib `_Global` slot; `get_or_create_ptr()`
#     returns `MutUntrackedOrigin` into process-lifetime static storage (no env
#     var, no address rebuilt from an integer).
#   * Every `handle.call` site carries a `# SAFETY:` comment.
# =============================================================================

from std.ffi import OwnedDLHandle, _Global

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
    raises only when the library cannot be loaded (a fatal provisioning
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
    return type, confined to this FFI helper. No env var, no address rebuilt from an integer.
    """
    return _ZSTD_FFI_GLOBAL.get_or_create_ptr()




# -----------------------------------------------------------------------------
# Entries — the codec dispatch in compression.mojo calls these.
# -----------------------------------------------------------------------------


def _zstd_decompress_into[
    dori: MutOrigin
](dst: Span[UInt8, dori], src: Span[UInt8, _]) raises -> Int:
    """Decompress one or more concatenated zstd frames in `src` into `dst`
    via libzstd's `ZSTD_decompress`; return the bytes written. `len(dst)` is
    the capacity: frames that decode to more are refused.

    SAFETY: libzstd's ZSTD_decompress reads exactly `len(src)` bytes from
    `src` and writes up to `len(dst)` bytes to `dst`. Both Spans keep their
    buffers alive for this synchronous call; libzstd retains no pointer past
    it. The handle is a process-lifetime singleton (never freed). Origins are
    cast to an untracked origin ONLY at the call site.
    """
    var src_size = len(src)
    var dst_capacity = len(dst)
    var handle_ptr = _default_zstd_ffi_handle()
    var result = handle_ptr[].call["ZSTD_decompress", Int](
        dst.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin](),
        dst_capacity,
        src.unsafe_ptr()
        .unsafe_mut_cast[True]()
        .unsafe_origin_cast[MutUntrackedOrigin](),
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


def _zstd_compress_into[
    dori: MutOrigin
](
    dst: Span[UInt8, dori],
    src: Span[UInt8, _],
    compression_level: Int32,
) raises -> Int:
    """Compress `src` into `dst` via libzstd's `ZSTD_compress` at
    `compression_level`; return the bytes written. `dst` should hold
    `_zstd_compress_bound(len(src))` bytes; libzstd refuses a destination too
    small for the frame it produces.

    SAFETY: identical contract to `_zstd_decompress_into` — the Spans keep
    both buffers alive, and libzstd retains no pointer past the call.
    """
    var src_size = len(src)
    var dst_capacity = len(dst)
    var handle_ptr = _default_zstd_ffi_handle()
    var result = handle_ptr[].call["ZSTD_compress", Int](
        dst.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin](),
        dst_capacity,
        src.unsafe_ptr()
        .unsafe_mut_cast[True]()
        .unsafe_origin_cast[MutUntrackedOrigin](),
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


def _zstd_compress_bound(src_size: Int) raises -> Int:
    """ZSTD_compressBound(srcSize) — maximum possible compressed size.

    Stateless, pure arithmetic on the C side; equivalent to the
    `ZSTD_COMPRESSBOUND` macro in zstd.h (srcSize + (srcSize >> 8) + 512).
    """
    var handle_ptr = _default_zstd_ffi_handle()
    return handle_ptr[].call["ZSTD_compressBound", Int](src_size)

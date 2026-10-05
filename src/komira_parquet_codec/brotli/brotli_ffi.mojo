# =============================================================================
# brotli/brotli_ffi.mojo
# =============================================================================
#
# Brotli DECOMPRESSION (read path only) — FFI wrapper to libbrotlidec's
# one-shot `BrotliDecoderDecompress` symbol.
#
# Parquet supports a BROTLI compression codec. This package reads it through
# libbrotlidec, opened by name (`libbrotlidec.so.1` / `libbrotlidec.dylib`)
# at first use; the loader resolves the dependent `libbrotlicommon`. Writing
# Brotli is out of scope.
#
# # API
#
# Brotli's one-shot decode API:
#   BrotliDecoderResult BrotliDecoderDecompress(
#       size_t encoded_size, const uint8_t* encoded_buffer,
#       size_t* decoded_size, uint8_t* decoded_buffer);
#
# `decoded_size` is in/out: caller sets it to the output buffer capacity
# (the Parquet page's uncompressed_page_size), and on SUCCESS it holds the
# actual number of bytes written. The return value is a BrotliDecoderResult
# enum; SUCCESS == 1.
#
#   fn brotli_decompress_ffi(dst, dst_capacity, src, src_size) raises -> Int
#
# # Encapsulation
#
# Public API: `brotli_decompress_ffi` accepts UnsafePointer with caller-chosen
# origins (Origin / MutOrigin), NOT wildcards. Caller pointers are cast to an
# untracked origin ONLY at the `handle.call[...]` site. The FFI call carries a
# `# SAFETY:` block.
# =============================================================================

from std.ffi import OwnedDLHandle, _Global

from std.memory import alloc
from std.os import abort
from std.sys.info import CompilationTarget


# -----------------------------------------------------------------------------
# Per-OS soname. Both branches type-check on every host; comptime-if elides
# the non-host branch at codegen.
# -----------------------------------------------------------------------------

comptime _LIBBROTLIDEC: StaticString = (
    "libbrotlidec.dylib" if CompilationTarget.is_macos() else "libbrotlidec.so.1"
)

# BrotliDecoderResult enum value for a complete, successful one-shot decode.
# (BROTLI_DECODER_RESULT_SUCCESS == 1; ERROR == 0; NEEDS_MORE_INPUT == 2;
#  NEEDS_MORE_OUTPUT == 3.)
comptime _BROTLI_DECODER_RESULT_SUCCESS: Int = 1


# -----------------------------------------------------------------------------
# Process-lifetime OwnedDLHandle singleton via the stdlib `_Global` runtime slot.
#
# `_Global[name, init_fn]` provides a
# name-keyed, process-global, init-once, cross-compile-unit-coherent slot managed
# by the KGEN runtime — no env var, no address laundering.
# -----------------------------------------------------------------------------


def _init_brotli_ffi_handle() -> OwnedDLHandle:
    """`_Global` init_fn: dlopen libbrotlidec once per process (KGEN-serialized).

    SAFETY: `_Global`'s init_fn must be non-raising. The OwnedDLHandle ctor
    raises only when the pinned dylib is unresolvable (a fatal provisioning
    error), so we `abort`: without the library no Brotli page can be read.
    """
    try:
        return OwnedDLHandle(_LIBBROTLIDEC)
    except e:
        abort("libbrotlidec dlopen failed (parquet brotli FFI handle init)")


comptime _BROTLI_FFI_GLOBAL = _Global[
    "komira_parquet_codec_brotlidec_handle", _init_brotli_ffi_handle
]


@always_inline
def _default_brotli_ffi_handle() raises -> UnsafePointer[
    OwnedDLHandle, MutUntrackedOrigin
]:
    """Return the process-lifetime libbrotlidec handle slot (init-once via `_Global`).

    SAFETY: FFI boundary. Targets KGEN-runtime-managed static storage
    (process-lifetime); `MutUntrackedOrigin` is the stdlib `_Global` API's own
    return type, confined to this FFI helper. No env var, no `unsafe_from_address`.
    """
    return _BROTLI_FFI_GLOBAL.get_or_create_ptr()


# -----------------------------------------------------------------------------
# Public FFI wrapper — matches the production caller shape in compression.mojo.
# -----------------------------------------------------------------------------


def brotli_decompress_ffi[
    sori: Origin, dori: MutOrigin
](
    dst: UnsafePointer[UInt8, dori],
    dst_capacity: Int,
    src: UnsafePointer[UInt8, sori],
    src_size: Int,
) raises -> Int:
    """Decompress a Brotli stream via libbrotlidec's one-shot
    `BrotliDecoderDecompress`. Returns the number of bytes written to dst.

    `decoded_size` is passed in as `dst_capacity` (the Parquet page's
    uncompressed size) and read back as the actual decoded byte count.

    SAFETY: BrotliDecoderDecompress reads exactly `src_size` bytes from
    `src` and writes up to `*decoded_size` bytes to `dst`. Both buffers are
    caller-owned for the duration of this synchronous call; libbrotlidec
    retains no pointer past the call. The handle is a process-lifetime
    singleton (never freed). Origins are cast to an untracked origin ONLY at
    the call site. `decoded_size_slot` is a stack local whose address is
    passed as the in/out size pointer; it is alive across the call.
    """
    var handle_ptr = _default_brotli_ffi_handle()

    # In/out size: set to output capacity, read back as decoded length.
    var decoded_size: Int = dst_capacity
    var size_slot = UnsafePointer(to=decoded_size)

    # SAFETY: see fn docstring. All four buffer/size pointers are
    # caller-owned (dst, src) or stack-local (size_slot) and outlive this
    # synchronous call; libbrotlidec copies nothing past return.
    var result = handle_ptr[].call["BrotliDecoderDecompress", Int](
        src_size,
        src.unsafe_mut_cast[True]().unsafe_origin_cast[MutUntrackedOrigin](),
        size_slot.unsafe_origin_cast[MutUntrackedOrigin](),
        dst.unsafe_origin_cast[MutUntrackedOrigin](),
    )

    if result != _BROTLI_DECODER_RESULT_SUCCESS:
        raise Error(
            "BrotliDecoderDecompress failed (result="
            + String(result)
            + ", input_len="
            + String(src_size)
            + ", output_cap="
            + String(dst_capacity)
            + ")"
        )
    return decoded_size

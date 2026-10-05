# =============================================================================
# snappy/snappy_ffi.mojo
# =============================================================================
#
# Snappy compression — FFI wrapper around the statically linked snappy C API
# (`snappy_compress` / `snappy_uncompress` / `snappy_uncompressed_length`,
# snappy-c.h), plus a dispatch to the Mojo decoder in `decompress.mojo`.
#
# # Approach: `external_call` against a statically linked library
#
# No dlopen: Mojo's `external_call["symbol", ReturnT, ArgTs...](args)` declares
# a link-time symbol reference, and the build links the snappy library into
# every binary that depends on this package, so no libsnappy is needed at run
# time.
#
# # Two decoders
#
# The C decoder is the default. The Mojo decoder (`decompress.mojo`) decodes
# the same format with the same public signature; the dispatch below selects
# it when the flag is set. Compression always uses the C library.
#
# # API
#
#   fn snappy_decompress(compressed: ByteView[_], dst: ByteView[mut=True, _])
#                       raises -> Int
#   fn snappy_compress(src: ByteView[_], dst: ByteView[mut=True, _])
#                     raises -> Int
#   fn snappy_uncompressed_length(compressed: ByteView[_]) raises -> Int
#   fn snappy_max_compressed_length(input_len: Int) -> Int
#
# # Encapsulation
#
# Public API:
#   * `snappy_*` entries accept ByteView[_] / ByteView[mut=True, _] with
#     caller-chosen origins — NOT wildcards.
# Internal FFI:
#   * Every `external_call` site casts the caller's buffer pointers to an
#     untracked origin ONLY at the call site itself. No wildcard escapes this
#     file.
#   * Every `external_call` site carries a `# SAFETY:` comment.
# =============================================================================

from std.ffi import external_call, _Global
from std.memory import alloc, OwnedPointer

from komira_buffer.byte_view import ByteView
from komira_core_ffi.posix import _env_is_set

from .decompress import (
    snappy_decompress_mojo,
    snappy_uncompressed_length_mojo,
)


# -----------------------------------------------------------------------------
# snappy status codes (the snappy-c.h contract).
# -----------------------------------------------------------------------------

comptime _SNAPPY_OK: Int32 = 0


# -----------------------------------------------------------------------------
# KOMIRA_SNAPPY_MOJO dispatch flag — MEMOIZED once per process.
#
# Reading the environment on every `snappy_decompress` /
# `snappy_uncompressed_length` call would cost a `String` heap alloc + libc
# `getenv` per Parquet page on the default path. The read is memoized into a
# process-global `_Global` slot (no env var per call, no `unsafe_from_address`)
# so the per-page hot path is a single predictable load + branch.
# -----------------------------------------------------------------------------


def _init_snappy_flag() -> OwnedPointer[Bool]:
    """`_Global` init_fn: read KOMIRA_SNAPPY_MOJO EXACTLY once per process.

    `alloc` + raw store + `OwnedPointer(unsafe_from_raw_pointer=)`.
    `_env_is_set` is non-raising, so the read is unconditional.
    """
    var raw = alloc[Bool](1)
    raw[0] = _env_is_set("KOMIRA_SNAPPY_MOJO")
    return OwnedPointer[Bool](unsafe_from_raw_pointer=raw)


comptime _SNAPPY_MOJO_FLAG = _Global[
    "komira_parquet_codec_snappy_decoder", _init_snappy_flag
]


@always_inline
def _snappy_use_mojo() raises -> Bool:
    """Process-memoized KOMIRA_SNAPPY_MOJO dispatch flag (init-once via
    `_Global`). One predictable load on the per-page hot path — NOT a String
    alloc + `getenv` per call.

    SAFETY: `get_or_create_ptr` targets KGEN-runtime-managed process-lifetime
    static storage; `MutUntrackedOrigin` is the stdlib `_Global` API's own
    return type, confined to this helper. The outer deref yields the
    process-global `OwnedPointer`; the inner deref the `Bool`.
    """
    return _SNAPPY_MOJO_FLAG.get_or_create_ptr()[][]


# -----------------------------------------------------------------------------
# Public FFI wrappers.
# -----------------------------------------------------------------------------


def snappy_max_compressed_length(input_len: Int) -> Int:
    """Maximum compressed size for Snappy.

    Snappy guarantees compressed output is at most 32 + input_len + input_len/6.
    We compute this locally (the formula of snappy's `MaxCompressedLength`)
    to avoid a link-time round trip for a pure-integer function.
    """
    return 32 + input_len + input_len // 6


def snappy_uncompressed_length(compressed: ByteView[_]) raises -> Int:
    """Read the uncompressed length from a Snappy preamble via the snappy
    C API.

    Delegates to `snappy_uncompressed_length` (snappy-c.h, over
    `snappy::GetUncompressedLength`) rather than parsing the varint preamble
    ourselves — the library's implementation is authoritative and handles
    all edge cases.

    SAFETY: the callee reads the leading varint preamble bytes from
    `compressed` and writes a single Int64 (size_t-width) into `size_buf`.
    Both buffers are caller-owned for the synchronous call; the callee
    retains no pointer past the call.
    """
    # Mojo varint preamble parse when the Mojo decoder is selected (keeps that
    # decoder free of any C dependency). Not on the hot path — callers
    # usually take the length from the Parquet page header's
    # uncompressed_page_size instead. Default (flag unset) = the C path
    # below. The flag is memoized (one predictable load, not a getenv per
    # call).
    if _snappy_use_mojo():
        return snappy_uncompressed_length_mojo(compressed)
    var input_len = compressed.len()
    if input_len == 0:
        raise Error("snappy: empty input")
    var size_buf = alloc[Int64](1)
    size_buf[0] = Int64(0)
    var src_ptr = compressed.into_span().unsafe_ptr()
    var status = external_call[
        "snappy_uncompressed_length",
        Int32,
        UnsafePointer[UInt8, MutUntrackedOrigin],
        UInt64,
        UnsafePointer[Int64, MutUntrackedOrigin],
    ](
        src_ptr.unsafe_mut_cast[True]().unsafe_origin_cast[MutUntrackedOrigin](),
        UInt64(input_len),
        size_buf.unsafe_origin_cast[MutUntrackedOrigin](),
    )
    var length = Int(size_buf[0])
    size_buf.free()
    if Int(status) != Int(_SNAPPY_OK):
        raise Error(
            "snappy_uncompressed_length failed (status="
            + String(Int(status)) + ")"
        )
    return length


def snappy_decompress(
    compressed: ByteView[_],
    dst: ByteView[mut=True, _],
) raises -> Int:
    """Decompress a raw/unframed Snappy blob into `dst` via the snappy C API
    (or the Mojo decoder, when selected).

    snappy-c.h API:
        snappy_status snappy_uncompress(const char* compressed,
                                        size_t compressed_length,
                                        char* uncompressed,
                                        size_t* uncompressed_length);

    Returns number of bytes written. Raises on malformed input or short dst.

    SAFETY: the callee reads exactly `compressed.len()` bytes from
    `compressed` and writes up to the value stored in `size_buf` to `dst`.
    Both buffers are caller-owned for the synchronous call; the callee
    retains no pointer past the call. Origins are cast to an untracked
    origin ONLY at the `external_call` site.
    """
    # When the Mojo decoder is selected, route to it (`decompress.mojo`)
    # instead of the C call: SAME public ByteView signature, SAME caller; only
    # the codec body changes. Default (flag unset) = the C decoder below. The
    # flag is memoized once per process (one predictable load on the hot
    # per-page path, not a getenv).
    if _snappy_use_mojo():
        return snappy_decompress_mojo(compressed, dst)
    var input_len = compressed.len()
    var output_cap = dst.len()
    if input_len == 0:
        raise Error("snappy: empty input")
    var size_buf = alloc[Int64](1)
    size_buf[0] = Int64(output_cap)
    var src_ptr = compressed.into_span().unsafe_ptr()
    var dst_ptr = dst.into_span().unsafe_ptr()
    var status = external_call[
        "snappy_uncompress",
        Int32,
        UnsafePointer[UInt8, MutUntrackedOrigin],
        UInt64,
        UnsafePointer[UInt8, MutUntrackedOrigin],
        UnsafePointer[Int64, MutUntrackedOrigin],
    ](
        src_ptr.unsafe_mut_cast[True]().unsafe_origin_cast[MutUntrackedOrigin](),
        UInt64(input_len),
        dst_ptr.unsafe_origin_cast[MutUntrackedOrigin](),
        size_buf.unsafe_origin_cast[MutUntrackedOrigin](),
    )
    var written = Int(size_buf[0])
    size_buf.free()
    if Int(status) != Int(_SNAPPY_OK):
        raise Error(
            "snappy_uncompress failed (status=" + String(Int(status))
            + ", input_len=" + String(input_len)
            + ", output_cap=" + String(output_cap) + ")"
        )
    return written


def snappy_compress(
    src: ByteView[_],
    dst: ByteView[mut=True, _],
) raises -> Int:
    """Compress `src` into `dst` via the snappy C API's
    `snappy_compress`.

    snappy-c.h API:
        snappy_status snappy_compress(const char* input, size_t input_length,
                                      char* compressed, size_t* compressed_length);

    Returns number of bytes written.

    SAFETY: identical contract to snappy_decompress — buffers are
    caller-owned, the callee retains no pointer past the call.
    """
    var input_len = src.len()
    var output_cap = dst.len()
    var size_buf = alloc[Int64](1)
    size_buf[0] = Int64(output_cap)
    var src_ptr = src.into_span().unsafe_ptr()
    var dst_ptr = dst.into_span().unsafe_ptr()
    var status = external_call[
        "snappy_compress",
        Int32,
        UnsafePointer[UInt8, MutUntrackedOrigin],
        UInt64,
        UnsafePointer[UInt8, MutUntrackedOrigin],
        UnsafePointer[Int64, MutUntrackedOrigin],
    ](
        src_ptr.unsafe_mut_cast[True]().unsafe_origin_cast[MutUntrackedOrigin](),
        UInt64(input_len),
        dst_ptr.unsafe_origin_cast[MutUntrackedOrigin](),
        size_buf.unsafe_origin_cast[MutUntrackedOrigin](),
    )
    var written = Int(size_buf[0])
    size_buf.free()
    if Int(status) != Int(_SNAPPY_OK):
        raise Error(
            "snappy_compress failed (status=" + String(Int(status))
            + ", input_len=" + String(input_len)
            + ", output_cap=" + String(output_cap) + ")"
        )
    return written

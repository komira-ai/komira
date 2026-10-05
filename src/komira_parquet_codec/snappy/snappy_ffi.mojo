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
# a link-time symbol reference, and the build links the snappy library
# (//third_party/snappy) into every binary that depends on this package, so no
# libsnappy is needed at run time.
#
# # Two decoders
#
# The C decoder is the default. The Mojo decoder (`decompress.mojo`) decodes
# the same format behind the same public signature; `set_snappy_decoder`
# selects it for the whole process. Compression always uses the C library.
# The selection is an explicit call, never read from the environment: a
# program that wants it configurable maps its own flag to the setter.
#
# # API
#
#   fn snappy_decompress(compressed: Span[UInt8], dst: Span[mut UInt8]) -> Int
#   fn snappy_compress(src: Span[UInt8], dst: Span[mut UInt8]) -> Int
#   fn snappy_uncompressed_length(compressed: Span[UInt8]) -> Int
#   fn snappy_max_compressed_length(input_len: Int) -> Int
#   fn set_snappy_decoder(SnappyDecoder) / snappy_decoder() -> SnappyDecoder
#
# # Encapsulation
#
# No public signature holds a raw pointer: the entries take Spans with
# caller-chosen origins. The pointers are taken from the Spans inside each
# entry and cast to an untracked origin ONLY at the `external_call` site;
# every `external_call` site carries a `# SAFETY:` comment.
# =============================================================================

from std.atomic import Atomic
from std.ffi import external_call, _Global
from std.memory import alloc, OwnedPointer

from komira_buffer.byte_view import ByteView

from .decompress import (
    snappy_decompress_mojo,
    snappy_uncompressed_length_mojo,
)


# -----------------------------------------------------------------------------
# snappy status codes (the snappy-c.h contract).
# -----------------------------------------------------------------------------

comptime _SNAPPY_OK: Int32 = 0


# -----------------------------------------------------------------------------
# Decoder selection — one process-global atomic byte.
# -----------------------------------------------------------------------------


struct SnappyDecoder(ImplicitlyCopyable, Copyable, Equatable, Writable):
    """Which decoder `snappy_decompress` uses.

    `C_LIBRARY` (the default) is the snappy C library's decoder; `MOJO` is
    the Mojo decoder in `decompress.mojo`, which decodes the same format.
    """

    var value: UInt8

    comptime C_LIBRARY = SnappyDecoder(0)
    comptime MOJO = SnappyDecoder(1)

    def __init__(out self, value: UInt8):
        self.value = value

    @always_inline
    def __eq__(self, other: SnappyDecoder) -> Bool:
        return self.value == other.value

    @always_inline
    def __ne__(self, other: SnappyDecoder) -> Bool:
        return self.value != other.value

    def write_to[W: Writer](self, mut writer: W):
        if self == SnappyDecoder.C_LIBRARY:
            writer.write("C_LIBRARY")
        elif self == SnappyDecoder.MOJO:
            writer.write("MOJO")
        else:
            writer.write("SnappyDecoder(", String(Int(self.value)), ")")


comptime _DecoderSlot = Atomic[DType.uint8]


def _init_snappy_decoder_slot() -> OwnedPointer[_DecoderSlot]:
    """`_Global` init_fn: the selection starts at `C_LIBRARY` (non-raising)."""
    var raw = alloc[_DecoderSlot](1)
    raw.unsafe_bitcast[Scalar[DType.uint8]]().unsafe_write(
        SnappyDecoder.C_LIBRARY.value
    )
    return OwnedPointer[_DecoderSlot](unsafe_from_raw_pointer=raw)


comptime _SNAPPY_DECODER = _Global[
    "komira_parquet_codec_snappy_decoder", _init_snappy_decoder_slot
]


def set_snappy_decoder(decoder: SnappyDecoder) raises:
    """Select the decoder every later `snappy_decompress` and
    `snappy_uncompressed_length` call in this process uses.

    `raises` only to propagate the stdlib `_Global.get_or_create_ptr`
    signature; it never raises at run time.
    """
    # SAFETY: `get_or_create_ptr` targets KGEN-runtime-managed process-lifetime
    # static storage; `MutUntrackedOrigin` is the stdlib `_Global` API's own
    # return type, confined to this module.
    _SNAPPY_DECODER.get_or_create_ptr()[][].store(decoder.value)


def snappy_decoder() raises -> SnappyDecoder:
    """The decoder `snappy_decompress` uses (`C_LIBRARY` until
    `set_snappy_decoder` selects another)."""
    # SAFETY: see `set_snappy_decoder`.
    return SnappyDecoder(_SNAPPY_DECODER.get_or_create_ptr()[][].load())


@always_inline
def _snappy_use_mojo() raises -> Bool:
    """One atomic byte load on the per-page path."""
    return snappy_decoder() == SnappyDecoder.MOJO


# -----------------------------------------------------------------------------
# Public entries.
# -----------------------------------------------------------------------------


def snappy_max_compressed_length(input_len: Int) -> Int:
    """Maximum compressed size for Snappy.

    Snappy guarantees compressed output is at most 32 + input_len + input_len/6.
    We compute this locally (the formula of snappy's `MaxCompressedLength`)
    to avoid a link-time round trip for a pure-integer function.
    """
    return 32 + input_len + input_len // 6


def snappy_uncompressed_length(compressed: Span[UInt8, _]) raises -> Int:
    """Read the uncompressed length from a Snappy preamble.

    With the C decoder selected this delegates to `snappy_uncompressed_length`
    (snappy-c.h, over `snappy::GetUncompressedLength`); with the Mojo decoder,
    to its own varint parse. Not on the hot path — page decoders usually take
    the length from the page header's uncompressed_page_size instead.

    SAFETY: the callee reads the leading varint preamble bytes from
    `compressed` and writes a single Int64 (size_t-width) into `size_buf`.
    Both buffers are owned here or by the caller for the synchronous call;
    the callee retains no pointer past the call.
    """
    var input_len = len(compressed)
    if input_len == 0:
        raise Error("snappy: empty input")
    if _snappy_use_mojo():
        return snappy_uncompressed_length_mojo(
            ByteView(compressed.unsafe_ptr(), input_len)
        )
    var size_buf = alloc[Int64](1)
    size_buf[0] = Int64(0)
    var status = external_call[
        "snappy_uncompressed_length",
        Int32,
        UnsafePointer[UInt8, MutUntrackedOrigin],
        UInt64,
        UnsafePointer[Int64, MutUntrackedOrigin],
    ](
        compressed.unsafe_ptr()
        .unsafe_mut_cast[True]()
        .unsafe_origin_cast[MutUntrackedOrigin](),
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


def snappy_decompress[
    dori: MutOrigin
](compressed: Span[UInt8, _], dst: Span[UInt8, dori]) raises -> Int:
    """Decompress a raw/unframed Snappy blob into `dst`; return the bytes
    written. `len(dst)` is the capacity: a blob that decodes to more is
    refused, as is a malformed one.

    The Mojo decoder, when selected, uses the room past the decoded length
    for its 16-byte fast paths: a caller that sizes `dst` at the decoded
    length + `kSlopBytes` gets them up to the end.

    snappy-c.h API:
        snappy_status snappy_uncompress(const char* compressed,
                                        size_t compressed_length,
                                        char* uncompressed,
                                        size_t* uncompressed_length);

    SAFETY: the callee reads exactly `len(compressed)` bytes from
    `compressed` and writes up to the value stored in `size_buf` (`len(dst)`)
    to `dst`. Both Spans keep their buffers alive for the synchronous call;
    the callee retains no pointer past it. Origins are cast to an untracked
    origin ONLY at the `external_call` site.
    """
    var input_len = len(compressed)
    var output_cap = len(dst)
    if input_len == 0:
        raise Error("snappy: empty input")
    if _snappy_use_mojo():
        return snappy_decompress_mojo(
            ByteView(compressed.unsafe_ptr(), input_len),
            ByteView(dst.unsafe_ptr(), output_cap),
        )
    var size_buf = alloc[Int64](1)
    size_buf[0] = Int64(output_cap)
    var status = external_call[
        "snappy_uncompress",
        Int32,
        UnsafePointer[UInt8, MutUntrackedOrigin],
        UInt64,
        UnsafePointer[UInt8, MutUntrackedOrigin],
        UnsafePointer[Int64, MutUntrackedOrigin],
    ](
        compressed.unsafe_ptr()
        .unsafe_mut_cast[True]()
        .unsafe_origin_cast[MutUntrackedOrigin](),
        UInt64(input_len),
        dst.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin](),
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


def snappy_compress[
    dori: MutOrigin
](src: Span[UInt8, _], dst: Span[UInt8, dori]) raises -> Int:
    """Compress `src` into `dst` via the snappy C API's `snappy_compress`;
    return the bytes written. `dst` must hold at least
    `snappy_max_compressed_length(len(src))` bytes (the library refuses a
    smaller one).

    snappy-c.h API:
        snappy_status snappy_compress(const char* input, size_t input_length,
                                      char* compressed, size_t* compressed_length);

    SAFETY: identical contract to snappy_decompress — the Spans keep both
    buffers alive for the synchronous call, and the callee retains no
    pointer past it.
    """
    var input_len = len(src)
    var output_cap = len(dst)
    var size_buf = alloc[Int64](1)
    size_buf[0] = Int64(output_cap)
    var status = external_call[
        "snappy_compress",
        Int32,
        UnsafePointer[UInt8, MutUntrackedOrigin],
        UInt64,
        UnsafePointer[UInt8, MutUntrackedOrigin],
        UnsafePointer[Int64, MutUntrackedOrigin],
    ](
        src.unsafe_ptr()
        .unsafe_mut_cast[True]()
        .unsafe_origin_cast[MutUntrackedOrigin](),
        UInt64(input_len),
        dst.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin](),
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

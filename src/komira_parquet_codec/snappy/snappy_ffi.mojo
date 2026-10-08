# =============================================================================
# snappy/snappy_ffi.mojo
# =============================================================================
#
# Snappy compression — the snappy C API through komira_compression's
# snappy_block (the one module of the tree that declares the snappy symbols),
# plus a dispatch to the Mojo decoder in `decompress.mojo`.
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
# `dst` is a Span with a mutable origin, `compressed` and `src` Spans; the
# full signatures are on the functions.
#
#   snappy_decompress(compressed, dst) raises -> Int
#   snappy_compress(src, dst) raises -> Int
#   snappy_uncompressed_length(compressed) raises -> Int
#   snappy_max_compressed_length(input_len: Int) -> Int
#   set_snappy_decoder(decoder: SnappyDecoder) raises
#   snappy_decoder() raises -> SnappyDecoder
#
# The C decoder path is komira_compression's `snappy_uncompress_into`, which
# gives snappy `len(dst)` as the capacity: it never writes past `dst`, the
# contract the exact-destination and fuzz tests hold both decoders to.
#
# # Encapsulation
#
# No public signature holds a raw pointer: the entries take Spans with
# caller-chosen origins. The Mojo decoder takes a ByteView built from the
# Spans here.
# =============================================================================

from std.atomic import Atomic
from std.ffi import _Global
from std.memory import alloc, OwnedPointer

from komira_buffer.byte_view import ByteView
from komira_compression.snappy_block import (
    snappy_compress_into as _c_snappy_compress_into,
    snappy_max_compressed_length as _c_snappy_max_compressed_length,
    snappy_uncompress_into as _c_snappy_uncompress_into,
    snappy_uncompressed_length as _c_snappy_uncompressed_length,
)

from .decompress import (
    _snappy_decompress_mojo,
    _snappy_uncompressed_length_mojo,
)


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
    """Maximum compressed size for Snappy: 32 + input_len + input_len / 6
    (snappy's `MaxCompressedLength`, komira_compression's
    `snappy_max_compressed_length`)."""
    return _c_snappy_max_compressed_length(input_len)


def snappy_uncompressed_length(compressed: Span[UInt8, _]) raises -> Int:
    """Read the uncompressed length from a Snappy preamble.

    With the C decoder selected this is komira_compression's
    `snappy_uncompressed_length` (snappy-c.h, over
    `snappy::GetUncompressedLength`); with the Mojo decoder, its own varint
    parse. Not on the hot path — page decoders usually take the length from
    the page header's uncompressed_page_size instead.
    """
    var input_len = len(compressed)
    if input_len == 0:
        raise Error("snappy: empty input")
    if _snappy_use_mojo():
        return _snappy_uncompressed_length_mojo(
            ByteView(compressed.unsafe_ptr(), input_len)
        )
    return _c_snappy_uncompressed_length(compressed)


def snappy_decompress[
    dori: MutOrigin
](compressed: Span[UInt8, _], dst: Span[UInt8, dori]) raises -> Int:
    """Decompress a raw/unframed Snappy blob into `dst`; return the bytes
    written. `len(dst)` is the capacity: a blob that decodes to more is
    refused, as is a malformed one, and no byte past `len(dst)` is written.

    The Mojo decoder, when selected, uses the room past the decoded length
    for its 16-byte fast paths: a caller that sizes `dst` at the decoded
    length + `kSlopBytes` gets them up to the end. The C decoder raises
    `snappy_uncompress failed (status=S, input_len=N, output_cap=C)`.
    """
    var input_len = len(compressed)
    var output_cap = len(dst)
    if input_len == 0:
        raise Error("snappy: empty input")
    if _snappy_use_mojo():
        return _snappy_decompress_mojo(
            ByteView(compressed.unsafe_ptr(), input_len),
            ByteView(dst.unsafe_ptr(), output_cap),
        )
    return _c_snappy_uncompress_into(dst, compressed)


def snappy_compress[
    dori: MutOrigin
](src: Span[UInt8, _], dst: Span[UInt8, dori]) raises -> Int:
    """Compress `src` into `dst` with the snappy C API; return the bytes
    written. `dst` must hold at least
    `snappy_max_compressed_length(len(src))` bytes (the library refuses a
    smaller one with `snappy_compress failed (status=2, ...)`).
    """
    return _c_snappy_compress_into(dst, src)

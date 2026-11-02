# =============================================================================
# test_codec_conformers.mojo
# =============================================================================
#
# The codec conformers of komira_compression.compression_codecs that the other
# test files leave out: `Uncompressed`, `Snappy`, `Zstd`, the three scaffolds
# (`Lzo`, `Brotli`, `Zlib`), the refusals of `Lz4Raw` and `Lz4Frame`, and the
# per-worker context handle `_CodecDctxHandle` over each codec that has one.
#
# For each working codec: a round trip of the empty input and of 4 KiB of
# incompressible bytes through every entry (the List, the `*_into` and the
# cached-context paths), and every refusal compared with its whole message: a
# size that is not positive, a destination too small, a corrupt or empty
# input, and a null context. The scaffolds raise their exact messages from
# both directions.
#
# What it catches: an identity codec that drops or adds a byte, a capacity
# check that lets a source past `dst_capacity`, a snappy decode that ignores
# `expected_size` or the block's own declared length, a zstd error read as
# success, a context handle that frees a null context, never creates one or
# creates a second one per call, and a message that drops the codec, the
# library's result or a size.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_compression.compression import ArrowIpcCompression
from komira_compression.compression_codecs import (
    Brotli,
    Gzip,
    Lz4Frame,
    Lz4Raw,
    Lzo,
    Snappy,
    Uncompressed,
    Zlib,
    Zstd,
    _CodecDctxHandle,
)


def _incompressible(n: Int) -> List[UInt8]:
    """`n` bytes of a 32-bit LCG's high byte: no codec here shrinks them."""
    var out = List[UInt8](capacity=n)
    var state: UInt32 = 0x9E3779B9
    for _ in range(n):
        state = state * UInt32(1103515245) + UInt32(12345)
        out.append(UInt8((state >> 24) & 0xFF))
    return out^


def _hello() -> List[UInt8]:
    return [UInt8(0x68), UInt8(0x65), UInt8(0x6C), UInt8(0x6C), UInt8(0x6F)]


def _cases() -> List[List[UInt8]]:
    """The empty input, five bytes, and 4 KiB of incompressible bytes."""
    var cases = List[List[UInt8]]()
    cases.append(List[UInt8]())
    cases.append(_hello())
    cases.append(_incompressible(4096))
    return cases^


def _assert_same(got: Span[UInt8, _], want: Span[UInt8, _], what: String) raises:
    assert_equal(len(got), len(want), what + ": length")
    for i in range(len(want)):
        assert_equal(got[i], want[i], what + ": byte " + String(i))


# A single-segment zstd frame holding one raw block of "hello" (as in
# test_codec_block_api.mojo).
comptime _ZSTD_HELLO: List[UInt8] = [
    0x28, 0xB5, 0x2F, 0xFD, 0x20, 0x05, 0x29, 0x00, 0x00,
    0x68, 0x65, 0x6C, 0x6C, 0x6F,
]


def _not_a_frame() -> List[UInt8]:
    """16 bytes with no codec's magic number."""
    return List[UInt8](length=16, fill=0x58)


# -----------------------------------------------------------------------------
# Uncompressed
# -----------------------------------------------------------------------------


def test_uncompressed_is_the_identity_through_every_entry() raises:
    _ = Uncompressed()
    var cases = _cases()
    for c in range(len(cases)):
        var data = cases[c].copy()
        var n = len(data)
        _assert_same(Span(Uncompressed.compress(Span(data))), Span(data), "compress")
        # 0 is "size unknown"; the exact size is accepted too.
        _assert_same(
            Span(Uncompressed.decompress(Span(data), 0)), Span(data), "decompress 0"
        )
        _assert_same(
            Span(Uncompressed.decompress(Span(data), n)), Span(data), "decompress n"
        )
        assert_equal(Uncompressed.compress_bound(n), n)

        var into = List[UInt8](length=n + 1, fill=UInt8(0xA5))
        assert_equal(Uncompressed.compress_into(Span(data), into.unsafe_ptr(), n), n)
        _assert_same(Span(into)[0:n], Span(data), "compress_into")
        assert_equal(into[n], UInt8(0xA5), "compress_into wrote past n")

        var back = List[UInt8](length=n + 1, fill=UInt8(0x5A))
        assert_equal(Uncompressed.decompress_into(Span(data), back.unsafe_ptr(), n), n)
        _assert_same(Span(back)[0:n], Span(data), "decompress_into")
        assert_equal(back[n], UInt8(0x5A), "decompress_into wrote past n")

        # The context is the null sentinel: freeing it is a no-op and the
        # context path is the plain copy.
        var dctx = Uncompressed.create_dctx()
        assert_equal(Int(dctx), 0)
        var viadctx = List[UInt8](length=n + 1, fill=UInt8(0x33))
        assert_equal(
            Uncompressed.decompress_into_with_dctx(
                dctx, Span(data), viadctx.unsafe_ptr(), n
            ),
            n,
        )
        _assert_same(Span(viadctx)[0:n], Span(data), "decompress_into_with_dctx")
        Uncompressed.free_dctx(dctx)


def test_uncompressed_refuses_a_size_mismatch_and_a_short_destination() raises:
    var data = _hello()
    var msg = String("")
    try:
        _ = Uncompressed.decompress(Span(data), 4)
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "Uncompressed.decompress: expected_size=4 does not match input.len()=5",
    )

    var dst = List[UInt8](length=4, fill=UInt8(0))
    msg = ""
    try:
        _ = Uncompressed.decompress_into(Span(data), dst.unsafe_ptr(), 4)
    except e:
        msg = String(e)
    assert_equal(msg, "Uncompressed.decompress_into: input.len()=5 > dst_capacity=4")

    msg = ""
    try:
        _ = Uncompressed.compress_into(Span(data), dst.unsafe_ptr(), 4)
    except e:
        msg = String(e)
    assert_equal(msg, "Uncompressed.compress_into: input.len()=5 > dst_capacity=4")


# -----------------------------------------------------------------------------
# Snappy
# -----------------------------------------------------------------------------


def test_snappy_round_trips_with_and_without_the_size() raises:
    _ = Snappy()
    var cases = _cases()
    for c in range(len(cases)):
        var data = cases[c].copy()
        var packed = Snappy.compress(Span(data))
        # The block starts with its length as a varint (one byte below 128).
        if len(data) < 128:
            assert_equal(Int(packed[0]), len(data))
        _assert_same(
            Span(Snappy.decompress(Span(packed), len(data))), Span(data), "sized"
        )
        # A size of 0 reads the length the block declares.
        _assert_same(Span(Snappy.decompress(Span(packed), 0)), Span(data), "unsized")


def test_snappy_refusals_name_the_status_and_sizes() raises:
    var msg = String("")
    try:
        _ = Snappy.decompress(Span(List[UInt8]()), 5)
    except e:
        msg = String(e)
    assert_equal(msg, "Snappy.decompress: empty input")

    # Five continuation bytes: a varint snappy cannot parse (status 1).
    var no_length = List[UInt8](length=6, fill=0xFF)
    msg = ""
    try:
        _ = Snappy.decompress(Span(no_length), 0)
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "Snappy.decompress: snappy_uncompressed_length failed (status=1,"
        " input_len=6)",
    )

    # A size below the block's declared length (status 2: buffer too small).
    var packed = Snappy.compress(Span(_incompressible(4096)))
    msg = ""
    try:
        _ = Snappy.decompress(Span(packed), 4095)
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "Snappy.decompress: snappy_uncompress failed (status=2, input_len="
        + String(len(packed))
        + ", output_cap=4095)",
    )


# -----------------------------------------------------------------------------
# Zstd
# -----------------------------------------------------------------------------


def test_zstd_round_trips_through_every_entry() raises:
    _ = Zstd[3]()
    var cases = _cases()
    var dctx = Zstd[3].create_dctx()
    for c in range(len(cases)):
        var data = cases[c].copy()
        var n = len(data)
        var packed = Zstd[3].compress(Span(data))
        # The frame magic, 28 B5 2F FD.
        assert_equal(Int(packed[0]), 0x28)
        assert_equal(Int(packed[3]), 0xFD)
        # A destination of at least one byte, also for the empty input.
        var size = max(n, 1)
        _assert_same(
            Span(Zstd[3].decompress(Span(packed), size)), Span(data), "decompress"
        )

        var bound = Zstd[3].compress_bound(n)
        assert_true(bound >= len(packed), "compress_bound below a frame")
        var into = List[UInt8](length=bound, fill=UInt8(0))
        var w = Zstd[3].compress_into(Span(data), into.unsafe_ptr(), bound)
        _assert_same(Span(into)[0:w], Span(packed), "compress_into")

        var out = List[UInt8](length=size, fill=UInt8(0))
        assert_equal(Zstd[3].decompress_into(Span(packed), out.unsafe_ptr(), size), n)
        _assert_same(Span(out)[0:n], Span(data), "decompress_into")

        var again = List[UInt8](length=size, fill=UInt8(0))
        assert_equal(
            Zstd[3].decompress_into_with_dctx(
                dctx, Span(packed), again.unsafe_ptr(), size
            ),
            n,
        )
        _assert_same(Span(again)[0:n], Span(data), "decompress_into_with_dctx")
    Zstd[3].free_dctx(dctx)
    # A null context is not freed.
    Zstd[3].free_dctx(Uncompressed.create_dctx())


def test_zstd_refuses_sizes_corrupt_frames_and_a_null_context() raises:
    var garbage = _not_a_frame()
    var dst = List[UInt8](length=16, fill=UInt8(0))
    var msg = String("")
    try:
        _ = Zstd[3].decompress(Span(garbage), 0)
    except e:
        msg = String(e)
    assert_equal(msg, "Zstd.decompress: expected_size must be > 0 (got 0)")

    # prefix_unknown (a bad magic number) is zstd error 10.
    msg = ""
    try:
        _ = Zstd[3].decompress(Span(garbage), 16)
    except e:
        msg = String(e)
    assert_equal(msg, "Zstd.decompress: ZSTD_decompress failed (result=-10, n=16)")

    msg = ""
    try:
        _ = Zstd[3].decompress_into(Span(garbage), dst.unsafe_ptr(), 0)
    except e:
        msg = String(e)
    assert_equal(msg, "Zstd.decompress_into: dst_capacity must be > 0 (got 0)")

    msg = ""
    try:
        _ = Zstd[3].decompress_into(Span(garbage), dst.unsafe_ptr(), 16)
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "Zstd.decompress_into: ZSTD_decompress failed (result=-10, n=16,"
        " dst_capacity=16)",
    )

    var hello = _hello()
    msg = ""
    try:
        _ = Zstd[3].compress_into(Span(hello), dst.unsafe_ptr(), 0)
    except e:
        msg = String(e)
    assert_equal(msg, "Zstd.compress_into: dst_capacity must be > 0 (got 0)")

    # dstSize_tooSmall is zstd error 70.
    msg = ""
    try:
        _ = Zstd[3].compress_into(Span(hello), dst.unsafe_ptr(), 1)
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "Zstd.compress_into: ZSTD_compress failed (result=-70, n=5,"
        " dst_capacity=1)",
    )

    var dctx = Zstd[3].create_dctx()
    msg = ""
    try:
        _ = Zstd[3].decompress_into_with_dctx(
            dctx, Span(garbage), dst.unsafe_ptr(), 0
        )
    except e:
        msg = String(e)
    assert_equal(
        msg, "Zstd.decompress_into_with_dctx: dst_capacity must be > 0 (got 0)"
    )

    msg = ""
    try:
        _ = Zstd[3].decompress_into_with_dctx(
            Uncompressed.create_dctx(), Span(garbage), dst.unsafe_ptr(), 16
        )
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "Zstd.decompress_into_with_dctx: null dctx (call create_dctx first)",
    )

    msg = ""
    try:
        _ = Zstd[3].decompress_into_with_dctx(
            dctx, Span(garbage), dst.unsafe_ptr(), 16
        )
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "Zstd.decompress_into_with_dctx: ZSTD_decompressDCtx failed"
        " (result=-10, n=16, dst_capacity=16)",
    )

    # The context that refused a frame still decodes a good one.
    var frame = materialize[_ZSTD_HELLO]()
    assert_equal(
        Zstd[3].decompress_into_with_dctx(
            dctx, Span(frame), dst.unsafe_ptr(), 16
        ),
        5,
    )
    _assert_same(Span(dst)[0:5], Span(hello), "after a refusal")
    Zstd[3].free_dctx(dctx)


# -----------------------------------------------------------------------------
# The scaffolds, Gzip's constructor, Lz4Raw and Lz4Frame refusals
# -----------------------------------------------------------------------------


def test_scaffold_codecs_refuse_both_directions() raises:
    _ = Lzo()
    _ = Brotli[11]()
    _ = Zlib[6]()
    var data = _hello()
    var msgs = List[String]()
    try:
        _ = Lzo.compress(Span(data))
    except e:
        msgs.append(String(e))
    try:
        _ = Lzo.decompress(Span(data), 5)
    except e:
        msgs.append(String(e))
    try:
        _ = Brotli[11].compress(Span(data))
    except e:
        msgs.append(String(e))
    try:
        _ = Brotli[11].decompress(Span(data), 5)
    except e:
        msgs.append(String(e))
    try:
        _ = Zlib[6].compress(Span(data))
    except e:
        msgs.append(String(e))
    try:
        _ = Zlib[6].decompress(Span(data), 5)
    except e:
        msgs.append(String(e))
    assert_equal(len(msgs), 6)
    assert_equal(
        msgs[0],
        "Lzo.compress: not supported. LZO is a legacy Parquet codec; re-write"
        " with Snappy or Zstd.",
    )
    assert_equal(
        msgs[1],
        "Lzo.decompress: not supported. LZO is a legacy Parquet codec;"
        " re-write with Snappy or Zstd.",
    )
    assert_equal(
        msgs[2],
        "Brotli.compress: not yet wired in Compression trait conformer"
        " (scaffold; libbrotli FFI is not wired).",
    )
    assert_equal(
        msgs[3],
        "Brotli.decompress: not yet wired in Compression trait conformer"
        " (scaffold; libbrotli FFI is not wired).",
    )
    assert_equal(
        msgs[4],
        "Zlib.compress: not yet wired in Compression trait conformer"
        " (scaffold; production uses komira_parquet.compression GZIP).",
    )
    assert_equal(
        msgs[5],
        "Zlib.decompress: not yet wired in Compression trait conformer"
        " (scaffold; production uses komira_parquet.compression GZIP).",
    )


def test_gzip_and_lz4_raw_constructors_and_lz4_raw_refusals() raises:
    _ = Gzip[6]()
    _ = Lz4Raw()
    var msg = String("")
    try:
        _ = Lz4Raw.decompress(Span(_hello()), 0)
    except e:
        msg = String(e)
    assert_equal(msg, "Lz4Raw.decompress: expected_size must be > 0 (got 0)")

    msg = ""
    try:
        _ = Lz4Raw.decompress(Span(List[UInt8]()), 5)
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "Lz4Raw.decompress: lz4_decompress_into: empty source (the shortest"
        " LZ4 block is the one-byte empty block 0x00)",
    )


def test_lz4_frame_refuses_sizes_corrupt_frames_and_a_null_context() raises:
    _ = Lz4Frame()
    var garbage = _not_a_frame()
    var dst = List[UInt8](length=16, fill=UInt8(0))
    var msg = String("")
    try:
        _ = Lz4Frame.decompress_into(Span(garbage), dst.unsafe_ptr(), 0)
    except e:
        msg = String(e)
    assert_equal(msg, "Lz4Frame.decompress_into: dst_capacity must be > 0 (got 0)")

    msg = ""
    try:
        _ = Lz4Frame.decompress_into(Span(garbage), dst.unsafe_ptr(), 16)
    except e:
        msg = String(e)
    assert_true(
        msg.startswith(
            "Lz4Frame.decompress_into: lz4_frame_decompress_into:"
            " LZ4F_decompress failed (result="
        ),
        msg,
    )

    var dctx = Lz4Frame.create_dctx()
    msg = ""
    try:
        _ = Lz4Frame.decompress_into_with_dctx(
            dctx, Span(garbage), dst.unsafe_ptr(), 0
        )
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "Lz4Frame.decompress_into_with_dctx: dst_capacity must be > 0 (got 0)",
    )
    Lz4Frame.free_dctx(dctx)

    msg = ""
    try:
        _ = Lz4Frame.decompress_into_with_dctx(
            Uncompressed.create_dctx(), Span(garbage), dst.unsafe_ptr(), 16
        )
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "Lz4Frame.decompress_into_with_dctx: null dctx (call create_dctx"
        " first)",
    )
    # A null context is not freed.
    Lz4Frame.free_dctx(Uncompressed.create_dctx())

    var hello = _hello()
    msg = ""
    try:
        _ = Lz4Frame.compress_into(Span(hello), dst.unsafe_ptr(), 0)
    except e:
        msg = String(e)
    assert_equal(msg, "Lz4Frame.compress_into: dst_capacity must be > 0 (got 0)")

    msg = ""
    try:
        _ = Lz4Frame.compress_into(Span(hello), dst.unsafe_ptr(), 1)
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "Lz4Frame.compress_into: lz4_frame_compress_into: destination holds 1"
        " bytes, below lz4_frame_compress_bound(5) = "
        + String(Lz4Frame.compress_bound(5)),
    )


# -----------------------------------------------------------------------------
# _CodecDctxHandle
# -----------------------------------------------------------------------------


def _decode_twice[
    C: ArrowIpcCompression
](mut h: _CodecDctxHandle[C], src: Span[UInt8, _], want: Span[UInt8, _]) raises:
    """Two decodes through one handle: the first creates the context when the
    handle has none, the second reuses it."""
    for round in range(2):
        var out = List[UInt8](length=len(want) + 1, fill=UInt8(0))
        assert_equal(
            h.decompress_into_with_dctx(src, out.unsafe_ptr(), len(want) + 1),
            len(want),
        )
        _assert_same(Span(out)[0 : len(want)], want, "handle round " + String(round))


def test_dctx_handle_creates_lazily_eagerly_and_frees_once() raises:
    var hello = _hello()
    var zstd_frame = materialize[_ZSTD_HELLO]()
    var lz4_frame = Lz4Frame.compress(Span(hello))

    # Lazily, on the first decode.
    var lazy = _CodecDctxHandle[Zstd[3]]()
    _decode_twice(lazy, Span(zstd_frame), Span(hello))
    var lazy_lz4 = _CodecDctxHandle[Lz4Frame]()
    _decode_twice(lazy_lz4, Span(lz4_frame), Span(hello))

    # Eagerly; `acquire` on a handle that has a context keeps it.
    var eager = _CodecDctxHandle[Zstd[3]].create()
    eager.acquire()
    _decode_twice(eager, Span(zstd_frame), Span(hello))

    # `acquire` on an empty handle creates the context, twice is once.
    var acquired = _CodecDctxHandle[Lz4Frame]()
    acquired.acquire()
    acquired.acquire()
    _decode_twice(acquired, Span(lz4_frame), Span(hello))

    # Uncompressed's context is null: its handle copies, and frees nothing.
    var plain = _CodecDctxHandle[Uncompressed].create()
    var stored = hello.copy()
    _decode_twice(plain, Span(stored), Span(hello))

    # A handle that never made a context frees nothing.
    var unused = _CodecDctxHandle[Zstd[3]]()
    _ = unused^


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

# =============================================================================
# test_codec_conformers.mojo
# =============================================================================
#
# The `Compression` / `ArrowIpcCompression` conformers of
# komira_compression.compression_codecs that no other test of this package
# calls: Snappy, Zstd, Uncompressed, the Lzo / Brotli / Zlib scaffolds, the
# nine constructors, and `_CodecDctxHandle` (the per-worker decompression
# context the Arrow IPC reader holds).
#
# Every round trip compares the decompressed bytes with the input, byte for
# byte; every refusal asserts the message of the function that refused, so a
# refusal from some other cause does not pass.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

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


def _varied(n: Int) -> List[UInt8]:
    """Deterministic data that compresses: runs plus a slowly moving byte."""
    var out = List[UInt8](capacity=n)
    for i in range(n):
        out.append(UInt8((i // 7 + (i % 13) * 5) % 251))
    return out^


def _assert_same(a: Span[UInt8, _], b: Span[UInt8, _]) raises:
    assert_equal(len(a), len(b))
    for i in range(len(a)):
        assert_equal(Int(a[i]), Int(b[i]), "byte mismatch at " + String(i))


# --- Snappy ----------------------------------------------------------------


def test_snappy_round_trip_with_exact_and_unknown_expected_size() raises:
    var data = _varied(10000)
    var packed = Snappy.compress(Span(data))
    assert_true(len(packed) > 0)
    assert_true(len(packed) < len(data), "varied data must shrink")
    _assert_same(Span(Snappy.decompress(Span(packed), len(data))), Span(data))
    # expected_size 0: the length comes from the block's own preamble.
    _assert_same(Span(Snappy.decompress(Span(packed), 0)), Span(data))


def test_snappy_empty_input_compresses_to_the_zero_length_block() raises:
    var empty = List[UInt8]()
    var packed = Snappy.compress(Span(empty))
    assert_equal(len(packed), 1)
    assert_equal(Int(packed[0]), 0)
    assert_equal(len(Snappy.decompress(Span(packed), 0)), 0)


def test_snappy_decompress_refuses_empty_input() raises:
    var empty = List[UInt8]()
    var raised = False
    try:
        _ = Snappy.decompress(Span(empty), 16)
    except e:
        raised = True
        assert_equal(String(e), "Snappy.decompress: empty input")
    assert_true(raised, "empty input must be refused")


def test_snappy_decompress_refuses_a_truncated_block() raises:
    var data = _varied(10000)
    var packed = Snappy.compress(Span(data))
    var cut = List[UInt8](capacity=len(packed) // 2)
    for i in range(len(packed) // 2):
        cut.append(packed[i])

    var raised = False
    try:
        _ = Snappy.decompress(Span(cut), len(data))
    except e:
        raised = True
        assert_true(String(e).startswith("Snappy.decompress: "), String(e))
    assert_true(raised, "a truncated block must be refused (known size)")

    raised = False
    try:
        _ = Snappy.decompress(Span(cut), 0)
    except e:
        raised = True
        assert_true(String(e).startswith("Snappy.decompress: "), String(e))
    assert_true(raised, "a truncated block must be refused (size from block)")


def test_snappy_decompress_refuses_a_preamble_that_is_not_a_length() raises:
    # Five continuation bytes: a varint longer than snappy accepts.
    var junk = List[UInt8]()
    for _ in range(6):
        junk.append(UInt8(0xFF))
    var raised = False
    try:
        _ = Snappy.decompress(Span(junk), 0)
    except e:
        raised = True
        assert_true(String(e).startswith("Snappy.decompress: "), String(e))
    assert_true(raised, "an unparsable length preamble must be refused")


# --- Zstd ------------------------------------------------------------------


def test_zstd_compress_and_decompress_round_trip() raises:
    var data = _varied(50000)
    var packed = Zstd.compress(Span(data))
    assert_true(len(packed) > 0)
    assert_true(len(packed) < len(data), "varied data must shrink")
    _assert_same(Span(Zstd.decompress(Span(packed), len(data))), Span(data))

    var small = _varied(5000)
    var packed19 = Zstd[19].compress(Span(small))
    _assert_same(
        Span(Zstd[19].decompress(Span(packed19), len(small))), Span(small)
    )


def test_zstd_decompress_refuses_zero_expected_size_and_corrupt_input() raises:
    var data = _varied(2000)
    var packed = Zstd.compress(Span(data))
    var raised = False
    try:
        _ = Zstd.decompress(Span(packed), 0)
    except e:
        raised = True
        assert_true("expected_size must be > 0" in String(e), String(e))
    assert_true(raised)

    var bad = packed.copy()
    bad[0] = UInt8(0)  # the frame magic starts 28 B5 2F FD
    raised = False
    try:
        _ = Zstd.decompress(Span(bad), len(data))
    except e:
        raised = True
        assert_true("ZSTD_decompress failed" in String(e), String(e))
    assert_true(raised, "a frame with a wrong magic must be refused")


def test_zstd_compress_bound_covers_the_worst_case() raises:
    var data = _varied(50000)
    var packed = Zstd.compress(Span(data))
    assert_true(Zstd.compress_bound(len(data)) >= len(packed))
    # ZSTD_compressBound(n) >= n for any n: incompressible data must fit.
    assert_true(Zstd.compress_bound(1000) >= 1000)
    assert_true(Zstd.compress_bound(0) > 0)


def test_zstd_compress_into_and_decompress_into_with_exact_buffers() raises:
    var data = _varied(50000)
    var expected = Zstd.compress(Span(data))

    # A destination of exactly compress_bound bytes, the size the Arrow IPC
    # writer gives it (libzstd needs the bound, not just the output length,
    # to take its one-pass path).
    var bound = Zstd.compress_bound(len(data))
    var dst = List[UInt8](length=bound, fill=UInt8(0))
    var w = Zstd.compress_into(Span(data), dst.unsafe_ptr(), bound)
    assert_equal(w, len(expected))
    _assert_same(Span(dst)[0:w], Span(expected))

    # Decompress into a buffer exactly as long as the input was.
    var out = List[UInt8](length=len(data), fill=UInt8(0xAA))
    var r = Zstd.decompress_into(Span(dst)[0:w], out.unsafe_ptr(), len(out))
    assert_equal(r, len(data))
    _assert_same(Span(out), Span(data))


def test_zstd_compress_into_refuses_a_too_small_destination() raises:
    var data = _varied(50000)
    var small = List[UInt8](length=8, fill=UInt8(0))
    var raised = False
    try:
        _ = Zstd.compress_into(Span(data), small.unsafe_ptr(), len(small))
    except e:
        raised = True
        assert_true("Zstd.compress_into: ZSTD_compress failed" in String(e), String(e))
    assert_true(raised, "an 8-byte destination cannot hold a zstd frame")

    var none = List[UInt8](length=1, fill=UInt8(0))
    raised = False
    try:
        _ = Zstd.compress_into(Span(data), none.unsafe_ptr(), 0)
    except e:
        raised = True
        assert_true("dst_capacity must be > 0" in String(e), String(e))
    assert_true(raised, "a zero capacity must be refused")


def test_zstd_decompress_into_refuses_a_too_small_destination() raises:
    var data = _varied(50000)
    var packed = Zstd.compress(Span(data))
    var small = List[UInt8](length=len(data) - 1, fill=UInt8(0))
    var raised = False
    try:
        _ = Zstd.decompress_into(Span(packed), small.unsafe_ptr(), len(small))
    except e:
        raised = True
        assert_true("Zstd.decompress_into: ZSTD_decompress failed" in String(e), String(e))
    assert_true(raised, "one byte short must be refused")

    var raised_zero = False
    try:
        _ = Zstd.decompress_into(Span(packed), small.unsafe_ptr(), 0)
    except e:
        raised_zero = True
        assert_true("dst_capacity must be > 0" in String(e), String(e))
    assert_true(raised_zero, "a zero capacity must be refused")


def test_zstd_dctx_create_decompress_twice_then_free() raises:
    var a = _varied(30000)
    var b = _varied(7000)
    var pa = Zstd.compress(Span(a))
    var pb = Zstd.compress(Span(b))

    var dctx = Zstd.create_dctx()
    assert_true(Int(dctx) != 0, "create_dctx must return a context")
    var oa = List[UInt8](length=len(a), fill=UInt8(0))
    assert_equal(
        Zstd.decompress_into_with_dctx(dctx, Span(pa), oa.unsafe_ptr(), len(oa)),
        len(a),
    )
    _assert_same(Span(oa), Span(a))
    # The same context decodes a second, different frame.
    var ob = List[UInt8](length=len(b), fill=UInt8(0))
    assert_equal(
        Zstd.decompress_into_with_dctx(dctx, Span(pb), ob.unsafe_ptr(), len(ob)),
        len(b),
    )
    _assert_same(Span(ob), Span(b))
    Zstd.free_dctx(dctx)


def test_zstd_dctx_refusals_and_null_free() raises:
    var data = _varied(5000)
    var packed = Zstd.compress(Span(data))
    var out = List[UInt8](length=len(data), fill=UInt8(0))
    var dctx = Zstd.create_dctx()

    var raised = False
    try:
        _ = Zstd.decompress_into_with_dctx(
            dctx, Span(packed), out.unsafe_ptr(), len(data) - 1
        )
    except e:
        raised = True
        assert_true("ZSTD_decompressDCtx failed" in String(e), String(e))
    assert_true(raised, "a too-small destination must be refused")

    raised = False
    try:
        _ = Zstd.decompress_into_with_dctx(dctx, Span(packed), out.unsafe_ptr(), 0)
    except e:
        raised = True
        assert_true("dst_capacity must be > 0" in String(e), String(e))
    assert_true(raised, "a zero capacity must be refused")

    # The context still decodes after refusals (reset before each use).
    assert_equal(
        Zstd.decompress_into_with_dctx(
            dctx, Span(packed), out.unsafe_ptr(), len(out)
        ),
        len(data),
    )
    _assert_same(Span(out), Span(data))

    var null_dctx = Uncompressed.create_dctx()
    raised = False
    try:
        _ = Zstd.decompress_into_with_dctx(
            null_dctx, Span(packed), out.unsafe_ptr(), len(out)
        )
    except e:
        raised = True
        assert_true("null dctx" in String(e), String(e))
    assert_true(raised, "a null context must be refused")

    Zstd.free_dctx(null_dctx)  # null-safe: returns without calling libzstd
    Zstd.free_dctx(dctx)


# --- _CodecDctxHandle ------------------------------------------------------


def test_dctx_handle_zstd_acquire_decompress_and_drop() raises:
    var data = _varied(20000)
    var packed = Zstd.compress(Span(data))
    var out = List[UInt8](length=len(data), fill=UInt8(0))

    var h = _CodecDctxHandle[Zstd[3]]()
    h.acquire()
    h.acquire()  # idempotent: the second call creates nothing
    assert_equal(
        h.decompress_into_with_dctx(Span(packed), out.unsafe_ptr(), len(out)),
        len(data),
    )
    _assert_same(Span(out), Span(data))
    # Reuse for a second frame.
    var again = List[UInt8](length=len(data), fill=UInt8(0))
    assert_equal(
        h.decompress_into_with_dctx(Span(packed), again.unsafe_ptr(), len(again)),
        len(data),
    )
    _assert_same(Span(again), Span(data))


def test_dctx_handle_zstd_create_and_lazy_first_use() raises:
    var data = _varied(3000)
    var packed = Zstd.compress(Span(data))

    var eager = _CodecDctxHandle[Zstd[3]].create()
    var out = List[UInt8](length=len(data), fill=UInt8(0))
    assert_equal(
        eager.decompress_into_with_dctx(Span(packed), out.unsafe_ptr(), len(out)),
        len(data),
    )
    _assert_same(Span(out), Span(data))

    # A default handle creates its context on the first decompress.
    var lazy = _CodecDctxHandle[Zstd[3]]()
    var out2 = List[UInt8](length=len(data), fill=UInt8(0))
    assert_equal(
        lazy.decompress_into_with_dctx(Span(packed), out2.unsafe_ptr(), len(out2)),
        len(data),
    )
    _assert_same(Span(out2), Span(data))


def test_dctx_handle_default_destroyed_unused() raises:
    # Destroying a handle that never created a context frees nothing.
    var unused = _CodecDctxHandle[Zstd[3]]()
    var unused_lz4 = _CodecDctxHandle[Lz4Frame]()
    _ = unused^
    _ = unused_lz4^


def test_dctx_handle_lz4_frame_acquire_decompress_and_drop() raises:
    var data = _varied(20000)
    var packed = Lz4Frame.compress(Span(data))
    var out = List[UInt8](length=len(data), fill=UInt8(0))

    var h = _CodecDctxHandle[Lz4Frame]()
    h.acquire()
    h.acquire()
    assert_equal(
        h.decompress_into_with_dctx(Span(packed), out.unsafe_ptr(), len(out)),
        len(data),
    )
    _assert_same(Span(out), Span(data))

    var eager = _CodecDctxHandle[Lz4Frame].create()
    var out2 = List[UInt8](length=len(data), fill=UInt8(0))
    assert_equal(
        eager.decompress_into_with_dctx(Span(packed), out2.unsafe_ptr(), len(out2)),
        len(data),
    )
    _assert_same(Span(out2), Span(data))


# --- Uncompressed ----------------------------------------------------------


def test_uncompressed_compress_and_decompress_are_the_identity() raises:
    var data = _varied(1000)
    _assert_same(Span(Uncompressed.compress(Span(data))), Span(data))
    _assert_same(Span(Uncompressed.decompress(Span(data), len(data))), Span(data))
    # expected_size 0 means "unknown".
    _assert_same(Span(Uncompressed.decompress(Span(data), 0)), Span(data))
    var empty = List[UInt8]()
    assert_equal(len(Uncompressed.compress(Span(empty))), 0)


def test_uncompressed_decompress_refuses_a_wrong_expected_size() raises:
    var data = _varied(100)
    var raised = False
    try:
        _ = Uncompressed.decompress(Span(data), 99)
    except e:
        raised = True
        assert_equal(
            String(e),
            "Uncompressed.decompress: expected_size=99 does not match"
            " input.len()=100",
        )
    assert_true(raised, "a size that is not the input length must be refused")


def test_uncompressed_into_methods_copy_and_refuse_a_small_destination() raises:
    var data = _varied(100)
    assert_equal(Uncompressed.compress_bound(100), 100)
    assert_equal(Uncompressed.compress_bound(0), 0)

    var out = List[UInt8](length=100, fill=UInt8(0))
    assert_equal(Uncompressed.compress_into(Span(data), out.unsafe_ptr(), 100), 100)
    _assert_same(Span(out), Span(data))

    var out2 = List[UInt8](length=150, fill=UInt8(0))
    assert_equal(Uncompressed.decompress_into(Span(data), out2.unsafe_ptr(), 150), 100)
    _assert_same(Span(out2)[0:100], Span(data))

    var raised = False
    try:
        _ = Uncompressed.compress_into(Span(data), out.unsafe_ptr(), 99)
    except e:
        raised = True
        assert_equal(
            String(e),
            "Uncompressed.compress_into: input.len()=100 > dst_capacity=99",
        )
    assert_true(raised, "compress_into must refuse a 99-byte destination")

    raised = False
    try:
        _ = Uncompressed.decompress_into(Span(data), out.unsafe_ptr(), 99)
    except e:
        raised = True
        assert_equal(
            String(e),
            "Uncompressed.decompress_into: input.len()=100 > dst_capacity=99",
        )
    assert_true(raised, "decompress_into must refuse a 99-byte destination")


def test_uncompressed_dctx_stubs_are_null_and_decompress_by_copy() raises:
    var data = _varied(64)
    var dctx = Uncompressed.create_dctx()
    assert_equal(Int(dctx), 0)
    var out = List[UInt8](length=64, fill=UInt8(0))
    assert_equal(
        Uncompressed.decompress_into_with_dctx(dctx, Span(data), out.unsafe_ptr(), 64),
        64,
    )
    _assert_same(Span(out), Span(data))
    Uncompressed.free_dctx(dctx)

    var h = _CodecDctxHandle[Uncompressed]()
    h.acquire()
    var out2 = List[UInt8](length=64, fill=UInt8(0))
    assert_equal(
        h.decompress_into_with_dctx(Span(data), out2.unsafe_ptr(), 64), 64
    )
    _assert_same(Span(out2), Span(data))


# --- scaffolds -------------------------------------------------------------


def test_lzo_refuses_compress_and_decompress() raises:
    var data = _varied(10)
    var msg = String(
        "not supported. LZO is a legacy Parquet codec; re-write with Snappy"
        " or Zstd."
    )
    var raised = False
    try:
        _ = Lzo.compress(Span(data))
    except e:
        raised = True
        assert_equal(String(e), "Lzo.compress: " + msg)
    assert_true(raised)
    raised = False
    try:
        _ = Lzo.decompress(Span(data), 10)
    except e:
        raised = True
        assert_equal(String(e), "Lzo.decompress: " + msg)
    assert_true(raised)


def test_brotli_refuses_compress_and_decompress() raises:
    var data = _varied(10)
    var msg = String(
        "not yet wired in Compression trait conformer (scaffold; libbrotli"
        " FFI is not wired)."
    )
    var raised = False
    try:
        _ = Brotli.compress(Span(data))
    except e:
        raised = True
        assert_equal(String(e), "Brotli.compress: " + msg)
    assert_true(raised)
    raised = False
    try:
        _ = Brotli.decompress(Span(data), 10)
    except e:
        raised = True
        assert_equal(String(e), "Brotli.decompress: " + msg)
    assert_true(raised)


def test_zlib_refuses_compress_and_decompress() raises:
    var data = _varied(10)
    var msg = String(
        "not yet wired in Compression trait conformer (scaffold; production"
        " uses komira_parquet.compression GZIP)."
    )
    var raised = False
    try:
        _ = Zlib.compress(Span(data))
    except e:
        raised = True
        assert_equal(String(e), "Zlib.compress: " + msg)
    assert_true(raised)
    raised = False
    try:
        _ = Zlib.decompress(Span(data), 10)
    except e:
        raised = True
        assert_equal(String(e), "Zlib.decompress: " + msg)
    assert_true(raised)


# --- constructors ----------------------------------------------------------


def test_the_nine_constructors_build_each_codec_with_its_parquet_id() raises:
    _ = Uncompressed()
    _ = Snappy()
    _ = Gzip()
    _ = Lzo()
    _ = Brotli()
    _ = Zstd()
    _ = Lz4Raw()
    _ = Lz4Frame()
    _ = Zlib()
    assert_equal(Int(Uncompressed.PARQUET_CODEC_ID), 0)
    assert_equal(Int(Snappy.PARQUET_CODEC_ID), 1)
    assert_equal(Int(Gzip.PARQUET_CODEC_ID), 2)
    assert_equal(Int(Lzo.PARQUET_CODEC_ID), 3)
    assert_equal(Int(Brotli.PARQUET_CODEC_ID), 4)
    assert_equal(Int(Zstd.PARQUET_CODEC_ID), 6)
    assert_equal(Int(Lz4Raw.PARQUET_CODEC_ID), 7)
    assert_equal(Int(Zlib.PARQUET_CODEC_ID), 8)
    assert_equal(String(Zstd.NAME), "zstd")
    assert_equal(String(Snappy.NAME), "snappy")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

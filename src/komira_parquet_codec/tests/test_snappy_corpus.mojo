# =============================================================================
# test_snappy_corpus.mojo
# =============================================================================
#
# The Snappy correctness corpus of google/snappy (its testdata/ files, the
# ones snappy_unittest round-trips), staged at corpus/ from the archive
# //third_party/snappy pins by sha256. For each file:
#
#   (a) C-library-encoded -> C-library-decoded == the file, and
#   (b) C-library-encoded -> Mojo-decoded == the file, both into a buffer of
#       the exact size and into one with kSlopBytes of room.
#
# And the three corrupt blobs of the same corpus (baddata1..3.snappy), which
# snappy_unittest requires `Uncompress` to refuse: both decoders must refuse
# each one.
#
# The test this one replaces also decoded blobs a different snappy build had
# encoded. That arm is dropped: its blobs were generated and committed, not
# published by the snappy project, and the encoder that wrote them is the
# same snappy release linked here, so (a) covers what it did.
# =============================================================================

from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_true

from komira_parquet_codec.snappy import (
    SnappyDecoder,
    kSlopBytes,
    set_snappy_decoder,
    snappy_compress,
    snappy_decompress,
    snappy_max_compressed_length,
)


def _read(name: String) raises -> List[UInt8]:
    return Path(String("corpus/") + name).read_bytes()


def _filled(n: Int, b: UInt8) -> List[UInt8]:
    var out = List[UInt8](capacity=n)
    for _ in range(n):
        out.append(b)
    return out^


def _decode_with(
    decoder: SnappyDecoder, blob: Span[UInt8, _], cap: Int
) raises -> List[UInt8]:
    var out = _filled(cap, 0)
    var got = List[UInt8]()
    set_snappy_decoder(decoder)
    try:
        var n = snappy_decompress(blob, Span(out))
        for i in range(n):
            got.append(out[i])
    except e:
        set_snappy_decoder(SnappyDecoder.C_LIBRARY)
        raise e^
    set_snappy_decoder(SnappyDecoder.C_LIBRARY)
    return got^


def _check_one_corpus_file(name: String) raises:
    var raw = _read(name)
    assert_true(len(raw) > 0, name + ": staged and not empty")

    var comp_buf = _filled(snappy_max_compressed_length(len(raw)), 0)
    var comp_len = snappy_compress(Span(raw), Span(comp_buf))
    var blob = Span(comp_buf)[0:comp_len]

    for d in range(2):
        var decoder = SnappyDecoder.MOJO if d == 1 else SnappyDecoder.C_LIBRARY
        for slop in range(2):
            var cap = len(raw) + (kSlopBytes if slop == 1 else 0)
            var out = _decode_with(decoder, blob, cap)
            var where = name + " " + String(decoder) + (
                " +slop" if slop == 1 else " exact"
            )
            assert_equal(len(out), len(raw), where + ": length")
            for i in range(len(raw)):
                if out[i] != raw[i]:
                    raise Error(where + ": byte mismatch at offset " + String(i))
    print("  PASS:", name, "(raw", len(raw), "bytes, encoded", comp_len, "bytes)")


def _check_refused(name: String) raises:
    var blob = _read(name)
    for d in range(2):
        var decoder = SnappyDecoder.MOJO if d == 1 else SnappyDecoder.C_LIBRARY
        var raised = False
        var msg = String("")
        try:
            _ = _decode_with(decoder, Span(blob), 1 << 20)
        except e:
            raised = True
            msg = String(e)
        assert_true(raised, name + ": " + String(decoder) + " must refuse it")
        # The refusal names the decoder that made it, which proves the
        # selection reached `snappy_decompress`: the C path reports the C
        # call, the Mojo decoder its own "snappy: ..." diagnosis.
        var from_c = msg.find("snappy_uncompress failed") >= 0
        assert_equal(from_c, d == 0, name + ": refused by the wrong decoder: " + msg)


def test_alice29() raises:
    _check_one_corpus_file("alice29.txt")


def test_asyoulik() raises:
    _check_one_corpus_file("asyoulik.txt")


def test_fireworks_jpeg() raises:
    _check_one_corpus_file("fireworks.jpeg")


def test_geo_protodata() raises:
    _check_one_corpus_file("geo.protodata")


def test_html() raises:
    _check_one_corpus_file("html")


def test_html_x_4() raises:
    _check_one_corpus_file("html_x_4")


def test_kppkn_gtb() raises:
    _check_one_corpus_file("kppkn.gtb")


def test_lcet10() raises:
    _check_one_corpus_file("lcet10.txt")


def test_paper_100k_pdf() raises:
    _check_one_corpus_file("paper-100k.pdf")


def test_plrabn12() raises:
    _check_one_corpus_file("plrabn12.txt")


def test_urls_10k() raises:
    _check_one_corpus_file("urls.10K")


def test_baddata_refused() raises:
    _check_refused("baddata1.snappy")
    _check_refused("baddata2.snappy")
    _check_refused("baddata3.snappy")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

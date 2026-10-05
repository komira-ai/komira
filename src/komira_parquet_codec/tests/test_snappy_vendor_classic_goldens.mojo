# =============================================================================
# test_snappy_vendor_classic_goldens.mojo
# =============================================================================
#
# Decompress byte-equivalence oracle over the Snappy correctness corpus
# (google/snappy's testdata files), in two directions:
#
#   (a) golden-encoded -> decoded == original corpus file (a payload another
#       snappy build compressed still decodes correctly)
#   (b) encoded -> decoded == original corpus file (the codec's own round
#       trip)
# =============================================================================

from std.io import FileHandle
from std.memory import alloc
from std.testing import TestSuite, assert_equal

from komira_buffer.byte_view import ByteView
from komira_parquet_codec.snappy import (
    snappy_compress,
    snappy_decompress,
    snappy_max_compressed_length,
)


def _read_file_len(path: String) raises -> Int:
    var f = FileHandle(path, "r")
    _ = f.seek(0, 2)  # SEEK_END
    var file_size = Int(f.seek(0, 1))  # SEEK_CUR == tell
    f.close()
    return file_size


def _read_file_into_alloc(
    path: String, size: Int
) raises -> UnsafePointer[UInt8, MutUntrackedOrigin]:
    """Read the full contents of `path` (exactly `size` bytes) into a
    freshly `alloc`'d buffer. Caller owns the returned pointer (`.free()`
    it when done)."""
    var f = FileHandle(path, "r")
    var raw = f.read_bytes(size)
    f.close()
    var buf = alloc[UInt8](size)
    for i in range(size):
        buf[i] = raw[i]
    return buf


def _check_one_corpus_file(name: String) raises:
    """Byte-equivalence oracle for one corpus file: verifies (a) OLD-encoded
    goldens decode correctly via the NEW codec, and (b) the NEW codec's own
    compress->decompress round-trip is exact.
    """
    var raw_path = "tests/fixtures/snappy_corpus/" + name
    var golden_path = (
        "tests/fixtures/snappy_corpus/golden_old_encoded/" + name + ".snappy"
    )

    var raw_len = _read_file_len(raw_path)
    var raw_ptr = _read_file_into_alloc(raw_path, raw_len)

    var golden_len = _read_file_len(golden_path)
    var golden_ptr = _read_file_into_alloc(golden_path, golden_len)

    # -------------------------------------------------------------------
    # (a) OLD-encoded golden -> NEW decoder -> compare to original raw file.
    # -------------------------------------------------------------------
    var dst_cap = raw_len + 64  # slop margin, mirrors kSlopBytes convention
    var dst_buf = alloc[UInt8](dst_cap)
    var written = snappy_decompress(
        ByteView[MutUntrackedOrigin](golden_ptr, golden_len),
        ByteView[MutUntrackedOrigin](dst_buf, dst_cap),
    )
    if written != raw_len:
        raise Error(
            name
            + ": OLD-encoded->NEW-decoded LENGTH mismatch: got "
            + String(written)
            + " want "
            + String(raw_len)
        )
    var mismatch_a = -1
    for i in range(raw_len):
        if dst_buf[i] != raw_ptr[i]:
            mismatch_a = i
            break
    if mismatch_a != -1:
        raise Error(
            name
            + ": OLD-encoded->NEW-decoded BYTE mismatch at offset "
            + String(mismatch_a)
        )
    dst_buf.free()

    # -------------------------------------------------------------------
    # (b) NEW encoder -> NEW decoder round-trip self-check.
    # -------------------------------------------------------------------
    var comp_cap = snappy_max_compressed_length(raw_len)
    var comp_buf = alloc[UInt8](comp_cap)
    var comp_written = snappy_compress(
        ByteView[MutUntrackedOrigin](raw_ptr, raw_len),
        ByteView[MutUntrackedOrigin](comp_buf, comp_cap),
    )

    var rt_buf = alloc[UInt8](dst_cap)
    var rt_written = snappy_decompress(
        ByteView[MutUntrackedOrigin](comp_buf, comp_written),
        ByteView[MutUntrackedOrigin](rt_buf, dst_cap),
    )
    if rt_written != raw_len:
        raise Error(
            name
            + ": NEW round-trip LENGTH mismatch: got "
            + String(rt_written)
            + " want "
            + String(raw_len)
        )
    var mismatch_b = -1
    for i in range(raw_len):
        if rt_buf[i] != raw_ptr[i]:
            mismatch_b = i
            break
    if mismatch_b != -1:
        raise Error(
            name
            + ": NEW round-trip BYTE mismatch at offset "
            + String(mismatch_b)
        )

    comp_buf.free()
    rt_buf.free()
    raw_ptr.free()
    golden_ptr.free()

    print(
        "  PASS:", name, "(raw", raw_len, "bytes, old-encoded", golden_len,
        "bytes, new-encoded", comp_written, "bytes)"
    )


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


# ---------------------------------------------------------------------------
# TestSuite registration
# ---------------------------------------------------------------------------


def main() raises:
    var suite = TestSuite()
    suite.test[test_alice29]()
    suite.test[test_asyoulik]()
    suite.test[test_fireworks_jpeg]()
    suite.test[test_geo_protodata]()
    suite.test[test_html]()
    suite.test[test_html_x_4]()
    suite.test[test_kppkn_gtb]()
    suite.test[test_lcet10]()
    suite.test[test_paper_100k_pdf]()
    suite.test[test_plrabn12]()
    suite.test[test_urls_10k]()
    suite^.run()

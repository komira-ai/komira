# =============================================================================
# ParquetFileReader over LocalFs (the mmap-backed arm) and
# read_parquet_preamble.
#
# Files are written into the runner's TEST_TMPDIR: "PAR1", a data region of
# known bytes, a footer, its 4-byte little-endian length, "PAR1". The footer
# bytes are opaque here (the reader stores them; metadata_parser decodes
# them), so the tests compare them byte for byte.
#
# What each test proves:
#   * the preamble is sliced out of one tail read when the window covers the
#     footer, and read again exactly when it does not; a file too small, a
#     bad trailing magic and a metadata length of 0 or past the file are
#     refused;
#   * read_bytes returns the file's bytes from the mapping and refuses a
#     range outside the file, including a length whose sum with the offset
#     wraps Int (the check compared `offset + length` and passed it);
#   * a metadata-only reader has no mapping and says so; a footer-only
#     reader has no bytes; a clone shares the mapping (and a reader adopting
#     a caller's mapping uses it) instead of mapping again;
#   * validate_magic checks both ends.
# =============================================================================

from std.memory import ArcPointer
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_runtime_paths import test_tmpdir
from komira_fs.local_fs import LocalFs
from komira_async.ops.waker_sink import NoopSink
from komira_buffer.mmap_region import ADVICE_NOT_ISSUED, MmapRegion
from komira_parquet.file_reader import (
    MIN_FILE_SIZE,
    _ParquetFileReaderImpl,
    ParquetFilePreamble,
    ParquetFileReader,
    read_parquet_preamble,
)

comptime _Fs = LocalFs[NoopSink]
comptime _DATA = 100


def _footer(n: Int) -> List[UInt8]:
    var out = List[UInt8](capacity=n)
    for i in range(n):
        out.append(UInt8((i * 7 + 3) % 256))
    return out^


def _file(footer: List[UInt8], footer_len_field: Int = -1) -> List[UInt8]:
    var out: List[UInt8] = [0x50, 0x41, 0x52, 0x31]
    for i in range(_DATA):
        out.append(UInt8(i % 251))
    for i in range(len(footer)):
        out.append(footer[i])
    var n = len(footer) if footer_len_field < 0 else footer_len_field
    for k in range(4):
        out.append(UInt8((n >> (8 * k)) & 0xFF))
    out.append(0x50)
    out.append(0x41)
    out.append(0x52)
    out.append(0x31)
    return out^


def _write(name: String, data: List[UInt8]) raises -> String:
    var path = test_tmpdir() + "/" + name
    var fh = open(path, "w")
    fh.write_bytes(Span(data))
    fh.close()
    return path


def _byte(reader: ParquetFileReader[_Fs], offset: Int) raises -> Int:
    var buf = reader.read_bytes(offset, 1)
    return Int(buf.view_range_ro(0, 1).into_span()[0])


def _raises(path: String, needle: String) -> Bool:
    try:
        _ = ParquetFileReader[_Fs].open(path)
    except e:
        return String(e).find(needle) >= 0
    return False


def test_open_reads_the_preamble_and_the_data() raises:
    var footer = _footer(40)
    var path = _write("basic.parquet", _file(footer))
    var r = ParquetFileReader[_Fs].open(path)
    assert_equal(r.file_path, path)
    assert_equal(r.file_size, 4 + _DATA + 40 + 8)
    assert_equal(r.metadata_length, 40)
    assert_equal(r.metadata_offset(), 4 + _DATA)
    assert_equal(r.data_region_size(), _DATA)
    assert_equal(r._impl.metadata_offset(), 4 + _DATA)
    assert_equal(r._impl.data_region_size(), _DATA)
    var md = r.metadata_bytes.view_range_ro(0, 40).into_span()
    for i in range(40):
        assert_equal(md[i], footer[i])
    assert_equal(_byte(r, 4), 0)
    assert_equal(_byte(r, 4 + 77), 77)
    var chunk = r.read_bytes(4 + 10, 20)
    assert_equal(chunk.len(), 20)
    assert_equal(Int(chunk.view_range_ro(19, 1).into_span()[0]), 29)
    assert_equal(r.read_bytes(0, 0).len(), 0)
    r.validate_magic()
    assert_equal(r.mmap_share_count(), 1)
    assert_equal(r.advise_prefetch(4, 16), 0)
    assert_equal(r.advise_prefetch(r.file_size + 10, 16), ADVICE_NOT_ISSUED)


def test_the_impl_opens_on_its_own() raises:
    var path = _write("impl.parquet", _file(_footer(12)))
    var impl = _ParquetFileReaderImpl[_Fs].open(_Fs.new(), path)
    assert_equal(impl.metadata_length, 12)
    assert_equal(impl.mmap_share_count(), 1)
    assert_equal(Int(impl.read_bytes(4 + 3, 1).view_range_ro(0, 1).into_span()[0]), 3)


def test_read_bytes_refuses_ranges_outside_the_file() raises:
    var path = _write("bounds.parquet", _file(_footer(16)))
    var r = ParquetFileReader[_Fs].open(path)
    var size = r.file_size
    _ = r.read_bytes(size - 1, 1)
    _ = r.read_bytes(size, 0)
    var offsets: List[Int] = [-1, 0, size - 1, size + 1, 4]
    var lengths: List[Int] = [1, -1, 2, 0, Int.MAX - 2]
    for i in range(len(offsets)):
        var raised = False
        try:
            _ = r.read_bytes(offsets[i], lengths[i])
        except e:
            raised = String(e).find("read out of bounds") >= 0
        assert_true(raised, "offset " + String(offsets[i]) + " length " + String(lengths[i]))


def test_preamble_hit_and_miss_read_the_same_footer() raises:
    var footer = _footer(300)
    var path = _write("window.parquet", _file(footer))
    var fs = _Fs.new()
    var hit = read_parquet_preamble[_Fs](fs, path)
    # A 64-byte window holds the trailer but not the 300-byte footer: the
    # footer is read again, exactly.
    var miss = read_parquet_preamble[_Fs](fs, path, window=64)
    assert_equal(hit.file_size, miss.file_size)
    assert_equal(hit.metadata_length, 300)
    assert_equal(miss.metadata_length, 300)
    assert_equal(miss.metadata_offset(), 4 + _DATA)
    var a = hit.metadata_bytes.view_range_ro(0, 300).into_span()
    var b = miss.metadata_bytes.view_range_ro(0, 300).into_span()
    for i in range(300):
        assert_equal(a[i], footer[i])
        assert_equal(b[i], footer[i])
    var shared = miss.share()
    assert_equal(shared.metadata_length, 300)
    assert_equal(shared.metadata_bytes.len(), 300)


def test_preamble_refusals() raises:
    var tiny: List[UInt8] = [0x50, 0x41, 0x52, 0x31, 0, 0, 0, 0, 0x50, 0x41, 0x52]
    assert_equal(len(tiny), MIN_FILE_SIZE - 1)
    assert_true(_raises(_write("tiny.parquet", tiny), "file too small"))
    var bad_magic = _file(_footer(8))
    bad_magic[len(bad_magic) - 1] = 0x32
    assert_true(_raises(_write("magic.parquet", bad_magic), "missing trailing PAR1"))
    var zero = _file(_footer(8), footer_len_field=0)
    assert_true(_raises(_write("zero.parquet", zero), "invalid metadata length 0"))
    var too_long = _file(_footer(8), footer_len_field=1 << 20)
    assert_true(_raises(_write("long.parquet", too_long), "invalid metadata length"))
    # Each of the other three magic bytes wrong on its own.
    var magic_bytes: List[Int] = [4, 3, 2]
    for k in range(3):
        var bad = _file(_footer(8))
        bad[len(bad) - magic_bytes[k]] = 0x00
        assert_true(
            _raises(_write("magic" + String(k) + ".parquet", bad), "missing trailing PAR1")
        )


def test_validate_magic_checks_both_ends() raises:
    var lead = _file(_footer(8))
    lead[1] = 0x00
    var r = ParquetFileReader[_Fs].open(_write("lead.parquet", lead))
    var raised = False
    try:
        r.validate_magic()
    except e:
        raised = String(e).find("leading PAR1") >= 0
    assert_true(raised)
    # A preamble that places the end of the file 4 bytes early: the bytes it
    # calls the trailer are not "PAR1".
    var path = _write("trail.parquet", _file(_footer(8)))
    var fs = _Fs.new()
    var pre = read_parquet_preamble[_Fs](fs, path)
    var short = ParquetFilePreamble(pre.file_size - 4, pre.metadata_length, pre.metadata_bytes.share())
    var r2 = ParquetFileReader[_Fs].open_with_preamble[_Fs](_Fs.new(), path, short^)
    raised = False
    try:
        r2.validate_magic()
    except e:
        raised = String(e).find("trailing PAR1") >= 0
    assert_true(raised)


def test_metadata_only_reader_has_no_mapping() raises:
    var footer = _footer(24)
    var path = _write("meta_only.parquet", _file(footer))
    var r = ParquetFileReader[_Fs].open_metadata_only(path)
    assert_equal(r.metadata_length, 24)
    assert_equal(Int(r.metadata_bytes.view_range_ro(23, 1).into_span()[0]), Int(footer[23]))
    assert_equal(r.mmap_share_count(), 0)
    assert_equal(r.advise_prefetch(0, 4), ADVICE_NOT_ISSUED)
    var raised = False
    try:
        _ = r.read_bytes(0, 4)
    except e:
        raised = String(e).find("METADATA-ONLY") >= 0
    assert_true(raised)
    var clone = r.clone_sharing_mmap()
    assert_equal(clone.mmap_share_count(), 0)
    assert_equal(clone.metadata_length, 24)


def test_clones_and_adopted_mappings_share_one_mapping() raises:
    var path = _write("share.parquet", _file(_footer(16)))
    var r = ParquetFileReader[_Fs].open(path)
    var c1 = r.clone_sharing_mmap()
    var c2 = c1.clone_sharing_mmap()
    assert_equal(r.mmap_share_count(), 3)
    assert_equal(c1.mmap_share_count(), 3)
    assert_equal(c2.mmap_share_count(), 3)
    assert_equal(_byte(c2, 4 + 5), 5)
    # Each reader is used last here, so all three live through the counts.
    assert_equal(c2.file_size + c1.file_size, 2 * r.file_size)
    var region = MmapRegion.open_readonly(path, advise_whole_file=False)
    var arc = ArcPointer[MmapRegion](region^)
    var fs = _Fs.new()
    var pre = read_parquet_preamble[_Fs](fs, path)
    var adopted = ParquetFileReader[_Fs].open_with_preamble[_Fs](
        _Fs.new(), path, pre^, Optional[ArcPointer[MmapRegion]](ArcPointer[MmapRegion](copy=arc))
    )
    # The caller's share and the reader's: one mapping, two handles.
    assert_equal(adopted.mmap_share_count(), 2)
    assert_equal(Int(arc.count()), 2)
    assert_equal(_byte(adopted, 4 + 9), 9)


def test_open_with_fs_ranges_and_footer_only() raises:
    var path = _write("fs.parquet", _file(_footer(16)))
    var r = ParquetFileReader[_Fs].open_with_fs[_Fs](_Fs.new(), path)
    assert_equal(r.metadata_length, 16)
    var ranges = List[Tuple[Int64, Int64]]()
    ranges.append((Int64(4), Int64(3)))
    ranges.append((Int64(4 + 50), Int64(2)))
    var bufs = r.read_ranges_prefetched(ranges)
    assert_equal(bufs.len(), 2)
    assert_equal(Int(bufs[1].view_range_ro(1, 1).into_span()[0]), 51)
    var placeholder = ParquetFileReader[_Fs].open_footer_only[_Fs](_Fs.new(), path)
    assert_equal(placeholder.file_size, 0)
    assert_equal(placeholder.metadata_length, 0)
    assert_equal(placeholder.mmap_share_count(), 0)
    var raised = False
    try:
        _ = placeholder.read_bytes(0, 1)
    except:
        raised = True
    assert_true(raised)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

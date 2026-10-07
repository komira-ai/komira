# =============================================================================
# ParquetFileReader over a FileSystem that is not mmap-backed.
#
# `_MemFs` holds one file in memory and answers the FileSystem trait the way
# an object store does: `IS_MMAP_BACKED` is False, every read is an owning
# copy, and the footer comes from a tail read. Its `mode` makes it misbehave
# on purpose, to reach the preamble's refusals that a well-behaved file
# system cannot: a tail region shorter than the 8-byte trailer, and an exact
# follow-up read that does not cover the footer, either because it starts
# after the footer or because it ends before the footer does.
#
# What each test proves: the reader takes the `fs.read_at` arm for data (no
# mapping, no advice), clones keep their own file system, the fan-out read
# returns the ranges in order, and the preamble refuses what it must.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_collections.slab import Slab
from komira_fs.file_system import FileSystem, WriteMode
from komira_fs.footer_region import FOOTER_SPECULATIVE_WINDOW, FooterRegion
from komira_fs.shallow_dir_entry import ShallowDirEntry
from komira_parquet.file_reader import ParquetFileReader, read_parquet_preamble

comptime _MODE_OK = 0
comptime _MODE_SHORT_REGION = 1
comptime _MODE_TRAILER_ONLY = 2
comptime _MODE_EXACT_ENDS_SHORT = 3


struct _Handle(Movable, Deinitable):
    var id: Int

    def __init__(out self, id: Int):
        self.id = id


struct _MemFs(FileSystem, Movable, Deinitable):
    comptime File = _Handle
    comptime WriteFile = _Handle
    comptime IS_MMAP_BACKED: Bool = False

    var data: List[UInt8]
    var mode: Int

    def __init__(out self, var data: List[UInt8], mode: Int = _MODE_OK):
        self.data = data^
        self.mode = mode

    def clone(self) -> Self:
        return Self(self.data.copy(), self.mode)

    def list(self, prefix: String) raises -> List[String]:
        raise Error("_MemFs.list: unused")

    def open(self, path: String) raises -> Self.File:
        return _Handle(1)

    def _copy(self, offset: Int, length: Int) -> SharedAlignedBuffer[HeapRegion]:
        var part = List[UInt8](capacity=length)
        for i in range(length):
            part.append(self.data[offset + i])
        var buf = OwnedAlignedBuffer(max(length, 1))
        buf.copy_from_bytes_list(part)
        return SharedAlignedBuffer.from_owned(buf^)

    def read_at(
        self, mut file: Self.File, offset: Int64, length: Int64,
    ) raises -> SharedAlignedBuffer[HeapRegion]:
        return self._copy(Int(offset), Int(length))

    def read_ranges_prefetched(
        self, mut file: Self.File, ranges: List[Tuple[Int64, Int64]],
    ) raises -> Slab[SharedAlignedBuffer[HeapRegion]]:
        var out = Slab[SharedAlignedBuffer[HeapRegion]]()
        for i in range(len(ranges)):
            out.append(self._copy(Int(ranges[i][0]), Int(ranges[i][1])))
        return out^

    def prefetch_depth(self) -> Int:
        return 1

    def supports_random_read(self) -> Bool:
        return True

    def read_footer(self, path: String, window: Int) raises -> FooterRegion:
        var size = len(self.data)
        var w = min(window, size)
        if self.mode == _MODE_SHORT_REGION:
            w = 4
        elif self.mode == _MODE_TRAILER_ONLY:
            w = 8
        # _MODE_EXACT_ENDS_SHORT: a read wider than the 16-byte speculative
        # window the test asks for (the exact follow-up) starts where it
        # should but stops 9 bytes short of the end of the file.
        var end = size
        if self.mode == _MODE_EXACT_ENDS_SHORT and w > 16:
            end = size - 9
        var bytes = List[UInt8](capacity=w)
        for i in range(size - w, end):
            bytes.append(self.data[i])
        return FooterRegion(bytes^, size - w, size)

    def is_dir(self, path: String) raises -> Bool:
        return False

    def list_dir_shallow(self, dir: String) raises -> List[ShallowDirEntry]:
        raise Error("_MemFs.list_dir_shallow: unused")

    def file_size(self, path: String) raises -> Int:
        return len(self.data)

    def open_write(self, path: String, mode: WriteMode) raises -> Self.WriteFile:
        raise Error("_MemFs.open_write: unused")

    def write_at(self, mut file: Self.WriteFile, data: Span[UInt8, _]) raises -> Int64:
        raise Error("_MemFs.write_at: unused")

    def pwrite_at(
        self, file: Self.WriteFile, offset: Int64, data: Span[UInt8, _],
    ) raises -> Int64:
        raise Error("_MemFs.pwrite_at: unused")

    def close_write(self, var file: Self.WriteFile) raises -> None:
        raise Error("_MemFs.close_write: unused")


def _file(footer_len: Int) -> List[UInt8]:
    var out: List[UInt8] = [0x50, 0x41, 0x52, 0x31]
    for i in range(64):
        out.append(UInt8(i + 10))
    for i in range(footer_len):
        out.append(UInt8(200 + i % 50))
    for k in range(4):
        out.append(UInt8((footer_len >> (8 * k)) & 0xFF))
    out.append(0x50)
    out.append(0x41)
    out.append(0x52)
    out.append(0x31)
    return out^


def _at(buf: SharedAlignedBuffer[HeapRegion], i: Int) -> Int:
    return Int(buf.view_range_ro(i, 1).into_span()[0])


def test_reads_go_through_read_at() raises:
    var r = ParquetFileReader[_MemFs].open_with_fs[_MemFs](_MemFs(_file(20)), "mem://f")
    assert_equal(r.file_size, 4 + 64 + 20 + 8)
    assert_equal(r.metadata_length, 20)
    assert_equal(_at(r.metadata_bytes, 0), 200)
    var chunk = r.read_bytes(4, 10)
    assert_equal(chunk.len(), 10)
    assert_equal(_at(chunk, 9), 19)
    assert_true(chunk.is_owned())
    assert_equal(r.read_bytes(4, 0).len(), 0)
    assert_equal(r.advise_prefetch(4, 10), 0)
    assert_equal(r.mmap_share_count(), 0)
    r.validate_magic()


def test_clone_and_fan_out_read() raises:
    var r = ParquetFileReader[_MemFs].open_with_fs[_MemFs](_MemFs(_file(20)), "mem://f")
    var c = r.clone_sharing_mmap()
    assert_equal(c.mmap_share_count(), 0)
    assert_equal(_at(c.read_bytes(4 + 63, 1), 0), 73)
    var ranges = List[Tuple[Int64, Int64]]()
    ranges.append((Int64(4 + 30), Int64(2)))
    ranges.append((Int64(4), Int64(1)))
    var bufs = c.read_ranges_prefetched(ranges)
    assert_equal(bufs.len(), 2)
    assert_equal(_at(bufs[0], 1), 41)
    assert_equal(_at(bufs[1], 0), 10)


def test_preamble_miss_through_the_object_store() raises:
    var fs = _MemFs(_file(100))
    var pre = read_parquet_preamble[_MemFs](fs, "mem://f", window=16)
    assert_equal(pre.metadata_length, 100)
    assert_equal(_at(pre.metadata_bytes, 99), 200 + 99 % 50)
    var r = ParquetFileReader[_MemFs].open_with_preamble[_MemFs](fs.clone(), "mem://f", pre^)
    assert_equal(r.metadata_length, 100)


def _refused(
    mode: Int, needle: String, window: Int = FOOTER_SPECULATIVE_WINDOW
) -> Bool:
    try:
        var fs = _MemFs(_file(40), mode)
        _ = read_parquet_preamble[_MemFs](fs, "mem://f", window=window)
    except e:
        return String(e).find(needle) >= 0
    return False


def test_preamble_refuses_a_short_region_and_an_exact_read_that_misses() raises:
    assert_true(_refused(_MODE_SHORT_REGION, "< 8-byte trailer"))
    assert_true(_refused(_MODE_TRAILER_ONLY, "did not cover the metadata blob"))
    assert_false(_refused(_MODE_OK, "did not cover"))


def test_preamble_refuses_an_exact_read_that_ends_before_the_footer() raises:
    # The speculative 16-byte window misses the 40-byte footer; the exact
    # read starts at the footer's first byte but holds 39 of its 40 bytes.
    # Its start passes the check, so only the end comparison refuses it.
    assert_true(
        _refused(_MODE_EXACT_ENDS_SHORT, "did not cover the metadata blob", 16)
    )
    assert_false(_refused(_MODE_OK, "did not cover", 16))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

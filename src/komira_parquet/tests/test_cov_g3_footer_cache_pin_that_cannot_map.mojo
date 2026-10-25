# =============================================================================
# ParquetMetadataCache: a pin whose mapping cannot be made.
#
# What the test proves:
#   * on an mmap-backed file system whose path names no file on disk, the
#     footer is still served from the cache, the request answers no mapping
#     instead of failing the read, the failure is counted, and nothing is
#     counted as pinned or declined: a pin is an optimisation and never
#     fails a read.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_collections.slab import Slab
from komira_fs.file_system import FileSystem, WriteMode
from komira_fs.footer_region import FooterRegion
from komira_fs.shallow_dir_entry import ShallowDirEntry
from komira_parquet.runtime_footer_cache import ParquetMetadataCache


def _uleb(mut out: List[UInt8], v: Int):
    var x = UInt64(v)
    while x >= 0x80:
        out.append(UInt8((x & 0x7F) | 0x80))
        x >>= 7
    out.append(UInt8(x))


def _zz(mut out: List[UInt8], v: Int):
    _uleb(out, (v << 1) ^ (v >> 63))


def _footer(rg_rows: List[Int]) -> List[UInt8]:
    """FileMetaData: version 2, schema [root(1), a INT64], num_rows, and one
    RowGroup per entry of `rg_rows` with no column chunks. Every field id
    delta is 1, so each header is `0x10 | type`."""
    var total = 0
    for i in range(len(rg_rows)):
        total += rg_rows[i]
    var f: List[UInt8] = [0x15]  # 1: i32 version
    _zz(f, 2)
    f.append(0x19)  # 2: list schema
    f.append(0x2C)  # 2 structs
    # root: 4 name "s", 5 num_children 1
    f.append(0x48)
    _uleb(f, 1)
    f.append(0x73)
    f.append(0x15)
    _zz(f, 1)
    f.append(0x00)
    # leaf: 1 type INT64 (2), 4 name "a"
    f.append(0x15)
    _zz(f, 2)
    f.append(0x38)
    _uleb(f, 1)
    f.append(0x61)
    f.append(0x00)
    f.append(0x16)  # 3: i64 num_rows
    _zz(f, total)
    f.append(0x19)  # 4: list row_groups
    if len(rg_rows) < 15:
        f.append(UInt8((len(rg_rows) << 4) | 12))
    else:
        f.append(0xFC)
        _uleb(f, len(rg_rows))
    for i in range(len(rg_rows)):
        f.append(0x19)  # 1: list columns, empty
        f.append(0x0C)
        f.append(0x16)  # 2: i64 total_byte_size
        _zz(f, 100)
        f.append(0x16)  # 3: i64 num_rows
        _zz(f, rg_rows[i])
        f.append(0x00)
    f.append(0x00)
    return f^


def _bytes(rg_rows: List[Int], data_len: Int) -> List[UInt8]:
    var out: List[UInt8] = [0x50, 0x41, 0x52, 0x31]
    for i in range(data_len):
        out.append(UInt8(i % 251))
    var f = _footer(rg_rows)
    for i in range(len(f)):
        out.append(f[i])
    var n = len(f)
    for k in range(4):
        out.append(UInt8((n >> (8 * k)) & 0xFF))
    out.append(0x50)
    out.append(0x41)
    out.append(0x52)
    out.append(0x31)
    return out^


struct _Handle(Movable, Deinitable):
    var id: Int

    def __init__(out self, id: Int):
        self.id = id


struct _MemFs(FileSystem, Movable, Deinitable):
    """One in-memory file, served for any path; mmap-backed, though its path names no file on disk."""

    comptime File = _Handle
    comptime WriteFile = _Handle
    comptime IS_MMAP_BACKED: Bool = True

    var data: List[UInt8]

    def __init__(out self, var data: List[UInt8]):
        self.data = data^

    def clone(self) -> Self:
        return Self(self.data.copy())

    def list(self, prefix: String) raises -> List[String]:
        raise Error("unused")

    def open(self, path: String) raises -> Self.File:
        return _Handle(1)

    def _copy(self, offset: Int, length: Int) -> SharedAlignedBuffer[HeapRegion]:
        var part = List[UInt8](capacity=length)
        for i in range(length):
            part.append(self.data[offset + i])
        var buf = OwnedAlignedBuffer(max(length, 1))
        buf.copy_from_bytes_list(part)
        return SharedAlignedBuffer.from_owned(buf^)

    def read_at(self, mut file: Self.File, offset: Int64, length: Int64) raises -> SharedAlignedBuffer[HeapRegion]:
        return self._copy(Int(offset), Int(length))

    def read_ranges_prefetched(
        self, mut file: Self.File, ranges: List[Tuple[Int64, Int64]]
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
        var bytes = List[UInt8](capacity=w)
        for i in range(size - w, size):
            bytes.append(self.data[i])
        return FooterRegion(bytes^, size - w, size)

    def is_dir(self, path: String) raises -> Bool:
        return False

    def list_dir_shallow(self, dir: String) raises -> List[ShallowDirEntry]:
        raise Error("unused")

    def file_size(self, path: String) raises -> Int:
        return len(self.data)

    def open_write(self, path: String, mode: WriteMode) raises -> Self.WriteFile:
        raise Error("unused")

    def write_at(self, mut file: Self.WriteFile, data: Span[UInt8, _]) raises -> Int64:
        raise Error("unused")

    def pwrite_at(self, file: Self.WriteFile, offset: Int64, data: Span[UInt8, _]) raises -> Int64:
        raise Error("unused")

    def close_write(self, var file: Self.WriteFile) raises -> None:
        raise Error("unused")



def test_a_mapping_that_cannot_be_made_fails_no_read() raises:
    var fs = _MemFs(_bytes([6, 1], 20))
    var cache = ParquetMetadataCache(mmap_revalidate_min_age_ns=0)
    var shared = cache.get_or_parse_shared_via_fs("no_such_dir/no_such_file.parquet", fs)
    assert_equal(shared.meta[].num_rows, 7)
    assert_false(Bool(shared.mmap))
    assert_equal(cache.mmap_pin_failed(), 1)
    assert_equal(cache.mmap_pin_count(), 0)
    assert_equal(cache.mmap_pin_declined(), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

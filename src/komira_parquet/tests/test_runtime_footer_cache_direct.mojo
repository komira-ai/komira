# =============================================================================
# ParquetMetadataCache and the pin budget.
#
# Files are written into the test's scratch directory: PAR1, some data
# bytes, and a footer written here with a Thrift Compact writer (schema and
# row groups, no column chunks). An in-memory file system stands in for one
# that is not mmap-backed.
#
# What each test proves:
#   * the value surface reads and parses a path once; later lookups are hits
#     returning deep copies, and the populate itself is not counted a hit;
#   * the shared surface hands out shares of one footer (no deep copy), pins
#     the file's mapping once for many requests, and revalidates each hit
#     with one stat; `pin_mmap=False` takes no pin;
#   * revalidation: a file rewritten at another size is re-read and
#     re-parsed in place, its pin released and re-taken at the new size, and
#     the re-parse counts as a miss, not a hit; under the default settle
#     threshold a file written just now is never trusted, so every hit
#     re-parses it;
#   * the budget declines a file that does not fit beside the pins already
#     taken, and a declined pin still serves the footer;
#   * invalidate drops one entry and its pin; the others keep their pins and
#     their identities (no re-parse);
#   * the row-count memo serves a repeated path set without reading a
#     footer, keys on the ordered set, and is dropped by invalidate;
#   * the stripped footer and the summary copy no column chunk;
#   * a file system that is not mmap-backed is never pinned or stat-ed;
#   * the budget policy: an override wins, an unknown RAM basis gives the
#     default, otherwise 30% clamped to [1 GiB, 8 GiB].
# =============================================================================

from std.os import remove
from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_runtime_paths import test_tmpdir
from komira_async.ops.waker_sink import NoopSink
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_collections.slab import Slab
from komira_fs.file_system import FileSystem, WriteMode
from komira_fs.footer_region import FooterRegion
from komira_fs.local_fs import LocalFs
from komira_fs.shallow_dir_entry import ShallowDirEntry
from komira_parquet_api.metadata import SchemaElement
from komira_parquet.footer_pin_budget import (
    DEFAULT_MMAP_PIN_BYTE_CAP,
    MMAP_PIN_MAX_BYTES_CEILING,
    MMAP_PIN_MIN_BYTES,
    mmap_pin_budget_from_ram,
    resolve_mmap_pin_byte_cap,
)
from komira_parquet.runtime_footer_cache import ParquetMetadataCache

comptime _Fs = LocalFs[NoopSink]


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


def _write(name: String, rg_rows: List[Int], data_len: Int) raises -> String:
    var path = test_tmpdir() + "/" + name
    var b = _bytes(rg_rows, data_len)
    var fh = open(path, "w")
    fh.write_bytes(Span(b))
    fh.close()
    return path^


def _size(rg_rows: List[Int], data_len: Int) -> Int:
    return len(_bytes(rg_rows, data_len))


def test_value_surface_parses_once() raises:
    var path = _write("fc_value.parquet", [3, 4], 40)
    var cache = ParquetMetadataCache()
    var fs = _Fs.new()
    var md = cache.get_or_parse_via_fs(path, fs)
    assert_equal(md.num_rows, 7)
    assert_equal(len(md.row_groups), 2)
    assert_equal(md.row_groups[1].num_rows, 4)
    assert_equal(cache.hit_count_for(path), 0)  # the populate is not a hit
    var md2 = cache.get_or_parse(path)
    assert_equal(md2.num_rows, 7)
    assert_equal(cache.size(), 1)
    assert_equal(cache.miss_count(), 1)
    assert_equal(cache.parse_count_for(path), 1)
    assert_equal(cache.hit_count_for(path), 1)
    assert_equal(cache.deep_copy_count(), 2)
    assert_equal(cache.shared_clone_count(), 0)
    assert_equal(cache.hit_count_for("nope"), 0)
    with assert_raises():
        _ = cache.get_or_parse(test_tmpdir() + "/fc_absent.parquet")


def test_shared_surface_shares_and_pins_once() raises:
    var path = _write("fc_shared.parquet", [3, 4], 40)
    var cache = ParquetMetadataCache(mmap_revalidate_min_age_ns=0)
    var fs = _Fs.new()
    var a = cache.get_or_parse_shared_via_fs(path, fs)
    var b = cache.get_or_parse_shared_via_fs(path, fs)
    assert_equal(a.meta[].num_rows, 7)
    assert_equal(b.meta[].num_rows, 7)
    assert_equal(a.preamble.file_size, _size([3, 4], 40))
    assert_true(Bool(a.mmap))
    assert_true(Bool(b.mmap))
    assert_true(Bool(b.mmap_share()))
    assert_equal(cache.shared_clone_count(), 2)
    assert_equal(cache.deep_copy_count(), 0)
    assert_equal(cache.mmap_pin_count(), 1)
    assert_equal(cache.mmap_pinned_bytes(), _size([3, 4], 40))
    assert_equal(cache.revalidate_stat_count(), 1)  # the hit only
    assert_equal(cache.revalidate_drop_count(), 0)
    assert_equal(cache.hit_count_for(path), 1)
    var c = cache.get_or_parse_shared_via_fs(path, fs, pin_mmap=False)
    assert_false(Bool(c.mmap))
    assert_equal(cache.mmap_pin_count(), 1)


def test_a_rewritten_file_is_reparsed_in_place() raises:
    var path = _write("fc_rewrite.parquet", [3, 4], 40)
    var cache = ParquetMetadataCache(mmap_revalidate_min_age_ns=0)
    var fs = _Fs.new()
    _ = cache.get_or_parse_shared_via_fs(path, fs)
    _ = _write("fc_rewrite.parquet", [9], 90)
    var s = cache.get_or_parse_shared_via_fs(path, fs)
    assert_equal(s.meta[].num_rows, 9)
    assert_equal(len(s.meta[].row_groups), 1)
    assert_equal(cache.revalidate_drop_count(), 1)
    assert_equal(cache.miss_count(), 2)
    assert_equal(cache.parse_count_for(path), 2)
    assert_equal(cache.hit_count_for(path), 0)  # a re-parse is a miss
    assert_equal(cache.size(), 1)
    assert_equal(cache.mmap_pin_count(), 2)
    assert_equal(cache.mmap_pinned_bytes(), _size([9], 90))
    # The value surface sees the new footer too.
    assert_equal(cache.get_or_parse_via_fs(path, fs).num_rows, 9)


def test_a_file_written_just_now_is_never_trusted() raises:
    var path = _write("fc_fresh.parquet", [5], 10)
    var cache = ParquetMetadataCache()  # the default 10 s settle threshold
    var fs = _Fs.new()
    _ = cache.get_or_parse_shared_via_fs(path, fs)
    _ = cache.get_or_parse_shared_via_fs(path, fs)
    _ = cache.get_or_parse_shared_via_fs(path, fs)
    assert_equal(cache.revalidate_stat_count(), 2)
    assert_equal(cache.revalidate_drop_count(), 2)
    assert_equal(cache.miss_count(), 3)
    assert_equal(cache.mmap_pinned_bytes(), _size([5], 10))


def test_the_budget_declines_what_does_not_fit() raises:
    var pa = _write("fc_budget_a.parquet", [1], 30)
    var pb = _write("fc_budget_b.parquet", [2], 30)
    var sa = _size([1], 30)
    var sb = _size([2], 30)
    var cache = ParquetMetadataCache(mmap_pin_byte_cap=sa + sb - 1, mmap_revalidate_min_age_ns=0)
    var fs = _Fs.new()
    var a = cache.get_or_parse_shared_via_fs(pa, fs)
    var b = cache.get_or_parse_shared_via_fs(pb, fs)
    assert_true(Bool(a.mmap))
    assert_false(Bool(b.mmap))
    assert_equal(b.meta[].num_rows, 2)
    assert_equal(cache.mmap_pin_declined(), 1)
    assert_equal(cache.mmap_pinned_bytes(), sa)
    assert_equal(cache.mmap_pin_failed(), 0)
    assert_equal(cache.mmap_pin_byte_cap(), sa + sb - 1)


def test_invalidate_drops_one_entry_and_its_pin() raises:
    var pa = _write("fc_inv_a.parquet", [1], 30)
    var pb = _write("fc_inv_b.parquet", [2], 50)
    var cache = ParquetMetadataCache(mmap_revalidate_min_age_ns=0)
    var fs = _Fs.new()
    _ = cache.get_or_parse_shared_via_fs(pa, fs)
    _ = cache.get_or_parse_shared_via_fs(pb, fs)
    assert_equal(cache.mmap_pin_count(), 2)
    cache.invalidate(pa)
    cache.invalidate("never-cached")
    assert_equal(cache.size(), 1)
    assert_equal(cache.mmap_pinned_bytes(), _size([2], 50))
    var b = cache.get_or_parse_shared_via_fs(pb, fs)
    assert_true(Bool(b.mmap))
    assert_equal(cache.mmap_pin_count(), 2)  # b kept its pin
    assert_equal(cache.revalidate_drop_count(), 0)  # and its identity
    assert_equal(cache.parse_count_for(pb), 1)
    assert_equal(cache.hit_count_for(pb), 1)
    _ = cache.get_or_parse_shared_via_fs(pa, fs)
    assert_equal(cache.miss_count(), 3)


def test_the_row_count_memo() raises:
    var pa = _write("fc_rg_a.parquet", [3, 4], 10)
    var pb = _write("fc_rg_b.parquet", [5], 10)
    var cache = ParquetMetadataCache()
    var fs = _Fs.new()
    var ab: List[String] = [pa, pb]
    var out = List[Int]()
    cache.resolve_rg_counts_via_fs(ab, fs, out)
    assert_equal(len(out), 3)
    assert_equal(out[0], 3)
    assert_equal(out[2], 5)
    var again = List[Int]()
    cache.resolve_rg_counts_via_fs(ab, fs, again)
    assert_equal(len(again), 3)
    assert_equal(again[1], 4)
    assert_equal(cache.row_window_rg_counts_cache_hits(), 1)
    assert_equal(cache.row_window_rg_counts_cache_misses(), 1)
    assert_equal(cache.row_window_resolver_footer_reads(), 2)
    var ba: List[String] = [pb, pa]
    var rev = List[Int]()
    cache.resolve_rg_counts_via_fs(ba, fs, rev)
    assert_equal(rev[0], 5)
    assert_equal(rev[1], 3)
    assert_equal(cache.row_window_rg_counts_cache_misses(), 2)
    assert_equal(cache.miss_count(), 2)  # footers parsed once each
    cache.invalidate(pb)
    var after = List[Int]()
    cache.resolve_rg_counts_via_fs(ab, fs, after)
    assert_equal(cache.row_window_rg_counts_cache_misses(), 3)
    assert_equal(cache.deep_copy_count(), 0)


def test_stripped_footer_and_summary() raises:
    var path = _write("fc_strip.parquet", [3, 4], 10)
    var cache = ParquetMetadataCache()
    var fs = _Fs.new()
    var st = cache.stripped_footer_via_fs(path, fs)
    assert_equal(st.num_rows, 7)
    assert_equal(len(st.row_groups), 2)
    assert_equal(st.row_groups[0].num_rows, 3)
    assert_equal(st.row_groups[0].total_byte_size, 100)
    assert_equal(len(st.row_groups[0].columns), 0)
    assert_equal(len(st.schema), 2)
    var schema = List[SchemaElement]()
    assert_equal(cache.get_or_parse_summary_via_fs(path, fs, schema), 7)
    assert_equal(len(schema), 2)
    assert_equal(schema[1].name, "a")
    assert_equal(cache.deep_copy_count(), 0)
    assert_equal(cache.miss_count(), 1)
    assert_equal(cache.hit_count_for(path), 1)


struct _Handle(Movable, Deinitable):
    var id: Int

    def __init__(out self, id: Int):
        self.id = id


struct _MemFs(FileSystem, Movable, Deinitable):
    """One in-memory file, served for any path; not mmap-backed."""

    comptime File = _Handle
    comptime WriteFile = _Handle
    comptime IS_MMAP_BACKED: Bool = False

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


def test_a_file_system_that_is_not_mmap_backed() raises:
    var fs = _MemFs(_bytes([6, 1], 20))
    var cache = ParquetMetadataCache(mmap_revalidate_min_age_ns=0)
    var a = cache.get_or_parse_shared_via_fs("mem://x", fs)
    var b = cache.get_or_parse_shared_via_fs("mem://x", fs)
    assert_equal(a.meta[].num_rows, 7)
    assert_false(Bool(a.mmap))
    assert_false(Bool(b.mmap))
    assert_equal(cache.mmap_pin_count(), 0)
    assert_equal(cache.mmap_pin_declined(), 0)
    assert_equal(cache.revalidate_stat_count(), 0)
    assert_equal(cache.hit_count_for("mem://x"), 1)


def test_the_budget_policy() raises:
    assert_equal(mmap_pin_budget_from_ram(100 << 30, 12345), 12345)
    assert_equal(mmap_pin_budget_from_ram(0, 0), DEFAULT_MMAP_PIN_BYTE_CAP)
    assert_equal(mmap_pin_budget_from_ram(-1, 0), DEFAULT_MMAP_PIN_BYTE_CAP)
    # 30% of 10 GB is 3 GB, inside the clamp.
    assert_equal(mmap_pin_budget_from_ram(10_000_000_000, 0), 3_000_000_000)
    assert_equal(mmap_pin_budget_from_ram(1 << 30, 0), MMAP_PIN_MIN_BYTES)
    assert_equal(mmap_pin_budget_from_ram(1 << 40, 0), MMAP_PIN_MAX_BYTES_CEILING)
    assert_equal(resolve_mmap_pin_byte_cap(777), 777)
    assert_equal(ParquetMetadataCache.ram_sized(777).mmap_pin_byte_cap(), 777)
    var cap = resolve_mmap_pin_byte_cap()
    assert_true(cap >= MMAP_PIN_MIN_BYTES and cap <= MMAP_PIN_MAX_BYTES_CEILING)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

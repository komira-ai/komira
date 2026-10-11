# =============================================================================
# test_fs_stub_backend.mojo
# =============================================================================
# The FileSystem trait's default bodies and the discovery factories, driven
# over an in-memory backend (`_StubFs`) that implements only the required
# methods:
#
#   * every default body (`delete`, `fsync_file`, `fsync_dir`,
#     `seek_write_to_end`, `writev_at_cursor`, `abort_write`) raises its own
#     "unimplemented" error rather than silently succeeding;
#   * `EagerGlobDiscovery`: directory mode returns the listing sorted; a
#     brace glob whose alternatives overlap keeps each match once; a path
#     whose directory probe raises is one literal file; the partition hooks
#     report no partition columns; an unbalanced `{` is literal;
#   * `PathDiscovery.open` / `list_files`: directory listing and the single
#     path fallback;
#   * `PrunedHiveDiscovery.open` (no predicate) infers the partition schema
#     and keeps every file; `partition_fields` / `partition_col_name_at`;
#     `open_pruned` raises when the targeted prefixes list nothing (and
#     returns an empty set when that is allowed); pages that overlap across
#     prefixes are united without duplicates.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_buffer.heap_region import HeapRegion
from komira_collections.slab import Slab
from komira_fs.file_system import FileSystem, WriteMode
from komira_fs.footer_region import FooterRegion
from komira_fs.shallow_dir_entry import ShallowDirEntry
from komira_fs.file_discovery import EagerGlobDiscovery, GlobDiscoveryOptions
from komira_fs.path_discovery import PathDiscovery
from komira_fs.glob import brace_expand
from komira_fs.pruned_hive_discovery import (
    PartitionConstraint,
    PartitionPredicate,
    PrunedHiveDiscovery,
)


struct _Handle(Movable, Deinitable):
    var id: Int

    def __init__(out self, id: Int):
        self.id = id


struct _StubFs(FileSystem, Movable, Deinitable):
    """An in-memory store of bare keys. `list(prefix)` returns every key that
    starts with `prefix`, or every key when `flat` is set (a backend whose
    pages overlap). `is_dir` is True for the names in `dirs`, False for a
    stored key, and raises for anything else (not found). Everything else is
    a stub that raises."""

    comptime File = _Handle
    comptime WriteFile = _Handle

    var keys: List[String]
    var dirs: List[String]
    var flat: Bool

    def __init__(
        out self, var keys: List[String], var dirs: List[String], flat: Bool
    ):
        self.keys = keys^
        self.dirs = dirs^
        self.flat = flat

    def clone(self) -> Self:
        return Self(self.keys.copy(), self.dirs.copy(), self.flat)

    def list(self, prefix: String) raises -> List[String]:
        var out = List[String]()
        for i in range(len(self.keys)):
            if self.flat or self.keys[i].startswith(prefix):
                out.append(self.keys[i].copy())
        return out^

    def is_dir(self, path: String) raises -> Bool:
        for i in range(len(self.dirs)):
            if self.dirs[i] == path:
                return True
        for i in range(len(self.keys)):
            if self.keys[i] == path:
                return False
        raise Error("_StubFs.is_dir: path not found: " + path)

    def list_dir_shallow(self, dir: String) raises -> List[ShallowDirEntry]:
        raise Error("_StubFs.list_dir_shallow: unused")

    def open(self, path: String) raises -> Self.File:
        raise Error("_StubFs.open: unused")

    def read_at(
        self, mut file: Self.File, offset: Int64, length: Int64,
    ) raises -> SharedAlignedBuffer[HeapRegion]:
        raise Error("_StubFs.read_at: unused")

    def read_ranges_prefetched(
        self, mut file: Self.File, ranges: List[Tuple[Int64, Int64]],
    ) raises -> Slab[SharedAlignedBuffer[HeapRegion]]:
        raise Error("_StubFs.read_ranges_prefetched: unused")

    def prefetch_depth(self) -> Int:
        return 1

    def supports_random_read(self) -> Bool:
        return False

    def read_footer(self, path: String, window: Int) raises -> FooterRegion:
        raise Error("_StubFs.read_footer: unused")

    def file_size(self, path: String) raises -> Int:
        raise Error("_StubFs.file_size: unused")

    def open_write(
        self, path: String, mode: WriteMode,
    ) raises -> Self.WriteFile:
        return _Handle(1)

    def write_at(
        self, mut file: Self.WriteFile, data: Span[UInt8, _],
    ) raises -> Int64:
        raise Error("_StubFs.write_at: unused")

    def pwrite_at(
        self, file: Self.WriteFile, offset: Int64, data: Span[UInt8, _],
    ) raises -> Int64:
        raise Error("_StubFs.pwrite_at: unused")

    def close_write(self, var file: Self.WriteFile) raises -> None:
        _ = file^


def _strs(a: String, b: String = "", c: String = "", d: String = "") -> List[String]:
    var out = List[String]()
    out.append(a)
    if b.byte_length() > 0:
        out.append(b)
    if c.byte_length() > 0:
        out.append(c)
    if d.byte_length() > 0:
        out.append(d)
    return out^


def _empty_fs() -> _StubFs:
    return _StubFs(List[String](), List[String](), False)


# -----------------------------------------------------------------------------
# FileSystem default bodies
# -----------------------------------------------------------------------------


def _raises_with(msg: String, want: String) -> Bool:
    return want in msg


def test_default_delete_raises() raises:
    var fs = _empty_fs()
    var raised = False
    try:
        fs.delete("x")
    except e:
        raised = _raises_with(String(e), "FileSystem.delete: unimplemented")
    assert_true(raised)


def test_default_fsync_raises() raises:
    var fs = _empty_fs()
    var raised_file = False
    try:
        fs.fsync_file("x")
    except e:
        raised_file = _raises_with(String(e), "FileSystem.fsync_file: unimplemented")
    assert_true(raised_file)
    var raised_dir = False
    try:
        fs.fsync_dir("d")
    except e:
        raised_dir = _raises_with(String(e), "FileSystem.fsync_dir: unimplemented")
    assert_true(raised_dir)


def test_default_seek_write_to_end_raises() raises:
    var fs = _empty_fs()
    var wf = fs.open_write("x", WriteMode.create_truncate())
    var raised = False
    try:
        _ = fs.seek_write_to_end(wf)
    except e:
        raised = _raises_with(
            String(e), "FileSystem.seek_write_to_end: unimplemented"
        )
    assert_true(raised)
    fs.close_write(wf^)


def test_default_writev_at_cursor_raises() raises:
    var fs = _empty_fs()
    var wf = fs.open_write("x", WriteMode.create_truncate())
    var addrs = List[Int]()
    var lens = List[Int]()
    var raised = False
    try:
        _ = fs.writev_at_cursor(wf, Span(addrs), Span(lens))
    except e:
        raised = _raises_with(
            String(e), "FileSystem.writev_at_cursor: unimplemented"
        )
    assert_true(raised)
    fs.close_write(wf^)


def test_default_abort_write_raises() raises:
    var fs = _empty_fs()
    var wf = fs.open_write("x", WriteMode.create_truncate())
    var raised = False
    try:
        fs.abort_write(wf^)
    except e:
        raised = _raises_with(String(e), "FileSystem.abort_write: unimplemented")
    assert_true(raised)


# -----------------------------------------------------------------------------
# EagerGlobDiscovery / PathDiscovery over the stub
# -----------------------------------------------------------------------------


def test_eager_directory_mode_sorted() raises:
    var fs = _StubFs(
        _strs("d/b.parquet", "d/a.parquet", "e/z.parquet"), _strs("d/"), False
    )
    var disc = EagerGlobDiscovery.open(fs, "d/")
    assert_equal(disc.num_paths(), 2)
    assert_equal(disc.path_at(0), "d/a.parquet")
    assert_equal(disc.path_at(1), "d/b.parquet")
    assert_equal(disc.num_partition_cols(), 0)
    assert_true(disc.partition_col_type_at(0) == ArrowType.STRING)
    assert_equal(disc.partition_col_name_at(0), "")


def test_eager_overlapping_braces_dedupe() raises:
    """`{a,*}` expands to two patterns that both match `d/a.parquet`."""
    var fs = _StubFs(
        _strs("d/a.parquet", "d/b.parquet", "d/c.csv"), List[String](), False
    )
    var disc = EagerGlobDiscovery.open(fs, "d/{a,*}.parquet")
    assert_equal(disc.num_paths(), 2)
    assert_equal(disc.path_at(0), "d/a.parquet")
    assert_equal(disc.path_at(1), "d/b.parquet")


def test_path_discovery_directory_and_file() raises:
    var fs = _StubFs(
        _strs("d/x.parquet", "d/y.parquet", "e/z.parquet"), _strs("d/"), False
    )
    var disc = PathDiscovery.open(fs, "d/")
    assert_equal(disc.num_paths(), 2)
    assert_equal(disc.path_at(0), "d/x.parquet")
    assert_equal(disc.path_at(1), "d/y.parquet")
    var listed = disc.list_files(fs, "d/")
    assert_equal(len(listed), 2)
    assert_equal(listed[1], "d/y.parquet")


def test_path_discovery_single_file() raises:
    """A path the backend says is not a directory is taken as one file."""
    var fs = _StubFs(_strs("d/x.parquet", "d/y.parquet"), _strs("d/"), False)
    var disc = PathDiscovery.open(fs, "d/x.parquet")
    assert_equal(disc.num_paths(), 1)
    assert_equal(disc.path_at(0), "d/x.parquet")
    var listed = disc.list_files(fs, "d/y.parquet")
    assert_equal(len(listed), 1)
    assert_equal(listed[0], "d/y.parquet")


def test_eager_missing_path_is_single_file() raises:
    """`is_dir` raising (not found) is not a directory: the literal path is
    the one file, left for the open to fail on."""
    var fs = _StubFs(_strs("d/x.parquet"), _strs("d/"), False)
    var disc = EagerGlobDiscovery.open(fs, "d/missing.parquet")
    assert_equal(disc.num_paths(), 1)
    assert_equal(disc.path_at(0), "d/missing.parquet")


def test_brace_unbalanced_is_literal() raises:
    var out = brace_expand("d/{a,b")
    assert_equal(len(out), 1)
    assert_equal(out[0], "d/{a,b")
    var ok = brace_expand("d/{a,b}")
    assert_equal(len(ok), 2)


# -----------------------------------------------------------------------------
# PrunedHiveDiscovery over the stub
# -----------------------------------------------------------------------------


def _hive_keys() -> List[String]:
    return _strs(
        "t/year=2028/region=us/a.parquet",
        "t/year=2028/region=eu/b.parquet",
        "t/year=2029/region=us/c.parquet",
    )


def test_pruned_open_infers_and_keeps_all() raises:
    var fs = _StubFs(_hive_keys(), List[String](), False)
    var disc = PrunedHiveDiscovery.open(fs, "t")
    assert_false(PrunedHiveDiscovery.is_lazy())
    assert_equal(disc.num_paths(), 3)
    assert_equal(disc.path_at(0), "t/year=2028/region=eu/b.parquet")
    assert_equal(disc.num_partition_cols(), 2)
    assert_equal(disc.partition_col_name_at(0), "year")
    assert_equal(disc.partition_col_name_at(1), "region")
    var fields = disc.partition_fields()
    assert_equal(len(fields), 2)
    assert_equal(fields[0].name, "year")
    assert_true(fields[0].arrow_type == ArrowType.INT64)
    assert_false(fields[0].nullable)
    assert_equal(fields[1].name, "region")
    assert_true(fields[1].arrow_type == ArrowType.STRING)
    var pv = disc.partition_values_at(2)
    assert_equal(pv.values[0], "2029")
    assert_equal(pv.values[1], "us")


def _cols() -> List[String]:
    return _strs("year", "region")


def _types() -> List[ArrowType]:
    var t = List[ArrowType]()
    t.append(ArrowType.INT64)
    t.append(ArrowType.STRING)
    return t^


def test_pruned_open_pruned_no_match_raises() raises:
    var fs = _StubFs(_hive_keys(), List[String](), False)
    var cs = List[PartitionConstraint]()
    cs.append(PartitionConstraint.eq("year", "2030", ArrowType.INT64))
    var pred = PartitionPredicate(constraints=cs^)
    var raised = False
    try:
        _ = PrunedHiveDiscovery.open_pruned(
            fs, "t", _cols(), _types(), pred, GlobDiscoveryOptions.default()
        )
    except e:
        raised = True
        var msg = String(e)
        assert_true("partition pruning under base 't' matched no files" in msg)
    assert_true(raised)
    # Allowed: an empty discovery, not an error.
    var cs2 = List[PartitionConstraint]()
    cs2.append(PartitionConstraint.eq("year", "2030", ArrowType.INT64))
    var disc = PrunedHiveDiscovery.open_pruned(
        fs,
        "t",
        _cols(),
        _types(),
        PartitionPredicate(constraints=cs2^),
        GlobDiscoveryOptions(allow_empty_glob=True),
    )
    assert_equal(disc.num_paths(), 0)


def test_pruned_overlapping_pages_united_once() raises:
    """A backend whose `list` returns every key for every prefix: the two
    IN-list prefixes each return all three files; the union keeps each once
    and the fold drops the one outside the list."""
    var fs = _StubFs(_hive_keys(), List[String](), True)
    var vals = _strs("2028", "2027")
    var cs = List[PartitionConstraint]()
    cs.append(PartitionConstraint.in_list("year", vals, ArrowType.INT64))
    var disc = PrunedHiveDiscovery.open_pruned(
        fs,
        "t",
        _cols(),
        _types(),
        PartitionPredicate(constraints=cs^),
        GlobDiscoveryOptions.default(),
    )
    assert_equal(disc.num_paths(), 2)
    assert_equal(disc.path_at(0), "t/year=2028/region=eu/b.parquet")
    assert_equal(disc.path_at(1), "t/year=2028/region=us/a.parquet")


def main() raises:
    var suite = TestSuite()
    suite.test[test_default_delete_raises]()
    suite.test[test_default_fsync_raises]()
    suite.test[test_default_seek_write_to_end_raises]()
    suite.test[test_default_writev_at_cursor_raises]()
    suite.test[test_default_abort_write_raises]()
    suite.test[test_eager_directory_mode_sorted]()
    suite.test[test_eager_overlapping_braces_dedupe]()
    suite.test[test_path_discovery_directory_and_file]()
    suite.test[test_path_discovery_single_file]()
    suite.test[test_eager_missing_path_is_single_file]()
    suite.test[test_brace_unbalanced_is_literal]()
    suite.test[test_pruned_open_infers_and_keeps_all]()
    suite.test[test_pruned_open_pruned_no_match_raises]()
    suite.test[test_pruned_overlapping_pages_united_once]()
    suite^.run()

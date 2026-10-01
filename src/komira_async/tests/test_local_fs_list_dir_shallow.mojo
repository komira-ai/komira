# =============================================================================
# test_local_fs_list_dir_shallow.mojo
# =============================================================================
# LocalFs.list_dir_shallow: the SHALLOW one-level
# directory-listing primitive that backs lazy Hive partition-schema probing.
#
# The marquee property: it lists ONLY the immediate children (each tagged dir
# vs file) and NEVER recursively enumerates the leaf data files — that deferral
# is what delivers the cloud-listing win (the pruned leaf enumeration moves to
# the reader that opens the pruned set).
#
# Coverage (over a Hive tree dir/dt=.../<part-*.parquet>):
#   T1 — list_dir_shallow("dir") returns ONLY the two dt=... SUBDIRS (is_dir
#        True), and does NOT recurse into the leaf .parquet files.
#   T2 — list_dir_shallow returns the leaf parquet FILE
#        (is_dir False) — one level only.
#   T3 — a non-directory / non-existent prefix -> empty list.
#   T4 — a 2-level Hive tree (dt=.../hr=.../f.parquet): the level walk sees the
#        dt= subdir at level 0 and the hr= subdir one level down (NOT the leaf).
#
# Discipline (mirrors test_local_fs_list_recursive.mojo):
#   * Tree built under the runner's private TEST_TMPDIR (never /tmp).
#   * ZERO UnsafePointer in test code; assertions over owned List/String/Bool.
# =============================================================================

from std.ffi import external_call
from std.testing import assert_equal, assert_true, assert_false

from komira_runtime_paths import test_tmpdir
from komira_async.fs.local_fs import LocalFs, ShallowDirEntry
from komira_async.ops.waker_sink import NoopSink


comptime _Fs = LocalFs[NoopSink]


def _sh(cmd: String) raises:
    var cmd_local = cmd
    var rc = external_call["system", Int32](
        cmd_local.as_c_string_slice().unsafe_ptr()
    )
    if Int(rc) != 0:
        raise Error("shell command failed rc=" + String(Int(rc)) + ": " + cmd)


def _disk_root(tag: String) raises -> String:
    var base = test_tmpdir()
    var pid = external_call["getpid", Int32]()
    var root = base + String("/g12a_") + tag + String("_") + String(Int(pid))
    _sh(String("rm -rf '") + root + String("'"))
    _sh(String("mkdir -p '") + root + String("'"))
    return root


def _build_hive_tree(root: String) raises:
    """dir/dt=2026-11-01/a.parquet, dir/dt=2026-11-02/b.parquet (1 partition
    level: dt)."""
    var d = root + String("/dir")
    _sh(String("mkdir -p '") + d + String("/dt=2026-11-01'"))
    _sh(String("mkdir -p '") + d + String("/dt=2026-11-02'"))
    _sh(String("printf 'A' > '") + d + String("/dt=2026-11-01/a.parquet'"))
    _sh(String("printf 'B' > '") + d + String("/dt=2026-11-02/b.parquet'"))


def _entry_named(
    entries: List[ShallowDirEntry], name: String
) -> Int:
    """Index of the entry named `name`, or -1."""
    for i in range(len(entries)):
        if entries[i].name == name:
            return i
    return -1


def _count_dirs(entries: List[ShallowDirEntry]) -> Int:
    var n = 0
    for i in range(len(entries)):
        if entries[i].is_dir:
            n += 1
    return n


def _count_files(entries: List[ShallowDirEntry]) -> Int:
    var n = 0
    for i in range(len(entries)):
        if not entries[i].is_dir:
            n += 1
    return n


# =============================================================================
# T1 — shallow list of the base dir returns ONLY the partition subdirs.
# =============================================================================


def test_shallow_lists_partition_subdirs_only() raises:
    var root = _disk_root(String("t1"))
    _build_hive_tree(root)
    var fs = _Fs.new()
    var d = root + String("/dir")
    var entries = fs.list_dir_shallow(d)
    # Exactly the two dt=... SUBDIRS, no recursion into the leaf parquet files.
    assert_equal(len(entries), 2)
    assert_equal(_count_dirs(entries), 2)
    assert_equal(_count_files(entries), 0)
    var i1 = _entry_named(entries, String("dt=2026-11-01"))
    var i2 = _entry_named(entries, String("dt=2026-11-02"))
    assert_true(i1 >= 0)
    assert_true(i2 >= 0)
    assert_true(entries[i1].is_dir)
    assert_true(entries[i2].is_dir)
    _sh(String("rm -rf '") + root + String("'"))


# =============================================================================
# T2 — shallow list of a partition dir returns the leaf parquet FILE.
# =============================================================================


def test_shallow_lists_leaf_file() raises:
    var root = _disk_root(String("t2"))
    _build_hive_tree(root)
    var fs = _Fs.new()
    var part_dir = root + String("/dir/dt=2026-11-01")
    var entries = fs.list_dir_shallow(part_dir)
    assert_equal(len(entries), 1)
    assert_equal(_count_files(entries), 1)
    var idx = _entry_named(entries, String("a.parquet"))
    assert_true(idx >= 0)
    assert_false(entries[idx].is_dir)
    _sh(String("rm -rf '") + root + String("'"))


# =============================================================================
# T3 — non-directory / non-existent prefix -> empty.
# =============================================================================


def test_shallow_non_dir_is_empty() raises:
    var root = _disk_root(String("t3"))
    _build_hive_tree(root)
    var fs = _Fs.new()
    var file_path = root + String("/dir/dt=2026-11-01/a.parquet")
    assert_equal(len(fs.list_dir_shallow(file_path)), 0)
    var missing = root + String("/dir/nope")
    assert_equal(len(fs.list_dir_shallow(missing)), 0)
    _sh(String("rm -rf '") + root + String("'"))


# =============================================================================
# T4 — 2-level Hive tree: shallow level walk sees dt= then hr=, not the leaf.
# =============================================================================


def test_shallow_two_level_hive() raises:
    var root = _disk_root(String("t4"))
    var d = root + String("/dir")
    _sh(String("mkdir -p '") + d + String("/dt=2026-11-01/hr=00'"))
    _sh(String("mkdir -p '") + d + String("/dt=2026-11-01/hr=12'"))
    _sh(String("printf 'X' > '") + d + String("/dt=2026-11-01/hr=00/f.parquet'"))
    _sh(String("printf 'Y' > '") + d + String("/dt=2026-11-01/hr=12/g.parquet'"))
    var fs = _Fs.new()
    # Level 0: one dt= subdir.
    var lvl0 = fs.list_dir_shallow(d)
    assert_equal(_count_dirs(lvl0), 1)
    assert_true(_entry_named(lvl0, String("dt=2026-11-01")) >= 0)
    # Level 1 (inside dt=...): two hr= subdirs, NO leaf files at this level.
    var lvl1 = fs.list_dir_shallow(d + String("/dt=2026-11-01"))
    assert_equal(_count_dirs(lvl1), 2)
    assert_equal(_count_files(lvl1), 0)
    assert_true(_entry_named(lvl1, String("hr=00")) >= 0)
    assert_true(_entry_named(lvl1, String("hr=12")) >= 0)
    # Level 2 (inside hr=...): the leaf parquet file.
    var lvl2 = fs.list_dir_shallow(d + String("/dt=2026-11-01/hr=00"))
    assert_equal(_count_files(lvl2), 1)
    assert_true(_entry_named(lvl2, String("f.parquet")) >= 0)
    _sh(String("rm -rf '") + root + String("'"))


def main() raises:
    test_shallow_lists_partition_subdirs_only()
    test_shallow_lists_leaf_file()
    test_shallow_non_dir_is_empty()
    test_shallow_two_level_hive()
    print("test_local_fs_list_dir_shallow: ALL PASS")

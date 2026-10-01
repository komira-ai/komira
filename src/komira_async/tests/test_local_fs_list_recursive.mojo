# =============================================================================
# test_local_fs_list_recursive.mojo
# =============================================================================
# Recursive LocalFs.list, plus an end-to-end local-glob discovery smoke
# (glob + EagerGlobDiscovery + LocalFs.list together): recursive vs shallow
# listing and symlink-loop safety.
#
# Coverage:
#   T1 — recursive walk: dir/a.parquet, dir/sub/b.parquet,
#        dir/sub/deep/c.parquet -> LocalFs.list("dir") returns all 3
#        (recursive, any depth).
#   T2 — symlink-skip: add a symlink dir/loop -> dir (a cycle) and a symlink
#        dir/link.parquet -> dir/a.parquet; LocalFs.list must NOT follow the
#        directory symlink (no infinite recursion / no duplicated entries)
#        and must NOT emit the file symlink. Result is still exactly the 3
#        real files.
#   T3 — non-directory prefix -> empty list (consistent with the object-store
#        "prefix matched nothing" behavior).
#   T4 — e2e: EagerGlobDiscovery.open(local_fs, "dir/**/*.parquet") returns
#        the 3 .parquet paths, lexically sorted. The first real end-to-end
#        discovery over a local dir tree.
#   T5 — e2e shallow glob: EagerGlobDiscovery.open(local_fs, "dir/*.parquet")
#        — with the recursive list + client-side glob_match_path filter, only
#        dir/a.parquet matches (`*` does not cross `/`), so exactly 1 path.
#
# Discipline:
#   * Tree is built under the runner's private TEST_TMPDIR (never /tmp).
#   * ZERO UnsafePointer in test code (setup via `system()`; assertions over
#     owned List[String] / String).
#   * ZERO new wildcard origins in test code.
# =============================================================================

from std.ffi import external_call
from std.testing import assert_equal, assert_true, assert_false

from komira_runtime_paths import test_tmpdir
from komira_async.fs.local_fs import LocalFs
from komira_async.fs.file_discovery import EagerGlobDiscovery
from komira_async.ops.waker_sink import NoopSink


comptime _Fs = LocalFs[NoopSink]


# =============================================================================
# Fixture helpers — build/teardown a dir tree on the `/`-disk via system().
# =============================================================================


def _sh(cmd: String) raises:
    """Run a shell command via system(); raise on non-zero rc."""
    var cmd_local = cmd
    var rc = external_call["system", Int32](
        cmd_local.as_c_string_slice().unsafe_ptr()
    )
    if Int(rc) != 0:
        raise Error("shell command failed rc=" + String(Int(rc)) + ": " + cmd)


def _disk_root(tag: String) raises -> String:
    """A unique root for this test process under the runner's private
    TEST_TMPDIR. NEVER /tmp."""
    var base = test_tmpdir()
    var pid = external_call["getpid", Int32]()
    var root = base + String("/glob_g4_") + tag + String("_") + String(Int(pid))
    # Clean any stale tree, then create the base.
    _sh(String("rm -rf '") + root + String("'"))
    _sh(String("mkdir -p '") + root + String("'"))
    return root


def _build_tree(root: String) raises:
    """Create dir/a.parquet, dir/sub/b.parquet, dir/sub/deep/c.parquet under
    `root` (`root/dir` is the directory we list)."""
    var d = root + String("/dir")
    _sh(String("mkdir -p '") + d + String("/sub/deep'"))
    _sh(String("printf 'A' > '") + d + String("/a.parquet'"))
    _sh(String("printf 'B' > '") + d + String("/sub/b.parquet'"))
    _sh(String("printf 'C' > '") + d + String("/sub/deep/c.parquet'"))


def _count_suffix(paths: List[String], suffix: String) -> Int:
    var n = 0
    for i in range(len(paths)):
        if paths[i].endswith(suffix):
            n += 1
    return n


def _has_suffix(paths: List[String], suffix: String) -> Bool:
    for i in range(len(paths)):
        if paths[i].endswith(suffix):
            return True
    return False


# =============================================================================
# T1 — recursive walk returns all 3 files at all depths.
# =============================================================================


def test_recursive_walk_all_depths() raises:
    var root = _disk_root(String("t1"))
    _build_tree(root)
    var fs = _Fs.new()
    var d = root + String("/dir")
    var files = fs.list(d)
    # Exactly the 3 real files, at depths 0 / 1 / 2.
    assert_equal(len(files), 3)
    assert_true(_has_suffix(files, String("/dir/a.parquet")))
    assert_true(_has_suffix(files, String("/dir/sub/b.parquet")))
    assert_true(_has_suffix(files, String("/dir/sub/deep/c.parquet")))
    # Every returned path is absolute under the listed directory.
    for i in range(len(files)):
        assert_true(files[i].startswith(d))
    _sh(String("rm -rf '") + root + String("'"))


# =============================================================================
# T2 — symlinks are skipped (cycle-safe + no file-symlink emission).
# =============================================================================


def test_symlink_skip_cycle_safe() raises:
    var root = _disk_root(String("t2"))
    _build_tree(root)
    var d = root + String("/dir")
    # A directory symlink forming a cycle: dir/loop -> dir.
    _sh(String("ln -s '") + d + String("' '") + d + String("/loop'"))
    # A file symlink: dir/link.parquet -> dir/a.parquet.
    _sh(
        String("ln -s '") + d + String("/a.parquet' '")
        + d + String("/link.parquet'")
    )
    var fs = _Fs.new()
    var files = fs.list(d)
    # Still EXACTLY the 3 real regular files: the directory symlink was not
    # followed (no infinite recursion, no duplicated subtree), and the file
    # symlink was not emitted as a regular file.
    assert_equal(len(files), 3)
    assert_false(_has_suffix(files, String("/link.parquet")))
    # The cycle did not duplicate a.parquet via dir/loop/a.parquet etc.
    assert_equal(_count_suffix(files, String("/a.parquet")), 1)
    _sh(String("rm -rf '") + root + String("'"))


# =============================================================================
# T3 — a non-directory prefix lists nothing (matches object-store semantics).
# =============================================================================


def test_non_directory_prefix_is_empty() raises:
    var root = _disk_root(String("t3"))
    _build_tree(root)
    var fs = _Fs.new()
    # A path that names a regular file, not a directory.
    var file_path = root + String("/dir/a.parquet")
    var listed_file = fs.list(file_path)
    assert_equal(len(listed_file), 0)
    # A path that does not exist at all.
    var missing = root + String("/dir/does_not_exist")
    var listed_missing = fs.list(missing)
    assert_equal(len(listed_missing), 0)
    _sh(String("rm -rf '") + root + String("'"))


# =============================================================================
# T4 — e2e recursive glob discovery: dir/**/*.parquet -> all 3 paths, sorted.
# =============================================================================


def test_e2e_recursive_glob_discovery() raises:
    var root = _disk_root(String("t4"))
    _build_tree(root)
    var fs = _Fs.new()
    var spec = root + String("/dir/**/*.parquet")
    var disc = EagerGlobDiscovery.open(fs, spec)
    assert_equal(disc.num_paths(), 3)
    # Collect + verify the 3 expected files are present.
    var got = List[String]()
    for i in range(disc.num_paths()):
        got.append(disc.path_at(i))
    assert_true(_has_suffix(got, String("/dir/a.parquet")))
    assert_true(_has_suffix(got, String("/dir/sub/b.parquet")))
    assert_true(_has_suffix(got, String("/dir/sub/deep/c.parquet")))
    # Lexically sorted: each path <= the next.
    for i in range(disc.num_paths() - 1):
        assert_true(got[i] <= got[i + 1])
    _sh(String("rm -rf '") + root + String("'"))


# =============================================================================
# T5 — e2e shallow glob: dir/*.parquet matches only the top-level file
#      (`*` does not cross `/`; the recursive list is filtered client-side).
# =============================================================================


def test_e2e_shallow_glob_discovery() raises:
    var root = _disk_root(String("t5"))
    _build_tree(root)
    var fs = _Fs.new()
    var spec = root + String("/dir/*.parquet")
    var disc = EagerGlobDiscovery.open(fs, spec)
    # Only dir/a.parquet matches `dir/*.parquet` — `*` does not cross `/`, so
    # the deeper b.parquet / c.parquet are excluded by glob_match_path even
    # though the recursive list surfaced them as candidates.
    assert_equal(disc.num_paths(), 1)
    assert_true(disc.path_at(0).endswith(String("/dir/a.parquet")))
    _sh(String("rm -rf '") + root + String("'"))


def main() raises:
    test_recursive_walk_all_depths()
    test_symlink_skip_cycle_safe()
    test_non_directory_prefix_is_empty()
    test_e2e_recursive_glob_discovery()
    test_e2e_shallow_glob_discovery()
    print("test_local_fs_list_recursive: ALL PASS")

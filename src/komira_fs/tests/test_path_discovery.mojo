# =============================================================================
# test_path_discovery.mojo
# =============================================================================
# Smoke test for `PathDiscovery` (concrete struct, format-
# agnostic file-path discovery). Covers:
#
#   * open_paths(paths) — explicit-list ctor; num_paths + path_at parity.
#   * open(fs, path_spec) — auto-detect single-file mode against /tmp
#     existence + LocalFs.is_dir.
#   * Empty-list shape — open_paths([]) yields num_paths == 0.

# =============================================================================

from std.ffi import external_call
from std.testing import assert_equal, assert_true

from komira_runtime_paths import test_tmpdir
from komira_fs.local_fs import LocalFs
from komira_fs.path_discovery import PathDiscovery
from komira_async.ops.waker_sink import NoopSink


# ---------------------------------------------------------------------------
# ⚠ $TEST_TMPDIR, NOT A HARD-CODED `/tmp` PATH.
#
# A fixed `/tmp` path is shared by every concurrent execution of this test on
# one worker; the runner's private `TEST_TMPDIR` (read through
# `komira_runtime_paths.test_tmpdir`) keeps them disjoint.
# ---------------------------------------------------------------------------
def _scratch_dir() raises -> String:
    """The directory THIS execution may write scratch files into."""
    return test_tmpdir()


def _empty_dir(tag: String) raises -> String:
    """Create a fresh EMPTY directory under the runner's private
    test temp dir (NOT a /tmp tmpfs) and return its path. Post-
    `LocalFs.list` does a real recursive walk, so directory-mode discovery
    tests must use a known-empty dir rather than the (formerly stubbed) /tmp."""
    var base = test_tmpdir()
    var pid = external_call["getpid", Int32]()
    var d = base + String("/pathdisc_empty_") + tag + String("_") + String(Int(pid))
    var rm = String("rm -rf '") + d + String("'")
    var rm_l = rm
    _ = external_call["system", Int32](rm_l.as_c_string_slice().unsafe_ptr())
    var mk = String("mkdir -p '") + d + String("'")
    var mk_l = mk
    var rc = external_call["system", Int32](
        mk_l.as_c_string_slice().unsafe_ptr()
    )
    if Int(rc) != 0:
        raise Error("_empty_dir: mkdir failed for " + d)
    return d


def test_open_paths_single() raises:
    """open_paths([one]) yields num_paths == 1; path_at(0) round-trips."""
    var paths = List[String]()
    paths.append((_scratch_dir() + String("/a.parquet")))
    var disc = PathDiscovery.open_paths(paths)
    assert_equal(disc.num_paths(), 1)
    assert_equal(disc.path_at(0), (_scratch_dir() + String("/a.parquet")))


def test_open_paths_multi() raises:
    """open_paths([three]) yields num_paths == 3; path_at returns each."""
    var paths = List[String]()
    paths.append((_scratch_dir() + String("/a.parquet")))
    paths.append((_scratch_dir() + String("/b.parquet")))
    paths.append((_scratch_dir() + String("/c.parquet")))
    var disc = PathDiscovery.open_paths(paths)
    assert_equal(disc.num_paths(), 3)
    assert_equal(disc.path_at(0), (_scratch_dir() + String("/a.parquet")))
    assert_equal(disc.path_at(1), (_scratch_dir() + String("/b.parquet")))
    assert_equal(disc.path_at(2), (_scratch_dir() + String("/c.parquet")))


def test_open_paths_empty() raises:
    """open_paths([]) yields num_paths == 0."""
    var paths = List[String]()
    var disc = PathDiscovery.open_paths(paths)
    assert_equal(disc.num_paths(), 0)


def test_open_via_fs_directory() raises:
    """open(fs, <empty dir>) auto-detects directory mode; populates from
    fs.list. Post- `LocalFs.list` does a real recursive walk, so we use a
    freshly-created EMPTY directory — the directory branch fires
    (is_dir==True) and the (genuinely empty) listing yields num_paths==0."""
    var d = _empty_dir(String("dir"))
    var fs = LocalFs[NoopSink].new()
    var disc = PathDiscovery.open(fs, d)
    assert_equal(disc.num_paths(), 0)


def test_local_fs_is_dir() raises:
    """LocalFs.is_dir('/tmp') returns True; arbitrary nonexistent path
    raises (caller decides handling)."""
    var fs = LocalFs[NoopSink].new()
    assert_true(fs.is_dir(_scratch_dir()))


def test_local_fs_file_size_existing() raises:
    """LocalFs.file_size against /etc/hosts returns >= 1 byte. This
    validates the FFI plumbing (fopen+SEEK_END+ftell) without
    requiring a fixture under repo control.

    /etc/hosts is the universally-present POSIX networking-stack
    file: present on Linux, macOS (Darwin), and every BSD. This
    test previously used /etc/hostname which is Linux-only — Mac
    uses scutil/sysctl for hostname instead, and /etc/hostname is
    absent.
    """
    var fs = LocalFs[NoopSink].new()
    var size = fs.file_size(String("/etc/hosts"))
    assert_true(size >= 1)


def main() raises:
    test_open_paths_single()
    test_open_paths_multi()
    test_open_paths_empty()
    test_open_via_fs_directory()
    test_local_fs_is_dir()
    test_local_fs_file_size_existing()
    print(
        "test_path_discovery.mojo PASS",
        " (PathDiscovery + LocalFs.is_dir/file_size)",
    )

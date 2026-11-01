# =============================================================================
# test_local_disk_spill_storage.mojo: `LocalDiskSpillStorage` directory
# lifecycle.
# =============================================================================
#
# What each test proves:
#   1. test_root_with_quote_and_space: the storage creates a root whose name
#      holds a single quote and a space (and its missing parents), round-trips
#      a chunk through it, and `cleanup` removes the root. Defect caught: a
#      root created through a shell command (`mkdir -p '<root>'`), where the
#      quote ends the shell word and the directory is never created as named.
#   2. test_cleanup_keeps_a_non_empty_root: `cleanup` releases every live
#      chunk, and a root that still holds a file it does not own is left in
#      place without raising (the removal is best-effort).
# =============================================================================

from std.ffi import external_call
from std.os import makedirs, rmdir
from std.os.path import exists, isdir

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_libc.posix import _read_env

from komira_engine_runtime.spill.local_disk import LocalDiskSpillStorage


# Scratch files go under $TEST_TMPDIR (set by the test runner, unique per
# action), else $TMPDIR. `_read_env` rather than `std.os.getenv`:
# komira_libc.posix owns the one `getenv` declaration in the link.
def _scratch_dir() raises -> String:
    var d = _read_env("TEST_TMPDIR")
    if d.byte_length() == 0:
        d = _read_env("TMPDIR")
    if d.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    return d


def _unique(tag: String) raises -> String:
    var pid = external_call["getpid", Int32]()
    return (
        _scratch_dir()
        + String("/komira-local-disk-spill-")
        + String(Int(pid))
        + String("-")
        + tag
    )


def _make_buf(a: Int, b: Int, c: Int) -> SharedAlignedBuffer[HeapRegion]:
    var oab = OwnedAlignedBuffer(capacity=3)
    var view = oab.view_mut()
    view.write_u8_at(0, UInt8(a))
    view.write_u8_at(1, UInt8(b))
    view.write_u8_at(2, UInt8(c))
    return SharedAlignedBuffer[HeapRegion].from_owned(oab^)


def test_root_with_quote_and_space() raises:
    var parent = _unique("quote")
    var root = parent + String("/it's a dir/runs")
    assert_false(exists(parent), "the parent does not exist yet")

    var storage = LocalDiskSpillStorage.with_unlimited(root)
    assert_true(isdir(root), "the root is created exactly as named")

    var id0 = storage.write_chunk(_make_buf(7, 8, 9))
    var back = storage.read_chunk(id0)
    var view = back.as_view()
    assert_equal(view.len(), 3)
    assert_equal(Int(view.read_u8_at(0)), 7)
    assert_equal(Int(view.read_u8_at(2)), 9)

    storage.cleanup()
    assert_equal(storage.num_live_chunks(), 0)
    assert_false(exists(root), "cleanup removes the emptied root")


def test_cleanup_keeps_a_non_empty_root() raises:
    var root = _unique("nonempty")
    var storage = LocalDiskSpillStorage.with_unlimited(root)
    _ = storage.write_chunk(_make_buf(1, 2, 3))
    var stray = root + String("/not-a-chunk")
    makedirs(stray, exist_ok=True)

    storage.cleanup()
    assert_equal(storage.num_live_chunks(), 0)
    assert_true(isdir(root), "a root holding other entries is kept")
    rmdir(stray)


def main() raises:
    var suite = TestSuite()
    suite.test[test_root_with_quote_and_space]()
    suite.test[test_cleanup_keeps_a_non_empty_root]()
    suite^.run()

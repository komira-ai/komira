# =============================================================================
# MmapRegion.open_readonly refusals past a successful open(): a zero-length
# file (refused before mmap), and a directory (open and fstat succeed, mmap
# fails). whole_file_map_count counts a successful mapping and neither
# refusal.
# =============================================================================

from std.os import mkdir, remove, rmdir
from std.os.path import exists
from std.tempfile import mkdtemp
from std.testing import TestSuite, assert_equal, assert_true

from komira_buffer.file_identity import FileIdentity
from komira_buffer.mmap_region import MmapRegion


def _write(path: String, text: String) raises:
    with open(path, "w") as f:
        f.write(text)


def _open_error(path: String) -> String:
    try:
        var r = MmapRegion.open_readonly(path)
        _ = r^
    except e:
        return String(e)
    return String("no error")


def test_zero_length_file_is_refused() raises:
    """An empty file raises naming the zero length and the path, and maps
    nothing."""
    var dir = mkdtemp()
    var path = dir + "/empty.bin"
    try:
        _write(path, "")
        var before = MmapRegion.whole_file_map_count()
        var msg = _open_error(path)
        assert_true("zero-length file" in msg, msg)
        assert_true(path in msg, msg)
        assert_true("file_size=0" in msg, msg)
        assert_equal(MmapRegion.whole_file_map_count(), before)
    finally:
        if exists(path):
            remove(path)
        rmdir(dir)


def test_directory_fails_at_mmap() raises:
    """A directory opens read-only and has a non-zero size (it holds an
    entry; checked first, since that depends on the filesystem), but cannot
    be mapped: the refusal is the mmap one, naming the
    path, and nothing is counted."""
    var dir = mkdtemp()
    var sub = dir + "/d"
    var inner = sub + "/entry.txt"
    try:
        mkdir(sub)
        _write(inner, "x")
        # The test reaches the mmap refusal only if the directory's st_size
        # is non-zero (ext4, xfs, btrfs and tmpfs report one for a directory
        # with an entry). A filesystem reporting 0 would take the zero-length
        # refusal instead; say so here rather than fail on the message below.
        var dir_size = FileIdentity.stat_path(sub).size
        assert_true(
            dir_size > 0,
            "precondition: this filesystem reports st_size "
            + String(dir_size)
            + " for a directory with an entry, so open_readonly refuses it"
            " as zero-length before mmap; run the test on a filesystem that"
            " reports a directory size",
        )
        var before = MmapRegion.whole_file_map_count()
        var msg = _open_error(sub)
        assert_true("mmap() failed" in msg, msg)
        assert_true(sub in msg, msg)
        assert_equal(MmapRegion.whole_file_map_count(), before)
    finally:
        if exists(inner):
            remove(inner)
        if exists(sub):
            rmdir(sub)
        rmdir(dir)


def test_whole_file_map_count_counts_each_mapping() raises:
    """Each successful open_readonly adds exactly one, whichever advice
    form it uses."""
    var dir = mkdtemp()
    var path = dir + "/data.bin"
    try:
        _write(path, "0123456789")
        var before = MmapRegion.whole_file_map_count()
        var r = MmapRegion.open_readonly(path)
        assert_equal(r.len(), 10)
        assert_equal(MmapRegion.whole_file_map_count(), before + 1)
        var r2 = MmapRegion.open_readonly(path, advise_whole_file=False)
        assert_equal(MmapRegion.whole_file_map_count(), before + 2)
        _ = r^
        _ = r2^
    finally:
        if exists(path):
            remove(path)
        rmdir(dir)


def main() raises:
    var s = TestSuite()
    s.test[test_zero_length_file_is_refused]()
    s.test[test_directory_fails_at_mmap]()
    s.test[test_whole_file_map_count_counts_each_mapping]()
    s^.run()

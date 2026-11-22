# =============================================================================
# tests/test_atomic_write.mojo
#   write_file_atomic: the destination is the whole new file or unchanged.
# =============================================================================
#
# Every test works in its own directory under test_tmpdir() and lists that
# directory afterwards, so a temporary file left behind fails the test.
# Failures of the steps a test cannot force on a real disk (no space, an I/O
# error at fsync, close, rename or the directory sync, no random source) are
# injected through the shim's test seam, `komira_fs_test_inject_write_failure`,
# which each test clears before it asserts.
#
# What each test proves:
#   * test_a_new_file_holds_the_bytes: a missing destination is created with
#     exactly the bytes, and only it is in the directory.
#   * test_an_existing_file_is_replaced: the old content is gone, the new one
#     is whole, no temporary file stays.
#   * test_no_bytes_write_an_empty_file: an empty span gives a file of size 0.
#   * test_a_relative_path_resolves_against_the_working_directory: a bare name
#     is written in the working directory.
#   * test_a_missing_directory_is_storage_not_found: the full message, and
#     nothing is created (the parent is not made).
#   * test_a_file_as_the_parent_is_storage_io_at_create: ENOTDIR at the create
#     step, by exact message.
#   * test_a_directory_at_the_path_is_storage_io_at_rename: the rename fails
#     with EISDIR, the directory stays and the temporary file is removed.
#   * test_a_full_disk_leaves_the_old_file_whole: an injected ENOSPC after
#     half the bytes leaves the old destination byte-identical and no
#     temporary file; the same for no destination at all.
#   * test_each_failing_step_is_named_and_cleaned_up: create, fsync, close and
#     rename failures each name their step and errno, leave the old file and
#     leave no temporary file; a failing random source is named.
#   * test_a_failed_directory_sync_reports_after_the_rename: the new file is in
#     place and the failure is still reported.
#   * test_split_path: the prefix, name and directory of `a/b/c`, `/c` and `c`.
# =============================================================================

from std.ffi import external_call
from std.os import listdir, makedirs
from std.testing import TestSuite, assert_equal, assert_true

from fs.atomic_write import (
    STORAGE_IO,
    STORAGE_NOT_FOUND,
    _split_path,
    write_file_atomic,
)
from runtime_paths import test_tmpdir

# KOMIRA_FS_INJECT_* in _fs_shim.c.
comptime _NONE: Int32 = 0
comptime _CREATE: Int32 = 1
comptime _WRITE: Int32 = 2
comptime _FSYNC: Int32 = 3
comptime _CLOSE: Int32 = 4
comptime _RENAME: Int32 = 5
comptime _FSYNC_DIR: Int32 = 6
comptime _RANDOM: Int32 = 7


def _inject(op: Int32):
    external_call["komira_fs_test_inject_write_failure", NoneType](op)


def _dir(name: String) raises -> String:
    var d = test_tmpdir() + "/atomic_" + name
    makedirs(d, exist_ok=True)
    return d^


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var bs = s.as_bytes()
    for i in range(len(bs)):
        out.append(bs[i])
    return out^


def _read(path: String) raises -> String:
    with open(path, "r") as f:
        return f.read()


def _put(path: String, text: String) raises:
    with open(path, "w") as f:
        f.write(text)


def _entries(dir: String) raises -> List[String]:
    var names = listdir(dir)
    sort(names)
    return names^


def _assert_only(dir: String, want: List[String]) raises:
    var got = _entries(dir)
    assert_equal(len(got), len(want), "entries of " + dir)
    for i in range(len(want)):
        assert_equal(got[i], want[i])


def _failure(path: String, data: List[UInt8], op: Int32) raises -> String:
    """The message `write_file_atomic` raises with step `op` failing; fails
    the test when it does not raise."""
    _inject(op)
    var msg = String("")
    try:
        write_file_atomic(path, Span(data))
    except e:
        msg = String(e)
    _inject(_NONE)
    assert_true(msg != "", "the write did not fail")
    return msg^


def test_a_new_file_holds_the_bytes() raises:
    var d = _dir("new")
    write_file_atomic(d + "/out.bin", Span(_bytes("hello, parquet")))
    assert_equal(_read(d + "/out.bin"), "hello, parquet")
    _assert_only(d, ["out.bin"])


def test_an_existing_file_is_replaced() raises:
    var d = _dir("replace")
    _put(d + "/out.bin", "the old content, longer than the new")
    write_file_atomic(d + "/out.bin", Span(_bytes("new")))
    assert_equal(_read(d + "/out.bin"), "new")
    _assert_only(d, ["out.bin"])


def test_no_bytes_write_an_empty_file() raises:
    var d = _dir("empty")
    write_file_atomic(d + "/out.bin", Span(List[UInt8]()))
    assert_equal(_read(d + "/out.bin"), "")
    _assert_only(d, ["out.bin"])


def test_a_relative_path_resolves_against_the_working_directory() raises:
    var d = _dir("relative")
    var c = d.copy()
    # SAFETY: `c` is a local that outlives the call; chdir copies the path.
    assert_equal(external_call["chdir", Int32](c.as_c_string_slice().unsafe_ptr()), 0)
    write_file_atomic("rel.bin", Span(_bytes("here")))
    var back = test_tmpdir()
    # SAFETY: as above.
    assert_equal(
        external_call["chdir", Int32](back.as_c_string_slice().unsafe_ptr()), 0
    )
    assert_equal(_read(d + "/rel.bin"), "here")
    _assert_only(d, ["rel.bin"])


def test_a_missing_directory_is_storage_not_found() raises:
    var d = _dir("missing")
    var path = d + "/no_such_dir/out.bin"
    var msg = _failure(path, _bytes("x"), _NONE)
    assert_equal(
        msg,
        String(STORAGE_NOT_FOUND) + ": write '" + path + "': the directory '"
        + d + "/no_such_dir' does not exist",
    )
    _assert_only(d, List[String]())


def test_a_file_as_the_parent_is_storage_io_at_create() raises:
    var d = _dir("file_parent")
    _put(d + "/plain", "a file")
    var path = d + "/plain/out.bin"
    assert_equal(
        _failure(path, _bytes("x"), _NONE),
        String(STORAGE_IO) + ": write '" + path
        + "': create of the temporary file failed: errno 20 (ENOTDIR)",
    )
    _assert_only(d, ["plain"])


def test_a_directory_at_the_path_is_storage_io_at_rename() raises:
    var d = _dir("dir_at_path")
    makedirs(d + "/out.parquet", exist_ok=True)
    var path = d + "/out.parquet"
    assert_equal(
        _failure(path, _bytes("x"), _NONE),
        String(STORAGE_IO) + ": write '" + path
        + "': rename failed: errno 21 (EISDIR)",
    )
    _assert_only(d, ["out.parquet"])
    _assert_only(d + "/out.parquet", List[String]())


def test_a_full_disk_leaves_the_old_file_whole() raises:
    var d = _dir("full")
    var path = d + "/out.bin"
    _put(path, "old")
    assert_equal(
        _failure(path, _bytes("0123456789"), _WRITE),
        String(STORAGE_IO) + ": write '" + path
        + "': write failed: errno 28 (ENOSPC)",
    )
    assert_equal(_read(path), "old")
    _assert_only(d, ["out.bin"])
    # With no old file, nothing is left at all.
    var fresh = d + "/fresh.bin"
    _ = _failure(fresh, _bytes("0123456789"), _WRITE)
    _assert_only(d, ["out.bin"])


def test_each_failing_step_is_named_and_cleaned_up() raises:
    var d = _dir("steps")
    var path = d + "/out.bin"
    _put(path, "old")
    var head = String(STORAGE_IO) + ": write '" + path + "': "
    assert_equal(
        _failure(path, _bytes("new"), _CREATE),
        head + "create of the temporary file failed: errno 5 (EIO)",
    )
    assert_equal(_failure(path, _bytes("new"), _FSYNC), head + "fsync failed: errno 5 (EIO)")
    assert_equal(_failure(path, _bytes("new"), _CLOSE), head + "close failed: errno 5 (EIO)")
    assert_equal(_failure(path, _bytes("new"), _RENAME), head + "rename failed: errno 5 (EIO)")
    assert_equal(_read(path), "old")
    _assert_only(d, ["out.bin"])
    assert_equal(
        _failure(path, _bytes("new"), _RANDOM),
        String(STORAGE_IO) + ": no random name for a temporary file: errno 5 (EIO)",
    )
    assert_equal(_read(path), "old")
    _assert_only(d, ["out.bin"])


def test_a_failed_directory_sync_reports_after_the_rename() raises:
    var d = _dir("dirsync")
    var path = d + "/out.bin"
    _put(path, "old")
    assert_equal(
        _failure(path, _bytes("new"), _FSYNC_DIR),
        String(STORAGE_IO) + ": write '" + path
        + "': fsync of the directory failed: errno 5 (EIO)",
    )
    assert_equal(_read(path), "new")
    _assert_only(d, ["out.bin"])


def test_split_path() raises:
    var a = _split_path("a/b/c")
    assert_equal(a[0], "a/b/")
    assert_equal(a[1], "c")
    assert_equal(a[2], "a/b")
    var r = _split_path("/c")
    assert_equal(r[0], "/")
    assert_equal(r[1], "c")
    assert_equal(r[2], "/")
    var b = _split_path("c")
    assert_equal(b[0], "")
    assert_equal(b[1], "c")
    assert_equal(b[2], ".")


def main() raises:
    var suite = TestSuite()
    suite.test[test_a_new_file_holds_the_bytes]()
    suite.test[test_an_existing_file_is_replaced]()
    suite.test[test_no_bytes_write_an_empty_file]()
    suite.test[test_a_relative_path_resolves_against_the_working_directory]()
    suite.test[test_a_missing_directory_is_storage_not_found]()
    suite.test[test_a_file_as_the_parent_is_storage_io_at_create]()
    suite.test[test_a_directory_at_the_path_is_storage_io_at_rename]()
    suite.test[test_a_full_disk_leaves_the_old_file_whole]()
    suite.test[test_each_failing_step_is_named_and_cleaned_up]()
    suite.test[test_a_failed_directory_sync_reports_after_the_rename]()
    suite.test[test_split_path]()
    suite^.run()

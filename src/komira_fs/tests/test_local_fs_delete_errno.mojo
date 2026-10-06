# =============================================================================
# tests/test_local_fs_delete_errno.mojo
#   LocalFs.delete reads remove(3)'s own errno: only ENOENT is "already gone".
# =============================================================================
#
# THE DEFECT THIS CATCHES. LocalFs.delete ignored remove(3)'s errno and fell
# back to an existence probe, so a failed delete raised a message naming no
# errno ("remove(3) failed and path still exists (rc=-1)") or, when the probe
# could not see the entry, reported the probe's errno instead of remove's.
#
# WHAT EACH TEST PROVES (forced failure -> expected answer):
#   * controls: deleting a regular file and an EMPTY directory succeeds and
#     the entry is gone; deleting a missing path succeeds (ENOENT is an
#     idempotent delete).
#   * ENOTEMPTY: deleting a non-empty directory raises `cannot remove
#     '<path>': errno N (ENOTEMPTY)` (EEXIST is accepted: POSIX lets rmdir
#     report either). Forceable for any user.
#   * ENOTDIR: deleting a path below a regular file raises naming ENOTDIR.
#   * ELOOP: deleting a path below a self-referencing symlink raises naming
#     ELOOP.
#   * EACCES: a file in a directory without write permission; forceable only
#     unprivileged (probed with access(W_OK); the test prints which branch
#     ran). Privileged, it asserts the delete succeeds. EROFS needs a
#     read-only mount and is not forced.
# =============================================================================

from std.ffi import external_call
from std.testing import assert_equal, assert_false, assert_true

from komira_runtime_paths import test_tmpdir
from komira_fs.local_fs import LocalFs
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
    var root = base + String("/del_") + tag + String("_") + String(Int(pid))
    _sh(String("rm -rf '") + root + String("'"))
    _sh(String("mkdir -p '") + root + String("'"))
    return root


def _access(path: String, mode: Int32) -> Bool:
    var p = path
    # SAFETY: `p` pins the NUL-terminated path across the synchronous call.
    var rc = external_call["access", Int32](
        p.as_c_string_slice().unsafe_ptr(), mode
    )
    return rc == 0


def _err_delete(path: String) -> String:
    var fs = _Fs.new()
    try:
        fs.delete(path)
        return String("")
    except e:
        return String(e)


def _assert_remove_error(msg: String, names: List[String], path: String) raises:
    assert_true(msg.byte_length() > 0, "expected a raised error, got success")
    assert_true(
        msg.find("cannot remove '" + path + "'") >= 0,
        "not a remove error naming the path: " + msg,
    )
    var named = False
    for i in range(len(names)):
        if msg.find(names[i]) >= 0:
            named = True
    assert_true(named, "errno not named: " + msg)


def test_controls_succeed() raises:
    var root = _disk_root(String("ctl"))
    _sh(String("printf 'A' > '") + root + String("/f'"))
    _sh(String("mkdir '") + root + String("/empty'"))
    assert_equal(_err_delete(root + "/f"), String(""))
    assert_false(_access(root + "/f", Int32(0)), "file still present")
    assert_equal(_err_delete(root + "/empty"), String(""))
    assert_false(_access(root + "/empty", Int32(0)), "dir still present")
    assert_equal(_err_delete(root + "/missing"), String(""))
    _sh(String("rm -rf '") + root + String("'"))


def test_non_empty_directory_raises_enotempty() raises:
    var root = _disk_root(String("enotempty"))
    var d = root + String("/d")
    _sh(String("mkdir '") + d + String("'"))
    _sh(String("printf 'A' > '") + d + String("/inner'"))
    _assert_remove_error(
        _err_delete(d), [String("ENOTEMPTY"), String("EEXIST")], d
    )
    assert_true(_access(d + "/inner", Int32(0)), "content was removed")
    _sh(String("rm -rf '") + root + String("'"))


def test_path_under_file_raises_enotdir() raises:
    var root = _disk_root(String("enotdir"))
    _sh(String("printf 'A' > '") + root + String("/f'"))
    var p = root + String("/f/x")
    _assert_remove_error(_err_delete(p), [String("ENOTDIR")], p)
    _sh(String("rm -rf '") + root + String("'"))


def test_path_under_loop_raises_eloop() raises:
    var root = _disk_root(String("eloop"))
    var loop = root + String("/loop")
    _sh(String("ln -s '") + loop + String("' '") + loop + String("'"))
    var p = loop + String("/x")
    _assert_remove_error(_err_delete(p), [String("ELOOP")], p)
    _sh(String("rm -rf '") + root + String("'"))


def test_unwritable_parent_raises_eacces() raises:
    var root = _disk_root(String("eacces"))
    var d = root + String("/ro")
    _sh(String("mkdir '") + d + String("'"))
    _sh(String("printf 'A' > '") + d + String("/f'"))
    _sh(String("chmod 555 '") + d + String("'"))
    try:
        if _access(d, Int32(2)):
            print(
                "[test_local_fs_delete_errno] EACCES NOT FORCEABLE: the"
                " process is privileged (mode 555 still writable); asserting"
                " the delete succeeds instead"
            )
            assert_equal(_err_delete(d + "/f"), String(""))
        else:
            print("[test_local_fs_delete_errno] EACCES forced (unprivileged)")
            _assert_remove_error(
                _err_delete(d + "/f"), [String("EACCES"), String("EPERM")],
                d + "/f",
            )
    finally:
        _sh(String("chmod 755 '") + d + String("'"))
        _sh(String("rm -rf '") + root + String("'"))


def main() raises:
    var failures = 0
    try:
        test_unwritable_parent_raises_eacces()
        print("PASS test_unwritable_parent_raises_eacces")
    except e:
        failures += 1
        print("FAIL test_unwritable_parent_raises_eacces:", String(e))
    try:
        test_controls_succeed()
        print("PASS test_controls_succeed")
    except e:
        failures += 1
        print("FAIL test_controls_succeed:", String(e))
    try:
        test_non_empty_directory_raises_enotempty()
        print("PASS test_non_empty_directory_raises_enotempty")
    except e:
        failures += 1
        print("FAIL test_non_empty_directory_raises_enotempty:", String(e))
    try:
        test_path_under_file_raises_enotdir()
        print("PASS test_path_under_file_raises_enotdir")
    except e:
        failures += 1
        print("FAIL test_path_under_file_raises_enotdir:", String(e))
    try:
        test_path_under_loop_raises_eloop()
        print("PASS test_path_under_loop_raises_eloop")
    except e:
        failures += 1
        print("FAIL test_path_under_loop_raises_eloop:", String(e))
    if failures > 0:
        raise Error(
            "[test_local_fs_delete_errno] " + String(failures)
            + " test(s) FAILED"
        )
    print("[test_local_fs_delete_errno] all 5 tests PASS")

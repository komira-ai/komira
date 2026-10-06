# =============================================================================
# tests/test_local_fs_store_list_dir_errno.mojo
#   LocalFsConditionalStore's directory listing: only ENOENT lists empty.
# =============================================================================
#
# `_list_dir_fnames` lists the store root through komira_fs's
# `komira_list_dir_shallow` shim. That shim used to answer an EMPTY listing
# whenever opendir failed, so a root that exists but cannot be opened listed
# as an empty store (manifest recovery by LIST then saw no chunks).
#
#   * control: a missing directory lists empty (ENOENT keeps its answer), and
#     a real directory lists its regular files.
#   * ENOTDIR (a path below a regular file, forceable for any user): the
#     listing must raise an error naming ENOTDIR and the path.
#   * ELOOP (a symlink to itself, forceable for any user): same, naming ELOOP.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true
from std.time import perf_counter_ns

from komira_objectstore.local_fs_conditional_store import (
    LocalFsConditionalStore,
    _list_dir_fnames,
)
from komira_objectstore.path import Path
from komira_runtime_paths import test_tmpdir
from std.ffi import external_call


def _err_list(dir: String) -> String:
    try:
        var names = _list_dir_fnames(dir)
        return String("<listed ") + String(len(names)) + ">"
    except e:
        return String(e)


def _assert_real_error(msg: String, errno_name: String, path: String) raises:
    assert_true(msg.byte_length() > 0, "expected a raised error")
    assert_true(msg.find(errno_name) >= 0, "errno not named: " + msg)
    assert_true(msg.find(path) >= 0, "path not named: " + msg)
    assert_false(msg.find("not_found") >= 0, "reads as not-found: " + msg)


def main() raises:
    var root = (
        test_tmpdir() + String("/komira_store_listdir_")
        + String(UInt64(perf_counter_ns()))
    )
    var store = LocalFsConditionalStore(root.copy())
    var payload = List[UInt8]()
    payload.append(UInt8(65))
    _ = store.put(Path.parse(String("f")), payload^)

    # Control: a real directory lists its file; a missing one lists empty.
    assert_equal(_err_list(root), String("<listed 1>"))
    assert_equal(_err_list(root + "/missing"), String("<listed 0>"))

    # ENOTDIR: below the regular file `<root>/f`.
    var p = root + "/f/x"
    _assert_real_error(_err_list(p), String("ENOTDIR"), p)

    # ELOOP: a self-referencing symlink.
    var loop = root + "/loop"
    var l = loop
    var t = loop
    # SAFETY: `t`/`l` pin both NUL-terminated paths across the synchronous call.
    var rc = external_call["symlink", Int32](
        t.as_c_string_slice().unsafe_ptr(), l.as_c_string_slice().unsafe_ptr()
    )
    assert_equal(Int(rc), 0)
    _assert_real_error(_err_list(loop), String("ELOOP"), loop)
    print("[test_local_fs_store_list_dir_errno] PASS")

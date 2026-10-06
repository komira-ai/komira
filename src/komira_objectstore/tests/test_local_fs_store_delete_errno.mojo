# =============================================================================
# tests/test_local_fs_store_delete_errno.mojo
#   LocalFsConditionalStore.delete: only ENOENT is "already gone".
# =============================================================================
#
# delete used to swallow every remove(3) failure, so a key that could not be
# deleted reported success (a reaper then believed the object was gone).
#
#   * controls: deleting an existing key removes it (get is then not_found);
#     deleting a missing key succeeds (S3 semantics).
#   * ENOTEMPTY: the key's path is a non-empty directory -> raises naming
#     ENOTEMPTY (or EEXIST) and the path, and nothing reads as not_found.
#   * ENOTDIR: the store root is a regular file -> raises naming ENOTDIR.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true
from std.time import perf_counter_ns

from komira_objectstore.local_fs_conditional_store import (
    LocalFsConditionalStore,
)
from komira_objectstore.path import Path
from komira_runtime_paths import test_tmpdir


def _err_delete(store: LocalFsConditionalStore, key: String) -> String:
    try:
        store.delete(Path.parse(key))
        return String("")
    except e:
        return String(e)


def _one_byte() -> List[UInt8]:
    var b = List[UInt8]()
    b.append(UInt8(65))
    return b^


def _assert_remove_error(msg: String, a: String, b: String, path: String) raises:
    assert_true(msg.byte_length() > 0, "expected a raised error, got success")
    assert_true(msg.find(a) >= 0 or msg.find(b) >= 0, "errno not named: " + msg)
    assert_true(msg.find(path) >= 0, "path not named: " + msg)
    assert_false(msg.find("not_found") >= 0, "reads as not-found: " + msg)
    assert_false(msg.find("precondition") >= 0, "reads as a 412: " + msg)


def main() raises:
    var root = (
        test_tmpdir() + String("/komira_store_del_")
        + String(UInt64(perf_counter_ns()))
    )
    var store = LocalFsConditionalStore(root.copy())

    # Controls.
    _ = store.put(Path.parse(String("k")), _one_byte())
    assert_equal(_err_delete(store, String("k")), String(""))
    var gone = False
    try:
        _ = store.get(Path.parse(String("k")))
    except e:
        gone = String(e).find("not_found") >= 0
    assert_true(gone, "deleted key still readable")
    assert_equal(_err_delete(store, String("missing")), String(""))

    # ENOTEMPTY: `<root>/d` is a non-empty directory (a store rooted there).
    var inner = LocalFsConditionalStore(root + "/d")
    _ = inner.put(Path.parse(String("x")), _one_byte())
    _assert_remove_error(
        _err_delete(store, String("d")), String("ENOTEMPTY"), String("EEXIST"),
        root + "/d",
    )

    # ENOTDIR: a store whose root is the regular file `<root>/f`.
    _ = store.put(Path.parse(String("f")), _one_byte())
    var bad = LocalFsConditionalStore(root + "/f", True)
    _assert_remove_error(
        _err_delete(bad, String("k")), String("ENOTDIR"), String("ENOTDIR"),
        root + "/f/k",
    )
    print("[test_local_fs_store_delete_errno] PASS")

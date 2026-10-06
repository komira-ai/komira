# =============================================================================
# tests/test_local_fs_read_errno.mojo
#   LocalFsConditionalStore: only ENOENT is "not found".
# =============================================================================
#
# THE DEFECT THIS CATCHES. The store read every failure to open an object file
# as "not_found (404)". A file that EXISTS but cannot be read (EACCES, EMFILE,
# EIO, a store root that is not a directory, ...) was reported as absent, and a
# caller that treats absence as a normal state (manifest recovery, an If-Match
# precondition check, a listing) silently dropped or overwrote data.
#
# WHAT EACH TEST PROVES (and which failure it forces):
#   * missing key / missing root (ENOENT): still not-found on get, head and
#     get_range; If-Match on it is still a 412; a missing root lists empty.
#     Catches an over-correction that turns real absence into an error.
#   * ENOTDIR: the store root is a REGULAR FILE, so opening `<root>/<key>`
#     fails with ENOTDIR. Every verb (get, head, get_range, list, If-Match and
#     create conditional_put) must raise an error that names ENOTDIR and the
#     path, and none of them may read as not-found, as a 412, or as an empty
#     listing. Forceable for any user, root included.
#   * EISDIR: the key's file is a DIRECTORY. get, head, get_range and If-Match
#     must raise an error naming EISDIR. Forceable for any user.
#   * ELOOP: the key's file is a symlink to itself (the directory entry EXISTS
#     but cannot be opened, the root-proof stand-in for EACCES). get, head,
#     get_range, If-Match and create must raise naming ELOOP. Any user.
#   * ENAMETOOLONG: a key whose file name exceeds NAME_MAX. get, head,
#     get_range and create must raise naming ENAMETOOLONG. Any user.
#   * EACCES: the key's file is mode 000. Only forceable when the process is
#     unprivileged (uid 0 bypasses file modes): the test probes with
#     access(R_OK) and prints which branch ran. Privileged, it asserts the read
#     still succeeds (mode 000 is not a failure there).
#
# Every case runs even if an earlier one fails; main() prints each failure and
# raises once at the end, so a red run shows every case's result.
# =============================================================================

from std.ffi import external_call
from std.time import perf_counter_ns

from std.testing import assert_equal, assert_false, assert_true

from komira_objectstore.local_fs_conditional_store import (
    LocalFsConditionalStore,
)
from komira_objectstore.path import Path
from komira_objectstore.types import WritePrecondition
from komira_runtime_paths import test_tmpdir


def _scratch_root(tag: String) raises -> String:
    var t = UInt64(perf_counter_ns())
    return (
        test_tmpdir() + String("/komira_localfs_errno_") + tag + String("_")
        + String(t)
    )


def _bytes_from(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _reads_as_not_found(msg: String) -> Bool:
    """Every needle a not-found classifier in this tree matches on
    (`cas_manifest._is_not_found` and the broker copies)."""
    return (
        msg.find("not_found") >= 0
        or msg.find("NotFound") >= 0
        or msg.find("NoSuchKey") >= 0
        or msg.find("status=404") >= 0
        or msg.find("StoreError[NOT_FOUND]") >= 0
        or msg.find("(404)") >= 0
    )


def _assert_real_error(msg: String, errno_name: String, path: String) raises:
    """`msg` is a raised error (not empty), names the errno and the path, and
    reads as neither not-found nor a precondition (412)."""
    assert_true(msg.byte_length() > 0, "expected a raised error, got success")
    assert_false(
        _reads_as_not_found(msg), "reads as not-found: " + msg
    )
    assert_true(msg.find(errno_name) >= 0, "errno not named: " + msg)
    assert_true(msg.find(path) >= 0, "path not named: " + msg)
    assert_false(msg.find("precondition") >= 0, "reads as a 412: " + msg)


def _err_get(store: LocalFsConditionalStore, key: String) -> String:
    try:
        _ = store.get(Path.parse(key))
    except e:
        return String(e)
    return String("")


def _err_head(store: LocalFsConditionalStore, key: String) -> String:
    try:
        _ = store.head(Path.parse(key))
    except e:
        return String(e)
    return String("")


def _err_get_range(store: LocalFsConditionalStore, key: String) -> String:
    try:
        _ = store.get_range(Path.parse(key), Int64(0), Int64(1))
    except e:
        return String(e)
    return String("")


def _err_list(store: LocalFsConditionalStore) -> String:
    try:
        var res = store.list_with_delimiter(Path.parse(String("")))
        return String("<listed ") + String(len(res.objects)) + " objects>"
    except e:
        return String(e)


def _err_if_match(store: LocalFsConditionalStore, key: String) -> String:
    try:
        _ = store.conditional_put(
            Path.parse(key),
            _bytes_from(String("new")),
            WritePrecondition.if_match(String('"0000000000000000"')),
        )
    except e:
        return String(e)
    return String("")


def _err_create(store: LocalFsConditionalStore, key: String) -> String:
    try:
        _ = store.conditional_put(
            Path.parse(key),
            _bytes_from(String("new")),
            WritePrecondition.if_none_match_star(),
        )
    except e:
        return String(e)
    return String("")


def _chmod(path: String, mode: Int32) raises:
    var p = path
    # SAFETY: `p` pins the NUL-terminated path across the synchronous call.
    var rc = external_call["chmod", Int32](
        p.as_c_string_slice().unsafe_ptr(), mode
    )
    if rc != 0:
        raise Error("test: chmod failed for '" + path + "'")


def _symlink(target: String, link: String) raises:
    var t = target
    var l = link
    # SAFETY: `t`/`l` pin both NUL-terminated paths across the synchronous call.
    var rc = external_call["symlink", Int32](
        t.as_c_string_slice().unsafe_ptr(), l.as_c_string_slice().unsafe_ptr()
    )
    if rc != 0:
        raise Error("test: symlink failed for '" + link + "'")


def _readable(path: String) -> Bool:
    var p = path
    # SAFETY: as `_chmod`. R_OK == 4 on every POSIX platform this builds for.
    var rc = external_call["access", Int32](
        p.as_c_string_slice().unsafe_ptr(), Int32(4)
    )
    return rc == 0


# -----------------------------------------------------------------------------
# Control: real absence stays not-found.
# -----------------------------------------------------------------------------
def test_missing_key_and_missing_root_stay_not_found() raises:
    var root = _scratch_root(String("absent"))
    var store = LocalFsConditionalStore(root.copy())
    assert_true(_reads_as_not_found(_err_get(store, String("nope"))))
    assert_true(_reads_as_not_found(_err_head(store, String("nope"))))
    assert_true(_reads_as_not_found(_err_get_range(store, String("nope"))))
    var m = _err_if_match(store, String("nope"))
    assert_true(m.find("precondition") >= 0, "If-Match on absent: " + m)
    # A root that was never created (the infallible clone-ctor skips mkdir):
    # ENOENT on the root itself is still "absent", and it lists empty.
    var gone = LocalFsConditionalStore(root + "/never_made", True)
    assert_true(_reads_as_not_found(_err_get(gone, String("k"))))
    assert_equal(_err_list(gone), String("<listed 0 objects>"))


# -----------------------------------------------------------------------------
# ENOTDIR: the root is a regular file.
# -----------------------------------------------------------------------------
def test_root_is_a_file_raises_enotdir_on_every_verb() raises:
    var root = _scratch_root(String("enotdir"))
    var store = LocalFsConditionalStore(root.copy())
    _ = store.put(Path.parse(String("blocker")), _bytes_from(String("x")))
    var file_root = root + "/blocker"
    var bad = LocalFsConditionalStore(file_root.copy(), True)
    var p = file_root + "/k"
    var enotdir = String("ENOTDIR")
    _assert_real_error(_err_get(bad, String("k")), enotdir, p)
    _assert_real_error(_err_head(bad, String("k")), enotdir, p)
    _assert_real_error(_err_get_range(bad, String("k")), enotdir, p)
    _assert_real_error(_err_if_match(bad, String("k")), enotdir, p)
    _assert_real_error(_err_create(bad, String("k")), enotdir, p)
    # A listing of a root that is a file is an error, not an empty bucket.
    _assert_real_error(_err_list(bad), enotdir, file_root)


# -----------------------------------------------------------------------------
# EISDIR: the key's file is a directory.
# -----------------------------------------------------------------------------
def test_key_file_is_a_directory_raises_eisdir() raises:
    var root = _scratch_root(String("eisdir"))
    var store = LocalFsConditionalStore(root.copy())
    # A store rooted at `<root>/k` creates the directory `<root>/k`, which is
    # exactly where key "k" of `store` lives.
    _ = LocalFsConditionalStore(root + "/k")
    var p = root + "/k"
    var eisdir = String("EISDIR")
    _assert_real_error(_err_get(store, String("k")), eisdir, p)
    _assert_real_error(_err_head(store, String("k")), eisdir, p)
    _assert_real_error(_err_get_range(store, String("k")), eisdir, p)
    _assert_real_error(_err_if_match(store, String("k")), eisdir, p)


# -----------------------------------------------------------------------------
# ELOOP: the key's file is a self-referencing symlink.
# -----------------------------------------------------------------------------
def test_self_symlink_raises_eloop() raises:
    var root = _scratch_root(String("eloop"))
    var store = LocalFsConditionalStore(root.copy())
    var p = root + "/loop"
    _symlink(p, p)
    var eloop = String("ELOOP")
    _assert_real_error(_err_get(store, String("loop")), eloop, p)
    _assert_real_error(_err_head(store, String("loop")), eloop, p)
    _assert_real_error(_err_get_range(store, String("loop")), eloop, p)
    _assert_real_error(_err_if_match(store, String("loop")), eloop, p)
    _assert_real_error(_err_create(store, String("loop")), eloop, p)


# -----------------------------------------------------------------------------
# ENAMETOOLONG: the key's file name is longer than NAME_MAX.
# -----------------------------------------------------------------------------
def test_overlong_key_raises_enametoolong() raises:
    var root = _scratch_root(String("enametoolong"))
    var store = LocalFsConditionalStore(root.copy())
    var key = String("")
    for _ in range(300):
        key += "a"
    var p = root + "/" + key
    var e = String("ENAMETOOLONG")
    _assert_real_error(_err_get(store, key), e, p)
    _assert_real_error(_err_head(store, key), e, p)
    _assert_real_error(_err_get_range(store, key), e, p)
    _assert_real_error(_err_create(store, key), e, p)


# -----------------------------------------------------------------------------
# EACCES: the key's file is mode 000 (unprivileged processes only).
# -----------------------------------------------------------------------------
def test_unreadable_file_raises_eacces() raises:
    var root = _scratch_root(String("eacces"))
    var store = LocalFsConditionalStore(root.copy())
    var payload = _bytes_from(String("locked bytes"))
    _ = store.put(Path.parse(String("locked")), payload.copy())
    var p = root + "/locked"
    _chmod(p, Int32(0))
    try:
        if _readable(p):
            print(
                "[test_local_fs_read_errno] EACCES NOT FORCEABLE: the process"
                " is privileged (mode 000 still readable); asserting the read"
                " succeeds instead"
            )
            assert_equal(len(store.get(Path.parse(String("locked")))), 12)
        else:
            print("[test_local_fs_read_errno] EACCES forced (unprivileged)")
            var eacces = String("EACCES")
            _assert_real_error(_err_get(store, String("locked")), eacces, p)
            _assert_real_error(_err_head(store, String("locked")), eacces, p)
            _assert_real_error(
                _err_get_range(store, String("locked")), eacces, p
            )
            _assert_real_error(
                _err_if_match(store, String("locked")), eacces, p
            )
            _assert_real_error(_err_list(store), eacces, p)
    finally:
        _chmod(p, Int32(0o644))


def main() raises:
    var failures = 0

    try:
        test_unreadable_file_raises_eacces()
        print("PASS test_unreadable_file_raises_eacces")
    except e:
        failures += 1
        print("FAIL test_unreadable_file_raises_eacces:", String(e))

    try:
        test_missing_key_and_missing_root_stay_not_found()
        print("PASS test_missing_key_and_missing_root_stay_not_found")
    except e:
        failures += 1
        print("FAIL test_missing_key_and_missing_root_stay_not_found:", String(e))

    try:
        test_root_is_a_file_raises_enotdir_on_every_verb()
        print("PASS test_root_is_a_file_raises_enotdir_on_every_verb")
    except e:
        failures += 1
        print("FAIL test_root_is_a_file_raises_enotdir_on_every_verb:", String(e))

    try:
        test_self_symlink_raises_eloop()
        print("PASS test_self_symlink_raises_eloop")
    except e:
        failures += 1
        print("FAIL test_self_symlink_raises_eloop:", String(e))

    try:
        test_overlong_key_raises_enametoolong()
        print("PASS test_overlong_key_raises_enametoolong")
    except e:
        failures += 1
        print("FAIL test_overlong_key_raises_enametoolong:", String(e))

    try:
        test_key_file_is_a_directory_raises_eisdir()
        print("PASS test_key_file_is_a_directory_raises_eisdir")
    except e:
        failures += 1
        print("FAIL test_key_file_is_a_directory_raises_eisdir:", String(e))

    if failures > 0:
        raise Error(
            "[test_local_fs_read_errno] " + String(failures) + " test(s) FAILED"
        )
    print("[test_local_fs_read_errno] all 6 tests PASS")

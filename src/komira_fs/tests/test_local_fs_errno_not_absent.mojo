# =============================================================================
# tests/test_local_fs_errno_not_absent.mojo
#   komira_fs: only ENOENT means "not there".
# =============================================================================
#
# THE DEFECT THIS CATCHES. Three LocalFs paths read a failed probe as "absent":
#   (1) the `komira_list_dir_shallow` / `komira_walk_dir_recursive` C shims
#       answered an EMPTY listing when opendir failed, and the walk silently
#       skipped every subdirectory it could not open;
#   (2) LocalFs.delete probed existence after a failed remove(3) and read a
#       failed probe as "already gone", so delete returned success while the
#       entry remained (delete now reads remove(3)'s own errno; that contract
#       is tested in test_local_fs_delete_errno.mojo);
#   (3) `_local_fs_is_directory` read any fopen failure as "does not exist",
#       so LocalFs.list / list_dir_shallow answered [] and is_dir said "path
#       not found" for a path it could not even check.
# A caller that lists (search replay listing its splits) or deletes then drops
# data with no error.
#
# WHAT EACH TEST PROVES (forced failure -> expected answer):
#   * ENOENT controls: a missing path still lists [] (list, list_dir_shallow,
#     both private walkers), is_dir still raises "path not found", delete of a
#     missing path still succeeds, and a regular-file prefix still lists [].
#   * ENOTDIR (a path under a regular file): list, list_dir_shallow, is_dir,
#     delete, and the two shim walkers called directly must raise an error
#     naming ENOTDIR and the path. Forceable for any user.
#   * ELOOP (a symlink to itself): list, list_dir_shallow, is_dir, the two
#     walkers, and delete of a path below it must raise naming ELOOP. Any user.
#   * EMFILE BELOW THE ROOT (forceable for any user, root included: the soft
#     RLIMIT_NOFILE binds root too): the limit is lowered through the shim's
#     test seam so the walk's opendir of the ROOT takes the last descriptor
#     and its opendir of `<root>/sub` fails. The walk must raise exactly
#     `walk of '<root>' failed at '<root>/sub': errno N (EMFILE)` instead of
#     skipping `sub` and listing its file away. The limit is restored before
#     any assertion runs.
#   * ENAMETOOLONG ON AN ENTRY BELOW THE ROOT (forceable for any user, root
#     included): a directory chain whose absolute path is just under PATH_MAX
#     (4096) holds an entry created relative to it (a shell `cd` then
#     `touch`), so opendir of the deepest directory succeeds and the walk's
#     lstat of `<deepest>/<entry>` fails with ENAMETOOLONG. The walk must
#     raise `walk of '<root>' failed at '<path>': errno N (ENAMETOOLONG)`
#     with the path truncated to the 4095 bytes the error buffer holds,
#     instead of skipping the entry. The entry is removed the same relative
#     way before the tree is deleted.
#   * EACCES (mode 000 directory, and a mode 000 subdirectory inside a walked
#     tree): only forceable unprivileged; the test probes access(R_OK) and
#     prints which branch ran. Privileged, it asserts the listing succeeds.
#
# Every case runs even if an earlier one fails; main() prints each result and
# raises once at the end.
# =============================================================================

from std.ffi import external_call
from std.testing import assert_equal, assert_false, assert_true

from komira_runtime_paths import test_tmpdir
from komira_fs.local_fs import (
    LocalFs,
    _local_fs_list_dir_shallow,
    _local_fs_list_recursive,
)
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
    var root = base + String("/errno_") + tag + String("_") + String(Int(pid))
    _sh(String("rm -rf '") + root + String("'"))
    _sh(String("mkdir -p '") + root + String("'"))
    return root


def _readable(path: String) -> Bool:
    var p = path
    # SAFETY: `p` pins the NUL-terminated path across the synchronous call.
    # R_OK == 4 on every POSIX platform this builds for.
    var rc = external_call["access", Int32](
        p.as_c_string_slice().unsafe_ptr(), Int32(4)
    )
    return rc == 0


def _assert_real_error(msg: String, errno_name: String, path: String) raises:
    """`msg` is a raised error naming the errno and the path, and does not
    read as "not found"."""
    assert_true(msg.byte_length() > 0, "expected a raised error, got success")
    assert_true(msg.find(errno_name) >= 0, "errno not named: " + msg)
    assert_true(msg.find(path) >= 0, "path not named: " + msg)
    assert_false(msg.find("not found") >= 0, "reads as not-found: " + msg)


def _err_list(path: String) -> String:
    var fs = _Fs.new()
    try:
        var got = fs.list(path)
        return String("<listed ") + String(len(got)) + ">"
    except e:
        return String(e)


def _err_shallow(path: String) -> String:
    var fs = _Fs.new()
    try:
        var got = fs.list_dir_shallow(path)
        return String("<listed ") + String(len(got)) + ">"
    except e:
        return String(e)


def _err_is_dir(path: String) -> String:
    var fs = _Fs.new()
    try:
        _ = fs.is_dir(path)
        return String("")
    except e:
        return String(e)


def _err_delete(path: String) -> String:
    var fs = _Fs.new()
    try:
        fs.delete(path)
        return String("")
    except e:
        return String(e)


def _err_walk(path: String) -> String:
    try:
        var got = _local_fs_list_recursive(path)
        return String("<listed ") + String(len(got)) + ">"
    except e:
        return String(e)


def _err_shallow_shim(path: String) -> String:
    try:
        var got = _local_fs_list_dir_shallow(path)
        return String("<listed ") + String(len(got)) + ">"
    except e:
        return String(e)


# -----------------------------------------------------------------------------
# ENOENT controls: real absence keeps its answer.
# -----------------------------------------------------------------------------
def test_missing_paths_keep_absent_answers() raises:
    var root = _disk_root(String("absent"))
    _sh(String("printf 'A' > '") + root + String("/f.parquet'"))
    var missing = root + String("/nope")
    assert_equal(_err_list(missing), String("<listed 0>"))
    assert_equal(_err_shallow(missing), String("<listed 0>"))
    assert_equal(_err_walk(missing), String("<listed 0>"))
    assert_equal(_err_shallow_shim(missing), String("<listed 0>"))
    var m = _err_is_dir(missing)
    assert_true(m.find("not found") >= 0, "is_dir on missing: " + m)
    assert_equal(_err_delete(missing), String(""))
    # A regular-file prefix is "matched nothing", not an error.
    assert_equal(_err_list(root + "/f.parquet"), String("<listed 0>"))
    assert_equal(_err_shallow(root + "/f.parquet"), String("<listed 0>"))
    _sh(String("rm -rf '") + root + String("'"))


# -----------------------------------------------------------------------------
# ENOTDIR: a path below a regular file.
# -----------------------------------------------------------------------------
def test_path_under_a_file_raises_enotdir() raises:
    var root = _disk_root(String("enotdir"))
    _sh(String("printf 'A' > '") + root + String("/f.parquet'"))
    var p = root + String("/f.parquet/x")
    var e = String("ENOTDIR")
    _assert_real_error(_err_list(p), e, p)
    _assert_real_error(_err_shallow(p), e, p)
    _assert_real_error(_err_is_dir(p), e, p)
    _assert_real_error(_err_delete(p), e, p)
    _assert_real_error(_err_walk(p), e, p)
    _assert_real_error(_err_shallow_shim(p), e, p)
    _sh(String("rm -rf '") + root + String("'"))


# -----------------------------------------------------------------------------
# ELOOP: a symlink to itself.
# -----------------------------------------------------------------------------
def test_self_symlink_raises_eloop() raises:
    var root = _disk_root(String("eloop"))
    var p = root + String("/loop")
    _sh(String("ln -s '") + p + String("' '") + p + String("'"))
    var e = String("ELOOP")
    _assert_real_error(_err_list(p), e, p)
    _assert_real_error(_err_shallow(p), e, p)
    _assert_real_error(_err_is_dir(p), e, p)
    _assert_real_error(_err_walk(p), e, p)
    _assert_real_error(_err_shallow_shim(p), e, p)
    var below = p + String("/x")
    _assert_real_error(_err_delete(below), e, below)
    _sh(String("rm -rf '") + root + String("'"))


# -----------------------------------------------------------------------------
# EMFILE below the root: the walk must not skip a subdirectory it cannot open.
# -----------------------------------------------------------------------------
def test_walk_subdir_emfile_raises() raises:
    var root = _disk_root(String("emfile"))
    var sub = root + String("/sub")
    _sh(String("mkdir -p '") + sub + String("'"))
    _sh(String("printf 'A' > '") + sub + String("/a.parquet'"))
    var old_soft = Int64(0)
    # SAFETY: `old_soft` is a local out-param written during the synchronous
    # call only.
    var rc = external_call["komira_fs_test_allow_one_more_fd", Int32](
        UnsafePointer(to=old_soft)
    )
    assert_equal(Int(rc), 0, "could not lower RLIMIT_NOFILE")
    var msg = _err_walk(root)
    var rrc = external_call["komira_fs_test_set_nofile_soft", Int32](old_soft)
    assert_equal(Int(rrc), 0, "could not restore RLIMIT_NOFILE")
    var want = (
        String("walk of '") + root + "' failed at '" + sub + "': errno "
    )
    assert_true(msg.find(want) >= 0, "below-root failure not raised: " + msg)
    assert_true(msg.find("(EMFILE)") >= 0, "EMFILE not named: " + msg)
    # With the limit restored the same walk lists the file.
    assert_equal(_err_walk(root), String("<listed 1>"))
    _sh(String("rm -rf '") + root + String("'"))


# -----------------------------------------------------------------------------
# ENAMETOOLONG below the root: the walk must not skip an entry it cannot lstat.
# -----------------------------------------------------------------------------
def _repeat_x(n: Int) -> String:
    var s = String("")
    for _ in range(n):
        s += "x"
    return s


def test_walk_entry_lstat_enametoolong_raises() raises:
    var root = _disk_root(String("nametoolong"))
    # Grow `deep` with 200-byte components until it is just under PATH_MAX;
    # every mkdir names an absolute path of fewer than 4096 bytes.
    var comp = _repeat_x(200)
    var deep = root
    while deep.byte_length() + 1 + 200 <= 4000:
        deep += "/" + comp
    assert_true(
        deep.byte_length() > 3800,
        "chain too short: " + String(deep.byte_length()),
    )
    _sh(String("mkdir -p '") + deep + String("'"))
    # `<deep>/<entry>` is over 4095 bytes; create it relative to `deep` in a
    # child shell, which is the only way to name it.
    var entry = _repeat_x(200)
    var rel = String("cd '") + deep + String("' && ")
    _sh(rel + String("touch ") + entry)
    var msg = _err_walk(root)
    # Remove the entry the same relative way before asserting, so a failed
    # assertion cannot leave an over-PATH_MAX path behind.
    _sh(rel + String("rm ") + entry)
    _sh(String("rm -rf '") + root + String("'"))
    # The error buffer holds 4095 bytes: the reported path is `<deep>/` plus
    # as much of the entry name as fits, immediately followed by "': errno".
    var shown = deep + "/" + _repeat_x(4095 - deep.byte_length() - 1)
    var want = (
        String("walk of '") + root + "' failed at '" + shown + "': errno "
    )
    assert_true(
        msg.find(want) >= 0,
        "below-root lstat failure not raised: " + String(msg.byte_length())
        + " bytes, starts " + String(msg[byte=0:min(80, msg.byte_length())]),
    )
    assert_true(msg.find("(ENAMETOOLONG)") >= 0, "ENAMETOOLONG not named")


# -----------------------------------------------------------------------------
# EACCES: unreadable directory / subdirectory (unprivileged processes only).
# -----------------------------------------------------------------------------
def test_unreadable_directory_raises_eacces() raises:
    var root = _disk_root(String("eacces"))
    var tree = root + String("/tree")
    var locked = tree + String("/locked")
    _sh(String("mkdir -p '") + locked + String("'"))
    _sh(String("printf 'A' > '") + locked + String("/a.parquet'"))
    _sh(String("printf 'B' > '") + tree + String("/b.parquet'"))
    _sh(String("chmod 000 '") + locked + String("'"))
    try:
        if _readable(locked):
            print(
                "[test_local_fs_errno_not_absent] EACCES NOT FORCEABLE: the"
                " process is privileged (mode 000 still readable); asserting"
                " the listings succeed instead"
            )
            assert_equal(_err_list(tree), String("<listed 2>"))
            assert_equal(_err_shallow(locked), String("<listed 1>"))
        else:
            print("[test_local_fs_errno_not_absent] EACCES forced (unprivileged)")
            var e = String("EACCES")
            _assert_real_error(_err_shallow(locked), e, locked)
            _assert_real_error(_err_list(locked), e, locked)
            # The walk must not silently skip the unreadable subdirectory.
            _assert_real_error(_err_list(tree), e, locked)
    finally:
        _sh(String("chmod 755 '") + locked + String("'"))
        _sh(String("rm -rf '") + root + String("'"))


def main() raises:
    var failures = 0

    try:
        test_unreadable_directory_raises_eacces()
        print("PASS test_unreadable_directory_raises_eacces")
    except e:
        failures += 1
        print("FAIL test_unreadable_directory_raises_eacces:", String(e))

    try:
        test_missing_paths_keep_absent_answers()
        print("PASS test_missing_paths_keep_absent_answers")
    except e:
        failures += 1
        print("FAIL test_missing_paths_keep_absent_answers:", String(e))

    try:
        test_path_under_a_file_raises_enotdir()
        print("PASS test_path_under_a_file_raises_enotdir")
    except e:
        failures += 1
        print("FAIL test_path_under_a_file_raises_enotdir:", String(e))

    try:
        test_self_symlink_raises_eloop()
        print("PASS test_self_symlink_raises_eloop")
    except e:
        failures += 1
        print("FAIL test_self_symlink_raises_eloop:", String(e))

    try:
        test_walk_subdir_emfile_raises()
        print("PASS test_walk_subdir_emfile_raises")
    except e:
        failures += 1
        print("FAIL test_walk_subdir_emfile_raises:", String(e))

    try:
        test_walk_entry_lstat_enametoolong_raises()
        print("PASS test_walk_entry_lstat_enametoolong_raises")
    except e:
        failures += 1
        print("FAIL test_walk_entry_lstat_enametoolong_raises:", String(e))

    if failures > 0:
        raise Error(
            "[test_local_fs_errno_not_absent] " + String(failures)
            + " test(s) FAILED"
        )
    print("[test_local_fs_errno_not_absent] all 6 tests PASS")

# =============================================================================
# tests/test_cov_local_fs.mojo
#   LocalFsConditionalStore's filesystem failure arms that the other local-fs
#   tests do not reach: root creation, the atomic rename, the create race and
#   the temp open, and the filename decoder's lowercase escapes.
# =============================================================================
#
# What each case catches:
#   * a root that cannot be created (a regular file in its path) accepted
#     silently, so every later write lands nowhere;
#   * a failed rename (the key's path is a directory) reported as success, or
#     with any text a downstream classifier reads as a 412 (checked with
#     both quoted paths cut out: the root holds clock digits and, here, a
#     planted "412", and the temp suffix is random hex);
#   * a create that loses at link(2) (EEXIST: something appeared at the key
#     after the presence probe, here a dangling symlink the probe reads as
#     absent) raised as an I/O error instead of the precondition 412 a slot
#     loser must see;
#   * a temp that cannot be opened (the root is gone) raised as a 412 (a
#     fake create-loss) instead of an I/O error;
#   * `%2f` (lowercase) not decoded to `/` in a listing;
#   * a wrong stage name in the I/O error text (read, fsync, close: stages
#     only a device fault reaches through the store, so they are checked on
#     the namer directly);
#   * `_mkdir_one("")` raising instead of being a no-op. (Deleting the
#     empty-path guard is not observable: mkdir("") fails, and the
#     existing-directory probe then checks "/." and returns.)
#   * a short read (fewer bytes than fstat reported) returned as the whole
#     object. A sysfs attribute reports a size of 4096 and returns fewer
#     bytes; a key symlinked to one is a deterministic short read on Linux.
#     Where no such file is visible (no /sys), the case prints why it is
#     skipped.
# =============================================================================

from std.ffi import external_call
from std.testing import assert_equal, assert_false, assert_true
from std.time import perf_counter_ns

from komira_objectstore.local_fs_conditional_store import (
    LocalFsConditionalStore,
    _mkdir_one,
)
from komira_objectstore.local_fs_file_read import (
    _STAGE_CLOSE,
    _STAGE_FSTAT,
    _STAGE_FSYNC,
    _STAGE_LINK,
    _STAGE_OPEN,
    _STAGE_READ,
    _STAGE_STAT,
    _STAGE_WRITE,
    _stage_name,
)
from komira_objectstore.path import Path
from komira_objectstore.types import WritePrecondition
from komira_runtime_paths import test_tmpdir


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var sb = s.as_bytes()
    for i in range(len(sb)):
        out.append(sb[i])
    return out^


def _scratch(tag: String) raises -> String:
    return (
        test_tmpdir() + String("/komira_cov_lfs_") + tag + String("_")
        + String(UInt64(perf_counter_ns()))
    )


def _rename_error_store_text(msg: String, final_path: String) raises -> String:
    """The text of an atomic-rename error that the store composes, with both
    quoted paths cut out. The message is `... ('<final>.tmp.<16 hex>' ->
    '<final>', rc=N)`: the caller's root (clock digits, and here a planted
    "412") and the temp's random hex suffix can each spell "412", so a status
    check over the raw message is flaky. With the paths cut, the rest is fixed
    text, and a bare "412" in it is a status."""
    var tmp_open = String("('") + final_path + ".tmp."
    var start = msg.find(tmp_open)
    assert_true(start >= 0, msg)
    var tmp_close = String("' -> '") + final_path + "'"
    var end = msg.find(tmp_close, start)
    assert_true(end >= 0, msg)
    # The suffix between `.tmp.` and the closing quote is 16 hex digits.
    var suffix_len = end - (start + tmp_open.byte_length())
    assert_equal(suffix_len, 16, msg)
    return (
        String(msg[byte=0:start])
        + "('<tmp>' -> '<final>'"
        + String(msg[byte=end + tmp_close.byte_length() : msg.byte_length()])
    )


def _libc_path_call(name: StaticString, a: String, b: String) -> Int32:
    var x = a
    var y = b
    # SAFETY: `x` / `y` pin the NUL-terminated paths across the synchronous
    # libc call; no pointer escapes.
    if name == "rename":
        return external_call["rename", Int32](
            x.as_c_string_slice().unsafe_ptr(), y.as_c_string_slice().unsafe_ptr()
        )
    return external_call["symlink", Int32](
        x.as_c_string_slice().unsafe_ptr(), y.as_c_string_slice().unsafe_ptr()
    )


def test_root_under_a_regular_file_is_refused() raises:
    var root = _scratch(String("root"))
    var s = LocalFsConditionalStore(root.copy())
    _ = s.put(Path.parse(String("f")), _b("x"))
    # `<root>/f` is a regular file: a root below it cannot be created.
    var msg = String("")
    try:
        _ = LocalFsConditionalStore(root + "/f/sub")
    except e:
        msg = String(e)
    assert_true(msg.find("failed to create root dir") >= 0, msg)
    assert_true(msg.find("not an existing directory") >= 0, msg)
    assert_true(msg.find(root + "/f") >= 0, msg)
    # An empty root is a no-op mkdir (nothing to create), not an error.
    var empty = LocalFsConditionalStore(String(""))
    assert_equal(empty.coalesce_policy().max_concurrency, 8)


def test_put_over_a_directory_fails_loud() raises:
    # The root holds "412" on purpose: the error names the root, so a check
    # that read the caller's path as a status would fail on every run here,
    # not only when the clock's digits happen to spell it.
    var root = _scratch(String("ren_412"))
    var s = LocalFsConditionalStore(root.copy())
    # `<root>/d` is a directory (a store rooted there): an unconditional put
    # of key `d` cannot rename its temp over it.
    var inner = LocalFsConditionalStore(root + "/d")
    _ = inner.put(Path.parse(String("x")), _b("1"))
    var msg = String("")
    try:
        _ = s.put(Path.parse(String("d")), _b("payload"))
    except e:
        msg = String(e)
    assert_true(msg.find("atomic rename failed") >= 0, msg)
    assert_true(msg.find(root + "/d'") >= 0, msg)
    # Any spelling a downstream classifier reads as a precondition failure
    # (`cas_manifest`'s accepts a bare "412", "precondition", "Precondition"
    # and "PreconditionFailed") must be absent from the store's own text.
    var own = _rename_error_store_text(msg, root + "/d")
    assert_false(own.find("412") >= 0, msg)
    assert_false(own.find("recondition") >= 0, msg)
    # The directory under the key is intact.
    assert_equal(len(inner.get(Path.parse(String("x")))), 1)


def test_create_losing_at_link_is_a_412() raises:
    var root = _scratch(String("race"))
    var s = LocalFsConditionalStore(root.copy())
    # A dangling symlink at the key's filename: stat (the presence probe)
    # reads ENOENT, link(2) then fails with EEXIST.
    assert_equal(
        _libc_path_call("symlink", root + "/nowhere", root + "/k"), Int32(0)
    )
    var msg = String("")
    try:
        _ = s.conditional_put(
            Path.parse(String("k")), _b("v"), WritePrecondition.if_none_match_star()
        )
    except e:
        msg = String(e)
    assert_true(msg.find("precondition (412)") >= 0, msg)
    assert_true(msg.find("exclusive create lost the race for: k") >= 0, msg)


def test_create_with_missing_root_is_an_io_error() raises:
    var root = _scratch(String("gone"))
    # The infallible ctor (as `clone` uses) over a root that does not exist.
    var s = LocalFsConditionalStore(root.copy(), True)
    var msg = String("")
    try:
        _ = s.conditional_put(
            Path.parse(String("k")), _b("v"), WritePrecondition.if_none_match_star()
        )
    except e:
        msg = String(e)
    assert_true(msg.find("I/O error on exclusive create") >= 0, msg)
    assert_true(msg.find("temp open failed with errno") >= 0, msg)
    assert_true(msg.find("ENOENT") >= 0, msg)
    # This message names the call and errno only, never a path, so a bare
    # "412" anywhere in it is a status.
    assert_false(msg.find("412") >= 0, msg)
    assert_false(msg.find("recondition") >= 0, msg)


def test_lowercase_escape_decodes() raises:
    var root = _scratch(String("hex"))
    var s = LocalFsConditionalStore(root.copy())
    _ = s.put(Path.parse(String("x")), _b("body"))
    # Rename the object file to a lowercase-escaped name another writer of
    # the same codec could have produced: `a%2fb%3a` is key `a/b:`.
    assert_equal(
        _libc_path_call("rename", root + "/x", root + "/a%2fb%3a"), Int32(0)
    )
    var lr = s.list_with_delimiter(Path.parse(String("a/")))
    assert_equal(len(lr.objects), 1)
    assert_equal(lr.objects[0].location, String("a/b:"))
    assert_equal(lr.objects[0].size, Int64(4))


def test_stage_names() raises:
    assert_equal(_stage_name(_STAGE_OPEN), String("open"))
    assert_equal(_stage_name(_STAGE_FSTAT), String("fstat"))
    assert_equal(_stage_name(_STAGE_READ), String("read"))
    assert_equal(_stage_name(_STAGE_WRITE), String("write"))
    assert_equal(_stage_name(_STAGE_FSYNC), String("fsync"))
    assert_equal(_stage_name(_STAGE_CLOSE), String("close"))
    assert_equal(_stage_name(_STAGE_LINK), String("link"))
    assert_equal(_stage_name(_STAGE_STAT), String("stat"))


def test_mkdir_one_of_empty_path_is_a_noop() raises:
    # An empty path has nothing to create: no error.
    _mkdir_one(String(""))


def _short_read_size(path: String) -> Int:
    """Oracle, straight from the C shim (not the Mojo size check under
    test): the size fstat reports for `path` if a full read returns fewer
    bytes than that, else -1 (absent, unreadable, or not a short read)."""
    var p = path
    var fd = Int32(-1)
    var size = Int64(0)
    var stage = Int32(0)
    # SAFETY: `p` pins the path; `fd`/`size`/`stage` are locals the shim
    # writes during the synchronous call only.
    var rc = external_call["komira_objstore_open_for_read", Int32](
        p.as_c_string_slice().unsafe_ptr(),
        UnsafePointer(to=fd),
        UnsafePointer(to=size),
        UnsafePointer(to=stage),
    )
    if rc != 0:
        return -1
    var n = Int(size)
    var buf = List[UInt8]()
    buf.resize(n + 1, UInt8(0))
    var got = Int64(0)
    # SAFETY: `buf` holds n + 1 bytes and the shim writes at most n; it closes
    # `fd` on every path. `got` is a local out-param.
    var rrc = external_call["komira_objstore_read_exact_close", Int32](
        fd, buf.unsafe_ptr(), Int64(n), UnsafePointer(to=got)
    )
    if rrc != 0 or Int(got) >= n:
        return -1
    return n


def test_short_read_is_an_error() raises:
    var candidates = List[String]()
    candidates.append(String("/sys/devices/system/cpu/online"))
    candidates.append(String("/sys/kernel/mm/transparent_hugepage/enabled"))
    candidates.append(String("/sys/class/net/lo/mtu"))
    var target = String("")
    var n = -1
    for i in range(len(candidates)):
        n = _short_read_size(candidates[i])
        if n > 0:
            target = candidates[i]
            break
    if n <= 0:
        print(
            "[test_cov_local_fs] SKIP test_short_read_is_an_error: no"
            " short-reading sysfs attribute is visible here (no /sys mount)"
        )
        return
    var root = _scratch(String("short"))
    var s = LocalFsConditionalStore(root.copy())
    assert_equal(_libc_path_call("symlink", target, root + "/k"), Int32(0))
    var msg = String("")
    try:
        _ = s.get(Path.parse(String("k")))
    except e:
        msg = String(e)
    assert_true(msg.find("short read (") >= 0, msg)
    assert_true(msg.find(" < " + String(n) + ") for '" + root + "/k'") >= 0, msg)
    assert_false(msg.find("not_found") >= 0, msg)


def main() raises:
    test_root_under_a_regular_file_is_refused()
    test_put_over_a_directory_fails_loud()
    test_create_losing_at_link_is_a_412()
    test_create_with_missing_root_is_an_io_error()
    test_lowercase_escape_decodes()
    test_stage_names()
    test_mkdir_one_of_empty_path_is_a_noop()
    test_short_read_is_an_error()
    print("[test_cov_local_fs] PASS")

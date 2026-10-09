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
#     as a 412;
#   * a create that loses at link(2) (EEXIST: something appeared at the key
#     after the presence probe, here a dangling symlink the probe reads as
#     absent) raised as an I/O error instead of the precondition 412 a slot
#     loser must see;
#   * a temp that cannot be opened (the root is gone) raised as a 412 (a
#     fake create-loss) instead of an I/O error;
#   * `%2f` (lowercase) not decoded to `/` in a listing.
# =============================================================================

from std.ffi import external_call
from std.testing import assert_equal, assert_false, assert_true
from std.time import perf_counter_ns

from komira_objectstore.local_fs_conditional_store import (
    LocalFsConditionalStore,
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
    var root = _scratch(String("ren"))
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
    assert_false(msg.find("412") >= 0, msg)
    assert_false(msg.find("precondition") >= 0, msg)
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
    assert_false(msg.find("412") >= 0, msg)


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


def main() raises:
    test_root_under_a_regular_file_is_refused()
    test_put_over_a_directory_fails_loud()
    test_create_losing_at_link_is_a_412()
    test_create_with_missing_root_is_an_io_error()
    test_lowercase_escape_decodes()
    print("[test_cov_local_fs] PASS")

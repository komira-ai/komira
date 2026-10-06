# =============================================================================
# tests/test_local_fs_store_create_write_failure.mojo
#   LocalFsConditionalStore create-if-absent: a failed write publishes nothing.
# =============================================================================
#
# The create used to open the FINAL object path with O_CREAT|O_EXCL and then
# write into it, so a write that failed part-way left a torn object file at the
# key: readers saw the partial bytes, and a retried create got a fake 412.
#
#   * write failure: the soft RLIMIT_FSIZE is lowered to a few bytes (SIGXFSZ
#     ignored; the limit binds root, which file modes do not) and a larger
#     payload is create-put. The create must raise the non-412 I/O error; the
#     key must then be absent to get, head and list; no `.tmp.` file may be
#     left in the root; and, with the limit restored, a second create of the
#     same key must SUCCEED and read back byte-exact.
#   * create-loss: a create of a key that already exists still raises the
#     precondition (412) and leaves the existing bytes and no `.tmp.` file.
#     The store answers that from its presence probe, so the link(2) EEXIST
#     arm (a creator that wins between the probe and the link) is driven
#     directly through `_create_exclusive_and_write`: it must classify as
#     `_CREATE_LOST_EEXIST`, keep the winner's bytes and unlink the temp.
#   * link failure other than EEXIST: link(2) cannot be made to fail otherwise
#     by a privileged test on a real filesystem, so the shim's one-shot test
#     seam fails the next link with EMLINK. The create must raise the non-412
#     I/O error naming `link` and EMLINK (a create that read it as a 412 would
#     tell a claim loser to skip a slot nobody holds); the key must be absent;
#     no `.tmp.` file may be left; and a retried create must succeed.
#   * temp unlink failure: the same seam also fails the next remove with
#     EBUSY. After a link failure the I/O error must add `; temp unlink failed
#     with errno N (EBUSY)` (the stray temp is then removed by the test). After
#     a successful link the create must still succeed: the object is
#     published, and the stray temp is not listed as a key.
#   Every armed fault must be consumed by the create under test.
# =============================================================================

from std.ffi import external_call
from std.testing import assert_equal, assert_false, assert_true
from std.time import perf_counter_ns

from komira_objectstore.local_fs_conditional_store import (
    LocalFsConditionalStore,
    _CREATE_LOST_EEXIST,
    _create_exclusive_and_write,
    _list_dir_fnames,
)
from komira_objectstore.path import Path
from komira_objectstore.types import WritePrecondition
from komira_runtime_paths import test_tmpdir


comptime _FSIZE_LIMIT: Int64 = 4


def _payload(n: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(n):
        out.append(UInt8(65 + i % 26))
    return out^


def _bytes_eq(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def _err_create(
    store: LocalFsConditionalStore, key: String, bytes: List[UInt8]
) -> String:
    try:
        _ = store.conditional_put(
            Path.parse(key), bytes, WritePrecondition.if_none_match_star()
        )
        return String("")
    except e:
        return String(e)


def _err_create_limited(
    store: LocalFsConditionalStore, key: String, bytes: List[UInt8]
) raises -> String:
    """Create-put `key` with the soft RLIMIT_FSIZE at `_FSIZE_LIMIT` bytes.
    The limit and SIGXFSZ disposition are restored before anything here can
    raise or print (the create's error is captured, not propagated)."""
    var rc = external_call["komira_objstore_test_fsize_limit_begin", Int32](
        _FSIZE_LIMIT
    )
    assert_equal(Int(rc), 0, "could not lower RLIMIT_FSIZE")
    var msg = _err_create(store, key, bytes)
    var rrc = external_call["komira_objstore_test_fsize_limit_end", Int32]()
    assert_equal(Int(rrc), 0, "could not restore RLIMIT_FSIZE / SIGXFSZ")
    return msg^


def _is_not_found(store: LocalFsConditionalStore, key: String) -> Bool:
    try:
        _ = store.get(Path.parse(key))
        return False
    except e:
        return String(e).find("not_found") >= 0


def _head_not_found(store: LocalFsConditionalStore, key: String) -> Bool:
    try:
        _ = store.head(Path.parse(key))
        return False
    except e:
        return String(e).find("not_found") >= 0


def _assert_no_temp(root: String) raises:
    var names = _list_dir_fnames(root)
    for i in range(len(names)):
        assert_false(
            names[i].find(".tmp.") >= 0, "temp file left behind: " + names[i]
        )


def test_write_failure_publishes_nothing(root: String) raises:
    var store = LocalFsConditionalStore(root.copy())
    var key = String("manifest/00000000000000000000.chunk")
    var big = _payload(64)

    var msg = _err_create_limited(store, key, big)
    assert_true(msg.byte_length() > 0, "create under RLIMIT_FSIZE succeeded")
    assert_true(msg.find("I/O error") >= 0, "not an I/O error: " + msg)
    assert_true(msg.find("(EFBIG)") >= 0, "EFBIG not named: " + msg)
    assert_false(msg.find("412") >= 0, "write failure reads as a 412: " + msg)
    assert_false(
        msg.find("precondition") >= 0, "write failure reads as a 412: " + msg
    )

    # Nothing was published at the key.
    assert_true(_is_not_found(store, key), "torn object visible to get")
    assert_true(_head_not_found(store, key), "torn object visible to head")
    var listed = store.list_with_delimiter(Path.parse(String("manifest/")))
    assert_equal(len(listed.objects), 0, "torn object visible to list")
    _assert_no_temp(root)

    # A retried create (limit restored) wins and reads back byte-exact.
    assert_equal(_err_create(store, key, big), String(""))
    assert_true(_bytes_eq(store.get(Path.parse(key)), big), "retry bytes")
    _assert_no_temp(root)


def test_create_loss_is_412(root: String) raises:
    var store = LocalFsConditionalStore(root.copy())
    var key = String("claim/p0")
    var first = _payload(8)
    assert_equal(_err_create(store, key, first), String(""))
    var msg = _err_create(store, key, _payload(16))
    assert_true(msg.find("precondition") >= 0, "not a 412: " + msg)
    assert_true(msg.find("412") >= 0, "not a 412: " + msg)
    assert_true(_bytes_eq(store.get(Path.parse(key)), first), "bytes changed")
    _assert_no_temp(root)

    # The link(2) EEXIST arm, past the presence probe (the race window).
    var detail = String("")
    var res = _create_exclusive_and_write(
        store._path_for_key(key), _payload(16), detail
    )
    assert_equal(res, _CREATE_LOST_EEXIST, "link EEXIST not the 412: " + detail)
    assert_true(_bytes_eq(store.get(Path.parse(key)), first), "bytes changed")
    _assert_no_temp(root)


def _arm(seam: StaticString) raises:
    # Only the two seam names below are passed; each returns 0.
    var rc: Int32
    if seam == "link":
        rc = external_call[
            "komira_objstore_test_fail_next_link_emlink", Int32
        ]()
    else:
        rc = external_call[
            "komira_objstore_test_fail_next_remove_ebusy", Int32
        ]()
    assert_equal(Int(rc), 0, "could not arm the fault")


def _assert_faults_consumed() raises:
    var armed = external_call["komira_objstore_test_clear_faults", Int32]()
    assert_equal(Int(armed), 0, "an armed fault was not consumed")


def _remove_temps(root: String) raises -> Int:
    """Remove every `.tmp.` file in `root` through the shim (unarmed) and
    return how many there were."""
    var names = _list_dir_fnames(root)
    var n = 0
    for i in range(len(names)):
        if names[i].find(".tmp.") >= 0:
            var p = root + "/" + names[i]
            # SAFETY: `p` pins the NUL-terminated path across the call.
            var rc = external_call["komira_objstore_remove", Int32](
                p.as_c_string_slice().unsafe_ptr()
            )
            assert_equal(Int(rc), 0, "could not remove " + names[i])
            n += 1
    return n


def _assert_io_not_412(msg: String) raises:
    assert_true(msg.find("I/O error") >= 0, "not an I/O error: " + msg)
    assert_false(msg.find("412") >= 0, "I/O failure reads as a 412: " + msg)
    assert_false(
        msg.find("precondition") >= 0, "I/O failure reads as a 412: " + msg
    )


def _assert_absent(store: LocalFsConditionalStore, key: String) raises:
    assert_true(_is_not_found(store, key), "key visible to get")
    assert_true(_head_not_found(store, key), "key visible to head")
    var listed = store.list_with_delimiter(Path.parse(String("claim/")))
    assert_equal(len(listed.objects), 0, "key visible to list")


def test_link_failure_is_io_error(root: String) raises:
    var store = LocalFsConditionalStore(root.copy())
    var key = String("claim/p1")
    var bytes = _payload(16)

    _arm("link")
    var msg = _err_create(store, key, bytes)
    _assert_faults_consumed()
    _assert_io_not_412(msg)
    assert_true(msg.find("link failed with errno ") >= 0, "no link: " + msg)
    assert_true(msg.find("(EMLINK)") >= 0, "EMLINK not named: " + msg)
    assert_false(msg.find("temp unlink failed") >= 0, "unlink failed: " + msg)
    _assert_absent(store, key)
    _assert_no_temp(root)

    # A retried create wins and reads back byte-exact.
    assert_equal(_err_create(store, key, bytes), String(""))
    assert_true(_bytes_eq(store.get(Path.parse(key)), bytes), "retry bytes")
    _assert_no_temp(root)


def test_link_failure_then_unlink_failure(root: String) raises:
    var store = LocalFsConditionalStore(root.copy())
    var key = String("claim/p2")
    var bytes = _payload(16)

    _arm("link")
    _arm("remove")
    var msg = _err_create(store, key, bytes)
    _assert_faults_consumed()
    _assert_io_not_412(msg)
    assert_true(msg.find("(EMLINK)") >= 0, "EMLINK not named: " + msg)
    assert_true(
        msg.find("; temp unlink failed with errno ") >= 0,
        "unlink failure not reported: " + msg,
    )
    assert_true(msg.find("(EBUSY)") >= 0, "EBUSY not named: " + msg)
    _assert_absent(store, key)
    # The refused unlink left exactly one temp; it is not a key.
    assert_equal(_remove_temps(root), 1, "expected one stray temp")
    _assert_no_temp(root)

    assert_equal(_err_create(store, key, bytes), String(""))
    assert_true(_bytes_eq(store.get(Path.parse(key)), bytes), "retry bytes")


def test_unlink_failure_after_publish_succeeds(root: String) raises:
    var store = LocalFsConditionalStore(root.copy())
    var key = String("claim/p3")
    var bytes = _payload(16)

    _arm("remove")
    var msg = _err_create(store, key, bytes)
    _assert_faults_consumed()
    assert_equal(msg, String(""), "published create reported a failure")
    assert_true(_bytes_eq(store.get(Path.parse(key)), bytes), "bytes")
    var listed = store.list_with_delimiter(Path.parse(String("claim/")))
    assert_equal(len(listed.objects), 1, "stray temp listed as a key")
    assert_equal(_remove_temps(root), 1, "expected one stray temp")
    _assert_no_temp(root)
    # The key is published: a second create is the 412.
    var again = _err_create(store, key, bytes)
    assert_true(again.find("412") >= 0, "second create not a 412: " + again)


def main() raises:
    var base = (
        test_tmpdir() + String("/komira_store_create_")
        + String(UInt64(perf_counter_ns()))
    )
    test_write_failure_publishes_nothing(base + "/wf")
    test_create_loss_is_412(base + "/loss")
    test_link_failure_is_io_error(base + "/link")
    test_link_failure_then_unlink_failure(base + "/link_unlink")
    test_unlink_failure_after_publish_succeeds(base + "/unlink")
    print("[test_local_fs_store_create_write_failure] PASS")

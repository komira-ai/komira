# Teardown failures: a key the store keeps, or one whose delete fails, is
# LEAK; a list that raises is CANNOT_TELL; and every failure is kept in the
# verdict, whatever its final kind.

from std.testing import assert_equal, assert_false, assert_true

from komira_test_infra import (
    FakeObjectStore,
    FixedWallClock,
    NoProcess,
    RunId,
    TestBucket,
    VERDICT_CANNOT_TELL,
    VERDICT_CLEAN,
    VERDICT_LEAK,
    Verdict,
    open_test_bucket,
    parse_test_infra_config,
)

comptime _CFG: String = """
object_store {
  endpoint: "http://store.invalid:9000"
  region: "r1"
  bucket: "test-bucket"
  run_prefix: "runs/"
  credentials_file: "/c/credentials"
}
max_lease_seconds: 600
teardown_budget_seconds: 60
"""

comptime _ID: String = "1790000000-00000000000000aa"
comptime _PREFIX: String = "runs/1790000000-00000000000000aa/"


def _open(var store: FakeObjectStore) raises -> TestBucket[FakeObjectStore, NoProcess]:
    var clock = FixedWallClock(1790000000)
    return open_test_bucket(
        RunId(String(_ID), 1790000000), parse_test_infra_config(_CFG), "//p:t", store^, clock
    )


def _put(mut b: TestBucket[FakeObjectStore, NoProcess], rel: String) raises:
    var body = String("x")
    b.client().put(b.key(rel), body.as_bytes())


def _has_reason(v: Verdict, part: String) -> Bool:
    for r in v.reasons:
        if part in r:
            return True
    return False


def _has_residue(v: Verdict, rel: String) -> Bool:
    for r in v.residue:
        if r == rel:
            return True
    return False


def test_sticky_key_is_leak() raises:
    var store = FakeObjectStore()
    store.sticky_keys.append(_PREFIX + "kept.bin")
    var b = _open(store^)
    _put(b, "kept.bin")
    _put(b, "gone.bin")
    var v = b.close()
    assert_equal(v.kind, VERDICT_LEAK)
    assert_true(_has_residue(v, "kept.bin"), String(v))
    assert_false(_has_residue(v, "gone.bin"), String(v))
    var raised = False
    try:
        v.require_clean()
    except e:
        raised = True
        assert_true("LEAK" in String(e), String(e))
    assert_true(raised, "require_clean passed a LEAK")


def test_failed_delete_is_leak_and_keeps_the_lease() raises:
    var store = FakeObjectStore()
    store.fail_delete_keys.append(_PREFIX + "stuck.bin")
    var b = _open(store^)
    _put(b, "stuck.bin")
    var v = b.close()
    assert_equal(v.kind, VERDICT_LEAK)
    assert_true(_has_reason(v, "delete failed: stuck.bin"), String(v))
    assert_true(_has_reason(v, "kept _lease.textproto"), String(v))
    assert_true(_has_residue(v, "stuck.bin"), String(v))
    assert_true(_has_residue(v, "_lease.textproto"), String(v))
    assert_true(b.client().has(_PREFIX + "_lease.textproto"))


def test_failed_delete_request_is_leak() raises:
    var store = FakeObjectStore()
    store.fail_delete_request = True
    var b = _open(store^)
    _put(b, "a.bin")
    var v = b.close()
    assert_equal(v.kind, VERDICT_LEAK)
    assert_true(_has_reason(v, "delete_keys: ") and _has_reason(v, "HTTP 500"), String(v))
    assert_true(_has_residue(v, "a.bin"), String(v))


def test_raising_lists_are_cannot_tell() raises:
    # Both the list before the delete and the re-list raise.
    var store = FakeObjectStore()
    store.fail_list_calls.append(0)
    store.fail_list_calls.append(1)
    var b = _open(store^)
    _put(b, "a.bin")
    var v = b.close()
    assert_equal(v.kind, VERDICT_CANNOT_TELL)
    assert_equal(len(v.reasons), 2)
    assert_true(v.reasons[0].startswith("list_keys (before delete): "), String(v))
    assert_true(v.reasons[1].startswith("list_keys: "), String(v))
    assert_true("HTTP 503" in v.reasons[0] and "HTTP 503" in v.reasons[1], String(v))

    # Only the re-list raises: the deletes ran, but nothing proves them.
    var store2 = FakeObjectStore()
    store2.fail_list_calls.append(1)
    var b2 = _open(store2^)
    _put(b2, "a.bin")
    var v2 = b2.close()
    assert_equal(v2.kind, VERDICT_CANNOT_TELL)
    assert_false(b2.client().has(_PREFIX + "a.bin"))


def test_every_failure_is_kept() raises:
    var store = FakeObjectStore()
    store.fail_delete_keys.append(_PREFIX + "a.bin")
    store.sticky_keys.append(_PREFIX + "b.bin")
    store.fail_list_calls.append(1)
    var b = _open(store^)
    _put(b, "a.bin")
    _put(b, "b.bin")
    var v = b.close()
    # LEAK (a proven failure) outranks CANNOT_TELL; both findings are kept.
    assert_equal(v.kind, VERDICT_LEAK)
    assert_true(_has_reason(v, "delete failed: a.bin"), String(v))
    assert_true(_has_reason(v, "kept _lease.textproto"), String(v))
    assert_true(_has_reason(v, "HTTP 503"), String(v))
    # The second close reports the same verdict.
    var again = b.close()
    assert_equal(again.kind, VERDICT_LEAK)
    assert_equal(len(again.reasons), len(v.reasons))


def test_failed_lease_put_tears_down_and_raises() raises:
    var store = FakeObjectStore()
    store.fail_puts = True
    var raised = False
    try:
        var b = _open(store^)
        _ = b.close()
    except e:
        raised = True
        var msg = String(e)
        assert_true("put _lease.textproto" in msg, msg)
        assert_true("teardown verdict CLEAN" in msg, msg)
    assert_true(raised, "open succeeded although the lease put failed")


def test_verdict_merge_keeps_the_worst() raises:
    var a = Verdict()
    assert_equal(a.kind, VERDICT_CLEAN)
    var t = Verdict()
    t.add_cannot_tell("x")
    a.merge(t)
    assert_equal(a.kind, VERDICT_CANNOT_TELL)
    var l = Verdict()
    l.add_residue("k")
    a.merge(l)
    assert_equal(a.kind, VERDICT_LEAK)
    a.merge(t)
    assert_equal(a.kind, VERDICT_LEAK)
    assert_equal(len(a.reasons), 2)
    assert_equal(len(a.residue), 1)
    assert_equal(a.exit_code(), 6)


def main() raises:
    test_sticky_key_is_leak()
    test_failed_delete_is_leak_and_keeps_the_lease()
    test_failed_delete_request_is_leak()
    test_raising_lists_are_cannot_tell()
    test_every_failure_is_kept()
    test_failed_lease_put_tears_down_and_raises()
    test_verdict_merge_keeps_the_worst()
    print("test_bucket_failures: OK")

# Teardown failures: a key the store keeps, or one whose delete fails, is
# LEAK; a list that raises is CANNOT_TELL; and every failure is kept in the
# verdict, whatever its final kind.

from std.testing import assert_equal, assert_false, assert_true

from komira_test_bucket import (
    FakeObjectStore,
    StoreScope,
    StoreTarget,
    TestBucket,
    open_test_bucket,
)
from komira_test_run_id import FixedWallClock, RunId
from komira_test_verdict import VERDICT_CANNOT_TELL, VERDICT_CLEAN, VERDICT_LEAK, Verdict


def _scope() -> StoreScope:
    return StoreScope(
        StoreTarget("http://store.invalid:9000", "r1", "test-bucket", "/c/credentials"), 600, 60
    )


comptime _ID: String = "1790000000-00000000000000aa"
comptime _PREFIX: String = "runs/1790000000-00000000000000aa/"


def _open(var store: FakeObjectStore) raises -> TestBucket[FakeObjectStore]:
    var clock = FixedWallClock(1790000000)
    return open_test_bucket(
        RunId(String(_ID), 1790000000), _scope(), "//p:t", store^, clock
    )


def _put(mut b: TestBucket[FakeObjectStore], rel: String) raises:
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
    # The delete was reported successful, but the re-list still shows the
    # key: the lease stays, so the residue stays attributable.
    assert_true(b.client().has(_PREFIX + "_lease.textproto"), "lease deleted beside residue")
    assert_true(_has_reason(v, "kept _lease.textproto"), String(v))
    assert_true(_has_residue(v, "_lease.textproto"), String(v))
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

    # Only the final re-list raises (list 0 is before the delete, list 1
    # before the lease delete): the deletes ran, but nothing proves them.
    var store2 = FakeObjectStore()
    store2.fail_list_calls.append(2)
    var b2 = _open(store2^)
    _put(b2, "a.bin")
    var v2 = b2.close()
    assert_equal(v2.kind, VERDICT_CANNOT_TELL)
    assert_false(b2.client().has(_PREFIX + "a.bin"))

    assert_false(b2.client().has(_PREFIX + "_lease.textproto"))

    # The list before the lease delete raises: nothing proves the rest is
    # gone, so the lease is kept.
    var store3 = FakeObjectStore()
    store3.fail_list_calls.append(1)
    var b3 = _open(store3^)
    _put(b3, "a.bin")
    var v3 = b3.close()
    assert_equal(v3.kind, VERDICT_LEAK, String(v3))
    assert_true(_has_reason(v3, "list_keys (before lease delete): "), String(v3))
    assert_true(_has_reason(v3, "kept _lease.textproto"), String(v3))
    assert_false(b3.client().has(_PREFIX + "a.bin"))
    assert_true(b3.client().has(_PREFIX + "_lease.textproto"))


def test_out_of_prefix_keys_are_never_deleted_or_charged() raises:
    # A misbehaving client lists keys from outside this run: a sibling run
    # whose id extends ours, and one that starts with our prefix but climbs
    # out of it with `..`.
    var sibling = "runs/" + _ID + "-x/obj.bin"
    var climbing = _PREFIX + "../other/obj.bin"
    var store = FakeObjectStore()
    store.seed(sibling, "not mine")
    store.seed(climbing, "not mine")
    store.extra_listed_keys.append(sibling)
    store.extra_listed_keys.append(climbing)
    var b = _open(store^)
    _put(b, "a.bin")
    var v = b.close()
    assert_equal(v.kind, VERDICT_CLEAN, String(v))
    assert_equal(len(v.residue), 0)
    ref c = b.client()
    for call in c.calls:
        if call.startswith("delete_keys"):
            assert_false(sibling in call, call)
            assert_false("../" in call, call)
    assert_true(c.has(sibling), "close deleted another run's object")
    assert_true(c.has(climbing), "close deleted a key outside its prefix")
    assert_false(c.has(_PREFIX + "a.bin"))
    assert_false(c.has(_PREFIX + "_lease.textproto"))


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


def main() raises:
    test_sticky_key_is_leak()
    test_failed_delete_is_leak_and_keeps_the_lease()
    test_failed_delete_request_is_leak()
    test_raising_lists_are_cannot_tell()
    test_out_of_prefix_keys_are_never_deleted_or_charged()
    test_every_failure_is_kept()
    test_failed_lease_put_tears_down_and_raises()
    print("test_bucket_failures: OK")

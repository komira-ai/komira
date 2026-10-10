# TestBucket on an external S3-compatible store, over the in-memory fake: the lease
# is written first; `key()` refuses what would leave the prefix; `as_flags()`
# carries paths, not secrets; the deadline; a clean close; and close is
# idempotent.

from std.testing import assert_equal, assert_false, assert_true

from komira_test_bucket import (
    BACKEND_EXTERNAL_S3,
    FakeObjectStore,
    StoreScope,
    StoreTarget,
    TestBucket,
    open_test_bucket,
)
from komira_test_run_id import FixedWallClock, RunId
from komira_test_verdict import VERDICT_CLEAN


def _scope() -> StoreScope:
    return StoreScope(
        StoreTarget("http://store.invalid:9000", "r1", "test-bucket", "/mnt/creds/credentials"), 600, 60
    )


comptime _NOW: Int = 1790000000
comptime _ID: String = "1790000000-0123456789abcdef"
comptime _PREFIX: String = "runs/1790000000-0123456789abcdef/"


def _open(mut clock: FixedWallClock) raises -> TestBucket[FakeObjectStore]:
    return open_test_bucket(
        RunId(String(_ID), _NOW), _scope(), "//pkg:it", FakeObjectStore(), clock
    )


def _refused(b: TestBucket[FakeObjectStore], rel: String) -> Bool:
    try:
        _ = b.key(rel)
    except:
        return True
    return False


def test_lease_is_the_first_object() raises:
    var clock = FixedWallClock(_NOW)
    var b = _open(clock)
    ref c = b.client()
    assert_equal(len(c.calls), 2)
    assert_equal(c.calls[0], "bind")
    assert_equal(c.calls[1], "put " + _PREFIX + "_lease.textproto")
    assert_false(c.bucket_created, "an external store's bucket must never be created")
    assert_equal(c.target_endpoint, "http://store.invalid:9000")
    assert_equal(c.target_credentials_file, "/mnt/creds/credentials")
    var lease = c.body_text(_PREFIX + "_lease.textproto")
    assert_true("run_id: \"" + _ID + "\"" in lease, lease)
    assert_true("target: \"//pkg:it\"" in lease, lease)
    assert_true("created_unix: 1790000000\n" in lease, lease)
    assert_true("deadline_unix: 1790000600\n" in lease, lease)
    assert_true("backend: \"external-s3\"" in lease, lease)
    assert_equal(b.close().kind, VERDICT_CLEAN)


def test_accessors_keys_and_flags() raises:
    var clock = FixedWallClock(_NOW)
    var b = _open(clock)
    assert_equal(b.prefix(), _PREFIX)
    assert_equal(b.run_id().value, _ID)
    assert_equal(b.endpoint(), "http://store.invalid:9000")
    assert_equal(b.region(), "r1")
    assert_equal(b.bucket(), "test-bucket")
    assert_equal(b.credentials_file(), "/mnt/creds/credentials")
    assert_equal(b.created_unix(), _NOW)
    assert_equal(b.deadline_unix(), _NOW + 600)
    assert_equal(b.backend(), BACKEND_EXTERNAL_S3)

    assert_equal(b.key("seg/0001.log"), _PREFIX + "seg/0001.log")
    for bad in ["", "/abs", "..", "a/../b", "a/..", "_lease.textproto"]:
        assert_true(_refused(b, bad), "key() accepted: " + bad)

    var flags = b.as_flags()
    var want: List[String] = [
        "--s3-endpoint=http://store.invalid:9000",
        "--s3-region=r1",
        "--s3-bucket=test-bucket",
        "--s3-prefix=" + _PREFIX,
        "--aws-shared-credentials-file=/mnt/creds/credentials",
    ]
    assert_equal(len(flags), len(want))
    for i in range(len(want)):
        assert_equal(flags[i], want[i])
    assert_equal(b.close().kind, VERDICT_CLEAN)


def test_deadline_leaves_the_teardown_budget() raises:
    var clock = FixedWallClock(_NOW)
    var b = _open(clock)
    clock.advance(600 - 60 - 1)
    b.check_deadline(clock)  # one second before teardown must start
    clock.advance(1)
    var refused = False
    try:
        b.check_deadline(clock)
    except e:
        refused = True
        assert_true("lease deadline" in String(e), String(e))
    assert_true(refused, "check_deadline passed at deadline - teardown budget")
    assert_equal(b.close().kind, VERDICT_CLEAN)


def test_clean_close_deletes_lease_last_and_relists() raises:
    var clock = FixedWallClock(_NOW)
    var b = _open(clock)
    var body = String("payload")
    b.client().put(b.key("a.bin"), body.as_bytes())
    b.client().put(b.key("dir/b.bin"), body.as_bytes())
    b.client().seed("runs/other-run/x", "not mine")
    var v = b.close()
    assert_equal(v.kind, VERDICT_CLEAN)
    assert_equal(len(v.residue), 0)
    assert_equal(len(v.reasons), 0)
    assert_true(b.is_closed())
    ref c = b.client()
    var n = len(c.calls)
    assert_equal(c.calls[n - 5], "list_keys " + _PREFIX)
    assert_equal(c.calls[n - 4], "delete_keys " + _PREFIX + "a.bin," + _PREFIX + "dir/b.bin")
    # Re-listed before the lease delete: the lease goes only when it is the
    # last key left.
    assert_equal(c.calls[n - 3], "list_keys " + _PREFIX)
    assert_equal(c.calls[n - 2], "delete_keys " + _PREFIX + "_lease.textproto")
    assert_equal(c.calls[n - 1], "list_keys " + _PREFIX)
    assert_false(c.has(_PREFIX + "_lease.textproto"))
    assert_true(c.has("runs/other-run/x"), "close deleted another run's object")

    # Idempotent: the same verdict, and no further call.
    var again = b.close()
    assert_equal(again.kind, VERDICT_CLEAN)
    assert_equal(len(b.client().calls), n)
    v.require_clean()


def test_open_refuses_an_empty_target_label() raises:
    var clock = FixedWallClock(_NOW)
    var refused = False
    try:
        var b = open_test_bucket(
            RunId(String(_ID), _NOW), _scope(), "", FakeObjectStore(), clock
        )
        _ = b.close()
    except e:
        refused = True
        assert_true("target label" in String(e), String(e))
    assert_true(refused, "opened with an empty target label")


def test_open_refuses_an_invalid_run_id() raises:
    var clock = FixedWallClock(_NOW)
    var refused = False
    try:
        var b = open_test_bucket(
            RunId(String("Not/Valid"), _NOW), _scope(), "//p:t", FakeObjectStore(), clock
        )
        _ = b.close()
    except e:
        refused = True
        assert_true("run id" in String(e), String(e))
    assert_true(refused, "opened with an invalid run id")


def test_open_refuses_a_lease_without_a_teardown_reserve() raises:
    var clock = FixedWallClock(_NOW)
    var leases: List[Int] = [600, 600, 0, 60]
    var budgets: List[Int] = [600, 0, 0, 600]
    for i in range(len(leases)):
        var store = FakeObjectStore()
        var refused = False
        try:
            var b = open_test_bucket(
                RunId(String(_ID), _NOW),
                StoreScope(
                    StoreTarget("http://store.invalid:9000", "r1", "test-bucket", "/c"),
                    leases[i],
                    budgets[i],
                ),
                "//p:t",
                store^,
                clock,
            )
            _ = b.close()
        except e:
            refused = True
            assert_true("komira_test_bucket: open: lease: " in String(e), String(e))
        assert_true(refused, "opened with an invalid lease")


def main() raises:
    test_lease_is_the_first_object()
    test_accessors_keys_and_flags()
    test_deadline_leaves_the_teardown_budget()
    test_clean_close_deletes_lease_last_and_relists()
    test_open_refuses_an_empty_target_label()
    test_open_refuses_an_invalid_run_id()
    test_open_refuses_a_lease_without_a_teardown_reserve()
    print("test_bucket_lifecycle: OK")

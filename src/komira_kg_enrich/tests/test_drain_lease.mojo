# =============================================================================
# test_drain_lease.mojo -- the per-partition drain lease.
# =============================================================================
#
# Time is the `now_micros` argument of each call; no test waits.
#
#   exclusion    a second holder cannot take a lease that is held and unexpired;
#                the one second before expiry is still held, the instant of
#                expiry is not; two partitions are two leases; two clones of one
#                store see one lease.
#   epochs       the first grant has epoch 1; a takeover after expiry and a
#                re-acquire by the same holder each add one; the expiry moves
#                with the new grant.
#   release      a released lease is free at once, and the next holder's epoch is
#                higher than the released one's (the epoch never goes back); a
#                holder whose lease was taken over, or renewed, releases nothing
#                and the new holder keeps the lease.
#   race         the lease changing between the worker reading it and swapping it
#                (another worker renewing a lease that had expired) makes the
#                takeover fail, whether the change lands between the two reads
#                or after them; the stale reader is not granted a lease it never
#                saw.
#   overflow     a time and ttl whose sum does not fit in an Int64 are refused by
#                acquire, renew and take_over_malformed, and nothing is stored;
#                a sum of exactly Int64.MAX is allowed.
#   renew        keeps the epoch and extends the expiry (an excluded holder is
#                excluded until the new expiry); a grant at or past its expiry,
#                a grant whose lease was taken over, and a grant that was
#                already renewed (an old etag) are lost (None); a renewed grant
#                releases the lease.
#   malformed    a stored record that does not decode is reported by acquire; take_over_malformed replaces it (epoch one more than a
#                numeric epoch line, else 1, also for a record that is not
#                UTF-8) and the taker then excludes others; it never takes a
#                valid lease, held or expired, and takes nothing when absent.
#   refusal      a ttl of zero or less, a negative time, an unsafe partition id
#                or holder token, a prefix that is empty or ends in '/', and a
#                lease object that is not three lines are errors.
# =============================================================================

from std.memory import ArcPointer
from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from komira_objectstore import (
    CloneableConditionalWriteStore,
    CoalescePolicy,
    ConditionalWriteStore,
    DelimiterFaithfulConditionalStore,
    ListResult,
    ObjectMeta,
    ObjectStore,
    Path,
    WritePrecondition,
)

from komira_kg_enrich import DrainLease


comptime Store = DelimiterFaithfulConditionalStore
comptime TTL = Int64(1000)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _lease() raises -> DrainLease[Store]:
    return DrainLease[Store](Store(), "locks")


def test_first_acquire_is_epoch_one_and_excludes_others() raises:
    var lease = _lease()
    var a = lease.try_acquire("p", "worker-a", Int64(100), TTL)
    assert_true(Bool(a))
    assert_equal(a.value().epoch, Int64(1))
    assert_equal(a.value().expires_at_micros, Int64(1100))
    assert_equal(a.value().holder_token, "worker-a")
    assert_equal(a.value().partition_id, "p")
    var b = lease.try_acquire("p", "worker-b", Int64(101), TTL)
    assert_false(Bool(b))


def test_expiry_boundary() raises:
    var lease = _lease()
    _ = lease.try_acquire("p", "worker-a", Int64(0), TTL)
    # Expires at 1000: still held at 999, free at 1000.
    assert_false(Bool(lease.try_acquire("p", "worker-b", Int64(999), TTL)))
    var b = lease.try_acquire("p", "worker-b", Int64(1000), TTL)
    assert_true(Bool(b))
    assert_equal(b.value().epoch, Int64(2))
    assert_equal(b.value().expires_at_micros, Int64(2000))
    assert_equal(b.value().holder_token, "worker-b")
    # worker-b now holds it, so worker-a is out until 2000.
    assert_false(Bool(lease.try_acquire("p", "worker-a", Int64(1999), TTL)))


def test_same_holder_renews_with_a_higher_epoch() raises:
    var lease = _lease()
    var first = lease.try_acquire("p", "worker-a", Int64(0), TTL)
    var again = lease.try_acquire("p", "worker-a", Int64(500), TTL)
    assert_true(Bool(again))
    assert_equal(again.value().epoch, Int64(2))
    assert_equal(again.value().expires_at_micros, Int64(1500))
    # The renewed lease keeps others out past the first grant's expiry.
    assert_false(Bool(lease.try_acquire("p", "worker-b", Int64(1200), TTL)))
    assert_equal(first.value().epoch, Int64(1))


def test_partitions_are_independent() raises:
    var lease = _lease()
    assert_true(Bool(lease.try_acquire("p1", "worker-a", Int64(0), TTL)))
    assert_true(Bool(lease.try_acquire("p2", "worker-b", Int64(0), TTL)))
    assert_false(Bool(lease.try_acquire("p1", "worker-b", Int64(1), TTL)))


def test_two_handles_on_one_store_see_one_lease() raises:
    var store = Store()
    var one = DrainLease[Store](store.clone(), "locks")
    var two = DrainLease[Store](store.clone(), "locks")
    assert_true(Bool(one.try_acquire("p", "worker-a", Int64(0), TTL)))
    assert_false(Bool(two.try_acquire("p", "worker-b", Int64(1), TTL)))


def test_release_frees_the_lease_and_the_epoch_keeps_rising() raises:
    var lease = _lease()
    var a = lease.try_acquire("p", "worker-a", Int64(0), TTL)
    lease.release(a.value())
    var b = lease.try_acquire("p", "worker-b", Int64(1), TTL)
    assert_true(Bool(b))
    assert_equal(b.value().epoch, Int64(2))
    lease.release(b.value())
    var c = lease.try_acquire("p", "worker-a", Int64(2), TTL)
    assert_equal(c.value().epoch, Int64(3))


def test_release_by_a_holder_that_lost_the_lease_changes_nothing() raises:
    var lease = _lease()
    var a = lease.try_acquire("p", "worker-a", Int64(0), TTL)
    # worker-a's lease expires and worker-b takes over.
    var b = lease.try_acquire("p", "worker-b", Int64(2000), TTL)
    assert_true(Bool(b))
    # A late release by worker-a must not free worker-b's lease.
    lease.release(a.value())
    assert_false(Bool(lease.try_acquire("p", "worker-c", Int64(2001), TTL)))
    # Nor after a renewal by the same holder.
    var b2 = lease.try_acquire("p", "worker-b", Int64(2100), TTL)
    lease.release(b.value())
    assert_false(Bool(lease.try_acquire("p", "worker-c", Int64(2101), TTL)))
    lease.release(b2.value())
    assert_true(Bool(lease.try_acquire("p", "worker-c", Int64(2102), TTL)))


# ---- the lease changes between the reads and the swap ----


struct _Hook(Movable):
    var armed: Bool
    var reads_left: Int
    var key: String
    var bytes: List[UInt8]

    def __init__(out self):
        self.armed = False
        self.reads_left = 0
        self.key = String("")
        self.bytes = List[UInt8]()


struct _RacingStore(CloneableConditionalWriteStore, ConditionalWriteStore, ObjectStore, Movable):
    """A store that, once armed, writes one object right after the n-th `head`
    or `get` returns, as another worker would between this worker's reads and
    its swap."""

    var inner: DelimiterFaithfulConditionalStore
    var hook: ArcPointer[_Hook]

    def __init__(out self):
        self.inner = DelimiterFaithfulConditionalStore()
        self.hook = ArcPointer[_Hook](_Hook())

    def __init__(out self, *, var inner: DelimiterFaithfulConditionalStore, var hook: ArcPointer[_Hook]):
        self.inner = inner^
        self.hook = hook^

    def clone(self) -> Self:
        return Self(inner=self.inner.clone(), hook=self.hook.copy())

    def arm(self, after_reads: Int, key: String, var bytes: List[UInt8]):
        self.hook[].armed = True
        self.hook[].reads_left = after_reads
        self.hook[].key = key.copy()
        self.hook[].bytes = bytes^

    def _fire(self) raises:
        if self.hook[].armed:
            self.hook[].reads_left -= 1
            if self.hook[].reads_left <= 0:
                self.hook[].armed = False
                _ = self.inner.put(
                    Path.parse(self.hook[].key.copy()), self.hook[].bytes.copy()
                )

    def head(self, path: Path) raises -> ObjectMeta:
        var m = self.inner.head(path)
        self._fire()
        return m^

    def get(self, path: Path) raises -> List[UInt8]:
        var b = self.inner.get(path)
        self._fire()
        return b^

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        return self.inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self.inner.coalesce_policy()

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        return self.inner.conditional_put(path, bytes, precond)

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        return self.inner.compare_and_swap(path, bytes, expected_version)

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        return self.inner.put(path, bytes)

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        return self.inner.get_range(path, start, length)

    def delete(self, path: Path) raises -> None:
        self.inner.delete(path)


def test_a_lease_renewed_between_the_reads_is_not_taken_over() raises:
    var store = _RacingStore()
    var lease = DrainLease[_RacingStore](store.clone(), "locks")
    # worker-a holds the lease until 1000.
    _ = lease.try_acquire("p", "worker-a", Int64(0), TTL)
    # At 1500 worker-b reads an expired lease; worker-a renews it until 9000
    # (epoch 5), the write landing right after b's first read.
    store.arm(1, "locks/p.lease", _bytes("worker-a\n5\n9000"))
    var b = lease.try_acquire("p", "worker-b", Int64(1500), TTL)
    assert_false(Bool(b))
    # worker-a's renewal stands: still held at 8999 against another worker.
    assert_false(Bool(lease.try_acquire("p", "worker-c", Int64(8999), TTL)))


def test_a_lease_renewed_after_both_reads_loses_the_swap() raises:
    var store = _RacingStore()
    var lease = DrainLease[_RacingStore](store.clone(), "locks")
    _ = lease.try_acquire("p", "worker-a", Int64(0), TTL)
    # The renewal lands after both of worker-b's reads, before its swap.
    store.arm(2, "locks/p.lease", _bytes("worker-a\n5\n9000"))
    var b = lease.try_acquire("p", "worker-b", Int64(1500), TTL)
    assert_false(Bool(b))
    assert_false(Bool(lease.try_acquire("p", "worker-c", Int64(8999), TTL)))


# ---- refusals ----


def test_invalid_arguments_are_errors() raises:
    var lease = _lease()
    with assert_raises(contains="ttl_micros must be positive"):
        _ = lease.try_acquire("p", "w", Int64(0), Int64(0))
    with assert_raises(contains="ttl_micros must be positive"):
        _ = lease.try_acquire("p", "w", Int64(0), Int64(-5))
    with assert_raises(contains="now_micros must not be negative"):
        _ = lease.try_acquire("p", "w", Int64(-1), TTL)
    with assert_raises(contains="partition_id must not be empty"):
        _ = lease.try_acquire("", "w", Int64(0), TTL)
    with assert_raises(contains="partition_id must not hold"):
        _ = lease.try_acquire("a/b", "w", Int64(0), TTL)
    with assert_raises(contains="holder_token must not hold"):
        _ = lease.try_acquire("p", "w\nx", Int64(0), TTL)
    with assert_raises(contains="holder_token must not be empty"):
        _ = lease.try_acquire("p", "", Int64(0), TTL)


def test_bad_prefixes_are_errors() raises:
    with assert_raises(contains="lease prefix must not be empty"):
        _ = DrainLease[Store](Store(), "")
    with assert_raises(contains="must not start or end with '/'"):
        _ = DrainLease[Store](Store(), "locks/")
    with assert_raises(contains="must not hold '//'"):
        _ = DrainLease[Store](Store(), "a//b")
    # A nested prefix is fine.
    var nested = DrainLease[Store](Store(), "area/locks")
    assert_true(Bool(nested.try_acquire("p", "w", Int64(0), TTL)))


def test_malformed_lease_object_is_an_error() raises:
    var store = Store()
    var lease = DrainLease[Store](store.clone(), "locks")
    _ = store.put(Path.parse("locks/p.lease"), _bytes("holder-only"))
    with assert_raises(contains="malformed lease object"):
        _ = lease.try_acquire("p", "w", Int64(0), TTL)
    _ = store.put(Path.parse("locks/p.lease"), _bytes("h\nnot-a-number\n5"))
    with assert_raises(contains="not a decimal number"):
        _ = lease.try_acquire("p", "w", Int64(0), TTL)


# ---- overflow ----


def test_an_expiry_that_overflows_is_refused_and_stores_nothing() raises:
    var store = Store()
    var lease = DrainLease[Store](store.clone(), "locks")
    var now = Int64(9223372036854775800)
    with assert_raises(contains="does not fit"):
        _ = lease.try_acquire("p", "w", now, Int64(100))
    with assert_raises(contains="does not fit"):
        _ = lease.try_acquire("p", "w", now, Int64.MAX)
    # Nothing was stored: the partition is free, with epoch 1.
    var ok = lease.try_acquire("p", "w", Int64(0), TTL)
    assert_equal(ok.value().epoch, Int64(1))
    with assert_raises(contains="does not fit"):
        _ = lease.renew(ok.value(), now, Int64(100))
    with assert_raises(contains="does not fit"):
        _ = lease.take_over_malformed("p", "w", now, Int64(100))


def test_an_expiry_of_exactly_int64_max_is_allowed_and_stays_decodable() raises:
    var lease = _lease()
    var now = Int64(9223372036854775707)
    var g = lease.try_acquire("p", "w", now, Int64(100))
    assert_equal(g.value().expires_at_micros, Int64.MAX)
    # The stored record decodes: another holder reads it as held.
    assert_false(Bool(lease.try_acquire("p", "x", now + Int64(1), Int64(1))))


# ---- renew ----


def test_renew_keeps_the_epoch_and_extends_the_expiry() raises:
    var lease = _lease()
    var g = lease.try_acquire("p", "a", Int64(0), TTL)
    var r = lease.renew(g.value(), Int64(900), TTL)
    assert_true(Bool(r))
    assert_equal(r.value().epoch, Int64(1))
    assert_equal(r.value().expires_at_micros, Int64(1900))
    # The old expiry (1000) no longer frees the lease; the new one (1900) does.
    assert_false(Bool(lease.try_acquire("p", "b", Int64(1000), TTL)))
    assert_false(Bool(lease.try_acquire("p", "b", Int64(1899), TTL)))
    var b = lease.try_acquire("p", "b", Int64(1900), TTL)
    assert_equal(b.value().epoch, Int64(2))


def test_renew_is_lost_at_or_past_expiry() raises:
    var lease = _lease()
    var g = lease.try_acquire("p", "a", Int64(0), TTL)
    assert_false(Bool(lease.renew(g.value(), Int64(1000), TTL)))
    assert_false(Bool(lease.renew(g.value(), Int64(5000), TTL)))
    # Not renewed: the lease still ends at its first expiry.
    assert_true(Bool(lease.try_acquire("p", "b", Int64(1000), TTL)))


def test_renew_is_lost_after_a_takeover_and_after_an_earlier_renewal() raises:
    var lease = _lease()
    var g = lease.try_acquire("p", "a", Int64(0), TTL)
    var r = lease.renew(g.value(), Int64(10), TTL)
    assert_true(Bool(r))
    # The first grant's etag is stale now.
    assert_false(Bool(lease.renew(g.value(), Int64(20), TTL)))
    # The renewed grant works, then is lost to a takeover.
    var r2 = lease.renew(r.value(), Int64(20), TTL)
    assert_true(Bool(r2))
    # The same holder token takes the lease again (epoch 2) before expiry; the
    # grant it held is stale although it has not expired.
    var again = lease.try_acquire("p", "a", Int64(30), TTL)
    assert_equal(again.value().epoch, Int64(2))
    assert_false(Bool(lease.renew(r2.value(), Int64(31), TTL)))
    assert_true(Bool(lease.renew(again.value(), Int64(31), TTL)))


def test_a_renewed_grant_releases_the_lease() raises:
    var lease = _lease()
    var g = lease.try_acquire("p", "a", Int64(0), TTL)
    var r = lease.renew(g.value(), Int64(10), TTL)
    # The first grant's etag is stale: releasing it changes nothing.
    lease.release(g.value())
    assert_false(Bool(lease.try_acquire("p", "b", Int64(11), TTL)))
    lease.release(r.value())
    assert_true(Bool(lease.try_acquire("p", "b", Int64(12), TTL)))


# ---- malformed records ----


def test_take_over_malformed_replaces_only_a_record_that_does_not_decode() raises:
    var store = Store()
    var lease = DrainLease[Store](store.clone(), "locks")
    var key = Path.parse("locks/p.lease")

    # Absent: nothing to take over.
    assert_false(Bool(lease.take_over_malformed("p", "w", Int64(0), TTL)))

    # A record with a numeric epoch line: epoch is one more.
    _ = store.put(key, _bytes("h\n7\nsoon"))
    with assert_raises(contains="lease expiry of"):
        _ = lease.try_acquire("p", "w", Int64(0), TTL)
    var g = lease.take_over_malformed("p", "w", Int64(0), TTL)
    assert_true(Bool(g))
    assert_equal(g.value().epoch, Int64(8))
    assert_false(Bool(lease.try_acquire("p", "x", Int64(1), TTL)))
    # The taker's lease is a valid lease now: it cannot be taken over this way.
    assert_false(Bool(lease.take_over_malformed("p", "x", Int64(2000), TTL)))

    # No numeric epoch line: epoch 1.
    _ = store.put(key, _bytes("only one line"))
    assert_equal(
        lease.take_over_malformed("p", "w", Int64(0), TTL).value().epoch,
        Int64(1),
    )


def test_take_over_malformed_handles_a_record_that_is_not_utf8() raises:
    var store = Store()
    var lease = DrainLease[Store](store.clone(), "locks")
    var raw = _bytes("h\n3\n")
    raw.append(UInt8(0xFF))
    _ = store.put(Path.parse("locks/p.lease"), raw)
    with assert_raises():
        _ = lease.try_acquire("p", "w", Int64(0), TTL)
    var g = lease.take_over_malformed("p", "w", Int64(0), TTL)
    assert_equal(g.value().epoch, Int64(4))


def test_take_over_malformed_never_takes_a_valid_lease() raises:
    var lease = _lease()
    var g = lease.try_acquire("p", "a", Int64(0), TTL)
    # Held and valid.
    assert_false(Bool(lease.take_over_malformed("p", "b", Int64(1), TTL)))
    # Expired and valid: still not this path's to take.
    assert_false(Bool(lease.take_over_malformed("p", "b", Int64(5000), TTL)))
    # a's lease was left alone.
    assert_true(Bool(lease.renew(g.value(), Int64(2), TTL)))


def test_an_epoch_line_too_large_to_add_one_to_restarts_at_one() raises:
    var store = Store()
    var lease = DrainLease[Store](store.clone(), "locks")
    _ = store.put(
        Path.parse("locks/p.lease"), _bytes("h\n9223372036854775807\nx")
    )
    var g = lease.take_over_malformed("p", "w", Int64(0), TTL)
    assert_equal(g.value().epoch, Int64(1))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

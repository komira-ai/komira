# =============================================================================
# src/komira_http/tests/test_pool_race.mojo — PendingCheckout late-binding
# race via SelectFirstNotify
# =============================================================================
# Asserts:
# "late-binding race tested over ScriptedStream — saturate pool,
# request another checkout, free one; assert checkout resolves."
#
# Tests use the deterministic ordering trick: SelectFirstNotify's
# await_first has a fast-path gate check before parking. If the test
# fires source 0 (via pool.checkin) BEFORE the awaiter calls
# await_conn, the awaiter returns immediately via the fast path.
# This makes the tests synchronous + deterministic without needing
# real reactor stepping.

from std.memory import OwnedPointer
from std.testing import assert_equal, assert_false, assert_true

from komira_http.client.pool import (
    ClientConn,
    PendingCheckout,
    PerCorePool,
    PoolKey,
    PoolSizingKnobs,
)
from komira_http.transport.scripted import ScriptedStream


def _make_pool(max_conns: Int) -> PerCorePool[ScriptedStream]:
    var k = PoolSizingKnobs(
        max_conns_per_host=max_conns,
        max_idle_per_host=16,
        recv_ring_size=64 * 1024,
        idle_threshold_us=60_000_000,
    )
    return PerCorePool[ScriptedStream].new(k)


def _make_conn(
    key: PoolKey, now_us: Int,
) -> OwnedPointer[ClientConn[ScriptedStream]]:
    var stream = ScriptedStream.empty()
    return OwnedPointer[ClientConn[ScriptedStream]](
        ClientConn[ScriptedStream].new(stream^, key.copy(), now_us)
    )


def test_checkout_or_pending_ready_when_idle() raises:
    """If an idle conn is available, checkout_or_pending returns
    READY (no pending handle)."""
    var pool = _make_pool(max_conns=2)
    var key = PoolKey.http(String("127.0.0.1"), UInt16(80))
    # Seed an idle conn.
    pool.insert_dialed(key.copy())
    var c2 = _make_conn(key.copy(), 200)
    pool.checkin(c2^, 200)
    assert_equal(pool.idle_count_for(key.copy()), 1)
    # checkout_or_pending should return READY.
    var outcome = pool.checkout_or_pending(key.copy(), 300)
    assert_true(outcome.is_ready())
    assert_false(outcome.is_pending())
    assert_false(outcome.is_needs_dial())
    var conn = outcome.take_conn()
    _ = conn^


def test_checkout_or_pending_needs_dial_when_below_capacity() raises:
    """If no idle conn but bucket below max_conns -> NEEDS_DIAL."""
    var pool = _make_pool(max_conns=4)
    var key = PoolKey.http(String("127.0.0.1"), UInt16(80))
    var outcome = pool.checkout_or_pending(key.copy(), 100)
    assert_true(outcome.is_needs_dial())
    assert_false(outcome.is_pending())
    assert_false(outcome.is_ready())


def test_checkout_or_pending_at_capacity_returns_pending() raises:
    """ACCEPTANCE GATE (g): when bucket at max_conns AND no idle, the
    checkout pends via PendingCheckout.
    """
    var pool = _make_pool(max_conns=1)
    var key = PoolKey.http(String("127.0.0.1"), UInt16(80))
    # Saturate: one in_use.
    pool.insert_dialed(key.copy())
    assert_equal(pool.in_use_for(key.copy()), 1)
    # Next checkout: at-capacity, returns PENDING.
    var outcome = pool.checkout_or_pending(key.copy(), 200)
    assert_true(outcome.is_pending())
    assert_false(outcome.is_ready())
    assert_false(outcome.is_needs_dial())
    # Bucket records the waiter.
    assert_equal(pool.waiter_count_for(key.copy()), 1)
    # Drop the pending handle (test cleanup; the bucket's clone holds
    # the ArcPointer until the pool itself drops).
    var pending = outcome.take_pending()
    _ = pending^


def test_late_binding_race_checkin_fulfills_waiter() raises:
    """ACCEPTANCE GATE (f): the late-binding race resolves a pending
    checkout when a conn is freed via checkin.

    Saturate pool with one in_use; spawn a pending checkout; checkin
    the in_use conn; pending.await_conn returns with the freed conn.

    Uses the deterministic ordering trick — checkin fires source 0
    BEFORE the awaiter parks; SelectFirstNotify's fast-path gate check
    returns immediately on await_first.
    """
    var pool = _make_pool(max_conns=1)
    var key = PoolKey.http(String("127.0.0.1"), UInt16(80))
    # Saturate.
    pool.insert_dialed(key.copy())
    # Pend.
    var outcome = pool.checkout_or_pending(key.copy(), 200)
    assert_true(outcome.is_pending())
    var pending = outcome.take_pending()
    assert_equal(pool.waiter_count_for(key.copy()), 1)
    # Free the in_use conn -- fires source 0 on the waiter.
    var freed = _make_conn(key.copy(), 300)
    pool.checkin(freed^, 300)
    # Bucket: waiter dequeued; in_use stays at 1 (the conn moved to
    # the awaiter, not back to idle).
    assert_equal(pool.waiter_count_for(key.copy()), 0)
    assert_equal(pool.in_use_for(key.copy()), 1)
    assert_equal(pool.idle_count_for(key.copy()), 0)
    # await_conn returns immediately (fast-path gate hit).
    var conn = pending.await_conn()
    assert_true(conn[].is_healthy())
    assert_true(conn[].key() == key)
    assert_equal(conn[].last_used_us(), 300)
    _ = conn^


def test_fifo_waiter_ordering() raises:
    """Two pending checkouts; first checkin fulfills waiter A; second
    checkin fulfills waiter B."""
    var pool = _make_pool(max_conns=1)
    var key = PoolKey.http(String("127.0.0.1"), UInt16(80))
    # Saturate.
    pool.insert_dialed(key.copy())
    # Pend A then B.
    var oa = pool.checkout_or_pending(key.copy(), 200)
    var pending_a = oa.take_pending()
    var ob = pool.checkout_or_pending(key.copy(), 200)
    var pending_b = ob.take_pending()
    assert_equal(pool.waiter_count_for(key.copy()), 2)
    # Free one -> fulfills A.
    var freed1 = _make_conn(key.copy(), 300)
    pool.checkin(freed1^, 300)
    assert_equal(pool.waiter_count_for(key.copy()), 1)
    var conn_a = pending_a.await_conn()
    assert_equal(conn_a[].last_used_us(), 300)
    # Free another -> fulfills B.
    var freed2 = _make_conn(key.copy(), 400)
    pool.checkin(freed2^, 400)
    assert_equal(pool.waiter_count_for(key.copy()), 0)
    var conn_b = pending_b.await_conn()
    assert_equal(conn_b[].last_used_us(), 400)
    _ = conn_a^
    _ = conn_b^


def test_unhealthy_checkin_does_not_fulfill_waiter() raises:
    """An unhealthy conn is dropped on checkin even if there are
    waiters — the waiter stays pending. (A pool could dial a fresh conn
    in this scenario; this covers the source-0 happy path only.)
    """
    var pool = _make_pool(max_conns=1)
    var key = PoolKey.http(String("127.0.0.1"), UInt16(80))
    pool.insert_dialed(key.copy())
    var outcome = pool.checkout_or_pending(key.copy(), 200)
    var pending = outcome.take_pending()
    assert_equal(pool.waiter_count_for(key.copy()), 1)
    # Check in an unhealthy conn.
    var bad = _make_conn(key.copy(), 300)
    bad[].mark_unhealthy()
    pool.checkin(bad^, 300)
    # Unhealthy path falls through to standard "drop"; in_use
    # decrements; waiter remains pending.
    assert_equal(pool.waiter_count_for(key.copy()), 1)
    assert_equal(pool.in_use_for(key.copy()), 0)
    # Cleanup: fulfill the waiter so the test exits cleanly.
    var good = _make_conn(key.copy(), 400)
    pool.checkin(good^, 400)
    # After the second checkin (with a waiter present and conn
    # healthy), in_use bumps back to 0 already since the unhealthy
    # checkin decremented it, then this healthy-with-waiter checkin
    # does NOT change in_use (the conn moves to the waiter).
    var conn = pending.await_conn()
    _ = conn^


def test_capacity_with_idle_returns_ready_no_pending() raises:
    """If the bucket has an idle conn AND in_use is at capacity-1,
    checkout_or_pending returns READY (the idle slab is the first
    thing it tries; the capacity check is only relevant when no idle
    is available)."""
    var pool = _make_pool(max_conns=1)
    var key = PoolKey.http(String("127.0.0.1"), UInt16(80))
    # Seed: in_use=0, idle=1.
    pool.insert_dialed(key.copy())
    var c2 = _make_conn(key.copy(), 200)
    pool.checkin(c2^, 200)
    assert_equal(pool.in_use_for(key.copy()), 0)
    assert_equal(pool.idle_count_for(key.copy()), 1)
    # Checkout -> returns from idle.
    var outcome = pool.checkout_or_pending(key.copy(), 300)
    assert_true(outcome.is_ready())
    var conn = outcome.take_conn()
    _ = conn^


def main() raises:
    test_checkout_or_pending_ready_when_idle()
    test_checkout_or_pending_needs_dial_when_below_capacity()
    test_checkout_or_pending_at_capacity_returns_pending()
    test_late_binding_race_checkin_fulfills_waiter()
    test_fifo_waiter_ordering()
    test_unhealthy_checkin_does_not_fulfill_waiter()
    test_capacity_with_idle_returns_ready_no_pending()
    print("OK: test_pool_race")

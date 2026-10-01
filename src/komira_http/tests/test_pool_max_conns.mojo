# =============================================================================
# src/komira_http/tests/test_pool_max_conns.mojo — max_conns_per_host
# queueing
# =============================================================================
# Asserts:
# "max_conns_per_host queueing — saturate pool past limit, assert
# next checkout pends until freed".

from std.memory import OwnedPointer
from std.testing import assert_equal, assert_true

from komira_http.client.pool import (
    ClientConn,
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


def test_max_conns_one_three_checkouts_two_pend() raises:
    """ACCEPTANCE GATE (g): max_conns_per_host=1, dial once, then
    three more checkouts -> 1st returns the in-use conn never (it's
    held), checkouts 2-3 both pend until freed."""
    var pool = _make_pool(max_conns=1)
    var key = PoolKey.http(String("127.0.0.1"), UInt16(80))
    # Saturate.
    pool.insert_dialed(key.copy())
    # Two checkouts: both pend.
    var oa = pool.checkout_or_pending(key.copy(), 200)
    var ob = pool.checkout_or_pending(key.copy(), 200)
    assert_true(oa.is_pending())
    assert_true(ob.is_pending())
    assert_equal(pool.waiter_count_for(key.copy()), 2)
    var pa = oa.take_pending()
    var pb = ob.take_pending()
    # Free one -> waiter A resolves.
    var d1 = _make_conn(key.copy(), 300)
    pool.checkin(d1^, 300)
    var ca = pa.await_conn()
    assert_equal(pool.waiter_count_for(key.copy()), 1)
    # Free another -> waiter B resolves.
    var d2 = _make_conn(key.copy(), 400)
    pool.checkin(d2^, 400)
    var cb = pb.await_conn()
    assert_equal(pool.waiter_count_for(key.copy()), 0)
    _ = ca^
    _ = cb^


def test_max_conns_three_six_checkouts_three_pend() raises:
    """max_conns=3, saturate 3 in_use, 3 more checkouts pend.
    Free 3 -> all resolve in FIFO order."""
    var pool = _make_pool(max_conns=3)
    var key = PoolKey.http(String("127.0.0.1"), UInt16(80))
    # Saturate with 3.
    pool.insert_dialed(key.copy())
    pool.insert_dialed(key.copy())
    pool.insert_dialed(key.copy())
    assert_equal(pool.in_use_for(key.copy()), 3)
    # Three more checkouts -> all pend.
    var oa = pool.checkout_or_pending(key.copy(), 200)
    var ob = pool.checkout_or_pending(key.copy(), 200)
    var oc = pool.checkout_or_pending(key.copy(), 200)
    assert_true(oa.is_pending())
    assert_true(ob.is_pending())
    assert_true(oc.is_pending())
    assert_equal(pool.waiter_count_for(key.copy()), 3)
    var pa = oa.take_pending()
    var pb = ob.take_pending()
    var pc = oc.take_pending()
    # Free 3 conns (one at a time); each resolves in FIFO order
    # (last_used 300, 400, 500).
    var d1 = _make_conn(key.copy(), 300)
    pool.checkin(d1^, 300)
    var ca = pa.await_conn()
    assert_equal(ca[].last_used_us(), 300)
    var d2 = _make_conn(key.copy(), 400)
    pool.checkin(d2^, 400)
    var cb = pb.await_conn()
    assert_equal(cb[].last_used_us(), 400)
    var d3 = _make_conn(key.copy(), 500)
    pool.checkin(d3^, 500)
    var cc = pc.await_conn()
    assert_equal(cc[].last_used_us(), 500)
    assert_equal(pool.waiter_count_for(key.copy()), 0)
    _ = ca^
    _ = cb^
    _ = cc^


def test_max_conns_independent_per_host() raises:
    """max_conns_per_host is per-bucket — saturating host A does not
    block host B."""
    var pool = _make_pool(max_conns=1)
    var k_a = PoolKey.http(String("a.example.com"), UInt16(80))
    var k_b = PoolKey.http(String("b.example.com"), UInt16(80))
    # Saturate A.
    pool.insert_dialed(k_a.copy())
    # A is at capacity; checkout pends.
    var outcome_a = pool.checkout_or_pending(k_a.copy(), 200)
    assert_true(outcome_a.is_pending())
    var pa = outcome_a.take_pending()
    # B is empty; checkout returns NEEDS_DIAL.
    var outcome_b = pool.checkout_or_pending(k_b.copy(), 200)
    assert_true(outcome_b.is_needs_dial())
    # Cleanup A.
    var d = _make_conn(k_a.copy(), 300)
    pool.checkin(d^, 300)
    var conn = pa.await_conn()
    _ = conn^


def test_max_conns_capacity_check_includes_in_flight_dials() raises:
    """insert_dialed bumps in_use; that counts toward max_conns even
    before the conn is consumed by the caller."""
    var pool = _make_pool(max_conns=2)
    var key = PoolKey.http(String("127.0.0.1"), UInt16(80))
    pool.insert_dialed(key.copy())
    # First checkout NEEDS_DIAL (room for one more).
    var o1 = pool.checkout_or_pending(key.copy(), 200)
    assert_true(o1.is_needs_dial())
    pool.insert_dialed(key.copy())
    # Now bucket at max; next checkout pends.
    var o2 = pool.checkout_or_pending(key.copy(), 300)
    assert_true(o2.is_pending())
    # Cleanup.
    var pending = o2.take_pending()
    var d = _make_conn(key.copy(), 400)
    pool.checkin(d^, 400)
    var conn = pending.await_conn()
    _ = conn^


def test_reuse_ratio_warm_pool_no_extra_dials() raises:
    """ACCEPTANCE GATE (a) test-level: a warm pool (single conn, many
    checkout-checkin cycles) results in dials_total = 1, not N.
    Verifies the 100-checkout-checkin cycle keeps dials = 1.
    """
    var pool = _make_pool(max_conns=4)
    var key = PoolKey.http(String("127.0.0.1"), UInt16(80))
    # First checkout: NEEDS_DIAL.
    var o = pool.checkout_or_pending(key.copy(), 100)
    assert_true(o.is_needs_dial())
    # Caller dials and inserts.
    pool.insert_dialed(key.copy())
    assert_equal(pool.dials_total(), 1)
    # Now do 100 checkin+checkout cycles -> 0 extra dials.
    var i = 0
    while i < 100:
        var d = _make_conn(key.copy(), 200 + i * 100)
        pool.checkin(d^, 200 + i * 100)
        var o2 = pool.checkout_or_pending(key.copy(), 200 + i * 100)
        assert_true(o2.is_ready())
        var conn = o2.take_conn()
        _ = conn^
        i = i + 1
    # dials_total still 1 — gate (a) satisfied test-level.
    assert_equal(pool.dials_total(), 1)


def main() raises:
    test_max_conns_one_three_checkouts_two_pend()
    test_max_conns_three_six_checkouts_three_pend()
    test_max_conns_independent_per_host()
    test_max_conns_capacity_check_includes_in_flight_dials()
    test_reuse_ratio_warm_pool_no_extra_dials()
    print("OK: test_pool_max_conns")

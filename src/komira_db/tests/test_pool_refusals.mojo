# =============================================================================
# komira_db/tests/test_pool_refusals.mojo
# The generic Pool[T]'s refusals and teardown: every lease-taking method's
# out-of-range refusal, the exhausted checkout, the double return, the double
# take / vacate, a non-positive size, a discarded slot skipped by checkout, and
# close() reaching every live slot but not a vacated one.
# =============================================================================
# `_Res` is a minimal `PooledResource` (an id, and `closed` set by `close`).
# Each refusal is checked by its exact message (written out by hand from
# pool.mojo's raise sites), so a guard that fires from the wrong check, or a
# bounds check off by one, goes red. Leases at both sides of the valid range
# (-1 and size) are tried for every method.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_db.pool import Pool, PooledResource


struct _ResConfig(Copyable, Movable, Deinitable):
    var base: Int

    def __init__(out self, base: Int):
        self.base = base


struct _Res(PooledResource):
    comptime Config = _ResConfig

    var id: Int
    var closed: Bool

    def __init__(out self, id: Int):
        self.id = id
        self.closed = False

    @staticmethod
    def pooled_connect(var config: _ResConfig) raises -> _Res:
        return _Res(config.base)

    def close(mut self):
        self.closed = True


def _pool(size: Int) raises -> Pool[_Res]:
    return Pool[_Res].connect(_ResConfig(100), size)


def _err_take(mut p: Pool[_Res], lease: Int) -> String:
    try:
        _ = p.take(lease)
    except e:
        return String(e)
    return String("no error")


def _err_vacate(mut p: Pool[_Res], lease: Int) -> String:
    try:
        _ = p.vacate(lease)
    except e:
        return String(e)
    return String("no error")


def _err_give_back(mut p: Pool[_Res], lease: Int) -> String:
    try:
        p.give_back(lease, _Res(7))
    except e:
        return String(e)
    return String("no error")


def _err_restore(mut p: Pool[_Res], lease: Int) -> String:
    try:
        p.restore(lease, _Res(7))
    except e:
        return String(e)
    return String("no error")


def _err_is_vacated(p: Pool[_Res], lease: Int) -> String:
    try:
        _ = p.is_vacated(lease)
    except e:
        return String(e)
    return String("no error")


def _err_return(mut p: Pool[_Res], lease: Int) -> String:
    try:
        p.return_lease(lease)
    except e:
        return String(e)
    return String("no error")


def _err_discard(mut p: Pool[_Res], lease: Int) -> String:
    try:
        p.discard(lease)
    except e:
        return String(e)
    return String("no error")


def _err_checkout(mut p: Pool[_Res]) -> String:
    try:
        _ = p.checkout()
    except e:
        return String(e)
    return String("no error")


def _oor(verb: String, lease: Int) -> String:
    return "Pool." + verb + ": lease " + String(lease) + " out of range"


# =============================================================================
# 1 — size and exhaustion
# =============================================================================
def test_connect_refuses_non_positive_size() raises:
    """`Pool.connect` refuses size 0 and a negative size with the size named."""
    for size in [0, -3]:
        var msg = String("no error")
        try:
            _ = _pool(size)
        except e:
            msg = String(e)
        assert_equal(
            msg, "Pool.connect: size must be > 0 (got " + String(size) + ")"
        )
    var one = _pool(1)
    assert_equal(one.size(), 1, "size 1 is the smallest pool")
    print("  [1] connect refuses size 0 and -3 OK")


def test_checkout_exhausts_then_frees() raises:
    """A pool of 3 hands out leases 0, 1, 2 (lowest first), refuses a fourth
    with the pool size named, and after a return hands that lease out again."""
    var p = _pool(3)
    assert_equal(p.checkout(), 0)
    assert_equal(p.checkout(), 1)
    assert_equal(p.checkout(), 2)
    assert_equal(p.in_use_count(), 3)
    assert_equal(
        _err_checkout(p),
        String(
            "Pool exhausted: all 3 resources are in use (single-threaded pool:"
            " a real multi-pthread pool would block on a condvar here)"
        ),
    )
    p.return_lease(1)
    assert_equal(p.in_use_count(), 2)
    assert_equal(p.checkout(), 1, "the returned lease is handed out again")
    print("  [2] checkout exhausts at size, frees on return OK")


# =============================================================================
# 2 — the free-list refusals
# =============================================================================
def test_return_lease_refusals() raises:
    """`return_lease` refuses a lease outside [0, size) and a lease that is
    not checked out (a double return), each with its own message."""
    var p = _pool(2)
    assert_equal(_err_return(p, -1), _oor("return", -1))
    assert_equal(_err_return(p, 2), _oor("return", 2))
    assert_equal(
        _err_return(p, 0), String("Pool.return: lease 0 was not checked out")
    )
    var l = p.checkout()
    assert_equal(_err_return(p, l), String("no error"))
    assert_equal(
        _err_return(p, l), String("Pool.return: lease 0 was not checked out")
    )
    print("  [3] return_lease: out of range + double return OK")


def test_discard_skips_slot_and_refuses_out_of_range() raises:
    """A discarded slot is never handed out again, even once returned; a pool
    whose only live slot is discarded is exhausted. `discard` refuses a lease
    outside [0, size)."""
    var p = _pool(2)
    assert_equal(_err_discard(p, -1), _oor("discard", -1))
    assert_equal(_err_discard(p, 2), _oor("discard", 2))
    var l0 = p.checkout()
    p.discard(l0)
    p.return_lease(l0)
    assert_equal(p.checkout(), 1, "the dead slot 0 is skipped")
    assert_true(_err_checkout(p).startswith("Pool exhausted: all 2 "))
    print("  [4] discard: dead slot skipped, out of range refused OK")


# =============================================================================
# 3 — the move API's refusals
# =============================================================================
def test_move_api_out_of_range_both_sides() raises:
    """Every lease-taking move method refuses -1 and `size` with its own verb
    in the message, and answers at the last valid lease (size - 1)."""
    var p = _pool(2)
    for lease in [-1, 2]:
        assert_equal(_err_take(p, lease), _oor("take", lease))
        assert_equal(_err_vacate(p, lease), _oor("vacate", lease))
        assert_equal(_err_give_back(p, lease), _oor("give_back", lease))
        assert_equal(_err_restore(p, lease), _oor("restore", lease))
        assert_equal(_err_is_vacated(p, lease), _oor("is_vacated", lease))
    assert_false(p.is_vacated(1), "the last lease is in range and installed")
    _ = p.checkout()
    var l = p.checkout()
    assert_equal(l, 1)
    var r = p.vacate(l)
    assert_equal(r.id, 100)
    assert_true(p.is_vacated(l))
    p.restore(l, r^)
    assert_false(p.is_vacated(l), "restore reinstalls at the last lease")
    assert_equal(p.in_use_count(), 2, "vacate/restore keep the lease held")
    print("  [5] move API: -1 and size refused per verb, size-1 answers OK")


def test_double_take_and_double_vacate_refused() raises:
    """A second `take` or `vacate` of an already vacated slot is refused with
    its own message (never a second resource out of an empty slot)."""
    var p = _pool(1)
    var l = p.checkout()
    var r = p.take(l)
    assert_equal(
        _err_take(p, l),
        String("Pool.take: lease 0 is already vacated (no resource in slot)"),
    )
    assert_equal(
        _err_vacate(p, l),
        String("Pool.vacate: lease 0 is already vacated (double-vacate)"),
    )
    p.give_back(l, r^)
    assert_equal(p.in_use_count(), 0, "give_back frees the lease")
    var l2 = p.checkout()
    var r2 = p.vacate(l2)
    assert_equal(
        _err_vacate(p, l2),
        String("Pool.vacate: lease 0 is already vacated (double-vacate)"),
    )
    assert_equal(
        _err_take(p, l2),
        String("Pool.take: lease 0 is already vacated (no resource in slot)"),
    )
    p.restore(l2, r2^)
    print("  [6] double take / double vacate refused OK")


# =============================================================================
# 4 — close
# =============================================================================
def test_close_reaches_every_live_slot_not_a_vacated_one() raises:
    """`close` closes the resource in every installed slot (first and last
    included) and skips a vacated slot: the resource its holder vacated is
    still open after `close`."""
    var p = _pool(3)
    _ = p.checkout()
    var l1 = p.checkout()
    var held = p.vacate(l1)
    p.close()
    assert_false(held.closed, "the vacated resource is not the pool's to close")
    p.restore(l1, held^)
    var l2 = p.checkout()
    assert_equal(l2, 2)
    var r0 = p.take(0)
    var r2 = p.take(2)
    assert_true(r0.closed, "slot 0 was closed")
    assert_true(r2.closed, "the last slot was closed")
    var r1 = p.take(1)
    assert_false(r1.closed, "the slot vacated during close was skipped")
    p.give_back(0, r0^)
    p.give_back(2, r2^)
    p.give_back(1, r1^)
    print("  [7] close: every live slot, not a vacated one OK")


def main() raises:
    print("== komira_db generic Pool[T]: refusals + close ==")
    test_connect_refuses_non_positive_size()
    test_checkout_exhausts_then_frees()
    test_return_lease_refusals()
    test_discard_skips_slot_and_refuses_out_of_range()
    test_move_api_out_of_range_both_sides()
    test_double_take_and_double_vacate_refused()
    test_close_reaches_every_live_slot_not_a_vacated_one()
    print("PASS test_pool_refusals")

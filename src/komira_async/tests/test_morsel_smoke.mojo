# =============================================================================
# test_morsel_smoke.mojo
# =============================================================================
# minimal smoke for komira_async.morsel. Compile-pass canary
# with the new Vyukov MPMC implementation. Full tests at test_morsel_pool.mojo.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_async.morsel.morsel_pool import MorselPool


def test_morsel_pool_construct() raises:
    """new() returns an open pool; is_drained() == False."""
    var p = MorselPool[Int].new()
    assert_false(p.is_drained())


def test_morsel_pool_close_idempotent() raises:
    """close() twice is OK + pool drains after close + try_claim."""
    var p = MorselPool[Int].new()
    p.close()
    p.close()
    assert_true(p.is_drained())


def main() raises:
    test_morsel_pool_construct()
    test_morsel_pool_close_idempotent()
    print("PASS komira_async.morsel smoke")

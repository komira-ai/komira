# =============================================================================
# src/komira_http/tests/test_http_client_pool_fields.mojo
# HttpClient pool-stateful refactor.
# =============================================================================
#
# Verifies the pool field additions to HttpClient[C]:
#   * `_h1_pool: Optional[OwnedPointer[PerCorePool[Self.C.Stream]]]`
#   * `_h2_pool: Optional[OwnedPointer[H2ClientPool[Self.C.Stream]]]`
#
# Behavior verified:
#   1. A fresh HttpClient has both pool fields = Optional.None
#      (lazy-init; the per-call dial path is the fallback).
#   2. `ensure_h1_pool` and `ensure_h2_pool` are idempotent — repeated
#      calls do not replace the existing pool.
#   3. `h1_pool_is_init` / `h2_pool_is_init` accurately report state.
#   4. `h1_pool_dials_total` returns 0 on fresh init (pool exists, no
#      dials performed) and on uninitialized field (no pool yet).
#   5. `h2_pool_bucket_count` returns 0 on fresh init.
#
# These are the load-bearing diagnostic surfaces for a reuse benchmark
# (≥95% reuse) and the e2e fd-count test (verifies N
# concurrent requests land on ONE bucket via h2 multiplex).
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_http.client.client import HttpClient
from komira_http.transport.scripted import ScriptedConnector, ScriptedStream


def _new_client() -> HttpClient[ScriptedConnector]:
    """Build an HttpClient[ScriptedConnector] with an empty script —
    these tests never call send; only the pool fields are inspected."""
    var stream = ScriptedStream.empty()
    var conn = ScriptedConnector.with_stream(stream^)
    return HttpClient[ScriptedConnector].with_defaults(conn^)


def test_fresh_client_has_no_pools_init() raises:
    var client = _new_client()
    assert_false(
        client.h1_pool_is_init(),
        "fresh HttpClient must NOT have h1 pool init",
    )
    assert_false(
        client.h2_pool_is_init(),
        "fresh HttpClient must NOT have h2 pool init",
    )


def test_uninit_h1_dials_total_is_zero() raises:
    var client = _new_client()
    # Uninit pool path returns 0 (the "no pool" early-return).
    assert_equal(client.h1_pool_dials_total(), 0)


def test_uninit_h2_bucket_count_is_zero() raises:
    var client = _new_client()
    assert_equal(client.h2_pool_bucket_count(), 0)


def test_ensure_h1_pool_inits() raises:
    var client = _new_client()
    client.ensure_h1_pool()
    assert_true(
        client.h1_pool_is_init(),
        "ensure_h1_pool must init the h1 pool",
    )
    # No dials have happened, so dials_total is 0 — but the pool
    # exists.
    assert_equal(client.h1_pool_dials_total(), 0)


def test_ensure_h2_pool_inits() raises:
    var client = _new_client()
    client.ensure_h2_pool()
    assert_true(
        client.h2_pool_is_init(),
        "ensure_h2_pool must init the h2 pool",
    )
    assert_equal(client.h2_pool_bucket_count(), 0)


def test_ensure_h1_pool_is_idempotent() raises:
    var client = _new_client()
    client.ensure_h1_pool()
    assert_true(client.h1_pool_is_init())
    # Calling again must not panic / not crash / not replace the pool.
    client.ensure_h1_pool()
    assert_true(client.h1_pool_is_init())
    assert_equal(
        client.h1_pool_dials_total(),
        0,
        "idempotent ensure must NOT reset diagnostics",
    )


def test_ensure_h2_pool_is_idempotent() raises:
    var client = _new_client()
    client.ensure_h2_pool()
    assert_true(client.h2_pool_is_init())
    client.ensure_h2_pool()
    assert_true(client.h2_pool_is_init())


def test_h1_and_h2_pools_are_independent() raises:
    """Init only h1 — h2 stays uninit (and vice-versa)."""
    var client = _new_client()
    client.ensure_h1_pool()
    assert_true(client.h1_pool_is_init())
    assert_false(client.h2_pool_is_init())

    var client2 = _new_client()
    client2.ensure_h2_pool()
    assert_false(client2.h1_pool_is_init())
    assert_true(client2.h2_pool_is_init())


def main() raises:
    test_fresh_client_has_no_pools_init()
    test_uninit_h1_dials_total_is_zero()
    test_uninit_h2_bucket_count_is_zero()
    test_ensure_h1_pool_inits()
    test_ensure_h2_pool_inits()
    test_ensure_h1_pool_is_idempotent()
    test_ensure_h2_pool_is_idempotent()
    test_h1_and_h2_pools_are_independent()
    print("[OK] test_http_client_pool_fields — all 8 tests passed")

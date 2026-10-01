# =============================================================================
# komira_factory_build/tests/test_resolve_build_backend.mojo — the TRUST-CONTEXT
#   build-backend SELECTOR gate.
# =============================================================================
#
# A build must land on the RIGHT vehicle for its TRUST CONTEXT: the operator's
# own (trusted) builds belong on the operator's own compute; per-Job customer
# (isolated-external) builds belong in an isolated vehicle in the customer
# account. The trust signal is ALREADY typed on the wire — `account_ref` (empty =
# single-tenant = the operator's own; non-empty = per-Job customer account).
# `resolve_build_backend` is the PURE function over that: NO I/O, NO environment
# variable.
#
# WHAT THIS PROVES. Over the `resolve_build_backend` pure resolver:
#   1. an EMPTY `account_ref` -> BUILD_BACKEND_ON_FARM_K8S (the operator's own = trusted).
#   2. a NON-EMPTY `account_ref` -> BUILD_BACKEND_CLOUD_RUN_JOB (per-Job customer =
#      isolated-external — the one implemented backend).
#   3. the 4-arm ordinal set is the expected 0..3 (beside the BUILD_ROUTE_* idiom),
#      and the trust axis is monotone: empty is the SOLE trusted case, every
#      non-empty ref (regardless of shape) resolves isolated-external.
#
# Pure value transformation — NO cloud, NO container, NO job manager (the resolver
# is a pure ordinal function over a String).
# =============================================================================

from std.testing import assert_equal, assert_true, assert_not_equal

from komira_factory_build import (
    resolve_build_backend,
    BUILD_BACKEND_ON_FARM_K8S,
    BUILD_BACKEND_CLOUD_RUN_JOB,
    BUILD_BACKEND_SPOT_VM,
    BUILD_BACKEND_CLOUD_BUILD,
)


# =============================================================================
# Test 1 — an EMPTY account_ref (single-tenant = the operator's own = trusted) -> ON_FARM_K8S.
# =============================================================================
def test_empty_account_ref_routes_to_on_farm_k8s() raises:
    var backend = resolve_build_backend(String(""))
    assert_equal(
        backend,
        BUILD_BACKEND_ON_FARM_K8S,
        "empty account_ref = single-tenant = the operator's own = trusted -> ON_FARM_K8S",
    )


# =============================================================================
# Test 2 — a NON-EMPTY account_ref (a per-Job customer account = isolated-external)
#   -> CLOUD_RUN_JOB (the one implemented isolated-external backend).
# =============================================================================
def test_present_account_ref_routes_to_cloud_run_job() raises:
    var backend = resolve_build_backend(String("acme-gcp-conn-01"))
    assert_equal(
        backend,
        BUILD_BACKEND_CLOUD_RUN_JOB,
        "non-empty account_ref = per-Job customer account = isolated-external"
        " -> CLOUD_RUN_JOB",
    )


# =============================================================================
# Test 3 — the trust axis is MONOTONE on presence: the empty ref is the SOLE
#   trusted (ON_FARM_K8S) case; EVERY non-empty ref (any shape — a name, a uuid, a
#   single char) resolves isolated-external (CLOUD_RUN_JOB), never trusted.
# =============================================================================
def test_trust_axis_is_presence_monotone() raises:
    # the trusted case is the empty ref alone.
    assert_equal(
        resolve_build_backend(String("")),
        BUILD_BACKEND_ON_FARM_K8S,
        "empty is the sole trusted case",
    )
    # a variety of non-empty refs ALL resolve isolated-external (never trusted).
    var refs = List[String]()
    refs.append(String("x"))
    refs.append(String("customer-acct-42"))
    refs.append(String("01234567-89ab-cdef-0123-456789abcdef"))
    refs.append(String("projects/foo/connections/bar"))
    for i in range(len(refs)):
        var b = resolve_build_backend(refs[i])
        assert_equal(
            b,
            BUILD_BACKEND_CLOUD_RUN_JOB,
            "a non-empty account_ref -> isolated-external CLOUD_RUN_JOB",
        )
        assert_not_equal(
            b,
            BUILD_BACKEND_ON_FARM_K8S,
            "a non-empty account_ref is NEVER the trusted farm backend",
        )


# =============================================================================
# Test 4 — the 4-arm ordinal set is a distinct 0..3 (beside the BUILD_ROUTE_*
#   idiom) — the wire ordinals the placer stamps + the job manager reads are stable.
# =============================================================================
def test_backend_ordinals_are_distinct_0_to_3() raises:
    assert_equal(BUILD_BACKEND_ON_FARM_K8S, 0, "ON_FARM_K8S = 0")
    assert_equal(BUILD_BACKEND_CLOUD_RUN_JOB, 1, "CLOUD_RUN_JOB = 1")
    assert_equal(BUILD_BACKEND_SPOT_VM, 2, "SPOT_VM = 2")
    assert_equal(BUILD_BACKEND_CLOUD_BUILD, 3, "CLOUD_BUILD = 3")
    # all four are distinct (a keyed registry indexes by these ordinals).
    assert_true(
        BUILD_BACKEND_ON_FARM_K8S != BUILD_BACKEND_CLOUD_RUN_JOB
        and BUILD_BACKEND_CLOUD_RUN_JOB != BUILD_BACKEND_SPOT_VM
        and BUILD_BACKEND_SPOT_VM != BUILD_BACKEND_CLOUD_BUILD,
        "the four BuildBackend ordinals are distinct",
    )


def main() raises:
    test_empty_account_ref_routes_to_on_farm_k8s()
    test_present_account_ref_routes_to_cloud_run_job()
    test_trust_axis_is_presence_monotone()
    test_backend_ordinals_are_distinct_0_to_3()
    print("PASS test_resolve_build_backend")

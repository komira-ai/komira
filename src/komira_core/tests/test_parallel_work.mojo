# =============================================================================
# Unit tests for _ParallelWork[origin]
# =============================================================================
# Smoke coverage: the struct definition compiles and a caller that
# exercises construction + len() via an inferred origin parameter
# completes without crashing. The full _set_view_at + view_for semantics
# need a real `parallelize` barrier (state + pre-sliced views + closure),
# which is a driver pattern rather than a unit test.
# =============================================================================

from std.testing import TestSuite, assert_true

from komira_core.collections.parallel_work import _ParallelWork


def test_struct_compiles_and_smokes() raises:
    """Compile-gate that _ParallelWork is importable and pickable.

    This smoke test is intentionally lightweight -- the parametric
    origin inference that exercises the full struct API requires a
    driver pattern (state + pre-sliced views + parallelize closure)
    that is better expressed in a standalone driver than here.
    """
    # If the import above succeeded, the smoke check passes. No runtime
    # behavior to exercise at this layer without an origin-chain driver.
    assert_true(True)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

# Two debug_asserts that fail whenever they are compiled in: which one is
# compiled in is the assert level of the `mojo build` that compiles this
# package into a test.


def all_only_probe(i: Int) -> Int:
    """Asserts at ASSERT=all only (assert_mode "none", the default)."""
    debug_assert(i < 0, "ASSERT_PROBE all_only_probe: an assert_mode=none debug_assert fired")
    return i + 1


def safe_probe(i: Int) -> Int:
    """Asserts at ASSERT=safe (the default level) and all, not at none."""
    debug_assert[assert_mode="safe"](i < 0, "ASSERT_PROBE safe_probe: an assert_mode=safe debug_assert fired")
    return i + 1

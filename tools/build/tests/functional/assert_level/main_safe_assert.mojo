# Prints `past the assert` only when its assert_mode=safe debug_assert is not
# compiled in (assert_level = "none"); at the default level it aborts first.


def main():
    var n = 1
    debug_assert[assert_mode="safe"](n < 0, "ASSERT_PROBE main_safe_assert: an assert_mode=safe debug_assert fired")
    print("past the assert")

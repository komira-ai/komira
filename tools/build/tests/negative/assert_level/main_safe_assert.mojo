# The program of tests//functional/assert_level:bin_none and :test_none, built
# here at the default level (bin_default, test_default), where its
# assert_mode=safe debug_assert fires before the print.


def main():
    var n = 1
    debug_assert[assert_mode="safe"](n < 0, "ASSERT_PROBE main_safe_assert: an assert_mode=safe debug_assert fired")
    print("past the assert")

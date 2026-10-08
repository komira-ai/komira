# Runs every line of covtry, the `except` body included (check(a) raises
# once), but check(b) never raises: one arm of its `try` decision, the
# raise into the handler, is never taken (test 46).
from covtry import total
from std.testing import assert_equal


def main() raises:
    assert_equal(total(1, 2), 3, "no raise")
    assert_equal(total(-1, 2), -1, "the first call raises")

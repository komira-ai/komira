# Runs every line of covtry and takes both arms of each decision: each
# raising call in its `try:` body returns and raises once (test 46).
from covtry import total
from std.testing import assert_equal


def main() raises:
    assert_equal(total(1, 2), 3, "no raise")
    assert_equal(total(-1, 2), -1, "the first call raises")
    assert_equal(total(1, -2), -1, "the second call raises")

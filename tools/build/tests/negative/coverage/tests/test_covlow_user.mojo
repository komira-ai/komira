# covlow_user's test, built against covlow's package: covlow's red coverage
# gate blocks only covlow's conda package, never this build (test 46).
from covlow_user import shout
from std.testing import assert_equal


def main() raises:
    assert_equal(shout(0), "zero!", "zero")

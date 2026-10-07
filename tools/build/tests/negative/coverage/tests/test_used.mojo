# Calls used() only: covun/unused.mojo is in the package, and no test binary
# compiles it (test 46).
from covun import used
from std.testing import assert_equal


def main() raises:
    assert_equal(used(), "used", "used")

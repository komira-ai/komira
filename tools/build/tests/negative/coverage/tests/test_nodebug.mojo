from branchnodebug import use
from std.testing import assert_equal


def main() raises:
    assert_equal(use(3), 3, "three steps down")

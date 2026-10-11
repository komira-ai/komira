"""kgfix's standalone test: a dot has area 0."""

from kgfix import Dot
from std.testing import assert_equal


def main() raises:
    assert_equal(Dot().area(), 0)

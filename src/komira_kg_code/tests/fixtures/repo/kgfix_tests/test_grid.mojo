"""kgfix's welded test: a 2 by 3 grid has area 6."""

from kgfix import Grid
from std.testing import assert_equal


def main() raises:
    assert_equal(Grid[2, 3]().area(), 6)

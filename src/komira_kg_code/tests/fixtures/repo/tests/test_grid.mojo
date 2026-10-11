"""kgfix's welded test: a 2 by 3 grid has area 6, built here and by
kgfix.sub.leaf."""

from kgfix import Grid
from kgfix.sub.leaf import leaf_area
from std.testing import assert_equal


def main() raises:
    assert_equal(Grid[2, 3]().area(), 6)
    assert_equal(leaf_area(), 6)

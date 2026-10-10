"""A module in a subpackage, importing across lines."""

from kgfix.shapes import (
    Grid,
    Shaped,
)


def leaf_area() -> Int:
    """The area of an empty 2 by 3 grid."""
    return Grid[2, 3]().area()

"""Declarations of every kind the symbol check walks."""

comptime SIDES = 4
"""The sides of a square."""


trait Shaped:
    """Has an area."""

    def area(self) -> Int:
        """The area."""
        ...


struct Grid[
    width: Int,
    height: Int,
](Copyable, Movable, Shaped):
    """A parametric struct whose header spans lines."""

    var cells: Int

    def __init__(out self):
        """An empty grid."""
        self.cells = 0

    def area(self) -> Int:
        """`width * height`."""
        return Self.width * Self.height

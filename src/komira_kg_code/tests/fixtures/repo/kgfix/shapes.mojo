"""Shapes: a trait, a struct whose parametric header spans lines, and one
whose header is a single line."""

from komira_json import JsonValue

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
    """A grid whose header spans four lines."""

    var cells: Int

    def __init__(out self):
        """An empty grid."""
        self.cells = 0

    def area(self) -> Int:
        """`width * height`."""
        return Self.width * Self.height


struct Dot(Copyable, Shaped):
    """A point: area zero."""

    def __init__(out self):
        """A dot."""
        pass

    def area(self) -> Int:
        """Zero."""
        return 0


def total_area[T: Shaped](a: T, b: T) -> Int:
    """The sum of two areas."""
    return a.area() + b.area()


def as_json(n: Int) -> JsonValue:
    """`n` as a JSON number."""
    return JsonValue.from_i64(Int64(n))

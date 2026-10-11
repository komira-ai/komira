# A file of declarations only: traits whose methods have no body, comptime
# values and imports. The compiler emits no code for it, so covcheck counts
# none of its lines when no test compiled it (test_declaration_only.mojo).
"""Row traits.

    def f(self) -> Int:
        return 1

Text in a docstring is not code: `return` and `var` here count nothing.
"""

from std.os import abort
from .other import (
    Schema,
    describe,
)

comptime DEFAULT_ID: UInt32 = 7000
comptime Pair = Tuple[
    Int,
    Int,
]


trait Marker(Copyable, Movable):
    """A pure type tag."""

    ...


trait RowFn(
    Movable,
    Copyable,
):
    """A typed user function.

        var x = 1
        return x
    """

    comptime InRow: AnyType & Copyable & Movable & Marker  # the row struct
    comptime UDF_ID: UInt32 = DEFAULT_ID
    comptime Out: DType

    def run_row(mut self, row: Self.InRow) raises -> Scalar[Self.Out]:
        """REQUIRED: the row step. Normally `return row.a + row.b`."""
        ...

    # A generic header over several lines, closing at the method's indent.
    def run_view[
        origin: Origin[mut=False]
    ](self, view: Span[Int, origin]) raises -> Scalar[
        Self.Out
    ]:
        """The view form."""
        ...

    @staticmethod
    def name() -> String: ...

    fn width(self) -> Int:
        # A comment in a body.
        ...

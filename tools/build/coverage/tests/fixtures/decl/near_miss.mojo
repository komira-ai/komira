# A near miss: the declarations of declaration_only.mojo, but one trait
# method has a default implementation with code. That body is code, so
# covcheck keeps every executable line of the file counted.
"""Row traits with a default."""

from std.os import abort

comptime DEFAULT_ID: UInt32 = 7000


trait RowFn(Movable, Copyable):
    comptime UDF_ID: UInt32 = DEFAULT_ID

    def run_row(mut self, row: Int) raises -> Int:
        """REQUIRED: the row step."""
        ...

    def width(self) -> Int:
        """A default implementation: this is code."""
        return 8

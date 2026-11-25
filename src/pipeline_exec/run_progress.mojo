# =============================================================================
# run_progress -- how many segments of a run have finished, readable from any
# thread
# =============================================================================
#
# `run_plan` adds the plan's segment count to `total` once the plan is checked,
# and one to `done` after each segment it finished. Both only grow, and every
# addition to `done` follows the addition to `total` that counts that segment,
# so `done` never passes `total`. A reader on another thread takes `done` first
# and `total` second (`snapshot`): `total` can only have grown in between, so a
# snapshot never shows more segments done than counted. Handles made with
# `share` count into the same two cells, so a counter given to several runs one
# after another sums them.

from atomic_alias import AtomicI64
from containers.slab import Slab
from std.memory import ArcPointer

comptime _DONE = 0
comptime _TOTAL = 1
comptime _CELLS = 2


@fieldwise_init
struct ProgressSnapshot(Copyable, Movable):
    """One reading of a `RunProgress`: `done` is at most `total`."""

    var done: Int
    """Segments finished."""
    var total: Int
    """Segments counted by the runs that started."""


struct RunProgress(Movable):
    """The finished and counted segments of the runs it is given to, behind a
    shared handle: `share()` makes a second handle on the same counts."""

    var _cells: ArcPointer[Slab[AtomicI64]]

    def __init__(out self):
        """A counter at 0 of 0."""
        self._cells = ArcPointer[Slab[AtomicI64]](
            Slab[AtomicI64].create_prefilled(_CELLS)
        )

    def __init__(out self, *, shared_with: Self):
        """A second handle on the counts of `shared_with`."""
        self._cells = ArcPointer(copy=shared_with._cells)

    def share(self) -> RunProgress:
        """Another handle on the same counts."""
        return RunProgress(shared_with=self)

    def start(self, segments: Int):
        """Count the `segments` of a run that is about to start."""
        _ = self._cells[].get_mut_interior(_TOTAL).fetch_add(Int64(segments))

    def finish_segment(self):
        """Count one segment of a started run as finished."""
        _ = self._cells[].get_mut_interior(_DONE).fetch_add(Int64(1))

    def snapshot(self) -> ProgressSnapshot:
        """The counts now: `done` is read before `total`, so `done` is at
        most `total` even while a run on another thread adds to both."""
        var done = Int(self._cells[].get_mut_interior(_DONE).load())
        var total = Int(self._cells[].get_mut_interior(_TOTAL).load())
        return ProgressSnapshot(done=done, total=total)

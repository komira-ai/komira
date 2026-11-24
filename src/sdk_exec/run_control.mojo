# =============================================================================
# run_control -- the cancel token and the progress counter a caller gives a run
# =============================================================================
#
# A `RunControl` is what a caller holds to stop a run and watch it from another
# thread. `run_sql` given one passes a clone of its token to the run, so the
# run sees a cancel at the plan's next check (before each segment, and at each
# morsel boundary inside one), and counts the run's segments into its
# progress. `share()` makes a second handle on the same token and counts.
#
# Cancel is one-way: once cancelled, every later run given the control stops at
# its first check. It may be called from several threads at once: the first
# caller claims the token through an atomic cell and is the only one that
# writes its reason; every other call does nothing. A reader of the reason
# (the run, on its own thread) reads it only after it sees the token's flag,
# which the claimant stores after the reason.

from async_api.token import CancellationToken
from atomic_alias import AtomicI64
from containers.slab import Slab
from pipeline_exec.run_progress import ProgressSnapshot, RunProgress
from std.memory import ArcPointer

comptime RUN_CANCEL_REASON = "the caller cancelled the run"
"""The reason a run cancelled through `RunControl.cancel` reports."""


struct RunControl(Movable):
    """A cancel token and a segment progress counter, behind a shared handle.
    """

    var _token: CancellationToken
    var _progress: RunProgress
    var _claim: ArcPointer[Slab[AtomicI64]]

    def __init__(out self):
        """A control that is not cancelled, at 0 of 0 segments."""
        self._token = CancellationToken.new()
        self._progress = RunProgress()
        self._claim = ArcPointer[Slab[AtomicI64]](
            Slab[AtomicI64].create_prefilled(1)
        )

    def __init__(out self, *, shared_with: Self):
        """A second handle on the token and counts of `shared_with`."""
        self._token = shared_with._token.clone()
        self._progress = shared_with._progress.share()
        self._claim = ArcPointer(copy=shared_with._claim)

    def share(self) -> RunControl:
        """Another handle on the same token and counts."""
        return RunControl(shared_with=self)

    def cancel(mut self):
        """Cancel every run given this control, now or later, with the reason
        `RUN_CANCEL_REASON`. Only the first call, from any thread or handle,
        does anything."""
        var expected = Int64(0)
        if self._claim[].get_mut_interior(0).compare_exchange(
            expected, Int64(1)
        ):
            self._token.cancel(String(RUN_CANCEL_REASON))

    def is_cancelled(self) -> Bool:
        """Whether `cancel` was called on any handle of this control."""
        return self._token.is_cancelled()

    def token(self) -> CancellationToken:
        """A clone of the token: a run that polls it sees `cancel`."""
        return self._token.clone()

    def progress(self) -> RunProgress:
        """A handle on the counts, for the run to count into."""
        return self._progress.share()

    def snapshot(self) -> ProgressSnapshot:
        """The segments finished and counted so far (`done` at most
        `total`)."""
        return self._progress.snapshot()

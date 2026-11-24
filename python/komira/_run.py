"""One SQL statement run under a run handle (ABI 1.6; src/so/README.md, "Cancel
and progress"), so that Ctrl-C cancels it and a callback reads its progress.

A ctypes call keeps its thread inside the library until the call returns, and
Python runs a signal's handler on the main thread only, between bytecodes: a
query run on the main thread cannot be interrupted. `run_sql` therefore makes
the call, `komira_sql_stream_run`, on a helper thread, and the calling thread
waits for it. It wakes every `POLL_SECONDS`, so that a handler that is due
runs, on every platform, and to read the run's progress for the callback.

Whatever is raised on the calling thread while it waits, the
`KeyboardInterrupt` of a Ctrl-C or the exception of the progress callback,
cancels the run (`komira_run_cancel`). The calling thread then waits for the
helper's call to return, drops a stream the call made (a cancel that came after
the run's last check leaves the answer standing), frees the run handle, and
raises that exception again. The engine checks for a cancel before each
segment of the plan and at each morsel boundary inside one, so the call
returns soon after. An exception raised while the run stops (a second Ctrl-C)
is dropped, and the first one is raised: the run is already stopping, and the
session's context cannot be given to another call before the helper's call
returns.

The context is used only by the helper's call, while the calling thread holds
the session's lock. Each statement gets its own run handle, so a cancel never
reaches a later statement.
"""

from __future__ import annotations

import logging
import threading
from collections.abc import Callable

from . import _arrow, _native

# How long the calling thread waits for the helper's call before it reads the
# run's progress and lets a due signal handler run.
POLL_SECONDS = 0.05

# A callback that takes (done, total) plan segments.
Progress = Callable[[int, int], object]

_log = logging.getLogger("komira")

# The states of a `_Call`: the helper has not started the call; the call is
# running; it returned; or the calling thread gave up before the helper
# started, and the helper, if it ever runs, makes no call and frees the handle.
_PENDING = "pending"
_RUNNING = "running"
_DONE = "done"
_ABANDONED = "abandoned"


class _Call:
    """One komira_sql_stream_run on a helper thread, and its run handle.

    The handle is freed once, by the calling thread after the call returned
    (`finish` or `stop`), or by the helper when it finds the call abandoned.
    `_mu` orders the helper's start with the calling thread's cancel and
    abandon, so neither thread uses the handle after the other freed it.
    """

    def __init__(self, native: _native.Native, ctx: int, text: bytes, run: int) -> None:
        self._native = native
        self._ctx = ctx
        self._text = text
        self._run = run
        self._mu = threading.Lock()
        self._state = _PENDING
        self._cancelled = False
        self._freed = False
        self.done = threading.Event()
        self.stream: _arrow.ArrowArrayStream | None = None
        self.error: BaseException | None = None
        # The last progress read, for the log.
        self.reading = (0, 0)

    def start(self) -> None:
        try:
            threading.Thread(target=self._work, name="komira-sql", daemon=True).start()
        except RuntimeError:
            # No helper thread exists: the call is abandoned and its handle
            # freed here, since no helper will free it.
            with self._mu:
                self._state = _ABANDONED
            self._free()
            raise

    def _work(self) -> None:
        with self._mu:
            if self._state == _ABANDONED:
                self._native.run_free(self._run)
                return
            self._state = _RUNNING
        try:
            self.stream = self._native.sql_stream_run(self._ctx, self._text, self._run)
        except BaseException as e:
            self.error = e
        finally:
            with self._mu:
                self._state = _DONE
            self.done.set()

    def progress(self) -> tuple[int, int]:
        """The run's (done, total), read while the handle is alive: before
        `finish` or `stop` freed it."""
        self.reading = self._native.run_progress(self._run)
        return self.reading

    def finish(self) -> _arrow.ArrowArrayStream:
        """After the call returned: frees the handle, then returns the stream
        or raises the call's error."""
        self.progress()
        self._free()
        error, self.error = self.error, None
        if error is not None:
            raise error
        stream, self.stream = self.stream, None
        return stream  # type: ignore[return-value]

    def stop(self) -> None:
        """Cancels the call, waits for it to return, drops its stream and frees
        the handle. Never raises: an exception raised while it waits (a second
        Ctrl-C, or another handler's) is dropped and the wait goes on."""
        while True:
            try:
                self._stop_once()
                return
            except BaseException:
                continue

    def _stop_once(self) -> None:
        with self._mu:
            if self._state == _ABANDONED:
                return
            if self._state == _PENDING:
                self._state = _ABANDONED
                return
            if self._state == _RUNNING and not self._cancelled:
                # The flag is set once the cancel returned, so an exception
                # between the two repeats the cancel, which does nothing the
                # second time, rather than losing it.
                self._native.run_cancel(self._run)
                self._cancelled = True
        while not self.done.wait(POLL_SECONDS):
            pass
        # A stream made before the cancel took is released here, when the
        # struct is collected (`_arrow.ArrowArrayStream.__del__`).
        self.stream = None
        self.error = None
        if not self._freed:
            self.progress()
        self._free()

    def _free(self) -> None:
        if not self._freed:
            self._freed = True
            self._native.run_free(self._run)


def _report(call: _Call, progress: Progress, seen: tuple[int, int]) -> tuple[int, int]:
    """Calls `progress(done, total)` when the run's reading is not `seen`, the
    last one it was given, and returns the reading."""
    reading = call.progress()
    if reading != seen:
        progress(*reading)
    return reading


def run_sql(native: _native.Native, ctx: int, query: str, progress: Progress | None) -> _arrow.ArrowArrayStream:
    """Runs the SQL statement `query` on the context `ctx` under a new run
    handle, and returns the Arrow C stream of its answer.

    `progress`, when given, is called on this thread with (done, total) plan
    segments each time a reading differs from the one before (the first
    reading compared is (0, 0)), and once the run answered with its last
    reading, where done equals total, if that was not yet given. Readings
    only grow. A run that fails is given no last reading.

    A refusal raises the call's KomiraError. Anything raised on this thread
    while the run runs (a Ctrl-C's KeyboardInterrupt, the callback's
    exception) cancels the run and is raised once the run stopped; the context
    then answers the next call.
    """
    text = _native._c_string("query", query)
    call = _Call(native, ctx, text, native.run_new())
    try:
        call.start()
        seen = (0, 0)
        while not call.done.wait(POLL_SECONDS):
            if progress is not None:
                seen = _report(call, progress, seen)
        if progress is not None and call.error is None:
            _report(call, progress, seen)
    except BaseException as e:
        call.stop()
        _log.info(
            "query stopped by %s after %d of %d plan segments", type(e).__name__, call.reading[0], call.reading[1]
        )
        raise
    try:
        stream = call.finish()
    except BaseException:
        # The call's refusal, or a Ctrl-C that came while the handle was
        # freed: `stop` frees the handle if it is not yet, and drops a stream.
        call.stop()
        raise
    _log.debug("query answered after %d of %d plan segments", *call.reading)
    return stream

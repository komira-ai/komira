"""Ctrl-C and progress during Session.sql, on a stand-in of ABI 1.6
(fake_threads.c built with FAKE_RUN) whose komira_sql_stream_run holds the run
at a gate until the test opens it or the run is cancelled, journals each call
on a context and on a run handle, and counts the streams it made and released:

- Ctrl-C while a query runs cancels its run handle, sql raises
  KeyboardInterrupt once the run returned, the handle is freed after the call
  left, and the session answers the next query, under a new handle;
- a second Ctrl-C while the query stops is not raised: the first one is, and
  the run is cancelled once;
- a query that answers although it was cancelled (the cancel came after its
  last check) raises KeyboardInterrupt, and its stream is released;
- a refusal during which Ctrl-C came raises KeyboardInterrupt and makes no
  stream;
- a SIGINT handler that does not raise leaves the query running, and sql
  returns its answer;
- progress is called on the calling thread with each reading of the run's
  segments, (0, 3), (1, 3), (2, 3), (3, 3), also when sql is called from a
  thread other than the main one, and never for a plan with no segment;
- an exception the callback raises, on a reading while the run runs or on the
  last one, cancels the query and is raised from sql; a callback that calls
  the session gets the re-entry KomiraError, which sql raises;
- a refusal (-3) and a cancel nobody asked for (-6) raise KomiraError with the
  library's message and status, and free the handle;
- the arguments are checked before any handle is made;
- an exception raised inside run_cancel before it cancelled (a second
  Ctrl-C there) does not lose the cancel: it is made again, the handle is
  freed, the first KeyboardInterrupt is raised, and the session answers;
- a call abandoned before its helper thread started makes no call, and its
  helper frees the handle; a helper thread that cannot be started raises its
  RuntimeError from sql, with the handle freed and no call made;
- the logger "komira" says which library it loaded, how many segments a query
  ran, and what stopped one, word for word;
- no call ran on a context while another was inside it, none on a freed
  handle, and close frees the context once.

No check waits on a clock: a helper thread waits until the run entered a gate
(or the cancel arrived) and then signals the main thread with
signal.pthread_kill, or opens the gate.

    test_sql_cancel.py --lib-dir <dir> --runtime-dir <dir>

`<dir>/fake_run/libkomira.so` is the stand-in (`--runtime-dir`, which the rule
passes, is not read).
"""

import ctypes
import gc
import logging
import os
import signal
import sys
import threading

import komira
from komira import KomiraError
from komira import _native, _run

MAIN = threading.main_thread().ident

CANCELLED = "QUERY_CANCELLED: execute: the stand-in's run was cancelled"
REENTERED = (
    "a call on this session was made while another call on it is running on the same thread "
    "(from a signal handler, a finalizer or a progress callback): make it after that call returns"
)


class Fake:
    """The stand-in's controls."""

    def __init__(self, path):
        lib = ctypes.CDLL(path)
        self._open = lib.fake_open
        self._open.argtypes, self._open.restype = [ctypes.c_int], None
        self._wait = lib.fake_wait_entered
        self._wait.argtypes, self._wait.restype = [ctypes.c_int], None
        self._cancels = lib.fake_wait_cancels
        self._cancels.argtypes, self._cancels.restype = [ctypes.c_int], None
        self._overlaps = lib.fake_overlaps
        self._overlaps.argtypes, self._overlaps.restype = [], ctypes.c_int
        self._journal = lib.fake_journal
        self._journal.argtypes, self._journal.restype = [ctypes.c_char_p, ctypes.c_size_t], ctypes.c_size_t
        self._streams = lib.fake_streams
        self._streams.argtypes = [ctypes.POINTER(ctypes.c_int64)] * 2
        self._streams.restype = None

    def open(self, k):
        self._open(k)

    def wait_entered(self, k):
        """Returns once the run has entered gate k (ctypes lets go of the GIL
        while it waits)."""
        self._wait(k)

    def wait_cancels(self, n):
        self._cancels(n)

    def overlaps(self):
        return self._overlaps()

    def journal(self):
        n = self._journal(None, 0)
        buf = ctypes.create_string_buffer(n)
        self._journal(buf, n)
        return buf.raw[:n].decode().splitlines()

    def streams(self):
        """(made, released)."""
        made, released = ctypes.c_int64(0), ctypes.c_int64(0)
        self._streams(ctypes.byref(made), ctypes.byref(released))
        return made.value, released.value


class Journal:
    """The journal lines written after it was made."""

    def __init__(self, fake):
        self._fake = fake
        self._mark = len(fake.journal())

    def lines(self):
        return self._fake.journal()[self._mark :]


class Streams:
    """The streams made and released after it was made."""

    def __init__(self, fake):
        self._fake = fake
        self._before = fake.streams()

    def since(self):
        gc.collect()
        made, released = self._fake.streams()
        return made - self._before[0], released - self._before[1]


def on_thread(fn):
    """Runs `fn` on a daemon thread and returns the thread."""
    t = threading.Thread(target=fn, daemon=True)
    t.start()
    return t


def ctrl_c():
    """SIGINT to the main thread, as a Ctrl-C at the terminal is."""
    signal.pthread_kill(MAIN, signal.SIGINT)


def raised(call):
    """The exception `call` raises."""
    try:
        call()
    except BaseException as e:  # each caller checks the exact type
        return e
    raise AssertionError("the call raised nothing")


def run_number(lines):
    """The number of the one run handle the lines make."""
    news = [line for line in lines if line.startswith("r") and line.endswith(" new")]
    assert len(news) == 1, lines
    return int(news[0].split()[0][1:])


def answers(s):
    """The session runs a query and its answer reads: no rows of `n: int64`."""
    t = s.sql("ok").to_arrow()
    assert t.num_rows == 0 and t.schema.names == ["n"], t


class Handler:
    """A SIGINT handler that counts its calls, sets `called[i]` on call i
    (from 0) and raises `KeyboardInterrupt("<i>")` when `raises`."""

    def __init__(self, raises=True, calls=2):
        self.raises = raises
        self.count = 0
        self.called = [threading.Event() for _ in range(calls)]

    def __call__(self, signum, frame):
        i = self.count
        self.count += 1
        self.called[i].set()
        if self.raises:
            raise KeyboardInterrupt(str(i))


def ctrl_c_cancels_a_running_query(fake, s, c):
    journal, streams = Journal(fake), Streams(fake)
    waiter = on_thread(lambda: (fake.wait_entered(0), ctrl_c()))
    e = raised(lambda: s.sql("hold:0"))
    waiter.join()
    assert type(e) is KeyboardInterrupt, repr(e)
    lines = journal.lines()
    r = run_number(lines)
    assert lines == [
        "r{} new".format(r),
        "c{} sql_run hold:0 enter".format(c),
        "r{} cancel".format(r),
        "c{} sql_run hold:0 leave".format(c),
        # The two calls of the two-call protocol that read its message.
        "c{} last_error - enter".format(c),
        "c{} last_error - leave".format(c),
        "c{} last_error - enter".format(c),
        "c{} last_error - leave".format(c),
        "r{} free".format(r),
    ], lines
    assert streams.since() == (0, 0), streams.since()

    # The session answers the next query, under a handle of its own.
    journal, streams = Journal(fake), Streams(fake)
    answers(s)
    lines = journal.lines()
    assert run_number(lines) == r + 1, lines
    assert lines[-1] == "r{} free".format(r + 1) and not any(" cancel" in line for line in lines), lines
    assert streams.since() == (1, 1), streams.since()


def a_second_ctrl_c_while_the_query_stops_is_not_raised(fake, s):
    handler = Handler()
    signal.signal(signal.SIGINT, handler)
    journal = Journal(fake)

    def interrupt_twice():
        fake.wait_entered(1)
        ctrl_c()
        # The run was cancelled and now holds at gate 2 before it returns.
        fake.wait_entered(2)
        ctrl_c()
        handler.called[1].wait()
        fake.open(2)

    waiter = on_thread(interrupt_twice)
    e = raised(lambda: s.sql("slowcancel:1:2"))
    waiter.join()
    signal.signal(signal.SIGINT, signal.default_int_handler)
    assert type(e) is KeyboardInterrupt and str(e) == "0", repr(e)
    assert handler.count == 2, handler.count
    lines = journal.lines()
    assert [line for line in lines if line.endswith(" cancel")] == ["r{} cancel".format(run_number(lines))], lines
    answers(s)


def a_query_answering_after_its_cancel_is_dropped(fake, s, cancels):
    journal, streams = Journal(fake), Streams(fake)

    def interrupt_then_answer():
        fake.wait_entered(3)
        ctrl_c()
        fake.wait_cancels(cancels + 1)
        fake.open(3)

    waiter = on_thread(interrupt_then_answer)
    e = raised(lambda: s.sql("ignore:3"))
    waiter.join()
    assert type(e) is KeyboardInterrupt, repr(e)
    lines = journal.lines()
    r = run_number(lines)
    assert lines.index("r{} cancel".format(r)) < lines.index("r{} free".format(r)), lines
    assert streams.since() == (1, 1), streams.since()
    answers(s)


def a_refusal_during_ctrl_c_raises_the_interrupt(fake, s):
    streams = Streams(fake)
    waiter = on_thread(lambda: (fake.wait_entered(4), ctrl_c()))
    e = raised(lambda: s.sql("failhold:4:bind: the stand-in has no table t"))
    waiter.join()
    assert type(e) is KeyboardInterrupt, repr(e)
    assert streams.since() == (0, 0), streams.since()
    answers(s)


def a_handler_that_does_not_raise_leaves_the_query_running(fake, s):
    handler = Handler(raises=False, calls=1)
    signal.signal(signal.SIGINT, handler)
    journal = Journal(fake)

    def interrupt_then_open():
        fake.wait_entered(5)
        ctrl_c()
        handler.called[0].wait()
        fake.open(5)

    waiter = on_thread(interrupt_then_open)
    t = s.sql("hold:5").to_arrow()
    waiter.join()
    signal.signal(signal.SIGINT, signal.default_int_handler)
    assert handler.count == 1 and t.num_rows == 0, (handler.count, t)
    assert not any(line.endswith(" cancel") for line in journal.lines()), journal.lines()


class Readings:
    """A progress callback: records each (done, total) and the thread it was
    called on, and notifies `cond`."""

    def __init__(self, then=None):
        self.cond = threading.Condition()
        self.seen = []
        self.threads = set()
        self._then = then

    def __call__(self, done, total):
        with self.cond:
            self.seen.append((done, total))
            self.threads.add(threading.get_ident())
            self.cond.notify_all()
        if self._then is not None:
            self._then(done, total)

    def wait_for(self, reading):
        with self.cond:
            self.cond.wait_for(lambda: reading in self.seen)


def open_each_gate_once_seen(fake, readings, first, n):
    """Opens gate first+i once the callback was given (i, n), for each i, so
    that every reading is seen while the run holds."""
    for i in range(n):
        fake.wait_entered(first + i)
        readings.wait_for((i, n))
        fake.open(first + i)


def progress_is_given_each_reading(fake, s):
    readings = Readings()
    opener = on_thread(lambda: open_each_gate_once_seen(fake, readings, 6, 3))
    t = s.sql("steps:6:3", progress=readings).to_arrow()
    opener.join()
    assert t.num_rows == 0, t
    assert readings.seen == [(0, 3), (1, 3), (2, 3), (3, 3)], readings.seen
    assert readings.threads == {MAIN}, readings.threads

    # From another thread: the callback runs on that thread.
    readings = Readings()
    out = []
    opener = on_thread(lambda: open_each_gate_once_seen(fake, readings, 9, 1))
    caller = on_thread(lambda: out.append(s.sql("steps:9:1", progress=readings).to_arrow()))
    caller.join()
    opener.join()
    assert len(out) == 1 and out[0].num_rows == 0, out
    assert readings.seen == [(0, 1), (1, 1)], readings.seen
    assert readings.threads == {caller.ident}, (readings.threads, caller.ident)

    # A plan with no segment: never called.
    readings = Readings()
    assert s.sql("ok", progress=readings).to_arrow().num_rows == 0
    assert readings.seen == [], readings.seen


def an_exception_from_progress_cancels_the_query(fake, s):
    stop = ValueError("stopped at segment 1")

    def raise_at_one(done, total):
        if done == 1:
            raise stop

    readings = Readings(raise_at_one)
    journal, streams = Journal(fake), Streams(fake)
    opener = on_thread(lambda: (fake.wait_entered(10), readings.wait_for((0, 3)), fake.open(10)))
    e = raised(lambda: s.sql("steps:10:3", progress=readings))
    opener.join()
    assert e is stop, repr(e)
    assert readings.seen == [(0, 3), (1, 3)], readings.seen
    lines = journal.lines()
    r = run_number(lines)
    assert lines.index("r{} cancel".format(r)) < lines.index("r{} free".format(r)), lines
    assert streams.since() == (0, 0), streams.since()
    answers(s)

    # Raised on the last reading, once the run answered: the answer is
    # released.
    def raise_at_end(done, total):
        if done == total:
            raise stop

    readings = Readings(raise_at_end)
    streams = Streams(fake)
    opener = on_thread(lambda: (fake.wait_entered(13), readings.wait_for((0, 1)), fake.open(13)))
    e = raised(lambda: s.sql("steps:13:1", progress=readings))
    opener.join()
    assert e is stop and readings.seen == [(0, 1), (1, 1)], (repr(e), readings.seen)
    assert streams.since() == (1, 1), streams.since()
    answers(s)

    # A callback that calls the session is refused, and the refusal stops
    # the query.
    def call_the_session(done, total):
        s.sql("ok")

    e = raised(lambda: s.sql("steps:14:1", progress=call_the_session))
    assert type(e) is KomiraError and str(e) == REENTERED, repr(e)
    answers(s)


def refusals_raise_the_library_message(fake, s):
    journal = Journal(fake)
    e = raised(lambda: s.sql("fail:bind: the stand-in has no table t"))
    assert type(e) is KomiraError and str(e) == "bind: the stand-in has no table t" and e.status == -3, repr(e)
    e = raised(lambda: s.sql("cancelled"))
    assert type(e) is KomiraError and str(e) == CANCELLED, repr(e)
    assert e.status == _native.KOMIRA_ERR_CANCELLED == -6, e.status
    lines = journal.lines()
    news = [line.split()[0] for line in lines if line.startswith("r") and line.endswith(" new")]
    frees = [line.split()[0] for line in lines if line.startswith("r") and line.endswith(" free")]
    assert len(news) == 2 and frees == news, lines
    answers(s)


def the_arguments_are_checked_first(fake, s):
    journal = Journal(fake)
    e = raised(lambda: s.sql("ok", progress=5))
    assert type(e) is TypeError and str(e) == "progress must be callable, not int", repr(e)
    e = raised(lambda: s.sql(1))
    assert type(e) is TypeError and str(e) == "query must be a str, not int", repr(e)
    e = raised(lambda: s.sql("a\0b"))
    assert type(e) is ValueError and str(e) == "query holds a NUL byte", repr(e)
    assert journal.lines() == [], journal.lines()


def an_abandoned_call_makes_no_call(fake, s):
    """A Ctrl-C before the helper thread started its call: the helper makes no
    call and frees the handle; a second stop does nothing."""
    native = _native.load()
    journal = Journal(fake)
    call = _run._Call(native, s._ctx, b"ok", native.run_new())
    call.stop()
    call.stop()
    call._work()
    lines = journal.lines()
    r = run_number(lines)
    assert lines == ["r{} new".format(r), "r{} free".format(r)], lines
    assert call.stream is None and call.error is None


class CancelRaisingOnce:
    """Stands in for `Native.run_cancel`: the first call raises `raises`
    before it cancels, as a second Ctrl-C landing inside it would; every
    later call cancels through the stand-in."""

    def __init__(self, native, raises):
        self._cancel = native.run_cancel
        self._raises = raises
        self.calls = 0

    def __call__(self, run):
        self.calls += 1
        if self.calls == 1:
            raise self._raises
        self._cancel(run)


def a_cancel_an_exception_interrupted_is_made_again(fake, s):
    """An exception raised inside run_cancel, before it cancelled, does not
    lose the cancel: stop makes it again, then frees the handle."""
    native = _native.load()

    # On a call whose run is in flight and has returned (no helper thread,
    # so the order of the journal is the test's own).
    journal = Journal(fake)
    call = _run._Call(native, s._ctx, b"ok", native.run_new())
    call._state = _run._RUNNING
    call.done.set()
    flaky = CancelRaisingOnce(native, KeyboardInterrupt("inside run_cancel"))
    native.run_cancel = flaky
    try:
        call.stop()
    finally:
        del native.run_cancel
    lines = journal.lines()
    r = run_number(lines)
    assert flaky.calls == 2, flaky.calls
    assert lines == ["r{} new".format(r), "r{} cancel".format(r), "r{} free".format(r)], lines

    # Through sql, with a run held until it is cancelled: the run is
    # cancelled, the first KeyboardInterrupt is the one raised, and the
    # session answers after.
    handler = Handler(calls=1)
    signal.signal(signal.SIGINT, handler)
    journal, streams = Journal(fake), Streams(fake)
    flaky = CancelRaisingOnce(native, KeyboardInterrupt("inside run_cancel"))
    native.run_cancel = flaky
    waiter = on_thread(lambda: (fake.wait_entered(18), ctrl_c()))
    try:
        e = raised(lambda: s.sql("hold:18"))
    finally:
        del native.run_cancel
        waiter.join()
        signal.signal(signal.SIGINT, signal.default_int_handler)
    assert type(e) is KeyboardInterrupt and str(e) == "0", repr(e)
    assert flaky.calls == 2 and handler.count == 1, (flaky.calls, handler.count)
    lines = journal.lines()
    r = run_number(lines)
    assert [line for line in lines if line.startswith("r")] == [
        "r{} new".format(r),
        "r{} cancel".format(r),
        "r{} free".format(r),
    ], lines
    assert lines.index("r{} cancel".format(r)) < lines.index("c{} sql_run hold:18 leave".format(s_ctx_number(fake))), lines
    assert streams.since() == (0, 0), streams.since()
    answers(s)


def s_ctx_number(fake):
    """The number of the newest context the stand-in made."""
    news = [line for line in fake.journal() if line.startswith("c") and line.endswith(" new")]
    return int(news[-1].split()[0][1:])


def a_helper_thread_that_cannot_start_frees_its_handle(fake, s):
    """threading cannot start the helper: sql raises its RuntimeError, the
    handle is freed with no call made, and the session answers after."""

    class NoThread:
        def __init__(self, *args, **kwargs):
            pass

        def start(self):
            raise RuntimeError("can't start new thread")

    journal = Journal(fake)
    real = _run.threading.Thread
    _run.threading.Thread = NoThread
    try:
        e = raised(lambda: s.sql("ok"))
    finally:
        _run.threading.Thread = real
    assert type(e) is RuntimeError and str(e) == "can't start new thread", repr(e)
    lines = journal.lines()
    r = run_number(lines)
    assert lines == ["r{} new".format(r), "r{} free".format(r)], lines
    answers(s)


class Records(logging.Handler):
    def __init__(self):
        super().__init__(logging.DEBUG)
        self.lines = []

    def emit(self, record):
        self.lines.append((record.levelname, record.getMessage()))


def the_log_says_what_happened(fake, s, records):
    del records.lines[:]
    waiter = on_thread(lambda: (fake.wait_entered(15), ctrl_c()))
    raised(lambda: s.sql("hold:15"))
    waiter.join()
    readings = Readings()
    opener = on_thread(lambda: open_each_gate_once_seen(fake, readings, 16, 2))
    s.sql("steps:16:2", progress=readings).to_arrow()
    opener.join()
    assert records.lines == [
        ("INFO", "query stopped by KeyboardInterrupt after 0 of 0 plan segments"),
        ("DEBUG", "query answered after 2 of 2 plan segments"),
    ], records.lines


def main(args):
    lib_dir = os.path.abspath(args[args.index("--lib-dir") + 1])
    directory = os.path.join(lib_dir, "fake_run")
    records = Records()
    log = logging.getLogger("komira")
    log.addHandler(records)
    log.setLevel(logging.DEBUG)
    native = _native.load(directory)
    path = os.path.join(directory, _native._LIB_NAME)
    assert records.lines == [("DEBUG", "loaded libkomira ABI 1.6 from {}".format(path))], records.lines
    assert native.abi_version == 1006 and native.has("komira_sql_stream_run"), native.abi_version
    fake = Fake(path)

    # Python's own handler, whatever the process was started with.
    signal.signal(signal.SIGINT, signal.default_int_handler)
    s = komira.Session()
    news = [line for line in fake.journal() if line.startswith("c") and line.endswith(" new")]
    c = int(news[-1].split()[0][1:])

    ctrl_c_cancels_a_running_query(fake, s, c)
    a_second_ctrl_c_while_the_query_stops_is_not_raised(fake, s)
    a_query_answering_after_its_cancel_is_dropped(fake, s, cancels=2)
    a_refusal_during_ctrl_c_raises_the_interrupt(fake, s)
    a_handler_that_does_not_raise_leaves_the_query_running(fake, s)
    progress_is_given_each_reading(fake, s)
    an_exception_from_progress_cancels_the_query(fake, s)
    refusals_raise_the_library_message(fake, s)
    the_arguments_are_checked_first(fake, s)
    an_abandoned_call_makes_no_call(fake, s)
    a_helper_thread_that_cannot_start_frees_its_handle(fake, s)
    a_cancel_an_exception_interrupted_is_made_again(fake, s)
    the_log_says_what_happened(fake, s, records)

    journal = Journal(fake)
    s.close()
    assert journal.lines() == ["c{} free - enter".format(c), "c{} free - leave".format(c)], journal.lines()
    assert fake.overlaps() == 0, fake.journal()
    print("sql_cancel: libkomira {} cancels a query on Ctrl-C and reports its progress".format(komira.abi_version()))


if __name__ == "__main__":
    main(sys.argv[1:])
